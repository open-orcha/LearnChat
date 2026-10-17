import Foundation

/// What kind of file the user picked, decided from its MIME type.
enum AttachmentKind: Sendable {
    case pdf, image, video

    static func fromMime(_ mimeType: String?) -> AttachmentKind? {
        guard let mimeType else { return nil }
        if mimeType == "application/pdf" { return .pdf }
        if mimeType.hasPrefix("image/") { return .image }
        if mimeType.hasPrefix("video/") { return .video }
        return nil
    }
}

/// Progress reported while a file is being processed, for the chip under the composer.
struct PreprocessProgress: Sendable {
    var step: String
    var done: Int = 0
    var total: Int = 0

    var label: String { total > 0 ? "\(step) \(done)/\(total)" : step }
}

/// Result of on-device preprocessing: the `MessagePart` to attach to the outgoing message (with its
/// derived text filled in) plus a short human summary for the UI, e.g. "12 pages · 4,210 words".
struct PreprocessedAttachment: Sendable {
    var part: MessagePart
    var summary: String
}

/// Turns a user-picked file into a `MessagePart` whose derived text a text-only model can use.
/// All work happens on the phone: PDF text extraction, image OCR + labelling, video frame sampling.
/// The data layer provides the iOS implementation; the domain only sees this protocol.
protocol AttachmentPreprocessor: Sendable {
    /// Limits the derived text so one attachment cannot swamp the prompt.
    var maxCharsPerAttachment: Int { get }

    /// - Parameters:
    ///   - url: a file URL the app can open (may be security-scoped, from the Files picker)
    ///   - mimeType: as reported by the picker (may be nil; the implementation may sniff it)
    ///   - displayName: the file name to show and to mention to the model
    func preprocess(
        url: URL,
        mimeType: String?,
        displayName: String?,
        onProgress: @escaping @Sendable (PreprocessProgress) -> Void
    ) async throws -> PreprocessedAttachment
}

struct UnsupportedAttachmentError: LocalizedError {
    let mimeType: String?
    var errorDescription: String? {
        "Unsupported file type\(mimeType.map { " (\($0))" } ?? ""). Pick a PDF, photo or video."
    }
}

/// A plain-text error surfaced to the user ("This PDF is password-protected", ...).
struct PreprocessError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
