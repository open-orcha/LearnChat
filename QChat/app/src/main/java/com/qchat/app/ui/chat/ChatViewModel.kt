package com.qchat.app.ui.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.qchat.app.domain.model.AppSettings
import com.qchat.app.domain.model.Chat
import com.qchat.app.domain.model.Message
import com.qchat.app.domain.model.MessagePart
import com.qchat.app.domain.model.MessageStatus
import com.qchat.app.domain.preprocess.AttachmentKind
import com.qchat.app.domain.preprocess.AttachmentPreprocessor
import com.qchat.app.domain.repository.ChatRepository
import com.qchat.app.domain.repository.SettingsRepository
import com.qchat.app.domain.usecase.ReplyProgress
import com.qchat.app.domain.usecase.SendMessageUseCase
import com.qchat.app.domain.usecase.ConversationLeaseCoordinator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** In-memory view of the reply currently streaming in (not yet fully persisted). */
data class StreamingReply(
    val messageId: Long,
    val text: String = "",
    val thinking: String = "",
) {
    /** True until the first visible token arrives — drives the typing indicator. */
    val waitingForFirstToken: Boolean get() = text.isEmpty()
}

enum class AttachmentState { PROCESSING, READY, FAILED }

/** A file the user picked for the next message, being (or already) preprocessed on the phone. */
data class PendingAttachment(
    val id: Long,
    val name: String,
    val kind: AttachmentKind?,
    val state: AttachmentState = AttachmentState.PROCESSING,
    /** Progress label while processing, e.g. "Reading page 3/12". */
    val progress: String? = null,
    /** Short result once ready, e.g. "12 pages · 4,210 words". */
    val summary: String? = null,
    val error: String? = null,
    val part: MessagePart? = null,
)

data class ChatUiState(
    val chat: Chat? = null,
    val messages: List<Message> = emptyList(),
    val streaming: StreamingReply? = null,
    val showThinking: Boolean = false,
    val error: String? = null,
    val pending: List<PendingAttachment> = emptyList(),
) {
    val isSending: Boolean get() = streaming != null
    val isPreprocessing: Boolean get() = pending.any { it.state == AttachmentState.PROCESSING }
    val hasReadyAttachment: Boolean get() = pending.any { it.state == AttachmentState.READY }
}

class ChatViewModel(
    private val chatId: Long,
    private val repository: ChatRepository,
    settings: SettingsRepository,
    private val sendMessage: SendMessageUseCase,
    private val leases: ConversationLeaseCoordinator,
    private val cleanupScope: CoroutineScope,
    private val preprocessor: AttachmentPreprocessor,
) : ViewModel() {

    private val streaming = MutableStateFlow<StreamingReply?>(null)
    private val error = MutableStateFlow<String?>(null)
    private val pending = MutableStateFlow<List<PendingAttachment>>(emptyList())
    private val preprocessJobs = mutableMapOf<Long, Job>()
    private var nextAttachmentId = 1L
    private var sendJob: Job? = null
    private var screenVisible = false
    private var leaseSessionId: String? = null
    private var hasConversation = false

    init {
        viewModelScope.launch {
            combine(repository.observeChat(chatId), repository.observeMessages(chatId)) { chat, messages ->
                chat?.sessionId to messages.isNotEmpty()
            }.distinctUntilChanged().collect { (sessionId, hasMessages) ->
                leaseSessionId = sessionId
                hasConversation = hasMessages
                syncLeaseVisibility()
            }
        }
    }

    val state: StateFlow<ChatUiState> = combine(
        repository.observeChat(chatId),
        repository.observeMessages(chatId),
        streaming,
        settings.settings,
        error,
        pending,
    ) { values ->
        @Suppress("UNCHECKED_CAST")
        val chat = values[0] as Chat?
        @Suppress("UNCHECKED_CAST")
        val messages = values[1] as List<Message>
        val streaming = values[2] as StreamingReply?
        val cfg = values[3] as AppSettings
        val err = values[4] as String?
        @Suppress("UNCHECKED_CAST")
        val pending = values[5] as List<PendingAttachment>
        // Overlay the live streaming text onto the persisted (throttled) copy of the same message.
        val merged = if (streaming == null) messages else messages.map { m ->
            if (m.id == streaming.messageId) m.copy(
                parts = listOf(MessagePart.Text(streaming.text)),
                thinking = streaming.thinking.ifBlank { null },
                status = MessageStatus.STREAMING,
            ) else m
        }
        ChatUiState(chat, merged, streaming, cfg.showThinking, err, pending)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), ChatUiState())

    /** Start preprocessing a picked file right away so it is ready by the time the user hits Send. */
    fun attach(uri: String, mimeType: String?, displayName: String?) {
        val id = nextAttachmentId++
        val kind = AttachmentKind.fromMime(mimeType)
        pending.update { it + PendingAttachment(id, displayName ?: "Attachment", kind, progress = "Preparing") }
        preprocessJobs[id] = viewModelScope.launch {
            try {
                val result = preprocessor.preprocess(uri, mimeType, displayName) { progress ->
                    pending.update { list -> list.map { if (it.id == id) it.copy(progress = progress.label) else it } }
                }
                pending.update { list ->
                    list.map {
                        if (it.id == id) it.copy(
                            state = AttachmentState.READY, progress = null, summary = result.summary, part = result.part,
                            name = (result.part as? MessagePart.File)?.name ?: (result.part as? MessagePart.Image)?.name ?: it.name,
                            kind = kind ?: AttachmentKind.fromMime((result.part as? MessagePart.Image)?.mimeType ?: (result.part as? MessagePart.File)?.mimeType),
                        ) else it
                    }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (t: Throwable) {
                pending.update { list ->
                    list.map { if (it.id == id) it.copy(state = AttachmentState.FAILED, progress = null, error = t.message ?: "Couldn't process this file") else it }
                }
            } finally {
                preprocessJobs.remove(id)
            }
        }
    }

    fun removeAttachment(id: Long) {
        preprocessJobs.remove(id)?.cancel()
        pending.update { list -> list.filterNot { it.id == id } }
    }

    fun send(text: String) {
        val trimmed = text.trim()
        val current = pending.value
        if (current.any { it.state == AttachmentState.PROCESSING }) return
        val attachments = current.filter { it.state == AttachmentState.READY }.mapNotNull { it.part }
        if ((trimmed.isEmpty() && attachments.isEmpty()) || sendJob?.isActive == true) return
        val parts = buildList {
            if (trimmed.isNotEmpty()) add(MessagePart.Text(trimmed))
            addAll(attachments)
        }
        pending.value = emptyList()
        error.value = null
        sendJob = viewModelScope.launch {
            try {
                sendMessage(chatId, parts).collect { p ->
                    when (p) {
                        is ReplyProgress.Started -> streaming.value = StreamingReply(p.assistantMessageId)
                        is ReplyProgress.Thinking -> streaming.update { it?.copy(thinking = p.thinking) }
                        is ReplyProgress.Content -> streaming.update { it?.copy(text = p.text, thinking = p.thinking) }
                        is ReplyProgress.Finished -> {
                            if (p.status == MessageStatus.FAILED) error.value = p.error ?: "Something went wrong"
                            streaming.value = null
                        }
                    }
                }
            } finally {
                streaming.value = null
            }
        }
    }

    fun stop() {
        sendJob?.cancel()
        sendJob = null
        streaming.value = null
    }

    fun dismissError() { error.value = null }

    /** Called from the destination lifecycle, not merely composition, so backgrounding stops pulses. */
    fun setScreenVisible(visible: Boolean) {
        if (screenVisible == visible) return
        screenVisible = visible
        syncLeaseVisibility()
    }

    private fun syncLeaseVisibility() {
        val sessionId = leaseSessionId
        if (screenVisible && !sessionId.isNullOrBlank()) {
            leases.activate(this, sessionId, hasConversation)
        } else {
            leases.deactivate(this)
        }
    }

    override fun onCleared() {
        // Leaving the screen behaves like Stop; the partial reply is kept.
        sendJob?.cancel()
        leases.deactivate(this)
        // Don't leave an empty "New chat" behind if the user backed out without sending.
        cleanupScope.launch { runCatching { repository.deleteChatIfEmpty(chatId) } }
    }
}
