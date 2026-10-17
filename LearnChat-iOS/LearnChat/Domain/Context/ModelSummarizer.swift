import Foundation

/// Asks the model itself to fold older turns into a compact running summary. Falls back to
/// `ExtractiveSummarizer` on any failure so the chat never loses continuity.
struct ModelSummarizer: Summarizer {
    let clientProvider: ChatServerClientProvider
    let settings: SettingsRepository
    var fallback: Summarizer = ExtractiveSummarizer()

    func summarize(previousSummary: String?, messages: [Message]) async -> String {
        var transcript = ""
        for m in messages {
            transcript += (m.role == .user ? "User: " : "Assistant: ") + m.briefText.trimmed + "\n\n"
        }
        var prompt = "You are compressing a chat history so the conversation can continue later with less context.\n"
        if let prev = previousSummary, !prev.isBlank {
            prompt += "Existing summary of earlier turns:\n" + prev.trimmed + "\n\n"
        }
        prompt += "New turns to fold into the summary:\n" + transcript
        prompt += "Write an updated summary in at most 120 words. Keep facts, names, numbers, decisions, "
        prompt += "user preferences and anything the user asked to remember. Plain prose, no preamble."

        do {
            let model = await settings.current().modelName
            let request = ChatRequest(model: model, turns: [.text(.user, prompt)], includeThinking: false)
            let out = try await clientProvider().complete(request).trimmed
            return out.isBlank ? await fallback.summarize(previousSummary: previousSummary, messages: messages) : out
        } catch {
            return await fallback.summarize(previousSummary: previousSummary, messages: messages)
        }
    }
}
