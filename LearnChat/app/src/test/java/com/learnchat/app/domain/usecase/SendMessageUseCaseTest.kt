package com.learnchat.app.domain.usecase

import com.learnchat.app.domain.context.ContextCompactor
import com.learnchat.app.domain.model.AppSettings
import com.learnchat.app.domain.model.Chat
import com.learnchat.app.domain.model.ChatRequest
import com.learnchat.app.domain.model.ChatTurn
import com.learnchat.app.domain.model.HeartbeatResult
import com.learnchat.app.domain.model.Message
import com.learnchat.app.domain.model.MessagePart
import com.learnchat.app.domain.model.MessageRole
import com.learnchat.app.domain.model.MessageStatus
import com.learnchat.app.domain.model.ServerException
import com.learnchat.app.domain.model.ServerInfo
import com.learnchat.app.domain.model.StreamEvent
import com.learnchat.app.domain.repository.ChatRepository
import com.learnchat.app.domain.repository.ChatServerClient
import com.learnchat.app.domain.repository.SettingsRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class SendMessageUseCaseTest {

    @Test
    fun `transient conflict retries transport without duplicating local messages`() = runBlocking {
        val repo = FakeRepo()
        val client = ConflictThenSuccessClient()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val leases = ConversationLeaseCoordinator(scope, { client }, heartbeatIntervalMs = 10_000)
        val useCase = SendMessageUseCase(
            repository = repo,
            settings = FakeSettings,
            clientProvider = { client },
            compactor = FakeCompactor,
            leases = leases,
            backgroundScope = scope,
            persistIntervalMs = 0,
        )

        val progress = mutableListOf<ReplyProgress>()
        useCase(1, listOf(MessagePart.Text("hello"))).collect(progress::add)

        assertEquals(2, client.attempts)
        assertEquals("stable-session", client.requests.single().sessionId)
        assertEquals(1, repo.added.count { it.role == MessageRole.USER })
        assertEquals(1, repo.added.count { it.role == MessageRole.ASSISTANT })
        assertEquals(MessageStatus.COMPLETE, repo.finalStatus)
        assertTrue(progress.last() is ReplyProgress.Finished)
        scope.cancel()
    }

    @Test
    fun `same session sends are fully serialized`() = runBlocking {
        val repo = FakeRepo()
        val client = SerialClient()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val leases = ConversationLeaseCoordinator(scope, { client }, heartbeatIntervalMs = 10_000)
        val useCase = SendMessageUseCase(
            repo,
            FakeSettings,
            { client },
            FakeCompactor,
            leases,
            scope,
        )

        coroutineScope {
            listOf("one", "two").map { text ->
                async { useCase(1, listOf(MessagePart.Text(text))).collect { } }
            }.awaitAll()
        }

        assertEquals(1, client.maxActive.get())
        assertEquals(2, repo.added.count { it.role == MessageRole.USER })
        assertEquals(2, repo.added.count { it.role == MessageRole.ASSISTANT })
        scope.cancel()
    }

    @Test
    fun `stop keeps partial reply and releases session lock for immediate send`() = runBlocking {
        val repo = FakeRepo()
        val firstChunk = CompletableDeferred<Unit>()
        val client = CancelThenSuccessClient(firstChunk)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val leases = ConversationLeaseCoordinator(scope, { client }, heartbeatIntervalMs = 10_000)
        val useCase = SendMessageUseCase(
            repository = repo,
            settings = FakeSettings,
            clientProvider = { client },
            compactor = FakeCompactor,
            leases = leases,
            backgroundScope = scope,
            persistIntervalMs = 0,
        )

        val firstSend = launch {
            useCase(1, listOf(MessagePart.Text("first prompt"))).collect { }
        }
        withTimeout(1_000) { firstChunk.await() }
        firstSend.cancel()
        withTimeout(800) { firstSend.join() }

        val secondProgress = mutableListOf<ReplyProgress>()
        withTimeout(1_000) {
            useCase(1, listOf(MessagePart.Text("second prompt"))).collect(secondProgress::add)
        }

        val assistants = repo.added.filter { it.role == MessageRole.ASSISTANT }
        assertEquals(2, client.attempts)
        assertEquals(2, repo.added.count { it.role == MessageRole.USER })
        assertEquals(2, assistants.size)
        assertEquals(MessageStatus.STOPPED, repo.updates.getValue(assistants[0].id).status)
        assertEquals("partial", repo.updates.getValue(assistants[0].id).text)
        assertEquals(MessageStatus.COMPLETE, repo.updates.getValue(assistants[1].id).status)
        assertEquals("second reply", repo.updates.getValue(assistants[1].id).text)
        assertTrue(secondProgress.last() is ReplyProgress.Finished)
        scope.cancel()
    }

    private class FakeRepo : ChatRepository {
        data class Added(val id: Long, val role: MessageRole, val parts: List<MessagePart>, val status: MessageStatus)
        data class Update(val text: String, val thinking: String?, val status: MessageStatus, val error: String?)

        private val chat = Chat(1, "Chat", 0, 0, sessionId = "stable-session")
        val added = mutableListOf<Added>()
        private val messages = mutableListOf<Message>()
        val updates = mutableMapOf<Long, Update>()
        var finalStatus: MessageStatus? = null
        private var nextId = 1L

        override fun observeChats(): Flow<List<Chat>> = flowOf(listOf(chat))
        override fun observeChat(chatId: Long): Flow<Chat?> = flowOf(chat)
        override fun observeMessages(chatId: Long): Flow<List<Message>> = flowOf(messages)
        override suspend fun getChat(chatId: Long): Chat = chat
        override suspend fun getMessages(chatId: Long): List<Message> = messages.toList()
        override suspend fun createChat(title: String): Long = 1
        override suspend fun renameChat(chatId: Long, title: String) = Unit
        override suspend fun deleteChat(chatId: Long) = Unit
        override suspend fun deleteChatIfEmpty(chatId: Long) = Unit
        override suspend fun addMessage(
            chatId: Long,
            role: MessageRole,
            parts: List<MessagePart>,
            status: MessageStatus,
        ): Long {
            val id = nextId++
            added += Added(id, role, parts, status)
            messages += Message(id, chatId, role, parts, status, createdAt = id)
            return id
        }
        override suspend fun updateMessageContent(
            messageId: Long,
            text: String,
            thinking: String?,
            status: MessageStatus,
            error: String?,
        ) {
            finalStatus = status
            updates[messageId] = Update(text, thinking, status, error)
        }
        override suspend fun updateSummary(chatId: Long, summary: String, throughMessageId: Long) = Unit
    }

    private object FakeSettings : SettingsRepository {
        override val settings: Flow<AppSettings> = flowOf(AppSettings.DEFAULT)
        override suspend fun current(): AppSettings = AppSettings.DEFAULT
        override suspend fun update(transform: (AppSettings) -> AppSettings) = Unit
    }

    private object FakeCompactor : ContextCompactor {
        override suspend fun buildContext(
            chat: Chat,
            history: List<Message>,
            settings: AppSettings,
        ): List<ChatTurn> = history.map { ChatTurn(it.role, it.parts) }
        override suspend fun refreshSummaryIfNeeded(chatId: Long) = Unit
    }

    private class ConflictThenSuccessClient : ChatServerClient {
        var attempts = 0
        val requests = mutableListOf<ChatRequest>()

        override fun streamChat(request: ChatRequest): Flow<StreamEvent> = flow {
            attempts += 1
            if (attempts == 1) throw ServerException("busy", statusCode = 409)
            requests += request
            emit(StreamEvent.ContentDelta("reply"))
            emit(StreamEvent.Done())
        }
        override suspend fun complete(request: ChatRequest): String = ""
        override suspend fun heartbeat(sessionId: String): HeartbeatResult = HeartbeatResult.RENEWED
        override suspend fun ping(): ServerInfo = ServerInfo(true, emptyList())
    }

    private class SerialClient : ChatServerClient {
        private val active = AtomicInteger()
        val maxActive = AtomicInteger()

        override fun streamChat(request: ChatRequest): Flow<StreamEvent> = flow {
            val nowActive = active.incrementAndGet()
            maxActive.updateAndGet { maxOf(it, nowActive) }
            try {
                delay(40)
                emit(StreamEvent.Done())
            } finally {
                active.decrementAndGet()
            }
        }
        override suspend fun complete(request: ChatRequest): String = ""
        override suspend fun heartbeat(sessionId: String): HeartbeatResult = HeartbeatResult.RENEWED
        override suspend fun ping(): ServerInfo = ServerInfo(true, emptyList())
    }

    private class CancelThenSuccessClient(
        private val firstChunk: CompletableDeferred<Unit>,
    ) : ChatServerClient {
        var attempts = 0

        override fun streamChat(request: ChatRequest): Flow<StreamEvent> = flow {
            attempts += 1
            if (attempts == 1) {
                emit(StreamEvent.ContentDelta("partial"))
                firstChunk.complete(Unit)
                awaitCancellation()
            }
            emit(StreamEvent.ContentDelta("second reply"))
            emit(StreamEvent.Done())
        }

        override suspend fun complete(request: ChatRequest): String = ""
        override suspend fun heartbeat(sessionId: String): HeartbeatResult = HeartbeatResult.RENEWED
        override suspend fun ping(): ServerInfo = ServerInfo(true, emptyList())
    }
}
