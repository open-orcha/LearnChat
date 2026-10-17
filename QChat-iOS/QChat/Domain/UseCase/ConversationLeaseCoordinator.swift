import Foundation

/// Owns cache-lease heartbeat loops for the process. A chat screen registers only while it is
/// visible and the app is active. The runtime is allowed to expire leases naturally after a chat
/// leaves the foreground; the next full-history send recreates a missing session.
final class ConversationLeaseCoordinator: @unchecked Sendable {
    private final class SessionState {
        var owners: Set<UUID> = []
        var established = false
        var generation = UUID()
        var task: Task<Void, Never>?
    }

    private let clientProvider: ChatServerClientProvider
    private let heartbeatInterval: Duration
    private let lock = NSLock()
    private var sessions: [String: SessionState] = [:]
    private var ownerSessions: [UUID: String] = [:]
    /// Session IDs whose runtime cache was confirmed missing. Local history alone must not clear
    /// this fence; only a successful full-context send can establish the runtime session again.
    private var sessionsAwaitingSend: Set<String> = []

    init(
        clientProvider: @escaping ChatServerClientProvider,
        heartbeatInterval: Duration = .seconds(2 * 60)
    ) {
        self.clientProvider = clientProvider
        self.heartbeatInterval = heartbeatInterval
    }

    /// Register a visible chat. Empty chats are tracked but never start a heartbeat loop.
    func activate(owner: UUID, sessionId: String, hasConversation: Bool) {
        lock.lock()
        defer { lock.unlock() }

        if ownerSessions[owner] == sessionId, let current = sessions[sessionId] {
            if hasConversation, !sessionsAwaitingSend.contains(sessionId) {
                current.established = true
            }
            if current.established { startLocked(sessionId: sessionId, state: current, renewImmediately: true) }
            return
        }

        removeOwnerLocked(owner)
        let state = sessions[sessionId] ?? SessionState()
        sessions[sessionId] = state
        state.owners.insert(owner)
        ownerSessions[owner] = sessionId
        if hasConversation, !sessionsAwaitingSend.contains(sessionId) {
            state.established = true
        }
        if state.established { startLocked(sessionId: sessionId, state: state, renewImmediately: true) }
    }

    /// Stop renewal work owned by a chat screen.
    func deactivate(owner: UUID) {
        lock.lock()
        removeOwnerLocked(owner)
        lock.unlock()
    }

    /// A successful full-history request creates or rebuilds the runtime session.
    func markEstablished(sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        sessionsAwaitingSend.remove(sessionId)
        guard let state = sessions[sessionId] else { return }
        state.established = true
        if !state.owners.isEmpty {
            // A send is stronger evidence than an in-flight heartbeat. Restart from a fresh lease.
            state.task?.cancel()
            state.task = nil
            startLocked(sessionId: sessionId, state: state, renewImmediately: false)
        }
    }

    private func removeOwnerLocked(_ owner: UUID) {
        guard let oldSessionId = ownerSessions.removeValue(forKey: owner),
              let oldState = sessions[oldSessionId] else { return }
        oldState.owners.remove(owner)
        if oldState.owners.isEmpty {
            oldState.task?.cancel()
            sessions.removeValue(forKey: oldSessionId)
        }
    }

    private func startLocked(sessionId: String, state: SessionState, renewImmediately: Bool) {
        guard state.task == nil else { return }
        let generation = UUID()
        state.generation = generation
        state.task = Task { [weak self, weak state] in
            guard let self, let state else { return }
            if !renewImmediately {
                do { try await Task.sleep(for: heartbeatInterval) }
                catch { return }
            }

            while !Task.isCancelled {
                let result = try? await clientProvider().heartbeat(sessionId: sessionId)
                if Task.isCancelled { break }
                if result == .missing {
                    lock.withLock {
                        if self.sessions[sessionId] === state, state.generation == generation {
                            state.established = false
                            self.sessionsAwaitingSend.insert(sessionId)
                        }
                    }
                    break
                }
                // Network and server failures retry only on the normal cadence.
                do { try await Task.sleep(for: heartbeatInterval) }
                catch { break }
            }

            lock.withLock {
                if self.sessions[sessionId] === state, state.generation == generation {
                    state.task = nil
                }
            }
        }
    }
}
