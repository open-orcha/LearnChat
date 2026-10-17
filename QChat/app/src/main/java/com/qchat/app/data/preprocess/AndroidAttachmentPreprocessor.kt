package com.qchat.app.data.preprocess

import android.content.Context
import android.net.Uri
import com.qchat.app.domain.model.MessagePart
import com.qchat.app.domain.preprocess.AttachmentKind
import com.qchat.app.domain.preprocess.AttachmentPreprocessor
import com.qchat.app.domain.preprocess.PreprocessProgress
import com.qchat.app.domain.preprocess.PreprocessedAttachment
import com.qchat.app.domain.preprocess.UnsupportedAttachmentException
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import java.util.Locale

/**
 * The on-device preprocessing pipeline, one branch per [AttachmentKind]:
 *
 *  - PDF   → copy into app storage, extract the text layer page by page (OCR for scanned pages).
 *  - Image → downscale to ≤1280 px JPEG (kept for the bubble thumbnail and, when the server has a
 *            vision model, for sending as-is), then OCR + labels.
 *  - Video → sample up to [maxVideoFrames] frames, OCR + label each, build a timeline. Only the
 *            first frame is kept (as the thumbnail); the clip itself is never copied.
 *
 * Nothing here touches the network. The resulting [MessagePart] carries the derived text.
 */
class AndroidAttachmentPreprocessor(
    private val context: Context,
    override val maxCharsPerAttachment: Int = 24_000,
    private val maxVideoFrames: Int = 8,
) : AttachmentPreprocessor {

    private val store = AttachmentStore(context)
    private val sampler = VideoFrameSampler(context)

    init {
        // PDFBox needs its font/colour-space resources loaded once per process.
        PDFBoxResourceLoader.init(context.applicationContext)
    }

    override suspend fun preprocess(
        uri: String,
        mimeType: String?,
        displayName: String?,
        onProgress: (PreprocessProgress) -> Unit,
    ): PreprocessedAttachment {
        val source = Uri.parse(uri)
        val info = store.describe(source, displayName, mimeType)
        val kind = AttachmentKind.fromMime(info.mimeType) ?: throw UnsupportedAttachmentException(info.mimeType)
        return ImageAnalyzer().use { analyzer ->
            when (kind) {
                AttachmentKind.PDF -> pdf(source, info, analyzer, onProgress)
                AttachmentKind.IMAGE -> image(source, info, analyzer, onProgress)
                AttachmentKind.VIDEO -> video(source, info, analyzer, onProgress)
            }
        }
    }

    private suspend fun pdf(source: Uri, info: PickedFileInfo, analyzer: ImageAnalyzer, onProgress: (PreprocessProgress) -> Unit): PreprocessedAttachment {
        onProgress(PreprocessProgress("Copying"))
        val file = store.copyIn(source, "pdf")
        val extraction = PdfTextExtractor(analyzer, maxCharsPerAttachment).extract(file) { page, total, ocr ->
            onProgress(PreprocessProgress(if (ocr) "Scanning page" else "Reading page", page, total))
        }
        val words = wordCount(extraction.text)
        val summary = buildString {
            append("${extraction.pageCount} page${if (extraction.pageCount == 1) "" else "s"} · ")
            append(if (words == 0) "no readable text" else "${fmt(words)} words")
            if (extraction.ocrPages > 0) append(" · ${extraction.ocrPages} scanned")
            if (extraction.truncated) append(" · trimmed")
        }
        return PreprocessedAttachment(
            MessagePart.File(
                uri = file.toURI().toString(), name = info.displayName, mimeType = "application/pdf",
                sizeBytes = info.sizeBytes ?: file.length(), extractedText = extraction.text, pageCount = extraction.pageCount,
            ),
            summary,
        )
    }

    private suspend fun image(source: Uri, info: PickedFileInfo, analyzer: ImageAnalyzer, onProgress: (PreprocessProgress) -> Unit): PreprocessedAttachment {
        onProgress(PreprocessProgress("Preparing photo"))
        val bitmap = store.decodeScaled(source, maxSide = 1280)
        val copy = store.saveJpeg(bitmap)
        onProgress(PreprocessProgress("Looking at photo"))
        val analysis = analyzer.analyze(bitmap)
        val text = analysis.describe().take(maxCharsPerAttachment)
        val summary = when {
            analysis.isEmpty -> "nothing recognised"
            else -> listOfNotNull(
                analysis.labels.take(3).joinToString(", ") { it.first.lowercase(Locale.US) }.ifBlank { null },
                analysis.text.takeIf { it.isNotBlank() }?.let { "${fmt(wordCount(it))} words of text" },
            ).joinToString(" · ")
        }
        return PreprocessedAttachment(
            MessagePart.Image(
                uri = copy.toURI().toString(), mimeType = "image/jpeg", width = bitmap.width, height = bitmap.height,
                name = info.displayName, extractedText = text, thumbnailUri = copy.toURI().toString(),
            ),
            summary,
        )
    }

    private suspend fun video(source: Uri, info: PickedFileInfo, analyzer: ImageAnalyzer, onProgress: (PreprocessProgress) -> Unit): PreprocessedAttachment {
        onProgress(PreprocessProgress("Opening video"))
        val sample = sampler.sample(source, maxVideoFrames) { i, n -> onProgress(PreprocessProgress("Frame", i, n)) }
        val thumb = store.saveJpeg(sample.frames.first().bitmap.scaledTo(640))
        val lines = mutableListOf<String>()
        val allLabels = linkedMapOf<String, Float>()
        sample.frames.forEachIndexed { i, frame ->
            onProgress(PreprocessProgress("Looking at frame", i + 1, sample.frames.size))
            val a = analyzer.analyze(frame.bitmap)
            a.labels.forEach { (l, c) -> allLabels[l] = maxOf(allLabels[l] ?: 0f, c) }
            val at = clock(frame.timeMs)
            lines += "$at — " + (if (a.isEmpty) "nothing recognisable" else a.describe().replace("\n", " · "))
        }
        val text = buildString {
            append("Duration ${clock(sample.durationMs)}; ${sample.frames.size} frame${if (sample.frames.size == 1) "" else "s"} sampled and analysed on the phone.\n")
            if (allLabels.isNotEmpty()) append("Overall it seems to show: ").append(allLabels.entries.sortedByDescending { it.value }.take(8).joinToString(", ") { it.key.lowercase(Locale.US) }).append('\n')
            append("Timeline:\n").append(lines.joinToString("\n"))
        }.take(maxCharsPerAttachment)
        val summary = "${clock(sample.durationMs)} · ${sample.frames.size} frames" +
            (allLabels.keys.take(3).joinToString(", ") { it.lowercase(Locale.US) }.takeIf { it.isNotBlank() }?.let { " · $it" } ?: "")
        return PreprocessedAttachment(
            MessagePart.Image(
                uri = source.toString(), mimeType = info.mimeType ?: "video/*",
                width = sample.frames.first().bitmap.width, height = sample.frames.first().bitmap.height,
                name = info.displayName, extractedText = text, thumbnailUri = thumb.toURI().toString(),
            ),
            summary,
        )
    }

    private fun wordCount(s: String) = s.split(Regex("\\s+")).count { it.isNotBlank() }
    private fun fmt(n: Int) = String.format(Locale.US, "%,d", n)
    private fun clock(ms: Long): String {
        val s = ms / 1000
        return "%d:%02d".format(s / 60, s % 60)
    }
}
