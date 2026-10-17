package com.learnchat.app.data.preprocess

import android.graphics.Bitmap
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.label.ImageLabeling
import com.google.mlkit.vision.label.defaults.ImageLabelerOptions
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import java.io.Closeable
import java.util.Locale

/** What the phone could make out in one picture. */
data class ImageAnalysis(
    /** Object / scene labels with confidence 0..1, best first. */
    val labels: List<Pair<String, Float>>,
    /** Text read from the picture (OCR), line breaks preserved; empty if none. */
    val text: String,
) {
    val isEmpty: Boolean get() = labels.isEmpty() && text.isBlank()

    /** Model-facing description, e.g. "Looks like: dog (93%), grass (81%)\nText visible: ...". */
    fun describe(): String = buildString {
        if (labels.isNotEmpty()) {
            append("Looks like: ")
            append(labels.joinToString(", ") { (l, c) -> "${l.lowercase(Locale.US)} (${(c * 100).toInt()}%)" })
        }
        if (text.isNotBlank()) {
            if (isNotEmpty()) append('\n')
            append("Text visible in it:\n").append(text.trim())
        }
    }
}

/**
 * On-device OCR (ML Kit text recognition, Latin script) and image labelling (ML Kit's bundled
 * 400-label classifier). Both models ship inside the APK, so this works offline and never sends
 * pixels anywhere. Use one instance per preprocessing run and [close] it afterwards.
 */
class ImageAnalyzer(
    private val minLabelConfidence: Float = 0.55f,
    private val maxLabels: Int = 8,
) : Closeable {
    private val textRecognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    private val labeler = ImageLabeling.getClient(
        ImageLabelerOptions.Builder().setConfidenceThreshold(minLabelConfidence).build(),
    )

    suspend fun analyze(bitmap: Bitmap, ocr: Boolean = true, labels: Boolean = true): ImageAnalysis {
        val image = InputImage.fromBitmap(bitmap, 0)
        val found = if (labels) {
            labeler.process(image).await()
                .sortedByDescending { it.confidence }
                .take(maxLabels)
                .map { it.text to it.confidence }
        } else emptyList()
        val text = if (ocr) textRecognizer.process(image).await().text else ""
        return ImageAnalysis(found, text)
    }

    /** OCR only — used for scanned PDF pages, where labels are meaningless. */
    suspend fun readText(bitmap: Bitmap): String = analyze(bitmap, ocr = true, labels = false).text

    override fun close() {
        textRecognizer.close()
        labeler.close()
    }
}
