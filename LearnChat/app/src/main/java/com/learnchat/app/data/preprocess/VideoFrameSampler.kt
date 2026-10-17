package com.learnchat.app.data.preprocess

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext

data class SampledFrame(val timeMs: Long, val bitmap: Bitmap)

data class VideoSample(val durationMs: Long, val frames: List<SampledFrame>)

/**
 * Pulls a handful of evenly spaced frames out of a video with Android's built-in
 * [MediaMetadataRetriever] (hardware decoder, no copy of the clip is made). Each frame is then
 * treated like a photo by the caller.
 */
class VideoFrameSampler(private val context: Context, private val maxSide: Int = 960) {

    suspend fun sample(uri: Uri, maxFrames: Int, onFrame: (index: Int, total: Int) -> Unit): VideoSample =
        withContext(Dispatchers.IO) {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(context, uri)
                val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                // Short clips get fewer frames: roughly one every 5 s, at least 1, at most maxFrames.
                val count = if (durationMs <= 0) 1 else ((durationMs / 5_000L) + 1).toInt().coerceIn(1, maxFrames)
                val frames = ArrayList<SampledFrame>(count)
                for (i in 0 until count) {
                    coroutineContext.ensureActive()
                    onFrame(i + 1, count)
                    // Spread across the clip but stay clear of the very last frame, which often fails to decode.
                    val t = if (count == 1) durationMs / 2 else (durationMs * i) / count + (durationMs / count) / 2
                    val bmp = retriever.getFrameAtTime(t * 1000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: continue
                    frames += SampledFrame(t, bmp.scaledTo(maxSide))
                }
                if (frames.isEmpty()) throw IllegalStateException("Could not decode any frames from this video")
                VideoSample(durationMs, frames)
            } finally {
                runCatching { retriever.release() }
            }
        }
}
