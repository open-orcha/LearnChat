import Foundation

/// A turn as sent to the server: role + parts. Kept transport-agnostic.
struct ChatTurn: Equatable, Sendable {
    var role: MessageRole
    var parts: [MessagePart]

    static func text(_ role: MessageRole, _ text: String) -> ChatTurn { ChatTurn(role: role, parts: [.text(text)]) }
}

struct ChatRequest: Sendable {
    var model: String
    var turns: [ChatTurn]
    /// Stable local conversation ID used by the runtime to reuse and renew its cache.
    var sessionId: String? = nil
    /// Ask the server for its reasoning trace when supported.
    var includeThinking: Bool = true
    /// Attach photo pixels for vision-capable models (see AppSettings.sendImagesToModel).
    var sendImages: Bool = false
    /// Context window to request for this call, in tokens. Attachments need a larger window so
    /// their derived text is not silently dropped. nil = server default.
    var contextTokens: Int? = nil
}

/// Events emitted while a reply streams in.
enum StreamEvent: Sendable, Equatable {
    /// A chunk of the model's reasoning trace (may arrive before any content).
    case thinkingDelta(String)
    /// A chunk of the visible reply.
    case contentDelta(String)
    /// Stream ended normally.
    case done(totalDurationMs: Int64?, outputTokens: Int?)
}

struct ServerInfo: Sendable, Equatable {
    var reachable: Bool
    var models: [String]
    var detail: String? = nil
}

struct ServerError: LocalizedError, Sendable {
    let message: String
    let statusCode: Int?
    init(_ message: String, statusCode: Int? = nil) {
        self.message = message
        self.statusCode = statusCode
    }
    var errorDescription: String? { message }
}

enum HeartbeatResult: Sendable, Equatable {
    case renewed
    case missing
}
