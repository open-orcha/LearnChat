import SwiftUI

/// Message input bar: attach button, text field, send/stop. Picked files show as chips above the
/// field while the phone preprocesses them; Send waits until every chip is ready.
struct Composer: View {
    @Binding var text: String
    let sending: Bool
    let pending: [PendingAttachment]
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let onAttachPhoto: () -> Void
    let onAttachFile: () -> Void
    let onRemoveAttachment: (Int64) -> Void
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 0) {
            if !pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pending) { a in
                            AttachmentChip(attachment: a) { onRemoveAttachment(a.id) }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            HStack(alignment: .bottom, spacing: 0) {
                // iOS has no single "any document" picker that also covers the photo library, so the
                // paperclip offers both sources.
                Menu {
                    Button(action: onAttachPhoto) { Label("Photo or video", systemImage: "photo.on.rectangle") }
                    Button(action: onAttachFile) { Label("PDF from Files", systemImage: "doc.text") }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(sending ? LearnChatTheme.onSurfaceVariant.opacity(0.38) : LearnChatTheme.onSurfaceVariant)
                }
                .disabled(sending)
                .accessibilityLabel("Attach a PDF, photo or video")

                TextField(pending.isEmpty ? "Message" : "Ask about the attachment…", text: $text, axis: .vertical)
                    .font(LearnChatType.bodyLarge)
                    .lineLimit(1...6)
                    .focused(focused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(focused.wrappedValue ? LearnChatTheme.primary : LearnChatTheme.outline, lineWidth: focused.wrappedValue ? 2 : 1)
                    )
                    .frame(minHeight: 48)

                Button {
                    if sending { onStop() } else { onSend() }
                } label: {
                    Image(systemName: sending ? "stop.fill" : "paperplane.fill")
                        .font(.system(size: 18))
                        .frame(width: 48, height: 48)
                        .background(sending ? LearnChatTheme.errorContainer : LearnChatTheme.primary, in: Circle())
                        .foregroundStyle(sending ? LearnChatTheme.onErrorContainer : LearnChatTheme.onPrimary)
                        .opacity(sending || canSend ? 1 : 0.38)
                }
                .disabled(!(sending || canSend))
                .padding(.leading, 8)
                .accessibilityLabel(sending ? "Stop" : "Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(LearnChatTheme.surfaceContainer)
    }
}

/// Material InputChip: icon / spinner, name + status line, remove button.
private struct AttachmentChip: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    private var detail: String {
        switch attachment.state {
        case .processing: return attachment.progress ?? "Processing…"
        case .ready: return attachment.summary ?? "Ready"
        case .failed: return attachment.error ?? "Failed"
        }
    }

    private var ready: Bool { attachment.state == .ready }

    var body: some View {
        HStack(spacing: 8) {
            switch attachment.state {
            case .processing:
                ProgressView().controlSize(.small).frame(width: 18, height: 18)
            case .failed:
                Image(systemName: "exclamationmark.circle").foregroundStyle(LearnChatTheme.error)
            case .ready:
                Image(systemName: attachment.kind.iconName).foregroundStyle(LearnChatTheme.onSurfaceVariant)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.name).font(LearnChatType.labelLarge).lineLimit(1).foregroundStyle(LearnChatTheme.onSurface)
                Text(detail)
                    .font(LearnChatType.labelSmall)
                    .lineLimit(1)
                    .foregroundStyle(attachment.state == .failed ? LearnChatTheme.error : LearnChatTheme.onSurfaceVariant)
            }
            .frame(maxWidth: 200, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
            }
            .foregroundStyle(LearnChatTheme.onSurfaceVariant)
            .accessibilityLabel("Remove attachment")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(ready ? LearnChatTheme.surfaceContainerHighest : LearnChatTheme.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(ready ? Color.clear : LearnChatTheme.outline, lineWidth: 1))
    }
}

extension Optional where Wrapped == AttachmentKind {
    var iconName: String {
        switch self {
        case .pdf: return "doc.text.fill"
        case .video: return "video.fill"
        case .image, .none: return "photo.fill"
        }
    }
}
