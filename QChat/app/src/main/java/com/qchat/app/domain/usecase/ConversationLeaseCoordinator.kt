package com.qchat.app.domain.usecase

import com.qchat.app.domain.model.HeartbeatResult
import com.qchat.app.domain.repository.ChatServerClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.job
import kotlinx.coroutines.launch

/**
 * Owns conversation heartbeat loops for the process. ViewModels register only while their chat
 * destination is resumed, which also stops renewals when the app is backgrounded. Sessions are
 * never explicitly deleted here: once a screen leaves, the runtime lease expires naturally.
 */
class ConversationLeaseCoordinator(
    private val scope: CoroutineScope,
    private val clientProvider: suspend () -> ChatServerClient,
    private val heartbeatIntervalMs: Long = DEFAULT_HEARTBEAT_INTERVAL_MS,
) {
    private data class SessionState(
        val owners: MutableSet<Any> = mutableSetOf(),
        var established: Boolean = false,
        var job: Job? = null,
    )

    private val lock = Any()
    private val sessions = mutableMapOf<String, SessionState>()
    private val ownerSessions = mutableMapOf<Any, String>()

    /** Register a visible chat. Empty chats are tracked but never start a heartbeat loop. */
    fun activate(owner: Any, sessionId: String, hasConversation: Boolean) {
        synchronized(lock) {
            if (ownerSessions[owner] == sessionId) {
                val current = sessions.getValue(sessionId)
                if (hasConversation) current.established = true
                if (current.established) startLocked(sessionId, current, renewImmediately = true)
                return
            }
            removeOwnerLocked(owner)
            val state = sessions.getOrPut(sessionId) { SessionState() }
            state.owners += owner
            ownerSessions[owner] = sessionId
            if (hasConversation) state.established = true
            if (state.established) startLocked(sessionId, state, renewImmediately = true)
        }
    }

    /** Stop all renewal work owned by this screen. */
    fun deactivate(owner: Any) {
        synchronized(lock) { removeOwnerLocked(owner) }
    }

    /** A successful full-history chat call creates or rebuilds the runtime session. */
    fun markEstablished(sessionId: String) {
        synchronized(lock) {
            val state = sessions[sessionId] ?: return
            state.established = true
            if (state.owners.isNotEmpty()) {
                // A send is stronger evidence than an in-flight heartbeat (which may have started
                // just before the server created the session). Restart from a fresh full lease.
                state.job?.cancel()
                state.job = null
                startLocked(sessionId, state, renewImmediately = false)
            }
        }
    }

    private fun removeOwnerLocked(owner: Any) {
        val oldSessionId = ownerSessions.remove(owner) ?: return
        val oldState = sessions[oldSessionId] ?: return
        oldState.owners -= owner
        if (oldState.owners.isEmpty()) {
            oldState.job?.cancel()
            sessions.remove(oldSessionId)
        }
    }

    private fun startLocked(sessionId: String, state: SessionState, renewImmediately: Boolean) {
        if (state.job?.isActive == true) return
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                if (!renewImmediately) delay(heartbeatIntervalMs)
                while (currentCoroutineContext().isActive) {
                    val result = runCatching { clientProvider().heartbeat(sessionId) }
                    if (result.getOrNull() == HeartbeatResult.MISSING) {
                        synchronized(lock) {
                            sessions[sessionId]?.takeIf { it === state }?.established = false
                        }
                        return@launch
                    }
                    // Network/server errors retry only on the normal cadence, never in a tight loop.
                    delay(heartbeatIntervalMs)
                }
            } finally {
                val thisJob = currentCoroutineContext().job
                synchronized(lock) {
                    sessions[sessionId]?.takeIf { it === state && it.job === thisJob }?.job = null
                }
            }
        }
        state.job = job
        job.start()
    }

    companion object {
        const val DEFAULT_HEARTBEAT_INTERVAL_MS = 2 * 60 * 1000L
    }
}
