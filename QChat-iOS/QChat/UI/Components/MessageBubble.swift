import SwiftUI

/// One chat bubble: user messages on the right in the primary colour, assistant replies on the
/// left on a tonal surface. Parts render one by one so image/file/audio parts slot in.
struct MessageBubble: View {
    let message: Message
    let showThinking: Bool

    private var isUser: Bool { message.role == .user }
    private var streaming: Bool { message.status == .streaming }
    private var bubbleColor: Color { isUser ? QChatTheme.primary : QChatTheme.surfaceContainerHigh }
    private var textColor: Color { isUser ? QChatTheme.onPrimary : QChatTheme.onSurface }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 0) {
                if !isUser, let thinking = message.thinking, !thinking.isBlank {
                    ThinkingSection(thinking: thinking, expandedByDefault: showThinking, live: streaming && message.text.isEmpty)
                }
                if streaming && message.text.isEmpty {
                    TypingIndicator()
                } else {
                    ForEach(Array(message.parts.enumerated()), id: \.offset) { i, part in
                        if i > 0 { Spacer().frame(height: 6) }
                        switch part {
                        case .text(let text):
                            HStack(alignment: .lastTextBaseline, spacing: 0) {
                                Text(text)
                                    .font(QChatType.bodyLarge)
                                    .foregroundStyle(textColor)
                                    .textSelection(.enabled)
                                if streaming { BlinkingCaret(color: textColor) }
                            }
                        case .image(let image):
                            ImagePartView(part: image, textColor: textColor)
                        case .file(let file):
                            FilePartView(part: file, textColor: textColor)
                        case .audio:
                            Text("Audio clip").font(QChatType.bodyMedium).foregroundStyle(textColor.opacity(0.7))
                        }
                    }
                }
                switch message.status {
                case .stopped: StatusLine(text: "Stopped", color: textColor)
                case .failed: StatusLine(text: message.error.map { "Failed: \($0)" } ?? "Failed", color: QChatTheme.error)
                default: EmptyView()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(bubbleColor, in: BubbleShape(isUser: isUser))
            // Cap the bubble at 320 pt (Android widthIn(max = 320.dp)) without stretching short ones.
            .frame(maxWidth: 320, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

/// Rounded bubble with a small "tail" corner (Android: 18 dp corners, 4 dp on the tail side).
private struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 18
        let small: CGFloat = 4
        return UnevenRoundedRectangle(
            topLeadingRadius: big,
            bottomLeadingRadius: isUser ? big : small,
            bottomTrailingRadius: isUser ? small : big,
            topTrailingRadius: big,
            style: .continuous
        ).path(in: rect)
    }
}

private struct ThinkingSection: View {
    let thinking: String
    let expandedByDefault: Bool
    let live: Bool
    @State private var expanded: Bool? = nil

    private var isExpanded: Bool { expanded ?? expandedByDefault }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded = !isExpanded }
            } label: {
                HStack(spacing: 2) {
                    Text(live ? "Thinking…" : "Show reasoning")
                        .font(QChatType.labelMedium)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(QChatTheme.onSurfaceVariant)
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text(thinking.trimmed)
                    .font(QChatType.bodySmall.italic())
                    .foregroundStyle(QChatTheme.onSurfaceVariant)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(QChatTheme.surfaceContainerLowest, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.top, 4)
            }
        }
        .padding(.bottom, 6)
    }
}

private struct StatusLine: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(QChatType.labelSmall)
            .foregroundStyle(color.opacity(0.8))
            .padding(.top, 4)
    }
}
