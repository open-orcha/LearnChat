import Foundation
import PDFKit
import UIKit

struct PdfExtraction: Sendable {
    var text: String
    var pageCount: Int
    /// Pages that had no text layer and were OCR'd from a rendered bitmap instead.
    var ocrPages: Int
    /// True if extraction stopped early because `PdfTextExtractor.maxChars` was reached.
    var truncated: Bool
}

/// Pulls the text out of a PDF on the phone. Digital PDFs give up their text layer through PDFKit
/// page by page; a page with no text layer (a scan) is rendered and read with on-device OCR instead.
struct PdfTextExtractor: Sendable {
    let analyzer: ImageAnalyzer
    let maxChars: Int
    /// Render resolution for OCR of scanned pages (longest side, px).
    var ocrRenderSide: CGFloat = 1600
    /// Pages whose text layer is shorter than this are treated as scans.
    var minTextCharsPerPage: Int = 20

    func extract(_ url: URL, onProgress: @escaping @Sendable (_ page: Int, _ total: Int, _ ocr: Bool) -> Void) async throws -> PdfExtraction {
        guard let doc = PDFDocument(url: url) else { throw PreprocessError("Could not open this PDF") }
        if doc.isLocked { throw PreprocessError("This PDF is password-protected") }
        let total = doc.pageCount
        var out = ""
        var ocrPages = 0
        var truncated = false
        for index in 0..<total {
            try Task.checkCancellation()
            let page = index + 1
            onProgress(page, total, false)
            guard let pdfPage = doc.page(at: index) else { continue }
            var pageText = (pdfPage.string ?? "").trimmed
            if pageText.count < minTextCharsPerPage {
                // No usable text layer: render the page and OCR it.
                onProgress(page, total, true)
                if let rendered = render(pdfPage) {
                    let ocr = ((try? await analyzer.readText(rendered)) ?? "").trimmed
                    if ocr.count > pageText.count { pageText = ocr; ocrPages += 1 }
                }
            }
            if pageText.isEmpty { continue }
            if total > 1 { out += "--- page \(page) ---\n" }
            out += pageText + "\n\n"
            if out.count >= maxChars { truncated = true; break }
        }
        let text = truncated
            ? out.take(maxChars).trimmingTrailingWhitespace() + "\n[… PDF text cut here to keep the message a manageable size]"
            : out.trimmed
        return PdfExtraction(text: text, pageCount: total, ocrPages: ocrPages, truncated: truncated)
    }

    /// Draws the page onto a white bitmap (OCR wants a white page) at `ocrRenderSide` px.
    private func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = ocrRenderSide / max(bounds.width, bounds.height)
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.saveGState()
            // PDF space is bottom-up; flip and scale so the page fills the bitmap.
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: cg)
            cg.restoreGState()
        }
        return image.cgImage
    }
}
