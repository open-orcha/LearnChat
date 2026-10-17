import Foundation

/// Who authored a message. Mirrors the roles the server understands.
enum MessageRole: String, Sendable, Codable {
    case user = "USER"
    case assistant = "ASSISTANT"
    case system = "SYSTEM"
}

/// Lifecycle of a message on the device.
enum MessageStatus: String, Sendable, Codable {
    /// Fully written, safe to send as history.
    case complete = "COMPLETE"
    /// Assistant reply still arriving token-by-token.
    case streaming = "STREAMING"
    /// User pressed Stop before the reply finished.
    case stopped = "STOPPED"
    /// The request failed; `Message.error` explains why.
    case failed = "FAILED"
}

/// A photo, or a video (when `mimeType` starts with `video/`; then `uri` points at the picked clip
/// and `thumbnailUri` at a first-frame JPEG). `extractedText` is the on-device description
/// (labels + OCR, or a frame-by-frame timeline for video).
struct ImagePart: Equatable, Hashable, Sendable {
    var uri: String
    var mimeType: String
    var width: Int? = nil
    var height: Int? = nil
    var name: String? = nil
    var extractedText: String? = nil
    var thumbnailUri: String? = nil

    var isVideo: Bool { mimeType.hasPrefix("video/") }
}

/// A document (PDF today). `extractedText` is its text layer, extracted on the phone.
struct FilePart: Equatable, Hashable, Sendable {
    var uri: String
    var name: String
    var mimeType: String
    var sizeBytes: Int64? = nil
    var extractedText: String? = nil
    var pageCount: Int? = nil
}

struct AudioPart: Equatable, Hashable, Sendable {
    var uri: String
    var mimeType: String
    var durationMs: Int64? = nil
    var transcript: String? = nil
}

/// One piece of a message. A message is a list of parts so that images, files and audio can be
/// added without changing the message table or the UI list.
///
/// Attachments carry the text the phone derived from them (`ImagePart.extractedText`,
/// `FilePart.extractedText`) — that derived text is what a text-only model actually receives; see
/// `promptText`. The original file stays on the phone (copied into app storage, see `uri`).
enum MessagePart: Equatable, Hashable, Sendable {
    case text(String)
    case image(ImagePart)
    case file(FilePart)
    case audio(AudioPart)

    var isText: Bool { if case .text = self { return true } else { return false } }

    /// Short human label for an attachment part, e.g. `PDF "report.pdf"`.
    var attachmentLabel: String? {
        switch self {
        case .text: return nil
        case .image(let p): return (p.isVideo ? "video" : "photo") + (p.name.map { " \"\($0)\"" } ?? "")
        case .file(let p): return "PDF \"\(p.name)\""
        case .audio: return "audio clip"
        }
    }

    /// What the model receives for this part. Text is passed through; attachments become a clearly
    /// delimited block of the text the phone derived from them, so a text-only model can reason about
    /// a PDF, photo or video it cannot see.
    var promptText: String {
        switch self {
        case .text(let t):
            return t
        case .file(let p):
            let pages = p.pageCount.map { ", \($0) page\($0 == 1 ? "" : "s")" } ?? ""
            let body = p.extractedText.flatMap { $0.isBlank ? nil : $0 } ?? "(no readable text could be extracted from this file)"
            return "[Attached PDF: \"\(p.name)\"\(pages) — text extracted on the user's phone]\n\(body)\n[End of \"\(p.name)\"]"
        case .image(let p):
            let kind = p.isVideo ? "video" : "photo"
            let title = p.name.map { " \"\($0)\"" } ?? ""
            let body = p.extractedText.flatMap { $0.isBlank ? nil : $0 } ?? "(the phone could not make out anything in it)"
            return "[Attached \(kind)\(title) — you cannot see it, so the user's phone analysed it on-device. What it found:]\n\(body)\n[End of \(kind)]"
        case .audio(let p):
            return p.transcript.map { "[Attached audio clip, transcript]\n\($0)\n[End of audio]" } ?? "[Attached audio clip]"
        }
    }
}

struct Message: Equatable, Hashable, Sendable, Identifiable {
    let id: Int64
    let chatId: Int64
    var role: MessageRole
    var parts: [MessagePart]
    var status: MessageStatus = .complete
    /// Model reasoning trace (if the server sends one). Hidden by default in the UI.
    var thinking: String? = nil
    var error: String? = nil
    let createdAt: Int64

    /// Convenience: all text parts joined (what the user typed / the model replied).
    var text: String {
        parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
    }

    /// Attachment parts only (images, videos, files, audio).
    var attachments: [MessagePart] { parts.filter { !$0.isText } }

    /// Full content as sent to the model: typed text plus the derived text of every attachment.
    var promptText: String { parts.map(\.promptText).joined(separator: "\n\n").trimmed }

    /// Typed text plus a one-line mention per attachment — for summaries, previews and titles.
    var briefText: String {
        let tags = attachments.compactMap(\.attachmentLabel)
        return tags.isEmpty ? text : (text + "\n[attached: \(tags.joined(separator: ", "))]").trimmed
    }
}

extension String {
    var isBlank: Bool { allSatisfy(\.isWhitespace) }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Kotlin's `take(n)` on characters.
    func take(_ n: Int) -> String { String(prefix(n)) }
    /// Kotlin's `takeLast(n)` on characters.
    func takeLast(_ n: Int) -> String { String(suffix(n)) }
}
