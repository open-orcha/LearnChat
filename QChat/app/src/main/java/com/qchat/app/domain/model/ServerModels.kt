package com.qchat.app.domain.model

/** A turn as sent to the server: role + parts. Kept transport-agnostic. */
data class ChatTurn(val role: MessageRole, val parts: List<MessagePart>) {
    companion object {
        fun text(role: MessageRole, text: String) = ChatTurn(role, listOf(MessagePart.Text(text)))
    }
}

data class ChatRequest(
    val model: String,
    val turns: List<ChatTurn>,
    /** Stable local conversation ID used by the runtime to reuse and renew its cache. */
    val sessionId: String? = null,
    /** Ask the server for its reasoning trace when supported. */
    val includeThinking: Boolean = true,
    /** Attach photo pixels for vision-capable models (see AppSettings.sendImagesToModel). */
    val sendImages: Boolean = false,
    /**
     * Context window to request for this call, in tokens. Attachments need a larger window so
     * their derived text is not silently dropped. Null = server default.
     */
    val contextTokens: Int? = null,
)

/** Events emitted while a reply streams in. */
sealed interface StreamEvent {
    /** A chunk of the model's reasoning trace (may arrive before any content). */
    data class ThinkingDelta(val text: String) : StreamEvent
    /** A chunk of the visible reply. */
    data class ContentDelta(val text: String) : StreamEvent
    /** Stream ended normally. */
    data class Done(val totalDurationMs: Long? = null, val outputTokens: Int? = null) : StreamEvent
}

data class ServerInfo(val reachable: Boolean, val models: List<String>, val detail: String? = null)

class ServerException(
    message: String,
    cause: Throwable? = null,
    val statusCode: Int? = null,
) : Exception(message, cause)

enum class HeartbeatResult { RENEWED, MISSING }
