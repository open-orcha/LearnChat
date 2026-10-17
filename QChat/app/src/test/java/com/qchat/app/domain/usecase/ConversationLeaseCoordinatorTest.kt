package com.qchat.app.domain.usecase

import com.qchat.app.domain.model.ChatRequest
import com.qchat.app.domain.model.HeartbeatResult
import com.qchat.app.domain.model.ServerInfo
import com.qchat.app.domain.model.StreamEvent
import com.qchat.app.domain.repository.ChatServerClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class ConversationLeaseCoordinatorTest {

    @Test
    fun `empty chat stays quiet and successful send starts renewal`() = runBlocking {
        val fake = FakeClient(HeartbeatResult.RENEWED)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val coordinator = ConversationLeaseCoordinator(scope, { fake }, heartbeatIntervalMs = 25)
        val owner = Any()

        coordinator.activate(owner, "conversation", hasConversation = false)
        delay(60)
        assertEquals(0, fake.calls.get())

        coordinator.markEstablished("conversation")
        awaitCalls(fake, 1)
        coordinator.deactivate(owner)
        scope.cancel()
    }

    @Test
    fun `missing session pauses until a send re-establishes it`() = runBlocking {
        val fake = FakeClient(HeartbeatResult.MISSING)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val coordinator = ConversationLeaseCoordinator(scope, { fake }, heartbeatIntervalMs = 20)
        val owner = Any()

        coordinator.activate(owner, "conversation", hasConversation = true)
        awaitCalls(fake, 1)
        delay(60)
        assertEquals(1, fake.calls.get())

        fake.result = HeartbeatResult.RENEWED
        coordinator.markEstablished("conversation")
        awaitCalls(fake, 2)
        coordinator.deactivate(owner)
        scope.cancel()
    }

    @Test
    fun `duplicate activation has one loop and backgrounding stops it`() = runBlocking {
        val fake = FakeClient(HeartbeatResult.RENEWED)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val coordinator = ConversationLeaseCoordinator(scope, { fake }, heartbeatIntervalMs = 200)
        val owner = Any()

        coordinator.activate(owner, "conversation", hasConversation = true)
        awaitCalls(fake, 1)
        coordinator.activate(owner, "conversation", hasConversation = true)
        delay(50)
        assertEquals(1, fake.calls.get())

        coordinator.deactivate(owner)
        delay(250)
        assertEquals(1, fake.calls.get())
        scope.cancel()
    }

    private suspend fun awaitCalls(fake: FakeClient, expected: Int) {
        withTimeout(2_000) {
            while (fake.calls.get() < expected) delay(5)
        }
    }

    private class FakeClient(initialResult: HeartbeatResult) : ChatServerClient {
        val calls = AtomicInteger()
        @Volatile var result = initialResult

        override fun streamChat(request: ChatRequest): Flow<StreamEvent> = emptyFlow()
        override suspend fun complete(request: ChatRequest): String = ""
        override suspend fun heartbeat(sessionId: String): HeartbeatResult {
            calls.incrementAndGet()
            return result
        }
        override suspend fun ping(): ServerInfo = ServerInfo(true, emptyList())
    }
}
