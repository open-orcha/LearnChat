import Foundation
import Vision

/// What the phone could make out in one picture.
struct ImageAnalysis: Sendable {
    /// Object / scene labels with confidence 0..1, best first.
    var labels: [(String, Float)]
    /// Text read from the picture (OCR), line breaks preserved; empty if none.
    var text: String

    var isEmpty: Bool { labels.isEmpty && text.isBlank }

    /// Model-facing description, e.g. "Looks like: dog (93%), grass (81%)\nText visible: ...".
    func describe() -> String {
        var s = ""
        if !labels.isEmpty {
            s += "Looks like: "
            s += labels.map { "\($0.0.lowercased()) (\(Int($0.1 * 100))%)" }.joined(separator: ", ")
        }
        if !text.isBlank {
            if !s.isEmpty { s += "\n" }
            s += "Text visible in it:\n" + text.trimmed
        }
        return s
    }
}

/// On-device OCR (Vision text recognition) and image classification (Vision's built-in scene /
/// object classifier). Both run inside the OS, so this works offline and never sends pixels
/// anywhere. Android used ML Kit for the same two jobs.
struct ImageAnalyzer: Sendable {
    /// Vision's classifier reports many low-confidence labels; keep the confident ones only.
    var minLabelConfidence: Float = 0.55
    var maxLabels: Int = 8

    func analyze(_ image: CGImage, ocr: Bool = true, labels: Bool = true) async throws -> ImageAnalysis {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) { [self] in
            var found: [(String, Float)] = []
            var text = ""
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            // The two requests run separately so one failing (the classifier needs the device's
            // ML runtime and is unavailable in the Simulator) doesn't lose the other's result.
            var failure: Error?
            var requestSucceeded = false
            if labels {
                let classify = VNClassifyImageRequest()
                do {
                    try handler.perform([classify])
                    requestSucceeded = true
                    found = (classify.results ?? [])
                        .filter { $0.confidence >= minLabelConfidence }
                        .sorted { $0.confidence > $1.confidence }
                        .prefix(maxLabels)
                        .map { ($0.identifier.replacingOccurrences(of: "_", with: " "), $0.confidence) }
                } catch {
                    failure = error
                }
            }
            if ocr {
                let recognize = VNRecognizeTextRequest()
                recognize.recognitionLevel = .accurate
                recognize.usesLanguageCorrection = true
                do {
                    try handler.perform([recognize])
                    requestSucceeded = true
                    text = (recognize.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                } catch {
                    failure = error
                }
            }
            // Empty output is valid (for example a photo with no text). Only give up when neither
            // Vision request could run at all.
            if !requestSucceeded, let failure { throw failure }
            return ImageAnalysis(labels: found, text: text)
        }.value
    }

    /// OCR only — used for scanned PDF pages, where labels are meaningless.
    func readText(_ image: CGImage) async throws -> String {
        try await analyze(image, ocr: true, labels: false).text
    }
}
