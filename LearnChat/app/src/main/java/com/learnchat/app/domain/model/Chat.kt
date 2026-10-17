package com.learnchat.app.domain.model

data class Chat(
    val id: Long,
    val title: String,
    val createdAt: Long,
    val updatedAt: Long,
    /** Stable opaque ID sent to the runtime for this conversation's cache lease. */
    val sessionId: String = "",
    /** Last message preview for the chat list. */
    val preview: String = "",
    /** Rolling summary of older turns (see ContextCompactor). */
    val summary: String? = null,
    /** Id of the last message covered by [summary]; older messages are folded into it. */
    val summaryThroughMessageId: Long? = null,
)
