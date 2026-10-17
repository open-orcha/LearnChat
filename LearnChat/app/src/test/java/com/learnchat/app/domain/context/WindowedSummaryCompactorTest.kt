package com.learnchat.app.domain.context

import com.learnchat.app.domain.model.AppSettings
import com.learnchat.app.domain.model.Chat
import com.learnchat.app.domain.model.Message
import com.learnchat.app.domain.model.MessagePart
import com.learnchat.app.domain.model.MessageRole
import com.learnchat.app.domain.model.MessageStatus
import com.learnchat.app.domain.repository.ChatRepository
import com.learnchat.app.domain.repository.SettingsRepository
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WindowedSummaryCompactorTest {

    private class FakeRepo(var chat: Chat, var messages: List<Message>) : ChatRepository {
        var savedSummary: Pair<String, Long>? = null
        override fun observeChats(): Flow<List<Chat>> = flowOf(listOf(chat))
        override fun observeChat(chatId: Long): Flow<Chat?> = flowOf(chat)
        override fun observeMessages(chatId: Long): Flow<List<Message>> = flowOf(messages)
        override suspend fun getChat(chatId: Long): Chat? = chat
        override suspend fun getMessages(chatId: Long): List<Message> = messages
        override suspend fun createChat(title: String): Long = 1
        override suspend fun renameChat(chatId: Long, title: String) {}
        override suspend fun deleteChat(chatId: Long) {}
        override suspend fun deleteChatIfEmpty(chatId: Long) {}
        override suspend fun addMessage(chatId: Long, role: MessageRole, parts: List<MessagePart>, status: MessageStatus): Long = 0
        override suspend fun updateMessageContent(messageId: Long, text: String, thinking: String?, status: MessageStatus, error: String?) {}
        override suspend fun updateSummary(chatId: Long, summary: String, throughMessageId: Long) {
            savedSummary = summary to throughMessageId
            chat = chat.copy(summary = summary, summaryThroughMessageId = throughMessageId)
        }
    }

    private class FakeSettings(val s: AppSettings) : SettingsRepository {
        override val settings: Flow<AppSettings> = flowOf(s)
        override suspend fun current(): AppSettings = s
        override suspend fun update(transform: (AppSettings) -> AppSettings) {}
    }

    private fun msg(id: Long, role: MessageRole, text: String) =
        Message(id, 1, role, listOf(MessagePart.Text(text)), MessageStatus.COMPLETE, createdAt = id)

    private fun history(n: Int): List<Message> = (1..n).map { i ->
        msg(i.toLong(), if (i % 2 == 1) MessageRole.USER else MessageRole.ASSISTANT, "message number $i")
    }

    @Test
    fun `short chats are sent verbatim with no summary`() = runBlocking {
        val settings = AppSettings.DEFAULT.copy(verbatimWindow = 6)
        val repo = FakeRepo(Chat(1, "t", 0, 0), history(4))
        val compactor = WindowedSummaryCompactor(repo, FakeSettings(settings), ExtractiveSummarizer())
        val turns = compactor.buildContext(repo.chat, repo.messages, settings)
        assertEquals(4, turns.size)
        assertTrue(turns.none { it.role == MessageRole.SYSTEM })
    }

    @Test
    fun `long chats get a system summary plus the last N verbatim`() = runBlocking {
        val settings = AppSettings.DEFAULT.copy(verbatimWindow = 4)
        val repo = FakeRepo(Chat(1, "t", 0, 0), history(10))
        val compactor = WindowedSummaryCompactor(repo, FakeSettings(settings), ExtractiveSummarizer())
        val turns = compactor.buildContext(repo.chat, repo.messages, settings)
        assertEquals(5, turns.size)
        assertEquals(MessageRole.SYSTEM, turns.first().role)
        val summary = (turns.first().parts.first() as MessagePart.Text).text
        assertTrue(summary.contains("message number 1"))
        assertTrue(!summary.contains("message number 7"))
        assertEquals("message number 7", (turns[1].parts.first() as MessagePart.Text).text)
    }

    @Test
    fun `stored summary is reused and only uncovered older turns are clipped`() = runBlocking {
        val settings = AppSettings.DEFAULT.copy(verbatimWindow = 4)
        val chat = Chat(1, "t", 0, 0, summary = "The user likes tea.", summaryThroughMessageId = 4)
        val repo = FakeRepo(chat, history(10))
        val compactor = WindowedSummaryCompactor(repo, FakeSettings(settings), ExtractiveSummarizer())
        val summary = (compactor.buildContext(repo.chat, repo.messages, settings).first().parts.first() as MessagePart.Text).text
        assertTrue(summary.contains("The user likes tea."))
        assertTrue(!summary.contains("message number 3"))
        assertTrue(summary.contains("message number 5"))
    }

    @Test
    fun `refresh stores a new summary once enough history is outside the window`() = runBlocking {
        val settings = AppSettings.DEFAULT.copy(verbatimWindow = 4)
        val repo = FakeRepo(Chat(1, "t", 0, 0), history(10))
        val compactor = WindowedSummaryCompactor(repo, FakeSettings(settings), ExtractiveSummarizer(), refreshThreshold = 4)
        compactor.refreshSummaryIfNeeded(1)
        val (text, through) = requireNotNull(repo.savedSummary)
        assertEquals(6L, through)
        assertTrue(text.contains("message number 6"))
    }
}
