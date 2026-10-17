package com.qchat.app.domain.context

import com.qchat.app.domain.model.Message
import com.qchat.app.domain.model.MessageRole

/**
 * Zero-cost fallback: clip each older message to its first sentence-ish and join them.
 * Used when the model is unreachable or while a model-made summary is still being generated.
 */
class ExtractiveSummarizer(
    private val perMessageChars: Int = 160,
    private val maxChars: Int = 1200,
) : Summarizer {
    override suspend fun summarize(previousSummary: String?, messages: List<Message>): String {
        val sb = StringBuilder()
        if (!previousSummary.isNullOrBlank()) sb.append(previousSummary.trim()).append('\n')
        for (m in messages) {
            val who = if (m.role == MessageRole.USER) "User" else "Assistant"
            val clipped = m.briefText.replace('\n', ' ').trim().let { if (it.length > perMessageChars) it.take(perMessageChars).trimEnd() + "…" else it }
            if (clipped.isEmpty()) continue
            sb.append("- ").append(who).append(": ").append(clipped).append('\n')
        }
        val out = sb.toString().trim()
        return if (out.length > maxChars) "…" + out.takeLast(maxChars) else out
    }
}
