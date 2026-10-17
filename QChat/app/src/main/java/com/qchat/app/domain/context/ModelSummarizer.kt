package com.qchat.app.domain.context

import com.qchat.app.domain.model.ChatRequest
import com.qchat.app.domain.model.ChatTurn
import com.qchat.app.domain.model.Message
import com.qchat.app.domain.model.MessageRole
import com.qchat.app.domain.repository.ChatServerClient
import com.qchat.app.domain.repository.SettingsRepository

/**
 * Asks the model itself to fold older turns into a compact running summary. Falls back to
 * [ExtractiveSummarizer] on any failure so the chat never loses continuity.
 */
class ModelSummarizer(
    private val clientProvider: suspend () -> ChatServerClient,
    private val settings: SettingsRepository,
    private val fallback: Summarizer = ExtractiveSummarizer(),
) : Summarizer {
    override suspend fun summarize(previousSummary: String?, messages: List<Message>): String {
        val transcript = buildString {
            for (m in messages) {
                append(if (m.role == MessageRole.USER) "User: " else "Assistant: ")
                append(m.briefText.trim()).append("\n\n")
            }
        }
        val prompt = buildString {
            append("You are compressing a chat history so the conversation can continue later with less context.\n")
            if (!previousSummary.isNullOrBlank()) {
                append("Existing summary of earlier turns:\n").append(previousSummary.trim()).append("\n\n")
            }
            append("New turns to fold into the summary:\n").append(transcript)
            append("Write an updated summary in at most 120 words. Keep facts, names, numbers, decisions, ")
            append("user preferences and anything the user asked to remember. Plain prose, no preamble.")
        }
        return try {
            val model = settings.current().modelName
            val out = clientProvider().complete(
                ChatRequest(model = model, turns = listOf(ChatTurn.text(MessageRole.USER, prompt)), includeThinking = false),
            ).trim()
            if (out.isBlank()) fallback.summarize(previousSummary, messages) else out
        } catch (t: Throwable) {
            fallback.summarize(previousSummary, messages)
        }
    }
}
