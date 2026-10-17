package com.qchat.app.domain.preprocess

import com.qchat.app.domain.model.MessagePart

/** What kind of file the user picked, decided from its MIME type. */
enum class AttachmentKind { PDF, IMAGE, VIDEO;
    companion object {
        fun fromMime(mimeType: String?): AttachmentKind? = when {
            mimeType == null -> null
            mimeType == "application/pdf" -> PDF
            mimeType.startsWith("image/") -> IMAGE
            mimeType.startsWith("video/") -> VIDEO
            else -> null
        }
    }
}

/** Progress reported while a file is being processed, for the chip under the composer. */
data class PreprocessProgress(val step: String, val done: Int = 0, val total: Int = 0) {
    val label: String get() = if (total > 0) "$step $done/$total" else step
}

/**
 * Result of on-device preprocessing: the [MessagePart] to attach to the outgoing message (with its
 * derived text filled in) plus a short human summary for the UI, e.g. "12 pages · 4,210 words".
 */
data class PreprocessedAttachment(val part: MessagePart, val summary: String)

/**
 * Turns a user-picked file into a [MessagePart] whose derived text a text-only model can use.
 * All work happens on the phone: PDF text extraction, image OCR + labelling, video frame sampling.
 * The data layer provides the Android implementation; the domain only sees this interface.
 */
interface AttachmentPreprocessor {
    /** Limits the derived text so one attachment cannot swamp the prompt. */
    val maxCharsPerAttachment: Int

    /**
     * @param uri a content:// or file:// URI the app can open
     * @param mimeType as reported by the picker (may be null; the implementation may sniff it)
     * @param displayName the file name to show and to mention to the model
     */
    suspend fun preprocess(
        uri: String,
        mimeType: String?,
        displayName: String?,
        onProgress: (PreprocessProgress) -> Unit = {},
    ): PreprocessedAttachment
}

class UnsupportedAttachmentException(mimeType: String?) :
    Exception("Unsupported file type${mimeType?.let { " ($it)" } ?: ""}. Pick a PDF, photo or video.")
