import Foundation

/// Transport abstraction over the inference server. The UI and repository only ever see this
/// protocol, so swapping the current service for another backend (SSE, websocket audio, ...)
/// is a data-layer change.
protocol ChatServerClient: Sendable {
    /// Stream a reply; cancelling the consuming task aborts the HTTP call.
    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>

    /// Non-streaming completion, used for background jobs such as summarisation.
    func complete(_ request: ChatRequest) async throws -> String

    /// Renew a conversation cache lease. A missing lease is recoverable on the next full send.
    func heartbeat(sessionId: String) async throws -> HeartbeatResult

    func ping() async -> ServerInfo
}

/// Builds a client from the *current* settings so a URL change takes effect on the next call.
typealias ChatServerClientProvider = @Sendable () async -> ChatServerClient
