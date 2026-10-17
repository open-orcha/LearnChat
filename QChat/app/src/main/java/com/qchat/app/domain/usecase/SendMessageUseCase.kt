package com.qchat.app.domain.usecase

import com.qchat.app.domain.context.ContextCompactor
import com.qchat.app.domain.model.ChatRequest
import com.qchat.app.domain.model.ChatTurn
import com.qchat.app.domain.model.MessagePart
import com.qchat.app.domain.model.MessageRole
import com.qchat.app.domain.model.MessageStatus
import com.qchat.app.domain.model.ServerException
import com.qchat.app.domain.model.StreamEvent
import com.qchat.app.domain.model.attachmentLabel
import com.qchat.app.domain.repository.ChatRepository
import com.qchat.app.domain.repository.ChatServerClient
import com.qchat.app.domain.repository.SettingsRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import java.util.concurrent.ConcurrentHashMap

/** What the UI sees while a reply is being produced. */
sealed interface ReplyProgress {
    data class Started(val userMessageId: Long, val assistantMessageId: Long) : ReplyProgress
    data class Thinking(val assistantMessageId: Long, val thinking: String) : ReplyProgress
    data class Content(val assistantMessageId: Long, val text: String, val thinking: String) : ReplyProgress
    data class Finished(val assistantMessageId: Long, val status: MessageStatus, val error: String? = null) : ReplyProgress
}

/**
 * Sends a user message and streams the assistant reply.
 *
 * Flow of a send: persist the user turn → compact history into context → persist an empty
 * assistant turn marked STREAMING → stream deltas (persisting a snapshot every ~400 ms so a killed
 * app keeps partial replies) → finalise → kick off background summary refresh.
 * Cancelling the collector = pressing Stop: the reply is kept with status STOPPED.
 */
class SendMessageUseCase(
    private val repository: ChatRepository,
    private val settings: SettingsRepository,
    private val clientProvider: suspend () -> ChatServerClient,
    private val compactor: ContextCompactor,
    private val leases: ConversationLeaseCoordinator,
    private val backgroundScope: CoroutineScope,
    private val persistIntervalMs: Long = 400,
) {
    private val sessionSendLocks = ConcurrentHashMap<String, Mutex>()

    operator fun invoke(chatId: Long, parts: List<MessagePart>): Flow<ReplyProgress> = flow {
        val initialChat = repository.getChat(chatId) ?: error("chat $chatId missing")
        val sendLock = sessionSendLocks.getOrPut(initialChat.sessionId) { Mutex() }
        sendLock.lock()
        try {
            val userId = repository.addMessage(chatId, MessageRole.USER, parts)
            maybeAutoTitle(chatId, parts)

            val cfg = settings.current()
            val chat = repository.getChat(chatId) ?: error("chat $chatId missing")
            val history = repository.getMessages(chatId)
            val context: List<ChatTurn> = compactor.buildContext(chat, history, cfg)

            val assistantId = repository.addMessage(
                chatId,
                MessageRole.ASSISTANT,
                listOf(MessagePart.Text("")),
                MessageStatus.STREAMING,
            )
            val content = StringBuilder()
            val thinking = StringBuilder()
            var lastPersist = 0L
            var finalStatus = MessageStatus.COMPLETE
            var error: String? = null
            try {
                emit(ReplyProgress.Started(userId, assistantId))
                // Attachments carry a lot of derived text; ask for a bigger context window so
                // the server does not silently truncate their derived text.
                val hasAttachments = context.any { turn -> turn.parts.any { it !is MessagePart.Text } }
                val request = ChatRequest(
                    model = cfg.modelName,
                    turns = context,
                    sessionId = chat.sessionId,
                    sendImages = cfg.sendImagesToModel,
                    contextTokens = if (hasAttachments) ATTACHMENT_CONTEXT_TOKENS else null,
                )
                var attempt = 0
                while (true) {
                    var receivedStreamEvent = false
                    try {
                        clientProvider().streamChat(request).collect { ev ->
                            receivedStreamEvent = true
                            when (ev) {
                                is StreamEvent.ThinkingDelta -> {
                                    thinking.append(ev.text)
                                    emit(ReplyProgress.Thinking(assistantId, thinking.toString()))
                                }
                                is StreamEvent.ContentDelta -> {
                                    content.append(ev.text)
                                    emit(ReplyProgress.Content(assistantId, content.toString(), thinking.toString()))
                                    val now = System.currentTimeMillis()
                                    if (now - lastPersist > persistIntervalMs) {
                                        lastPersist = now
                                        repository.updateMessageContent(assistantId, content.toString(), thinking.toString().ifBlank { null }, MessageStatus.STREAMING)
                                    }
                                }
                                is StreamEvent.Done -> Unit
                            }
                        }
                        break
                    } catch (e: ServerException) {
                        if (e.statusCode != 409 || receivedStreamEvent || attempt >= MAX_CONFLICT_RETRIES) throw e
                        delay(CONFLICT_RETRY_DELAYS_MS[attempt++])
                    }
                }
                leases.markEstablished(chat.sessionId)
            } catch (e: CancellationException) {
                finalStatus = MessageStatus.STOPPED
                // Persist what we have before propagating the cancellation.
                persistFinal(assistantId, content, thinking, finalStatus, null)
                throw e
            } catch (t: Throwable) {
                finalStatus = MessageStatus.FAILED
                error = t.message ?: t.javaClass.simpleName
            }
            persistFinal(assistantId, content, thinking, finalStatus, error)
            emit(ReplyProgress.Finished(assistantId, finalStatus, error))

            if (finalStatus == MessageStatus.COMPLETE) {
                backgroundScope.launch { runCatching { compactor.refreshSummaryIfNeeded(chatId) } }
            }
        } finally {
            sendLock.unlock()
        }
    }

    private companion object {
        /** Context window requested when attachments are in play (muse-glimmer supports 128k). */
        const val ATTACHMENT_CONTEXT_TOKENS = 16_384
        const val MAX_CONFLICT_RETRIES = 5
        val CONFLICT_RETRY_DELAYS_MS = longArrayOf(250, 500, 1_000, 2_000, 2_000)
    }

    private suspend fun persistFinal(id: Long, content: StringBuilder, thinking: StringBuilder, status: MessageStatus, error: String?) {
        // Use a non-cancellable context so Stop still writes the partial reply.
        kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) {
            repository.updateMessageContent(id, content.toString(), thinking.toString().ifBlank { null }, status, error)
        }
    }

    private suspend fun maybeAutoTitle(chatId: Long, parts: List<MessagePart>) {
        val chat = repository.getChat(chatId) ?: return
        if (chat.title != "New chat") return
        val text = parts.filterIsInstance<MessagePart.Text>().joinToString(" ") { it.text }.trim()
            .ifEmpty { parts.firstNotNullOfOrNull { it.attachmentLabel() }.orEmpty() }
        if (text.isEmpty()) return
        val title = text.replace(Regex("\\s+"), " ").take(48).let { if (text.length > 48) "$it…" else it }
        repository.renameChat(chatId, title)
    }
}
