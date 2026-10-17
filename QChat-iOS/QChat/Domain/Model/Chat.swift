import Foundation

struct Chat: Equatable, Hashable, Sendable {
    let id: Int64
    /// Stable opaque ID sent to the runtime for this conversation's cache lease.
    let sessionId: String
    var title: String
    let createdAt: Int64
    var updatedAt: Int64
    /// Last message preview for the chat list.
    var preview: String = ""
    /// Rolling summary of older turns (see ContextCompactor).
    var summary: String? = nil
    /// Id of the last message covered by `summary`; older messages are folded into it.
    var summaryThroughMessageId: Int64? = nil

    init(
        id: Int64,
        sessionId: String = UUID().uuidString.lowercased(),
        title: String,
        createdAt: Int64,
        updatedAt: Int64,
        preview: String = "",
        summary: String? = nil,
        summaryThroughMessageId: Int64? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.preview = preview
        self.summary = summary
        self.summaryThroughMessageId = summaryThroughMessageId
    }
}
