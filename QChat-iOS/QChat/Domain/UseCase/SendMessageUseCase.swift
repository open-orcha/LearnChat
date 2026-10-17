import Foundation

/// What the UI sees while a reply is being produced.
enum ReplyProgress: Sendable, Equatable {
    case started(userMessageId: Int64, assistantMessageId: Int64)
    case thinking(assistantMessageId: Int64, thinking: String)
    case content(assistantMessageId: Int64, text: String, thinking: String)
    case finished(assistantMessageId: Int64, status: MessageStatus, error: String?)
}

/// Sends a user message and streams the assistant reply.
///
/// Flow of a send: persist the user turn → compact history into context → persist an empty
/// assistant turn marked STREAMING → stream deltas (persisting a snapshot every ~400 ms so a killed
/// app keeps partial replies) → finalise → kick off background summary refresh.
/// Cancelling the consumer = pressing Stop: the reply is kept with status STOPPED.
final class SendMessageUseCase: @unchecked Sendable {
    private let repository: ChatRepository
    private let settings: SettingsRepository
    private let clientProvider: ChatServerClientProvider
    private let compactor: ContextCompactor
    private let leases: ConversationLeaseCoordinator
    private let persistInterval: TimeInterval
    private let sessionSendLocks = SessionSendLockRegistry()

    /// Context window requested when attachments are in play (muse-glimmer supports 128k).
    private static let attachmentContextTokens = 16_384

    init(
        repository: ChatRepository,
        settings: SettingsRepository,
        clientProvider: @escaping ChatServerClientProvider,
        compactor: ContextCompactor,
        leases: ConversationLeaseCoordinator,
        persistIntervalMs: Int = 400
    ) {
        self.repository = repository
        self.settings = settings
        self.clientProvider = clientProvider
        self.compactor = compactor
        self.leases = leases
        self.persistInterval = TimeInterval(persistIntervalMs) / 1000
    }

    func callAsFunction(chatId: Int64, parts: [MessagePart]) -> AsyncThrowingStream<ReplyProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await run(chatId: chatId, parts: parts, emit: { continuation.yield($0) })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(chatId: Int64, parts: [MessagePart], emit: @escaping (ReplyProgress) -> Void) async throws {
        guard let initialChat = try await repository.getChat(chatId) else { throw ServerError("chat \(chatId) missing") }
        let sendLock = await sessionSendLocks.lock(for: initialChat.sessionId)
        try await sendLock.withLock { [self] in
            try Task.checkCancellation()
            try await runLocked(chatId: chatId, parts: parts, emit: emit)
        }
    }

    private func runLocked(chatId: Int64, parts: [MessagePart], emit: @escaping (ReplyProgress) -> Void) async throws {
        let userId = try await repository.addMessage(chatId: chatId, role: .user, parts: parts)
        try await maybeAutoTitle(chatId: chatId, parts: parts)

        let cfg = await settings.current()
        guard let chat = try await repository.getChat(chatId) else { throw ServerError("chat \(chatId) missing") }
        let history = try await repository.getMessages(chatId)
        let context = await compactor.buildContext(chat: chat, history: history, settings: cfg)

        let assistantId = try await repository.addMessage(chatId: chatId, role: .assistant, parts: [.text("")], status: .streaming)
        emit(.started(userMessageId: userId, assistantMessageId: assistantId))

        var content = ""
        var thinking = ""
        var lastPersist = Date.distantPast
        var finalStatus = MessageStatus.complete
        var failure: String? = nil
        do {
            // Attachments carry a lot of derived text; ask for a bigger context window so the
            // server does not silently truncate it.
            let hasAttachments = context.contains { turn in turn.parts.contains { !$0.isText } }
            let request = ChatRequest(
                model: cfg.modelName,
                turns: context,
                sessionId: chat.sessionId,
                sendImages: cfg.sendImagesToModel,
                contextTokens: hasAttachments ? Self.attachmentContextTokens : nil
            )
            var attempt = 0
            while true {
                var receivedStreamEvent = false
                do {
                    let client = await clientProvider()
                    for try await ev in client.streamChat(request) {
                        try Task.checkCancellation()
                        receivedStreamEvent = true
                        switch ev {
                        case .thinkingDelta(let t):
                            thinking += t
                            emit(.thinking(assistantMessageId: assistantId, thinking: thinking))
                        case .contentDelta(let t):
                            content += t
                            emit(.content(assistantMessageId: assistantId, text: content, thinking: thinking))
                            let now = Date()
                            if now.timeIntervalSince(lastPersist) > persistInterval {
                                lastPersist = now
                                try await repository.updateMessageContent(messageId: assistantId, text: content, thinking: thinking.isBlank ? nil : thinking, status: .streaming)
                            }
                        case .done:
                            break
                        }
                    }
                    break
                } catch let error as ServerError
                    where error.statusCode == 409 && !receivedStreamEvent && attempt < Self.conflictRetryDelays.count {
                    let delay = Self.conflictRetryDelays[attempt]
                    attempt += 1
                    try await Task.sleep(for: delay)
                }
            }
            if Task.isCancelled { throw CancellationError() }
            leases.markEstablished(sessionId: chat.sessionId)
        } catch is CancellationError {
            // Stop pressed: keep what we have before propagating the cancellation.
            finalStatus = .stopped
            await persistFinal(id: assistantId, content: content, thinking: thinking, status: finalStatus, error: nil)
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            finalStatus = .stopped
            await persistFinal(id: assistantId, content: content, thinking: thinking, status: finalStatus, error: nil)
            throw CancellationError()
        } catch {
            finalStatus = .failed
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await persistFinal(id: assistantId, content: content, thinking: thinking, status: finalStatus, error: failure)
        emit(.finished(assistantMessageId: assistantId, status: finalStatus, error: failure))

        if finalStatus == .complete {
            let compactor = self.compactor
            Task.detached { try? await compactor.refreshSummaryIfNeeded(chatId: chatId) }
        }
    }

    private func persistFinal(id: Int64, content: String, thinking: String, status: MessageStatus, error: String?) async {
        // Runs even when the task is cancelled so Stop still writes the partial reply.
        let repository = self.repository
        await Task.detached {
            try? await repository.updateMessageContent(
                messageId: id,
                text: content,
                thinking: thinking.isBlank ? nil : thinking,
                status: status,
                error: error
            )
        }.value
    }

    private func maybeAutoTitle(chatId: Int64, parts: [MessagePart]) async throws {
        guard let chat = try await repository.getChat(chatId), chat.title == "New chat" else { return }
        var text = parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: " ").trimmed
        if text.isEmpty { text = parts.compactMap(\.attachmentLabel).first ?? "" }
        if text.isEmpty { return }
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let title = text.count > 48 ? collapsed.take(48) + "…" : collapsed.take(48)
        try await repository.renameChat(chatId, title: title)
    }

    private static let conflictRetryDelays: [Duration] = [
        .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(2),
    ]
}

/// One lock per stable runtime session lets independent chats proceed while preventing the runtime
/// from receiving overlapping full-history updates for the same conversation.
private actor SessionSendLockRegistry {
    private var locks: [String: AsyncLock] = [:]

    func lock(for sessionId: String) -> AsyncLock {
        if let existing = locks[sessionId] { return existing }
        let created = AsyncLock()
        locks[sessionId] = created
        return created
    }
}
