package com.learnchat.app.domain.context

import com.learnchat.app.domain.model.AppSettings
import com.learnchat.app.domain.model.Chat
import com.learnchat.app.domain.model.ChatTurn
import com.learnchat.app.domain.model.Message
import com.learnchat.app.domain.model.MessagePart
import com.learnchat.app.domain.model.MessageRole
import com.learnchat.app.domain.model.MessageStatus
import com.learnchat.app.domain.repository.ChatRepository
import com.learnchat.app.domain.repository.SettingsRepository
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Simple on-device compaction:
 *  - the last [AppSettings.verbatimWindow] messages are sent word-for-word;
 *  - everything older is replaced by one short rolling summary (kept on the chat row);
 *  - a rough token budget clips the verbatim window if messages are very long;
 *  - older messages not yet covered by the stored summary are clipped extractively so the
 *    prompt is always coherent even before the background summariser has caught up.
 */
class WindowedSummaryCompactor(
    private val repository: ChatRepository,
    private val settingsRepository: SettingsRepository,
    private val summarizer: Summarizer,
    private val quickSummarizer: Summarizer = ExtractiveSummarizer(),
    private val tokenBudget: Int = 6000,
    /** Refresh the model summary once this many uncovered messages sit outside the window. */
    private val refreshThreshold: Int = 4,
) : ContextCompactor {

    private val refreshLock = Mutex()

    override suspend fun buildContext(chat: Chat, history: List<Message>, settings: AppSettings): List<ChatTurn> {
        val usable = history.filter { it.status != MessageStatus.FAILED && it.promptText.isNotBlank() }
        val window = settings.verbatimWindow.coerceAtLeast(2)
        var verbatim = usable.takeLast(window)
        var older = usable.dropLast(verbatim.size)

        // Clip the verbatim window to the token budget, moving overflow into "older".
        while (verbatim.size > 2 && estimateTokens(verbatim) > tokenBudget) {
            older = older + verbatim.first()
            verbatim = verbatim.drop(1)
        }

        val turns = mutableListOf<ChatTurn>()
        val summaryText = summaryFor(chat, older)
        if (summaryText.isNotBlank()) {
            turns += ChatTurn.text(
                MessageRole.SYSTEM,
                "You are continuing an earlier conversation with this user. Summary of what was said before:\n" +
                    summaryText + "\nContinue naturally and stay consistent with it.",
            )
        }
        verbatim.forEach { m -> turns += ChatTurn(m.role, m.parts.ifEmpty { listOf(MessagePart.Text(m.text)) }) }
        return turns
    }

    /** Stored summary + extractive clip of anything older that the stored summary doesn't cover yet. */
    private suspend fun summaryFor(chat: Chat, older: List<Message>): String {
        if (older.isEmpty()) return ""
        val coveredThrough = chat.summaryThroughMessageId ?: -1L
        val uncovered = older.filter { it.id > coveredThrough }
        val stored = chat.summary?.takeIf { coveredThrough >= 0 }
        return if (uncovered.isEmpty()) stored.orEmpty() else quickSummarizer.summarize(stored, uncovered)
    }

    override suspend fun refreshSummaryIfNeeded(chatId: Long) = refreshLock.withLock {
        val chat = repository.getChat(chatId) ?: return
        val settings = settingsRepository.current()
        val usable = repository.getMessages(chatId).filter { it.status == MessageStatus.COMPLETE && it.promptText.isNotBlank() }
        val older = usable.dropLast(settings.verbatimWindow.coerceAtLeast(2))
        val coveredThrough = chat.summaryThroughMessageId ?: -1L
        val uncovered = older.filter { it.id > coveredThrough }
        if (uncovered.size < refreshThreshold) return
        val summary = summarizer.summarize(chat.summary, uncovered)
        repository.updateSummary(chatId, summary, uncovered.last().id)
    }

    /** Rough chars/4 estimate over what is actually sent (typed text + derived attachment text). */
    private fun estimateTokens(messages: List<Message>): Int = messages.sumOf { (it.promptText.length + 3) / 4 }
}
