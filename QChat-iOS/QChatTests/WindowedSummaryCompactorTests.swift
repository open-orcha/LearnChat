import XCTest
@testable import QChat

final class WindowedSummaryCompactorTests: XCTestCase {

    private final class FakeRepo: ChatRepository, @unchecked Sendable {
        var chat: Chat
        var messages: [Message]
        var savedSummary: (String, Int64)?

        init(chat: Chat, messages: [Message]) {
            self.chat = chat
            self.messages = messages
        }

        func observeChats() -> AsyncStream<[Chat]> { AsyncStream { $0.yield([chat]); $0.finish() } }
        func observeChat(_ chatId: Int64) -> AsyncStream<Chat?> { AsyncStream { $0.yield(chat); $0.finish() } }
        func observeMessages(_ chatId: Int64) -> AsyncStream<[Message]> { AsyncStream { $0.yield(messages); $0.finish() } }
        func getChat(_ chatId: Int64) async throws -> Chat? { chat }
        func getMessages(_ chatId: Int64) async throws -> [Message] { messages }
        func createChat(title: String) async throws -> Int64 { 1 }
        func renameChat(_ chatId: Int64, title: String) async throws {}
        func deleteChat(_ chatId: Int64) async throws {}
        func deleteChatIfEmpty(_ chatId: Int64) async throws {}
        func addMessage(chatId: Int64, role: MessageRole, parts: [MessagePart], status: MessageStatus) async throws -> Int64 { 0 }
        func updateMessageContent(messageId: Int64, text: String, thinking: String?, status: MessageStatus, error: String?) async throws {}
        func updateSummary(chatId: Int64, summary: String, throughMessageId: Int64) async throws {
            savedSummary = (summary, throughMessageId)
            chat.summary = summary
            chat.summaryThroughMessageId = throughMessageId
        }
    }

    private final class FakeSettings: SettingsRepository, @unchecked Sendable {
        let s: AppSettings
        init(_ s: AppSettings) { self.s = s }
        var settings: AsyncStream<AppSettings> { AsyncStream { $0.yield(s); $0.finish() } }
        func current() async -> AppSettings { s }
        func update(_ transform: @Sendable (AppSettings) -> AppSettings) async {}
    }

    private func msg(_ id: Int64, _ role: MessageRole, _ text: String) -> Message {
        Message(id: id, chatId: 1, role: role, parts: [.text(text)], status: .complete, createdAt: id)
    }

    private func history(_ n: Int) -> [Message] {
        (1...n).map { i in msg(Int64(i), i % 2 == 1 ? .user : .assistant, "message number \(i)") }
    }

    private func settings(window: Int) -> AppSettings {
        var s = AppSettings.default
        s.verbatimWindow = window
        return s
    }

    private func text(of turn: ChatTurn) -> String {
        if case .text(let t) = turn.parts.first! { return t }
        XCTFail("expected a text part")
        return ""
    }

    func testShortChatsAreSentVerbatimWithNoSummary() async {
        let settings = settings(window: 6)
        let repo = FakeRepo(chat: Chat(id: 1, title: "t", createdAt: 0, updatedAt: 0), messages: history(4))
        let compactor = WindowedSummaryCompactor(repository: repo, settingsRepository: FakeSettings(settings), summarizer: ExtractiveSummarizer())
        let turns = await compactor.buildContext(chat: repo.chat, history: repo.messages, settings: settings)
        XCTAssertEqual(turns.count, 4)
        XCTAssertFalse(turns.contains { $0.role == .system })
    }

    func testLongChatsGetASystemSummaryPlusTheLastNVerbatim() async {
        let settings = settings(window: 4)
        let repo = FakeRepo(chat: Chat(id: 1, title: "t", createdAt: 0, updatedAt: 0), messages: history(10))
        let compactor = WindowedSummaryCompactor(repository: repo, settingsRepository: FakeSettings(settings), summarizer: ExtractiveSummarizer())
        let turns = await compactor.buildContext(chat: repo.chat, history: repo.messages, settings: settings)
        XCTAssertEqual(turns.count, 5)
        XCTAssertEqual(turns.first?.role, .system)
        let summary = text(of: turns[0])
        XCTAssertTrue(summary.contains("message number 1"))
        XCTAssertFalse(summary.contains("message number 7"))
        XCTAssertEqual(text(of: turns[1]), "message number 7")
    }

    func testStoredSummaryIsReusedAndOnlyUncoveredOlderTurnsAreClipped() async {
        let settings = settings(window: 4)
        let chat = Chat(id: 1, title: "t", createdAt: 0, updatedAt: 0, summary: "The user likes tea.", summaryThroughMessageId: 4)
        let repo = FakeRepo(chat: chat, messages: history(10))
        let compactor = WindowedSummaryCompactor(repository: repo, settingsRepository: FakeSettings(settings), summarizer: ExtractiveSummarizer())
        let turns = await compactor.buildContext(chat: repo.chat, history: repo.messages, settings: settings)
        let summary = text(of: turns[0])
        XCTAssertTrue(summary.contains("The user likes tea."))
        XCTAssertFalse(summary.contains("message number 3"))
        XCTAssertTrue(summary.contains("message number 5"))
    }

    func testRefreshStoresANewSummaryOnceEnoughHistoryIsOutsideTheWindow() async throws {
        let settings = settings(window: 4)
        let repo = FakeRepo(chat: Chat(id: 1, title: "t", createdAt: 0, updatedAt: 0), messages: history(10))
        let compactor = WindowedSummaryCompactor(
            repository: repo, settingsRepository: FakeSettings(settings), summarizer: ExtractiveSummarizer(), refreshThreshold: 4
        )
        try await compactor.refreshSummaryIfNeeded(chatId: 1)
        let (text, through) = try XCTUnwrap(repo.savedSummary)
        XCTAssertEqual(through, 6)
        XCTAssertTrue(text.contains("message number 6"))
    }
}
