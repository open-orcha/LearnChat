package com.learnchat.app.domain.repository

import com.learnchat.app.domain.model.ChatRequest
import com.learnchat.app.domain.model.HeartbeatResult
import com.learnchat.app.domain.model.ServerInfo
import com.learnchat.app.domain.model.StreamEvent
import kotlinx.coroutines.flow.Flow

/**
 * Transport abstraction over the inference server. The UI and repository only ever see this
 * interface, so swapping the current service for another backend (SSE, websocket audio, ...)
 * is a data-layer change.
 */
interface ChatServerClient {
    /** Stream a reply; cancelling the collecting coroutine aborts the HTTP call. */
    fun streamChat(request: ChatRequest): Flow<StreamEvent>

    /** Non-streaming completion, used for background jobs such as summarisation. */
    suspend fun complete(request: ChatRequest): String

    /** Renew a conversation cache lease. A missing lease is recoverable on the next full send. */
    suspend fun heartbeat(sessionId: String): HeartbeatResult

    suspend fun ping(): ServerInfo
}
