package com.qchat.app.data.preprocess

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import com.google.android.gms.tasks.Task
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.max
import kotlin.math.roundToInt

/** Name / size / MIME of a picked document, read from the content provider. */
data class PickedFileInfo(val displayName: String, val sizeBytes: Long?, val mimeType: String?)

/**
 * Keeps attachments under `filesDir/attachments/`. Content URIs from the system picker are only
 * readable while the grant lasts, so anything we want to show again (thumbnails, the PDF) is
 * copied here first.
 */
class AttachmentStore(private val context: Context) {
    private val dir: File get() = File(context.filesDir, "attachments").apply { mkdirs() }

    fun describe(uri: Uri, fallbackName: String?, fallbackMime: String?): PickedFileInfo {
        var name: String? = null
        var size: Long? = null
        runCatching {
            context.contentResolver.query(uri, null, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val s = c.getColumnIndex(OpenableColumns.SIZE)
                    if (n >= 0) name = c.getString(n)
                    if (s >= 0 && !c.isNull(s)) size = c.getLong(s)
                }
            }
        }
        val resolvedName = name ?: fallbackName ?: uri.lastPathSegment ?: "file"
        val mime = fallbackMime ?: context.contentResolver.getType(uri)
            ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(resolvedName.substringAfterLast('.', "").lowercase())
        return PickedFileInfo(resolvedName, size, mime)
    }

    /** Copies the content behind [uri] into app storage and returns the new file. */
    suspend fun copyIn(uri: Uri, extension: String): File = withContext(Dispatchers.IO) {
        val target = newFile(extension)
        context.contentResolver.openInputStream(uri)?.use { input ->
            FileOutputStream(target).use { out -> input.copyTo(out) }
        } ?: throw IllegalStateException("Could not open the selected file")
        target
    }

    /**
     * Decodes the image at [uri] scaled so its longest side is at most [maxSide], applying EXIF
     * rotation on API 28+. Large photos are subsampled during decode to keep memory in check.
     */
    suspend fun decodeScaled(uri: Uri, maxSide: Int): Bitmap = withContext(Dispatchers.IO) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val source = ImageDecoder.createSource(context.contentResolver, uri)
            ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                val scale = max(info.size.width, info.size.height).toFloat() / maxSide
                if (scale > 1f) decoder.setTargetSize((info.size.width / scale).roundToInt(), (info.size.height / scale).roundToInt())
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.isMutableRequired = false
            }
        } else {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            var sample = 1
            while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            val bmp = context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, opts) }
                ?: throw IllegalStateException("Could not decode image")
            bmp.scaledTo(maxSide)
        }
    }

    /** Writes [bitmap] as a JPEG into app storage. */
    suspend fun saveJpeg(bitmap: Bitmap, quality: Int = 85): File = withContext(Dispatchers.IO) {
        val target = newFile("jpg")
        FileOutputStream(target).use { bitmap.compress(Bitmap.CompressFormat.JPEG, quality, it) }
        target
    }

    private fun newFile(extension: String) = File(dir, "${UUID.randomUUID()}.$extension")
}

/** Scales so the longest side is at most [maxSide]; returns the same bitmap if already small enough. */
fun Bitmap.scaledTo(maxSide: Int): Bitmap {
    val longest = max(width, height)
    if (longest <= maxSide) return this
    val scale = maxSide.toFloat() / longest
    return Bitmap.createScaledBitmap(this, (width * scale).roundToInt(), (height * scale).roundToInt(), true)
}

/** Suspend on a Play-services style [Task] (ML Kit returns these); cancelling the coroutine drops the result. */
suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { cont ->
    addOnSuccessListener { if (cont.isActive) cont.resume(it) }
    addOnFailureListener { if (cont.isActive) cont.resumeWithException(it) }
    addOnCanceledListener { cont.cancel() }
}
