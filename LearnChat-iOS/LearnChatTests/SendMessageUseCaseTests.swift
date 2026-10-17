import XCTest
@testable import LearnChat

final class SendMessageUseCaseTests: XCTestCase {
    func testConflictRetryKeepsOneLocalTurnAndSendsStableSession() async throws {
        let repository = SendFakeRepository()
        let client = SendFakeClient(mode: .conflictThenSuccess)
        let useCase = makeUseCase(repository: repository, client: client)

        var progress: [ReplyProgress] = []
        for try await event in useCase(chatId: 1, parts: [.text("hello")]) { progress.append(event) }

        XCTAssertEqual(client.attemptCount, 2)
        XCTAssertEqual(client.sessionIds, ["stable-session", "stable-session"])
        XCTAssertEqual(repository.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(repository.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(repository.messages.last?.status, .complete)
        XCTAssertTrue(progress.last == .finished(assistantMessageId: 2, status: .complete, error: nil))
    }

    func testSameSessionSendsAreFullySerialized() async throws {
        let repository = SendFakeRepository()
        let client = SendFakeClient(mode: .delayedSuccess)
        let useCase = makeUseCase(repository: repository, client: client)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for text in ["one", "two"] {
                group.addTask {
                    for try await _ in useCase(chatId: 1, parts: [.text(text)]) {}
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(client.maximumActive, 1)
        XCTAssertEqual(repository.messages.filter { $0.role == .user }.count, 2)
        XCTAssertEqual(repository.messages.filter { $0.role == .assistant }.count, 2)
    }

    func testStopKeepsPartialReplyAndReleasesSessionForImmediateSend() async throws {
        let repository = SendFakeRepository()
        let client = SendFakeClient(mode: .hangOnceThenSuccess)
        let useCase = makeUseCase(repository: repository, client: client)
        let partial = expectation(description: "partial reply received")

        let first = Task {
            for try await event in useCase(chatId: 1, parts: [.text("first")]) {
                if case .content(_, let text, _) = event, text == "partial" { partial.fulfill() }
            }
        }
        await fulfillment(of: [partial], timeout: 1)
        first.cancel()
        _ = await first.result

        var secondProgress: [ReplyProgress] = []
        for try await event in useCase(chatId: 1, parts: [.text("second")]) { secondProgress.append(event) }

        let assistants = repository.messages.filter { $0.role == .assistant }
        XCTAssertEqual(client.attemptCount, 2)
        XCTAssertEqual(assistants.count, 2)
        XCTAssertEqual(assistants[0].status, .stopped)
        XCTAssertEqual(assistants[0].text, "partial")
        XCTAssertEqual(assistants[1].status, .complete)
        XCTAssertEqual(assistants[1].text, "second reply")
        XCTAssertTrue(secondProgress.last == .finished(assistantMessageId: assistants[1].id, status: .complete, error: nil))
    }

    private func makeUseCase(repository: SendFakeRepository, client: SendFakeClient) -> SendMessageUseCase {
        let leases = ConversationLeaseCoordinator(clientProvider: { client }, heartbeatInterval: .seconds(60))
        return SendMessageUseCase(
            repository: repository,
            settings: SendFakeSettings(),
            clientProvider: { client },
            compactor: SendFakeCompactor(),
            leases: leases,
            persistIntervalMs: 0
        )
    }
}

private final class SendFakeRepository: ChatRepository, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var chat = Chat(id: 1, sessionId: "stable-session", title: "Chat", createdAt: 0, updatedAt: 0)
    private var storedMessages: [Message] = []
    private var nextId: Int64 = 1

    var messages: [Message] { lock.withLock { storedMessages } }

    func observeChats() -> AsyncStream<[Chat]> { AsyncStream { $0.yield([chat]); $0.finish() } }
    func observeChat(_ chatId: Int64) -> AsyncStream<Chat?> { AsyncStream { $0.yield(chat); $0.finish() } }
    func observeMessages(_ chatId: Int64) -> AsyncStream<[Message]> { AsyncStream { $0.yield(messages); $0.finish() } }
    func getChat(_ chatId: Int64) async throws -> Chat? { lock.withLock { chat } }
    func getMessages(_ chatId: Int64) async throws -> [Message] { messages }
    func createChat(title: String) async throws -> Int64 { 1 }
    func renameChat(_ chatId: Int64, title: String) async throws { lock.withLock { chat.title = title } }
    func deleteChat(_ chatId: Int64) async throws {}
    func deleteChatIfEmpty(_ chatId: Int64) async throws {}

    func addMessage(chatId: Int64, role: MessageRole, parts: [MessagePart], status: MessageStatus) async throws -> Int64 {
        lock.withLock {
            let id = nextId
            nextId += 1
            storedMessages.append(Message(id: id, chatId: chatId, role: role, parts: parts, status: status, createdAt: id))
            return id
        }
    }

    func updateMessageContent(messageId: Int64, text: String, thinking: String?, status: MessageStatus, error: String?) async throws {
        lock.withLock {
            guard let index = storedMessages.firstIndex(where: { $0.id == messageId }) else { return }
            storedMessages[index].parts = [.text(text)]
            storedMessages[index].thinking = thinking
            storedMessages[index].status = status
            storedMessages[index].error = error
        }
    }

    func updateSummary(chatId: Int64, summary: String, throughMessageId: Int64) async throws {}
}

private final class SendFakeSettings: SettingsRepository, @unchecked Sendable {
    var settings: AsyncStream<AppSettings> { AsyncStream { $0.yield(.default); $0.finish() } }
    func current() async -> AppSettings { .default }
    func update(_ transform: @Sendable (AppSettings) -> AppSettings) async {}
}

private struct SendFakeCompactor: ContextCompactor {
    func buildContext(chat: Chat, history: [Message], settings: AppSettings) async -> [ChatTurn] {
        history.map { ChatTurn(role: $0.role, parts: $0.parts) }
    }
    func refreshSummaryIfNeeded(chatId: Int64) async throws {}
}

private final class SendFakeClient: ChatServerClient, @unchecked Sendable {
    enum Mode { case conflictThenSuccess, delayedSuccess, hangOnceThenSuccess }

    private let mode: Mode
    private let lock = NSLock()
    private var attempts = 0
    private var active = 0
    private var maxActive = 0
    private var capturedSessions: [String] = []

    init(mode: Mode) { self.mode = mode }
    var attemptCount: Int { lock.withLock { attempts } }
    var maximumActive: Int { lock.withLock { maxActive } }
    var sessionIds: [String] { lock.withLock { capturedSessions } }

    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let attempt = lock.withLock {
            attempts += 1
            capturedSessions.append(request.sessionId ?? "")
            return attempts
        }
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                let nowActive = lock.withLock {
                    active += 1
                    maxActive = max(maxActive, active)
                    return active
                }
                _ = nowActive
                defer { lock.withLock { active -= 1 } }
                do {
                    switch mode {
                    case .conflictThenSuccess where attempt == 1:
                        throw ServerError("busy", statusCode: 409)
                    case .delayedSuccess:
                        try await Task.sleep(for: .milliseconds(40))
                        continuation.yield(.contentDelta("reply"))
                    case .hangOnceThenSuccess where attempt == 1:
                        continuation.yield(.contentDelta("partial"))
                        try await Task.sleep(for: .seconds(20))
                    case .hangOnceThenSuccess:
                        continuation.yield(.contentDelta("second reply"))
                    default:
                        continuation.yield(.contentDelta("reply"))
                    }
                    continuation.yield(.done(totalDurationMs: nil, outputTokens: nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func complete(_ request: ChatRequest) async throws -> String { "" }
    func heartbeat(sessionId: String) async throws -> HeartbeatResult { .renewed }
    func ping() async -> ServerInfo { ServerInfo(reachable: true, models: []) }
}
