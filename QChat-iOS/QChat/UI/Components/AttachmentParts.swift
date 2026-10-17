import SwiftUI
import UIKit

/// Renders a PDF attachment inside a bubble: name + page count, tap to reveal the extracted text.
struct FilePartView: View {
    let part: FilePart
    let textColor: Color

    private var meta: String {
        [
            part.pageCount.map { "\($0) page\($0 == 1 ? "" : "s")" },
            part.sizeBytes.map(humanSize),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill").foregroundStyle(textColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text(part.name).font(QChatType.bodyMedium).foregroundStyle(textColor)
                    if !meta.isEmpty {
                        Text(meta).font(QChatType.labelSmall).foregroundStyle(textColor.opacity(0.7))
                    }
                }
            }
            DerivedTextSection(title: "Text extracted on this phone", text: part.extractedText, color: textColor)
        }
    }
}

/// Renders a photo or video attachment: thumbnail, then what the phone made of it.
struct ImagePartView: View {
    let part: ImagePart
    let textColor: Color
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 220)
                } else {
                    Rectangle()
                        .fill(textColor.opacity(0.1))
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
                if part.isVideo {
                    Image(systemName: "play.fill")
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.5), in: Circle())
                        .accessibilityLabel("Video")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .task(id: part.thumbnailUri ?? part.uri) { image = await loadFileImage(part.thumbnailUri ?? part.uri) }
            if let name = part.name {
                Text(name).font(QChatType.labelSmall).foregroundStyle(textColor.opacity(0.7)).padding(.top, 4)
            }
            DerivedTextSection(
                title: part.isVideo ? "What this phone saw in the video" : "What this phone saw in the photo",
                text: part.extractedText,
                color: textColor
            )
        }
    }
}

/// Collapsible block showing the text that was sent to the model on the user's behalf.
private struct DerivedTextSection: View {
    let title: String
    let text: String?
    let color: Color
    var previewChars = 1500
    @State private var expanded = false

    var body: some View {
        if let text, !text.isBlank {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 2) {
                        Text(title).font(QChatType.labelMedium)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(color.opacity(0.8))
                }
                .buttonStyle(.plain)
                if expanded {
                    let shown = text.count > previewChars
                        ? text.take(previewChars) + "\n… (\(text.count - previewChars) more characters were sent)"
                        : text
                    Text(shown)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(color.opacity(0.9))
                        .textSelection(.enabled)
                        .padding(10)
                        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.top, 4)
                }
            }
            .padding(.top, 6)
        }
    }
}

/// Decodes a `file://` JPEG in app storage off the main thread; nil if missing.
func loadFileImage(_ uri: String?) async -> UIImage? {
    guard let uri, let url = URL(string: uri) else { return nil }
    return await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path) }.value
}

private func humanSize(_ bytes: Int64) -> String {
    if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
    if bytes >= 1_000 { return "\(bytes / 1_000) KB" }
    return "\(bytes) B"
}
