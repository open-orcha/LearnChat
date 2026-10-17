import SwiftData
import XCTest
@testable import LearnChat

final class SessionLifecycleTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.onStop = nil
        super.tearDown()
    }

    @MainActor
    func testExistingChatWithoutSessionIdIsBackfilledOnceAndPreserved() async throws {
        let container = try SwiftDataChatRepository.makeContainer(inMemory: true)
        let legacy = ChatEntity(id: 7, sessionId: nil, title: "Existing chat", createdAt: 1, updatedAt: 2)
        container.mainContext.insert(legacy)
        try container.mainContext.save()

        let repository = SwiftDataChatRepository(container: container)
        let firstValue = try await repository.getChat(7)
        let secondValue = try await repository.getChat(7)
        let reopenedValue = try await SwiftDataChatRepository(container: container).getChat(7)
        let first = try XCTUnwrap(firstValue)
        let second = try XCTUnwrap(secondValue)
        let reopened = try XCTUnwrap(reopenedValue)

        XCTAssertFalse(first.sessionId.isEmpty)
        XCTAssertEqual(first.sessionId, second.sessionId)
        XCTAssertEqual(reopened.sessionId, first.sessionId)
        XCTAssertEqual(first.title, "Existing chat")
    }

    @MainActor
    func testNewChatsReceiveDistinctStableSessionIds() async throws {
        let repository = SwiftDataChatRepository(container: try SwiftDataChatRepository.makeContainer(inMemory: true))
        let firstId = try await repository.createChat(title: "One")
        let secondId = try await repository.createChat(title: "Two")
        let firstValue = try await repository.getChat(firstId)
        let rereadValue = try await repository.getChat(firstId)
        let secondValue = try await repository.getChat(secondId)
        let first = try XCTUnwrap(firstValue)
        let reread = try XCTUnwrap(rereadValue)
        let second = try XCTUnwrap(secondValue)

        XCTAssertEqual(first.sessionId, reread.sessionId)
        XCTAssertNotEqual(first.sessionId, second.sessionId)
    }

    func testChatAndCompletionSendSessionHeaderAndMissingHeartbeatIsRecoverable() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = MuseGlimmerChatClient(baseUrl: "http://learnchat.test", session: session)
        let requests = LockedRequests()
        StubURLProtocol.handler = { proto, request in
            requests.append(request)
            if request.url?.path.hasSuffix("/heartbeat") == true {
                proto.respond(status: 404, body: #"{"error":"session not found or expired"}"#)
            } else {
                proto.respond(status: 200, body: #"{"message":{"role":"assistant","content":"ok"},"done":true}"#)
            }
        }

        let request = ChatRequest(
            model: "muse-glimmer:latest",
            turns: [.text(.user, "hello")],
            sessionId: "conversation-123"
        )
        let reply = try await client.complete(request)
        let heartbeat = try await client.heartbeat(sessionId: "conversation-123")
        XCTAssertEqual(reply, "ok")
        XCTAssertEqual(heartbeat, .missing)

        let captured = requests.values
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[0].value(forHTTPHeaderField: "X-Muse-Session-ID"), "conversation-123")
        XCTAssertEqual(captured[1].url?.path, "/api/sessions/conversation-123/heartbeat")
        XCTAssertEqual(captured[1].httpMethod, "POST")
    }

    func testCancellingStalledStreamClosesUnderlyingRequest() async throws {
        let received = expectation(description: "received first chunk")
        let stopped = expectation(description: "underlying request stopped")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = MuseGlimmerChatClient(baseUrl: "http://learnchat.test", session: URLSession(configuration: config))
        StubURLProtocol.handler = { proto, _ in
            proto.respond(
                status: 200,
                body: #"{"message":{"role":"assistant","content":"partial"},"done":false}"# + "\n",
                finish: false
            )
        }
        StubURLProtocol.onStop = { stopped.fulfill() }

        let task = Task {
            for try await event in client.streamChat(ChatRequest(
                model: "muse-glimmer:latest",
                turns: [.text(.user, "hello")],
                sessionId: "cancel-regression"
            )) {
                if event == .contentDelta("partial") { received.fulfill() }
            }
        }

        await fulfillment(of: [received], timeout: 1)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 1)
        _ = await task.result
    }

    func testStreamRequiresDoneConfirmation() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = MuseGlimmerChatClient(baseUrl: "http://learnchat.test", session: URLSession(configuration: config))
        StubURLProtocol.handler = { proto, _ in
            proto.respond(
                status: 200,
                body: #"{"message":{"role":"assistant","content":"partial"},"done":false}"# + "\n"
            )
        }

        do {
            for try await _ in client.streamChat(ChatRequest(
                model: "muse-glimmer:latest",
                turns: [.text(.user, "hello")],
                sessionId: "incomplete-stream"
            )) {}
            XCTFail("expected an incomplete stream error")
        } catch let error as ServerError {
            XCTAssertTrue(error.message.contains("confirmed completion"))
        }
    }

    func testLeaseLifecycleSkipsEmptyChatsStopsOnMissingAndRestartsAfterSend() async throws {
        let fake = HeartbeatClient(result: .missing)
        let coordinator = ConversationLeaseCoordinator(
            clientProvider: { fake },
            heartbeatInterval: .milliseconds(25)
        )
        let owner = UUID()

        coordinator.activate(owner: owner, sessionId: "conversation", hasConversation: false)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fake.callCount, 0)

        coordinator.activate(owner: owner, sessionId: "conversation", hasConversation: true)
        let firstHeartbeat = await waitUntil { fake.callCount == 1 }
        XCTAssertTrue(firstHeartbeat)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fake.callCount, 1, "a missing lease should pause renewal")

        coordinator.activate(owner: owner, sessionId: "conversation", hasConversation: true)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fake.callCount, 1, "a local-message refresh must not revive a missing lease")

        coordinator.deactivate(owner: owner)
        let reopenedOwner = UUID()
        coordinator.activate(owner: reopenedOwner, sessionId: "conversation", hasConversation: true)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fake.callCount, 1, "reopening saved history must wait for a successful send")

        fake.result = .renewed
        coordinator.markEstablished(sessionId: "conversation")
        let restarted = await waitUntil { fake.callCount >= 2 }
        XCTAssertTrue(restarted)
        coordinator.deactivate(owner: reopenedOwner)
        let stoppedAt = fake.callCount
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(fake.callCount, stoppedAt)
    }

    func testSuccessfulSendFencesLateMissingHeartbeatAndKeepsRenewing() async throws {
        let fake = BlockingFirstHeartbeatClient()
        let coordinator = ConversationLeaseCoordinator(
            clientProvider: { fake },
            heartbeatInterval: .milliseconds(25)
        )
        let owner = UUID()

        coordinator.activate(owner: owner, sessionId: "conversation", hasConversation: true)
        let firstHeartbeatStarted = await waitUntil { fake.callCount == 1 }
        XCTAssertTrue(firstHeartbeatStarted)

        coordinator.markEstablished(sessionId: "conversation")
        let postSendHeartbeatStarted = await waitUntil { fake.callCount >= 2 }
        XCTAssertTrue(postSendHeartbeatStarted)
        fake.releaseFirstMissingHeartbeat()

        let renewalContinued = await waitUntil { fake.callCount >= 3 }
        XCTAssertTrue(renewalContinued)
        let afterLateMissing = fake.callCount
        let anotherRenewalRan = await waitUntil { fake.callCount > afterLateMissing }
        XCTAssertTrue(anotherRenewalRan)
        coordinator.deactivate(owner: owner)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private final class HeartbeatClient: ChatServerClient, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var nextResult: HeartbeatResult

    init(result: HeartbeatResult) { nextResult = result }

    var callCount: Int { lock.withLock { calls } }
    var result: HeartbeatResult {
        get { lock.withLock { nextResult } }
        set { lock.withLock { nextResult = newValue } }
    }

    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func complete(_ request: ChatRequest) async throws -> String { "" }
    func heartbeat(sessionId: String) async throws -> HeartbeatResult {
        lock.withLock {
            calls += 1
            return nextResult
        }
    }
    func ping() async -> ServerInfo { ServerInfo(reachable: true, models: []) }
}

private final class BlockingFirstHeartbeatClient: ChatServerClient, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?

    var callCount: Int { lock.withLock { calls } }

    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func complete(_ request: ChatRequest) async throws -> String { "" }
    func heartbeat(sessionId: String) async throws -> HeartbeatResult {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        guard call == 1 else { return .renewed }
        await withCheckedContinuation { continuation in
            lock.withLock { firstContinuation = continuation }
        }
        return .missing
    }
    func ping() async -> ServerInfo { ServerInfo(reachable: true, models: []) }

    func releaseFirstMissingHeartbeat() {
        let continuation = lock.withLock {
            defer { firstContinuation = nil }
            return firstContinuation
        }
        continuation?.resume()
    }
}

private final class LockedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    var values: [URLRequest] { lock.withLock { requests } }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((StubURLProtocol, URLRequest) -> Void)?
    static var onStop: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self, request) }
    override func stopLoading() { Self.onStop?() }

    func respond(status: Int, body: String, finish: Bool = true) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/x-ndjson"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }
}
