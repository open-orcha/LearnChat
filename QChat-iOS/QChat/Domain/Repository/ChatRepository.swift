import Foundation

protocol ChatRepository: AnyObject, Sendable {
    func observeChats() -> AsyncStream<[Chat]>
    func observeChat(_ chatId: Int64) -> AsyncStream<Chat?>
    func observeMessages(_ chatId: Int64) -> AsyncStream<[Message]>

    func getChat(_ chatId: Int64) async throws -> Chat?
    func getMessages(_ chatId: Int64) async throws -> [Message]

    func createChat(title: String) async throws -> Int64
    func renameChat(_ chatId: Int64, title: String) async throws
    func deleteChat(_ chatId: Int64) async throws
    /// Removes the chat only if it never received a message (backing out of a fresh "New chat").
    func deleteChatIfEmpty(_ chatId: Int64) async throws

    func addMessage(chatId: Int64, role: MessageRole, parts: [MessagePart], status: MessageStatus) async throws -> Int64
    func updateMessageContent(messageId: Int64, text: String, thinking: String?, status: MessageStatus, error: String?) async throws

    func updateSummary(chatId: Int64, summary: String, throughMessageId: Int64) async throws
}

extension ChatRepository {
    func createChat() async throws -> Int64 { try await createChat(title: "New chat") }

    func addMessage(chatId: Int64, role: MessageRole, parts: [MessagePart]) async throws -> Int64 {
        try await addMessage(chatId: chatId, role: role, parts: parts, status: .complete)
    }

    func updateMessageContent(messageId: Int64, text: String, thinking: String?, status: MessageStatus) async throws {
        try await updateMessageContent(messageId: messageId, text: text, thinking: thinking, status: status, error: nil)
    }
}
