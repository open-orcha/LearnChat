package com.qchat.app.data.preprocess

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import com.tom_roush.pdfbox.text.PDFTextStripper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.coroutines.coroutineContext

data class PdfExtraction(
    val text: String,
    val pageCount: Int,
    /** Pages that had no text layer and were OCR'd from a rendered bitmap instead. */
    val ocrPages: Int,
    /** True if extraction stopped early because [PdfTextExtractor.maxChars] was reached. */
    val truncated: Boolean,
)

/**
 * Pulls the text out of a PDF on the phone. Digital PDFs give up their text layer through
 * PDFBox-Android page by page; a page with no text layer (a scan) is rendered with Android's
 * built-in [PdfRenderer] and read with on-device OCR instead.
 */
class PdfTextExtractor(
    private val analyzer: ImageAnalyzer,
    private val maxChars: Int,
    /** Render resolution for OCR of scanned pages (longest side, px). */
    private val ocrRenderSide: Int = 1600,
    /** Pages whose text layer is shorter than this are treated as scans. */
    private val minTextCharsPerPage: Int = 20,
) {
    suspend fun extract(file: File, onProgress: (page: Int, total: Int, ocr: Boolean) -> Unit): PdfExtraction =
        withContext(Dispatchers.IO) {
            val doc = try {
                PDDocument.load(file, MemoryUsageSetting.setupTempFileOnly())
            } catch (e: InvalidPasswordException) {
                throw IllegalStateException("This PDF is password-protected")
            }
            doc.use { pdf ->
                val total = pdf.numberOfPages
                val out = StringBuilder()
                var ocrPages = 0
                var truncated = false
                var renderer: PdfRenderer? = null
                try {
                    val stripper = PDFTextStripper().apply { sortByPosition = true }
                    for (page in 1..total) {
                        coroutineContext.ensureActive()
                        onProgress(page, total, false)
                        stripper.startPage = page
                        stripper.endPage = page
                        var pageText = runCatching { stripper.getText(pdf) }.getOrDefault("").trim()
                        if (pageText.length < minTextCharsPerPage) {
                            // No usable text layer: render the page and OCR it.
                            onProgress(page, total, true)
                            if (renderer == null) renderer = PdfRenderer(ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY))
                            val ocr = runCatching { analyzer.readText(renderPage(renderer, page - 1)) }.getOrDefault("").trim()
                            if (ocr.length > pageText.length) { pageText = ocr; ocrPages++ }
                        }
                        if (pageText.isEmpty()) continue
                        if (total > 1) out.append("--- page $page ---\n")
                        out.append(pageText).append("\n\n")
                        if (out.length >= maxChars) { truncated = true; break }
                    }
                } finally {
                    renderer?.close()
                }
                val text = if (truncated) out.substring(0, maxChars).trimEnd() + "\n[… PDF text cut here to keep the message a manageable size]" else out.toString().trim()
                PdfExtraction(text, total, ocrPages, truncated)
            }
        }

    private fun renderPage(renderer: PdfRenderer, index: Int): Bitmap = renderer.openPage(index).use { page ->
        val scale = ocrRenderSide.toFloat() / maxOf(page.width, page.height)
        val w = (page.width * scale).toInt().coerceAtLeast(1)
        val h = (page.height * scale).toInt().coerceAtLeast(1)
        Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).also { bmp ->
            bmp.eraseColor(Color.WHITE) // PdfRenderer draws onto transparent pixels; OCR wants a white page
            page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
        }
    }
}
