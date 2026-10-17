package com.qchat.app.domain.context

import com.qchat.app.domain.model.AppSettings
import com.qchat.app.domain.model.Chat
import com.qchat.app.domain.model.ChatTurn
import com.qchat.app.domain.model.Message

/**
 * Turns a chat's full local history into the (smaller) context that is sent with a new prompt.
 * Keeping this behind an interface lets us swap the strategy later (embedding retrieval,
 * server-side compaction, ...) without touching the UI or repository.
 */
interface ContextCompactor {
    /** Build the turns to send ahead of the new user prompt (prompt itself is the last item of [history]). */
    suspend fun buildContext(chat: Chat, history: List<Message>, settings: AppSettings): List<ChatTurn>

    /**
     * Refresh the chat's rolling summary if enough un-summarised history has piled up outside the
     * verbatim window. Slow (may call the model) — run it in the background after a reply finishes.
     */
    suspend fun refreshSummaryIfNeeded(chatId: Long)
}

/** Produces a short summary of older turns. */
interface Summarizer {
    suspend fun summarize(previousSummary: String?, messages: List<Message>): String
}
