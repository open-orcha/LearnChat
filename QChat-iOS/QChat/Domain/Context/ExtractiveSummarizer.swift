import Foundation

/// Zero-cost fallback: clip each older message to its first sentence-ish and join them.
/// Used when the model is unreachable or while a model-made summary is still being generated.
struct ExtractiveSummarizer: Summarizer {
    var perMessageChars: Int = 160
    var maxChars: Int = 1200

    func summarize(previousSummary: String?, messages: [Message]) async -> String {
        var sb = ""
        if let prev = previousSummary, !prev.isBlank { sb += prev.trimmed + "\n" }
        for m in messages {
            let who = m.role == .user ? "User" : "Assistant"
            var clipped = m.briefText.replacingOccurrences(of: "\n", with: " ").trimmed
            if clipped.count > perMessageChars {
                clipped = clipped.take(perMessageChars).trimmingTrailingWhitespace() + "…"
            }
            if clipped.isEmpty { continue }
            sb += "- \(who): \(clipped)\n"
        }
        let out = sb.trimmed
        return out.count > maxChars ? "…" + out.takeLast(maxChars) : out
    }
}

extension String {
    func trimmingTrailingWhitespace() -> String {
        var s = Substring(self)
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return String(s)
    }
}
