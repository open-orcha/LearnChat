import Foundation

/// Turns a chat's full local history into the (smaller) context that is sent with a new prompt.
/// Keeping this behind a protocol lets us swap the strategy later (embedding retrieval,
/// server-side compaction, ...) without touching the UI or repository.
protocol ContextCompactor: Sendable {
    /// Build the turns to send ahead of the new user prompt (prompt itself is the last item of `history`).
    func buildContext(chat: Chat, history: [Message], settings: AppSettings) async -> [ChatTurn]

    /// Refresh the chat's rolling summary if enough un-summarised history has piled up outside the
    /// verbatim window. Slow (may call the model) — run it in the background after a reply finishes.
    func refreshSummaryIfNeeded(chatId: Int64) async throws
}

/// Produces a short summary of older turns.
protocol Summarizer: Sendable {
    func summarize(previousSummary: String?, messages: [Message]) async -> String
}
