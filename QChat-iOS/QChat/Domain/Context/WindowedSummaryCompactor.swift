import Foundation

/// Simple on-device compaction:
///  - the last `AppSettings.verbatimWindow` messages are sent word-for-word;
///  - everything older is replaced by one short rolling summary (kept on the chat row);
///  - a rough token budget clips the verbatim window if messages are very long;
///  - older messages not yet covered by the stored summary are clipped extractively so the
///    prompt is always coherent even before the background summariser has caught up.
final class WindowedSummaryCompactor: ContextCompactor, @unchecked Sendable {
    private let repository: ChatRepository
    private let settingsRepository: SettingsRepository
    private let summarizer: Summarizer
    private let quickSummarizer: Summarizer
    private let tokenBudget: Int
    /// Refresh the model summary once this many uncovered messages sit outside the window.
    private let refreshThreshold: Int

    /// Serialises summary refreshes (Kotlin's Mutex).
    private let refreshLock = AsyncLock()

    init(
        repository: ChatRepository,
        settingsRepository: SettingsRepository,
        summarizer: Summarizer,
        quickSummarizer: Summarizer = ExtractiveSummarizer(),
        tokenBudget: Int = 6000,
        refreshThreshold: Int = 4
    ) {
        self.repository = repository
        self.settingsRepository = settingsRepository
        self.summarizer = summarizer
        self.quickSummarizer = quickSummarizer
        self.tokenBudget = tokenBudget
        self.refreshThreshold = refreshThreshold
    }

    func buildContext(chat: Chat, history: [Message], settings: AppSettings) async -> [ChatTurn] {
        let usable = history.filter { $0.status != .failed && !$0.promptText.isBlank }
        let window = max(settings.verbatimWindow, 2)
        var verbatim = Array(usable.suffix(window))
        var older = Array(usable.dropLast(verbatim.count))

        // Clip the verbatim window to the token budget, moving overflow into "older".
        while verbatim.count > 2 && estimateTokens(verbatim) > tokenBudget {
            older.append(verbatim.removeFirst())
        }

        var turns: [ChatTurn] = []
        let summaryText = await summaryFor(chat: chat, older: older)
        if !summaryText.isBlank {
            turns.append(.text(
                .system,
                "You are continuing an earlier conversation with this user. Summary of what was said before:\n"
                    + summaryText + "\nContinue naturally and stay consistent with it."
            ))
        }
        for m in verbatim {
            turns.append(ChatTurn(role: m.role, parts: m.parts.isEmpty ? [.text(m.text)] : m.parts))
        }
        return turns
    }

    /// Stored summary + extractive clip of anything older that the stored summary doesn't cover yet.
    private func summaryFor(chat: Chat, older: [Message]) async -> String {
        if older.isEmpty { return "" }
        let coveredThrough = chat.summaryThroughMessageId ?? -1
        let uncovered = older.filter { $0.id > coveredThrough }
        let stored = coveredThrough >= 0 ? chat.summary : nil
        if uncovered.isEmpty { return stored ?? "" }
        return await quickSummarizer.summarize(previousSummary: stored, messages: uncovered)
    }

    func refreshSummaryIfNeeded(chatId: Int64) async throws {
        try await refreshLock.withLock {
            guard let chat = try await repository.getChat(chatId) else { return }
            let settings = await settingsRepository.current()
            let usable = try await repository.getMessages(chatId).filter { $0.status == .complete && !$0.promptText.isBlank }
            let older = Array(usable.dropLast(max(settings.verbatimWindow, 2)))
            let coveredThrough = chat.summaryThroughMessageId ?? -1
            let uncovered = older.filter { $0.id > coveredThrough }
            if uncovered.count < refreshThreshold { return }
            let summary = await summarizer.summarize(previousSummary: chat.summary, messages: uncovered)
            try await repository.updateSummary(chatId: chatId, summary: summary, throughMessageId: uncovered.last!.id)
        }
    }

    /// Rough chars/4 estimate over what is actually sent (typed text + derived attachment text).
    private func estimateTokens(_ messages: [Message]) -> Int {
        messages.reduce(0) { $0 + ($1.promptText.count + 3) / 4 }
    }
}

/// Minimal async mutex: callers queue up and run `body` one at a time.
actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}
