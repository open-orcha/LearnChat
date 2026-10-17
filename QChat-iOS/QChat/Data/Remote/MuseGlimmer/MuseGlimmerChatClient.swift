import Foundation

/// `ChatServerClient` for the Muse Glimmer service. Streaming uses newline-delimited JSON:
/// each line is one chunk carrying either a `message.thinking` or `message.content` delta, and the
/// final line has `done: true`.
final class MuseGlimmerChatClient: ChatServerClient, @unchecked Sendable {
    private let baseUrl: String
    private let session: URLSession
    /// Reads a photo or sampled video-frame file and returns it base64-encoded.
    private let imageEncoder: @Sendable (ImagePart) -> String?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()
    private let decoder = JSONDecoder()

    init(baseUrl: String, session: URLSession = MuseGlimmerChatClient.defaultSession(), imageEncoder: @escaping @Sendable (ImagePart) -> String? = { _ in nil }) {
        self.baseUrl = baseUrl
        self.session = session
        self.imageEncoder = imageEncoder
    }

    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                let req = try makeRequest(
                    "/api/chat",
                    body: toWireRequest(request, stream: true),
                    sessionId: request.sessionId
                )
                // URLSession.AsyncBytes does not expose the underlying URLSessionTask. Keep an
                // explicit data task so Stop can close a socket that is stalled between chunks.
                let stream = MuseGlimmerStreamTask(
                    request: req,
                    configuration: session.configuration,
                    continuation: continuation
                )
                continuation.onTermination = { _ in stream.cancel() }
                stream.start()
            } catch {
                continuation.finish(throwing: Self.wrap(error))
            }
        }
    }

    func complete(_ request: ChatRequest) async throws -> String {
        do {
            let req = try makeRequest(
                "/api/chat",
                body: toWireRequest(request, stream: false),
                sessionId: request.sessionId
            )
            let (data, response) = try await session.data(for: req)
            let text = String(decoding: data, as: UTF8.self)
            try await checkStatus(response, bodyIfError: { text })
            let chunk = try decoder.decode(MuseGlimmerChatChunk.self, from: data)
            if let err = chunk.error { throw ServerError(err) }
            return chunk.message?.content ?? ""
        } catch {
            throw Self.wrap(error)
        }
    }

    func heartbeat(sessionId: String) async throws -> HeartbeatResult {
        do {
            guard let encoded = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: endpoint("/api/sessions/\(encoded)/heartbeat")) else {
                throw ServerError("Invalid server address: \(baseUrl)")
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = Data()
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .renewed }
            switch http.statusCode {
            case 200:
                return .renewed
            case 404:
                return .missing
            default:
                let text = String(decoding: data, as: UTF8.self)
                throw ServerError("Server error \(http.statusCode): \(text.take(300))", statusCode: http.statusCode)
            }
        } catch {
            throw Self.wrap(error)
        }
    }

    func ping() async -> ServerInfo {
        do {
            guard let url = URL(string: endpoint("/api/tags")) else { return ServerInfo(reachable: false, models: [], detail: "Invalid server address") }
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return ServerInfo(reachable: false, models: [], detail: "HTTP \(http.statusCode)")
            }
            let tags = try decoder.decode(MuseGlimmerModelsResponse.self, from: data)
            return ServerInfo(reachable: true, models: tags.models.map(\.name))
        } catch {
            return ServerInfo(reachable: false, models: [], detail: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func endpoint(_ path: String) -> String {
        var base = baseUrl
        while base.hasSuffix("/") { base.removeLast() }
        return base + path
    }

    private func makeRequest(_ path: String, body: MuseGlimmerChatRequest, sessionId: String?) throws -> URLRequest {
        guard let url = URL(string: endpoint(path)), url.host != nil else { throw ServerError("Invalid server address: \(baseUrl)") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let sessionId, !sessionId.isBlank {
            req.setValue(sessionId, forHTTPHeaderField: "X-Muse-Session-ID")
        }
        req.httpBody = try encoder.encode(body)
        return req
    }

    private func checkStatus(_ response: URLResponse, bodyIfError: () async throws -> String) async throws {
        guard let http = response as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            let body = (try? await bodyIfError()) ?? ""
            throw ServerError("Server error \(http.statusCode): \(body.take(300))", statusCode: http.statusCode)
        }
    }

    /// Network failures become `ServerError`s with a readable message; cancellation passes through.
    private static func wrap(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let e = error as? URLError {
            if e.code == .cancelled { return e }
            return ServerError(e.localizedDescription)
        }
        if error is ServerError { return error }
        if error is DecodingError { return ServerError("Unexpected reply from server") }
        return ServerError(error.localizedDescription)
    }

    private func toWireRequest(_ request: ChatRequest, stream: Bool) -> MuseGlimmerChatRequest {
        MuseGlimmerChatRequest(
            model: request.model,
            messages: request.turns.map { toWireMessage($0, sendImages: request.sendImages) },
            stream: stream,
            think: request.includeThinking ? nil : false,
            options: request.contextTokens.map { MuseGlimmerOptions(numCtx: $0) }
        )
    }

    /// Text parts go through as-is; attachments contribute the text the phone derived from them
    /// (see `MessagePart.promptText`). Photos and sampled video frames are additionally sent as
    /// base64 `images` when the request asks for it (vision-capable server model).
    private func toWireMessage(_ turn: ChatTurn, sendImages: Bool) -> MuseGlimmerMessage {
        var photos: [String] = []
        if sendImages {
            for part in turn.parts {
                if case .image(let p) = part, let encoded = imageEncoder(p) { photos.append(encoded) }
            }
        }
        let role: String
        switch turn.role {
        case .user: role = "user"
        case .assistant: role = "assistant"
        case .system: role = "system"
        }
        return MuseGlimmerMessage(
            role: role,
            content: turn.parts.map(\.promptText).joined(separator: "\n\n").trimmed,
            images: photos.isEmpty ? nil : photos
        )
    }

    static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        // Streaming: the model may think for a long time before the first byte arrives.
        config.timeoutIntervalForRequest = 60 * 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }
}

/// Incremental NDJSON reader backed by a concrete URLSessionDataTask. The explicit task reference
/// is the cancellation guarantee: ending the AsyncThrowingStream immediately closes the request,
/// including while the server is silent after sending response headers or an earlier chunk.
private final class MuseGlimmerStreamTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private let continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var statusCode: Int?
    private var finished = false

    init(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) {
        self.request = request
        self.configuration = configuration
        self.continuation = continuation
    }

    func start() {
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        let task = session.dataTask(with: request)
        lock.withLock {
            self.session = session
            self.task = task
        }
        task.resume()
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        statusCode = (response as? HTTPURLResponse)?.statusCode
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isFinished else { return }
        if let statusCode, !(200..<300).contains(statusCode) {
            if buffer.count < 4_096 { buffer.append(data.prefix(4_096 - buffer.count)) }
            return
        }
        buffer.append(data)
        drainLines()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isFinished else { return }
        if let statusCode, !(200..<300).contains(statusCode) {
            let text = String(decoding: buffer, as: UTF8.self)
            finish(.failure(ServerError("Server error \(statusCode): \(text.take(300))", statusCode: statusCode)))
            return
        }
        if let error {
            finish(.failure(error))
            return
        }
        if !buffer.isEmpty { decodeLine(buffer) }
        if !isFinished {
            finish(.failure(ServerError("Stream ended before the server confirmed completion")))
        }
    }

    private func drainLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { decodeLine(line) }
            if isFinished { return }
        }
    }

    private func decodeLine(_ line: Data) {
        do {
            let chunk = try decoder.decode(MuseGlimmerChatChunk.self, from: line)
            if let error = chunk.error { throw ServerError(error) }
            if let thinking = chunk.message?.thinking, !thinking.isEmpty {
                continuation.yield(.thinkingDelta(thinking))
            }
            if let content = chunk.message?.content, !content.isEmpty {
                continuation.yield(.contentDelta(content))
            }
            if chunk.done {
                continuation.yield(.done(
                    totalDurationMs: chunk.totalDurationNs.map { $0 / 1_000_000 },
                    outputTokens: chunk.evalCount
                ))
                finish(.success(()))
            }
        } catch let error as ServerError {
            finish(.failure(error))
        } catch {
            finish(.failure(ServerError("Unexpected reply from server")))
        }
    }

    private var isFinished: Bool { lock.withLock { finished } }

    private func finish(_ result: Result<Void, Error>) {
        let resources: (URLSessionDataTask?, URLSession?)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let resources = (task, session)
            task = nil
            session = nil
            return resources
        }
        guard let resources else { return }
        continuation.onTermination = nil
        switch result {
        case .success:
            continuation.finish()
        case .failure(let error):
            continuation.finish(throwing: error)
        }
        resources.0?.cancel()
        resources.1?.invalidateAndCancel()
    }
}
