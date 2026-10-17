import SwiftUI

/// Three bouncing dots, like the "assistant is typing" affordance in ChatGPT / Claude.
struct TypingIndicator: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(LearnChatTheme.onSurfaceVariant)
                    .frame(width: 7, height: 7)
                    .offset(y: phase ? -5 : 0)
                    .animation(
                        .easeInOut(duration: 0.3).repeatForever(autoreverses: true).delay(Double(i) * 0.12),
                        value: phase
                    )
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .onAppear { phase = true }
    }
}

/// Blinking caret appended to the streaming text (on 400 ms, off 400 ms).
struct BlinkingCaret: View {
    let color: Color
    @State private var visible = true

    var body: some View {
        Text("▍")
            .foregroundStyle(color.opacity(visible ? 1 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.001).delay(0.4).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}
