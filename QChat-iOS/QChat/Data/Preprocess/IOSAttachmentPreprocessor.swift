import Foundation

/// The on-device preprocessing pipeline, one branch per `AttachmentKind`:
///
///  - PDF   → copy into app storage, extract the text layer page by page (OCR for scanned pages).
///  - Image → downscale to ≤1280 px JPEG (kept for the bubble thumbnail and, when the server has a
///            vision model, for sending as-is), then OCR + labels.
///  - Video → sample up to `maxVideoFrames` frames, OCR + label each, build a timeline. Only the
///            first frame is kept (as the thumbnail); the clip itself is never copied.
///
/// Nothing here touches the network. The resulting `MessagePart` carries the derived text.
struct IOSAttachmentPreprocessor: AttachmentPreprocessor {
    let maxCharsPerAttachment: Int
    private let maxVideoFrames: Int
    private let store = AttachmentStore()
    private let sampler = VideoFrameSampler()
    private let analyzer = ImageAnalyzer()

    init(maxCharsPerAttachment: Int = 24_000, maxVideoFrames: Int = 8) {
        self.maxCharsPerAttachment = maxCharsPerAttachment
        self.maxVideoFrames = maxVideoFrames
    }

    func preprocess(
        url: URL,
        mimeType: String?,
        displayName: String?,
        onProgress: @escaping @Sendable (PreprocessProgress) -> Void
    ) async throws -> PreprocessedAttachment {
        // Files-app URLs are security-scoped; hold the grant for the whole run.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let info = store.describe(url, fallbackName: displayName, fallbackMime: mimeType)
        guard let kind = AttachmentKind.fromMime(info.mimeType) else { throw UnsupportedAttachmentError(mimeType: info.mimeType) }
        switch kind {
        case .pdf: return try await pdf(url, info, onProgress)
        case .image: return try await image(url, info, onProgress)
        case .video: return try await video(url, info, onProgress)
        }
    }

    private func pdf(_ source: URL, _ info: PickedFileInfo, _ onProgress: @escaping @Sendable (PreprocessProgress) -> Void) async throws -> PreprocessedAttachment {
        onProgress(PreprocessProgress(step: "Copying"))
        let file = try store.copyIn(source, extension: "pdf")
        let extraction = try await PdfTextExtractor(analyzer: analyzer, maxChars: maxCharsPerAttachment).extract(file) { page, total, ocr in
            onProgress(PreprocessProgress(step: ocr ? "Scanning page" : "Reading page", done: page, total: total))
        }
        let words = wordCount(extraction.text)
        var summary = "\(extraction.pageCount) page\(extraction.pageCount == 1 ? "" : "s") · "
        summary += words == 0 ? "no readable text" : "\(fmt(words)) words"
        if extraction.ocrPages > 0 { summary += " · \(extraction.ocrPages) scanned" }
        if extraction.truncated { summary += " · trimmed" }
        let size = info.sizeBytes ?? Int64((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0)
        return PreprocessedAttachment(
            part: .file(FilePart(
                uri: file.absoluteString, name: info.displayName, mimeType: "application/pdf",
                sizeBytes: size, extractedText: extraction.text, pageCount: extraction.pageCount
            )),
            summary: summary
        )
    }

    private func image(_ source: URL, _ info: PickedFileInfo, _ onProgress: @escaping @Sendable (PreprocessProgress) -> Void) async throws -> PreprocessedAttachment {
        onProgress(PreprocessProgress(step: "Preparing photo"))
        let bitmap = try store.decodeScaled(source, maxSide: 1280)
        let copy = try store.saveJpeg(bitmap)
        onProgress(PreprocessProgress(step: "Looking at photo"))
        let analysis = try await analyzer.analyze(bitmap)
        let text = analysis.describe().take(maxCharsPerAttachment)
        let summary: String
        if analysis.isEmpty {
            summary = "nothing recognised"
        } else {
            var bits: [String] = []
            let top = analysis.labels.prefix(3).map { $0.0.lowercased() }.joined(separator: ", ")
            if !top.isBlank { bits.append(top) }
            if !analysis.text.isBlank { bits.append("\(fmt(wordCount(analysis.text))) words of text") }
            summary = bits.joined(separator: " · ")
        }
        return PreprocessedAttachment(
            part: .image(ImagePart(
                uri: copy.absoluteString, mimeType: "image/jpeg", width: bitmap.width, height: bitmap.height,
                name: info.displayName, extractedText: text, thumbnailUri: copy.absoluteString
            )),
            summary: summary
        )
    }

    private func video(_ source: URL, _ info: PickedFileInfo, _ onProgress: @escaping @Sendable (PreprocessProgress) -> Void) async throws -> PreprocessedAttachment {
        onProgress(PreprocessProgress(step: "Opening video"))
        let sample = try await sampler.sample(source, maxFrames: maxVideoFrames) { i, n in
            onProgress(PreprocessProgress(step: "Frame", done: i, total: n))
        }
        let first = sample.frames[0].image
        let thumb = try store.saveJpeg(first.scaledTo(640))
        var lines: [String] = []
        var allLabels: [(String, Float)] = []   // insertion-ordered, max confidence per label
        for (i, frame) in sample.frames.enumerated() {
            onProgress(PreprocessProgress(step: "Looking at frame", done: i + 1, total: sample.frames.count))
            let a = try await analyzer.analyze(frame.image)
            for (l, c) in a.labels {
                if let idx = allLabels.firstIndex(where: { $0.0 == l }) { allLabels[idx].1 = max(allLabels[idx].1, c) } else { allLabels.append((l, c)) }
            }
            lines.append("\(clock(frame.timeMs)) — " + (a.isEmpty ? "nothing recognisable" : a.describe().replacingOccurrences(of: "\n", with: " · ")))
        }
        var text = "Duration \(clock(sample.durationMs)); \(sample.frames.count) frame\(sample.frames.count == 1 ? "" : "s") sampled and analysed on the phone.\n"
        if !allLabels.isEmpty {
            text += "Overall it seems to show: " + allLabels.sorted { $0.1 > $1.1 }.prefix(8).map { $0.0.lowercased() }.joined(separator: ", ") + "\n"
        }
        text += "Timeline:\n" + lines.joined(separator: "\n")
        text = text.take(maxCharsPerAttachment)
        var summary = "\(clock(sample.durationMs)) · \(sample.frames.count) frames"
        let top = allLabels.prefix(3).map { $0.0.lowercased() }.joined(separator: ", ")
        if !top.isBlank { summary += " · \(top)" }
        return PreprocessedAttachment(
            part: .image(ImagePart(
                uri: source.absoluteString, mimeType: info.mimeType ?? "video/*",
                width: first.width, height: first.height,
                name: info.displayName, extractedText: text, thumbnailUri: thumb.absoluteString
            )),
            summary: summary
        )
    }

    private func wordCount(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }

    private func fmt(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    private func clock(_ ms: Int64) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
