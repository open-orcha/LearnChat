package com.qchat.app.domain.model

/** Who authored a message. Mirrors the roles the server understands. */
enum class MessageRole { USER, ASSISTANT, SYSTEM }

/** Lifecycle of a message on the device. */
enum class MessageStatus {
    /** Fully written, safe to send as history. */
    COMPLETE,
    /** Assistant reply still arriving token-by-token. */
    STREAMING,
    /** User pressed Stop before the reply finished. */
    STOPPED,
    /** The request failed; [Message.error] explains why. */
    FAILED,
}

/**
 * One piece of a message. A message is a list of parts so that images, files and audio can be
 * added without changing the message table or the UI list.
 *
 * Attachments carry the text the phone derived from them ([Image.extractedText],
 * [File.extractedText]) — that derived text is what a text-only model actually receives; see
 * [promptText]. The original file stays on the phone (copied into app storage, see `uri`).
 */
sealed interface MessagePart {
    data class Text(val text: String) : MessagePart

    /**
     * A photo, or a video (when [mimeType] starts with `video/`; then [uri] points at the copied
     * clip and [thumbnailUri] at a first-frame JPEG). [extractedText] is the on-device
     * description (labels + OCR, or a frame-by-frame timeline for video).
     */
    data class Image(
        val uri: String,
        val mimeType: String,
        val width: Int? = null,
        val height: Int? = null,
        val name: String? = null,
        val extractedText: String? = null,
        val thumbnailUri: String? = null,
    ) : MessagePart {
        val isVideo: Boolean get() = mimeType.startsWith("video/")
    }

    /** A document (PDF today). [extractedText] is its text layer, extracted on the phone. */
    data class File(
        val uri: String,
        val name: String,
        val mimeType: String,
        val sizeBytes: Long? = null,
        val extractedText: String? = null,
        val pageCount: Int? = null,
    ) : MessagePart

    data class Audio(val uri: String, val mimeType: String, val durationMs: Long? = null, val transcript: String? = null) : MessagePart
}

/** Short human label for an attachment part, e.g. `PDF "report.pdf"`. */
fun MessagePart.attachmentLabel(): String? = when (this) {
    is MessagePart.Text -> null
    is MessagePart.Image -> (if (isVideo) "video" else "photo") + (name?.let { " \"$it\"" } ?: "")
    is MessagePart.File -> "PDF \"$name\""
    is MessagePart.Audio -> "audio clip"
}

/**
 * What the model receives for this part. Text is passed through; attachments become a clearly
 * delimited block of the text the phone derived from them, so a text-only model can reason about
 * a PDF, photo or video it cannot see.
 */
fun MessagePart.promptText(): String = when (this) {
    is MessagePart.Text -> text
    is MessagePart.File -> {
        val pages = pageCount?.let { ", $it page${if (it == 1) "" else "s"}" } ?: ""
        val body = extractedText?.takeIf { it.isNotBlank() } ?: "(no readable text could be extracted from this file)"
        "[Attached PDF: \"$name\"$pages — text extracted on the user's phone]\n$body\n[End of \"$name\"]"
    }
    is MessagePart.Image -> {
        val kind = if (isVideo) "video" else "photo"
        val title = name?.let { " \"$it\"" } ?: ""
        val body = extractedText?.takeIf { it.isNotBlank() } ?: "(the phone could not make out anything in it)"
        "[Attached $kind$title — you cannot see it, so the user's phone analysed it on-device. What it found:]\n$body\n[End of $kind]"
    }
    is MessagePart.Audio -> transcript?.let { "[Attached audio clip, transcript]\n$it\n[End of audio]" } ?: "[Attached audio clip]"
}

data class Message(
    val id: Long,
    val chatId: Long,
    val role: MessageRole,
    val parts: List<MessagePart>,
    val status: MessageStatus = MessageStatus.COMPLETE,
    /** Model reasoning trace (if the server sends one). Hidden by default in the UI. */
    val thinking: String? = null,
    val error: String? = null,
    val createdAt: Long,
) {
    /** Convenience: all text parts joined (what the user typed / the model replied). */
    val text: String get() = parts.filterIsInstance<MessagePart.Text>().joinToString("\n") { it.text }

    /** Attachment parts only (images, videos, files, audio). */
    val attachments: List<MessagePart> get() = parts.filter { it !is MessagePart.Text }

    /** Full content as sent to the model: typed text plus the derived text of every attachment. */
    val promptText: String get() = parts.joinToString("\n\n") { it.promptText() }.trim()

    /** Typed text plus a one-line mention per attachment — for summaries, previews and titles. */
    val briefText: String
        get() {
            val tags = attachments.mapNotNull { it.attachmentLabel() }
            return if (tags.isEmpty()) text else (text + "\n[attached: ${tags.joinToString(", ")}]").trim()
        }
}
