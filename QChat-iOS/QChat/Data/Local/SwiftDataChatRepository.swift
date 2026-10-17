import Foundation
import SwiftData

/// All database access happens on this actor (SwiftData's `@ModelActor` gives it its own
/// `ModelContext`), which keeps the UI thread free and serialises writes like Room does.
@ModelActor
actor ChatStore {
    private var nextChatId: Int64?
    private var nextMessageId: Int64?

    // MARK: Chats

    func listChats() throws -> [Chat] {
        let d = FetchDescriptor<ChatEntity>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let entities = try modelContext.fetch(d)
        try migrateSessionIds(entities)
        return entities.map { $0.toDomain() }
    }

    func getChat(_ id: Int64) throws -> Chat? {
        guard let entity = try chatEntity(id) else { return nil }
        try migrateSessionIds([entity])
        return entity.toDomain()
    }

    func createChat(title: String, now: Int64) throws -> Int64 {
        let id = try allocateChatId()
        modelContext.insert(ChatEntity(id: id, sessionId: Self.newSessionId(), title: title, createdAt: now, updatedAt: now))
        try modelContext.save()
        return id
    }

    func renameChat(_ id: Int64, title: String, now: Int64) throws {
        guard let c = try chatEntity(id) else { return }
        c.title = title
        c.updatedAt = now
        try modelContext.save()
    }

    func touchChat(_ id: Int64, preview: String, now: Int64) throws {
        guard let c = try chatEntity(id) else { return }
        c.preview = preview
        c.updatedAt = now
        try modelContext.save()
    }

    func updateSummary(_ id: Int64, summary: String, through: Int64) throws {
        guard let c = try chatEntity(id) else { return }
        c.summary = summary
        c.summaryThroughMessageId = through
        try modelContext.save()
    }

    func deleteChat(_ id: Int64) throws {
        let cid = id
        try modelContext.delete(model: MessagePartEntity.self, where: #Predicate { $0.chatId == cid })
        try modelContext.delete(model: MessageEntity.self, where: #Predicate { $0.chatId == cid })
        try modelContext.delete(model: ChatEntity.self, where: #Predicate { $0.id == cid })
        try modelContext.save()
    }

    func deleteChatIfEmpty(_ id: Int64) throws {
        let cid = id
        var d = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.chatId == cid })
        d.fetchLimit = 1
        if try modelContext.fetchCount(d) == 0 { try deleteChat(id) }
    }

    // MARK: Messages

    func listMessages(_ chatId: Int64) throws -> [Message] {
        let cid = chatId
        let messages = try modelContext.fetch(FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.chatId == cid },
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
        ))
        let parts = try modelContext.fetch(FetchDescriptor<MessagePartEntity>(predicate: #Predicate { $0.chatId == cid }))
        let byMessage = Dictionary(grouping: parts, by: \.messageId)
        return messages.map { $0.toDomain(parts: byMessage[$0.id] ?? []) }
    }

    func chatIdOf(messageId: Int64) throws -> Int64? { try messageEntity(messageId)?.chatId }

    func insertMessage(chatId: Int64, role: MessageRole, parts: [MessagePart], status: MessageStatus, now: Int64) throws -> Int64 {
        let id = try allocateMessageId()
        modelContext.insert(MessageEntity(id: id, chatId: chatId, role: role.rawValue, status: status.rawValue, createdAt: now))
        for (i, p) in parts.enumerated() { modelContext.insert(p.toEntity(messageId: id, chatId: chatId, position: i)) }
        try modelContext.save()
        return id
    }

    /// Replace the text of a streaming message and update its status in one save.
    func updateContent(messageId: Int64, text: String, thinking: String?, status: MessageStatus, error: String?) throws {
        guard let m = try messageEntity(messageId) else { return }
        let mid = messageId
        try modelContext.delete(model: MessagePartEntity.self, where: #Predicate { $0.messageId == mid && $0.type == "TEXT" })
        modelContext.insert(MessagePartEntity(messageId: mid, chatId: m.chatId, position: 0, type: "TEXT", text: text))
        m.status = status.rawValue
        m.thinking = thinking
        m.error = error
        try modelContext.save()
    }

    // MARK: Helpers

    private func chatEntity(_ id: Int64) throws -> ChatEntity? {
        let cid = id
        var d = FetchDescriptor<ChatEntity>(predicate: #Predicate { $0.id == cid })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    private func messageEntity(_ id: Int64) throws -> MessageEntity? {
        let mid = id
        var d = FetchDescriptor<MessageEntity>(predicate: #Predicate { $0.id == mid })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    /// Adding an optional field is a lightweight SwiftData migration. Existing rows receive nil;
    /// fill each one once and save it so every old chat gets a stable identity without data loss.
    private func migrateSessionIds(_ entities: [ChatEntity]) throws {
        var changed = false
        for entity in entities where entity.sessionId?.isEmpty != false {
            entity.sessionId = Self.newSessionId()
            changed = true
        }
        if changed { try modelContext.save() }
    }

    private static func newSessionId() -> String { UUID().uuidString.lowercased() }

    /// Ids are monotonically increasing like Room's autoincrement; the compactor relies on order.
    private func allocateChatId() throws -> Int64 {
        if nextChatId == nil {
            var d = FetchDescriptor<ChatEntity>(sortBy: [SortDescriptor(\.id, order: .reverse)])
            d.fetchLimit = 1
            nextChatId = (try modelContext.fetch(d).first?.id ?? 0) + 1
        }
        defer { nextChatId! += 1 }
        return nextChatId!
    }

    private func allocateMessageId() throws -> Int64 {
        if nextMessageId == nil {
            var d = FetchDescriptor<MessageEntity>(sortBy: [SortDescriptor(\.id, order: .reverse)])
            d.fetchLimit = 1
            nextMessageId = (try modelContext.fetch(d).first?.id ?? 0) + 1
        }
        defer { nextMessageId! += 1 }
        return nextMessageId!
    }
}

/// `ChatRepository` backed by SwiftData (Android's `RoomChatRepository`).
final class SwiftDataChatRepository: ChatRepository, @unchecked Sendable {
    private let store: ChatStore
    private let bus = ChangeBus()

    init(container: ModelContainer) {
        store = ChatStore(modelContainer: container)
    }

    /// `Application Support/qchat.store` (the folder is not guaranteed to exist on first launch).
    static var storeUrl: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("qchat.store")
    }

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([ChatEntity.self, MessageEntity.self, MessagePartEntity.self])
        let config = inMemory
            ? ModelConfiguration("qchat-tests", schema: schema, isStoredInMemoryOnly: true)
            : ModelConfiguration("qchat", schema: schema, url: storeUrl)
        return try ModelContainer(for: schema, configurations: [config])
    }

    func observeChats() -> AsyncStream<[Chat]> {
        bus.observing { [store] in (try? await store.listChats()) ?? [] }
    }

    func observeChat(_ chatId: Int64) -> AsyncStream<Chat?> {
        bus.observing { [store] in try? await store.getChat(chatId) }
    }

    func observeMessages(_ chatId: Int64) -> AsyncStream<[Message]> {
        bus.observing { [store] in (try? await store.listMessages(chatId)) ?? [] }
    }

    func getChat(_ chatId: Int64) async throws -> Chat? { try await store.getChat(chatId) }
    func getMessages(_ chatId: Int64) async throws -> [Message] { try await store.listMessages(chatId) }

    func createChat(title: String) async throws -> Int64 {
        let id = try await store.createChat(title: title, now: Self.now())
        await bus.notify()
        return id
    }

    func renameChat(_ chatId: Int64, title: String) async throws {
        try await store.renameChat(chatId, title: title, now: Self.now())
        await bus.notify()
    }

    func deleteChat(_ chatId: Int64) async throws {
        try await store.deleteChat(chatId)
        await bus.notify()
    }

    func deleteChatIfEmpty(_ chatId: Int64) async throws {
        try await store.deleteChatIfEmpty(chatId)
        await bus.notify()
    }

    func addMessage(chatId: Int64, role: MessageRole, parts: [MessagePart], status: MessageStatus) async throws -> Int64 {
        let now = Self.now()
        let id = try await store.insertMessage(chatId: chatId, role: role, parts: parts, status: status, now: now)
        // Chat-list preview: the typed text, or "[attached: …]" when the message is attachment-only.
        let preview = Message(id: id, chatId: chatId, role: role, parts: parts, status: status, createdAt: now)
            .briefText.replacingOccurrences(of: "\n", with: " ").take(120)
        if !preview.isBlank { try await store.touchChat(chatId, preview: preview, now: now) }
        await bus.notify()
        return id
    }

    func updateMessageContent(messageId: Int64, text: String, thinking: String?, status: MessageStatus, error: String?) async throws {
        try await store.updateContent(messageId: messageId, text: text, thinking: thinking, status: status, error: error)
        // Once a reply settles, surface it as the chat-list preview.
        if status != .streaming, !text.isBlank, let chatId = try await store.chatIdOf(messageId: messageId) {
            try await store.touchChat(chatId, preview: text.take(120), now: Self.now())
        }
        await bus.notify()
    }

    func updateSummary(chatId: Int64, summary: String, throughMessageId: Int64) async throws {
        try await store.updateSummary(chatId, summary: summary, through: throughMessageId)
        await bus.notify()
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
