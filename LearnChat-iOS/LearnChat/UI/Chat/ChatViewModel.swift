import Foundation
import Observation

/// In-memory view of the reply currently streaming in (not yet fully persisted).
struct StreamingReply: Equatable {
    var messageId: Int64
    var text: String = ""
    var thinking: String = ""

    /// True until the first visible token arrives — drives the typing indicator.
    var waitingForFirstToken: Bool { text.isEmpty }
}

enum AttachmentState { case processing, ready, failed }

/// A file the user picked for the next message, being (or already) preprocessed on the phone.
struct PendingAttachment: Identifiable {
    let id: Int64
    var name: String
    var kind: AttachmentKind?
    var state: AttachmentState = .processing
    /// Progress label while processing, e.g. "Reading page 3/12".
    var progress: String? = nil
    /// Short result once ready, e.g. "12 pages · 4,210 words".
    var summary: String? = nil
    var error: String? = nil
    var part: MessagePart? = nil
}

@Observable
@MainActor
final class ChatViewModel {
    let chatId: Int64
    private let repository: ChatRepository
    private let sendMessage: SendMessageUseCase
    private let leases: ConversationLeaseCoordinator
    private let preprocessor: AttachmentPreprocessor
    private let leaseOwner = UUID()

    private(set) var chat: Chat?
    private var persisted: [Message] = []
    private(set) var streaming: StreamingReply?
    private(set) var showThinking = true
    private(set) var error: String?
    private(set) var pending: [PendingAttachment] = []
    private var screenVisible = false
    private var hasConversation = false

    private var preprocessTasks: [Int64: Task<Void, Never>] = [:]
    private var nextAttachmentId: Int64 = 1
    nonisolated(unsafe) private var sendTask: Task<Void, Never>?
    nonisolated(unsafe) private var observers: [Task<Void, Never>] = []

    init(
        chatId: Int64,
        repository: ChatRepository,
        settings: SettingsRepository,
        sendMessage: SendMessageUseCase,
        leases: ConversationLeaseCoordinator,
        preprocessor: AttachmentPreprocessor
    ) {
        self.chatId = chatId
        self.repository = repository
        self.sendMessage = sendMessage
        self.leases = leases
        self.preprocessor = preprocessor

        observers = [
            Task { [weak self] in
                for await c in repository.observeChat(chatId) {
                    guard let self else { break }
                    self.chat = c
                    self.syncLeaseVisibility()
                }
            },
            Task { [weak self] in
                for await list in repository.observeMessages(chatId) {
                    guard let self else { break }
                    self.persisted = list
                    self.hasConversation = !list.isEmpty
                    self.syncLeaseVisibility()
                }
            },
            Task { [weak self] in
                for await cfg in settings.settings {
                    guard let self else { break }
                    self.showThinking = cfg.showThinking
                }
            },
        ]
    }

    deinit {
        // Leaving the screen behaves like Stop; the partial reply is kept.
        sendTask?.cancel()
        leases.deactivate(owner: leaseOwner)
        observers.forEach { $0.cancel() }
        // Don't leave an empty "New chat" behind if the user backed out without sending.
        let repository = self.repository
        let chatId = self.chatId
        Task { try? await repository.deleteChatIfEmpty(chatId) }
    }

    // MARK: State

    /// Persisted messages with the live streaming text overlaid onto the (throttled) stored copy.
    var messages: [Message] {
        guard let streaming else { return persisted }
        return persisted.map { m in
            guard m.id == streaming.messageId else { return m }
            var live = m
            live.parts = [.text(streaming.text)]
            live.thinking = streaming.thinking.isBlank ? nil : streaming.thinking
            live.status = .streaming
            return live
        }
    }

    var isSending: Bool { streaming != nil }
    var isPreprocessing: Bool { pending.contains { $0.state == .processing } }
    var hasReadyAttachment: Bool { pending.contains { $0.state == .ready } }

    // MARK: Attachments

    /// Start preprocessing a picked file right away so it is ready by the time the user hits Send.
    func attach(url: URL, mimeType: String?, displayName: String?) {
        let id = nextAttachmentId
        nextAttachmentId += 1
        let kind = AttachmentKind.fromMime(mimeType)
        pending.append(PendingAttachment(id: id, name: displayName ?? url.lastPathComponent, kind: kind, progress: "Preparing"))
        let preprocessor = self.preprocessor
        preprocessTasks[id] = Task { [weak self] in
            do {
                let result = try await preprocessor.preprocess(url: url, mimeType: mimeType, displayName: displayName) { progress in
                    Task { @MainActor [weak self] in self?.updatePending(id) { $0.progress = progress.label } }
                }
                guard let self else { return }
                self.updatePending(id) { a in
                    a.state = .ready
                    a.progress = nil
                    a.summary = result.summary
                    a.part = result.part
                    switch result.part {
                    case .file(let f): a.name = f.name; a.kind = kind ?? AttachmentKind.fromMime(f.mimeType)
                    case .image(let i): a.name = i.name ?? a.name; a.kind = kind ?? AttachmentKind.fromMime(i.mimeType)
                    default: break
                    }
                }
            } catch is CancellationError {
                // removed by the user
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "Couldn't process this file"
                self?.updatePending(id) { a in a.state = .failed; a.progress = nil; a.error = message }
            }
            self?.preprocessTasks[id] = nil
        }
    }

    private func updatePending(_ id: Int64, _ change: (inout PendingAttachment) -> Void) {
        guard let idx = pending.firstIndex(where: { $0.id == id }) else { return }
        change(&pending[idx])
    }

    func removeAttachment(_ id: Int64) {
        preprocessTasks.removeValue(forKey: id)?.cancel()
        pending.removeAll { $0.id == id }
    }

    // MARK: Sending

    func send(_ text: String) {
        let trimmed = text.trimmed
        if pending.contains(where: { $0.state == .processing }) { return }
        let attachments = pending.filter { $0.state == .ready }.compactMap(\.part)
        if (trimmed.isEmpty && attachments.isEmpty) || sendTask != nil { return }
        var parts: [MessagePart] = []
        if !trimmed.isEmpty { parts.append(.text(trimmed)) }
        parts.append(contentsOf: attachments)
        pending = []
        error = nil
        let sendMessage = self.sendMessage
        let chatId = self.chatId
        sendTask = Task { [weak self] in
            do {
                for try await p in sendMessage(chatId: chatId, parts: parts) {
                    guard let self else { break }
                    switch p {
                    case .started(_, let assistantId):
                        self.streaming = StreamingReply(messageId: assistantId)
                    case .thinking(_, let thinking):
                        self.streaming?.thinking = thinking
                    case .content(_, let text, let thinking):
                        self.streaming?.text = text
                        self.streaming?.thinking = thinking
                    case .finished(_, let status, let err):
                        if status == .failed { self.error = err ?? "Something went wrong" }
                        self.streaming = nil
                    }
                }
            } catch {
                // Cancellation (Stop) or a transport failure already recorded on the message.
            }
            self?.streaming = nil
            self?.sendTask = nil
        }
    }

    func stop() {
        sendTask?.cancel()
        sendTask = nil
        streaming = nil
    }

    func dismissError() { error = nil }

    /// The lease follows the actual foreground destination, not merely SwiftUI composition.
    func setScreenVisible(_ visible: Bool) {
        guard screenVisible != visible else { return }
        screenVisible = visible
        syncLeaseVisibility()
    }

    private func syncLeaseVisibility() {
        if screenVisible, let sessionId = chat?.sessionId, !sessionId.isBlank {
            leases.activate(owner: leaseOwner, sessionId: sessionId, hasConversation: hasConversation)
        } else {
            leases.deactivate(owner: leaseOwner)
        }
    }
}
