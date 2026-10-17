package com.qchat.app.data.remote.museglimmer

import com.qchat.app.domain.model.ChatRequest
import com.qchat.app.domain.model.ChatTurn
import com.qchat.app.domain.model.HeartbeatResult
import com.qchat.app.domain.model.MessagePart
import com.qchat.app.domain.model.MessageRole
import com.qchat.app.domain.model.promptText
import com.qchat.app.domain.model.ServerException
import com.qchat.app.domain.model.ServerInfo
import com.qchat.app.domain.model.StreamEvent
import com.qchat.app.domain.repository.ChatServerClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.BufferedSource
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * [ChatServerClient] for the Muse Glimmer service. Streaming uses newline-delimited JSON:
 * each line is one chunk carrying either a `message.thinking` or `message.content` delta, and the
 * final line has `done: true`.
 */
class MuseGlimmerChatClient(
    private val baseUrl: String,
    private val http: OkHttpClient = defaultHttp(),
    /** Reads a photo or sampled video-frame file and returns it base64-encoded. */
    private val imageEncoder: (MessagePart.Image) -> String? = { null },
) : ChatServerClient {

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = false }
    private val jsonType = "application/json; charset=utf-8".toMediaType()

    override fun streamChat(request: ChatRequest): Flow<StreamEvent> = flow {
        val body = json.encodeToString(MuseGlimmerChatRequest.serializer(), request.toWireRequest(stream = true))
        val call = http.newCall(chatRequest(request.sessionId, body))
        val response = call.await()
        response.use { resp ->
            if (!resp.isSuccessful) throw httpError(resp)
            val source = resp.body?.source() ?: throw ServerException("Empty response body")
            while (true) {
                val line = source.readUtf8LineCancellable(call) ?: break
                if (line.isBlank()) continue
                val chunk = json.decodeFromString(MuseGlimmerChatChunk.serializer(), line)
                chunk.error?.let { throw ServerException(it) }
                chunk.message?.thinking?.takeIf { it.isNotEmpty() }?.let { emit(StreamEvent.ThinkingDelta(it)) }
                chunk.message?.content?.takeIf { it.isNotEmpty() }?.let { emit(StreamEvent.ContentDelta(it)) }
                if (chunk.done) {
                    emit(StreamEvent.Done(chunk.totalDurationNs?.let { it / 1_000_000 }, chunk.evalCount))
                    break
                }
            }
        }
    }.flowOn(Dispatchers.IO)

    override suspend fun complete(request: ChatRequest): String = withContext(Dispatchers.IO) {
        val body = json.encodeToString(MuseGlimmerChatRequest.serializer(), request.toWireRequest(stream = false))
        val call = http.newCall(chatRequest(request.sessionId, body))
        call.await().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw ServerException("Server error ${resp.code}: ${text.take(300)}", statusCode = resp.code)
            val chunk = json.decodeFromString(MuseGlimmerChatChunk.serializer(), text)
            chunk.error?.let { throw ServerException(it) }
            chunk.message?.content.orEmpty()
        }
    }

    override suspend fun heartbeat(sessionId: String): HeartbeatResult = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url(endpoint("/api/sessions/$sessionId/heartbeat"))
            .post(ByteArray(0).toRequestBody(null))
            .build()
        http.newCall(request).await().use { resp ->
            when (resp.code) {
                200 -> HeartbeatResult.RENEWED
                404 -> HeartbeatResult.MISSING
                else -> throw httpError(resp)
            }
        }
    }

    override suspend fun ping(): ServerInfo = withContext(Dispatchers.IO) {
        try {
            http.newCall(Request.Builder().url(endpoint("/api/tags")).get().build()).await().use { resp ->
                val text = resp.body?.string().orEmpty()
                if (!resp.isSuccessful) return@withContext ServerInfo(false, emptyList(), "HTTP ${resp.code}")
                val tags = json.decodeFromString(MuseGlimmerModelsResponse.serializer(), text)
                ServerInfo(true, tags.models.map { it.name })
            }
        } catch (e: IOException) {
            ServerInfo(false, emptyList(), e.message ?: e.javaClass.simpleName)
        }
    }

    private fun endpoint(path: String): String = baseUrl.trimEnd('/') + path

    private fun chatRequest(sessionId: String?, body: String): Request {
        val builder = Request.Builder()
            .url(endpoint("/api/chat"))
            .post(body.toRequestBody(jsonType))
        if (!sessionId.isNullOrBlank()) builder.header("X-Muse-Session-ID", sessionId)
        return builder.build()
    }

    private fun httpError(response: Response): ServerException {
        val text = response.body?.string().orEmpty()
        return ServerException("Server error ${response.code}: ${text.take(300)}", statusCode = response.code)
    }

    private fun ChatRequest.toWireRequest(stream: Boolean) = MuseGlimmerChatRequest(
        model = model,
        messages = turns.map { it.toWireMessage(sendImages) },
        stream = stream,
        think = if (includeThinking) null else false,
        options = contextTokens?.let { MuseGlimmerOptions(numCtx = it) },
    )

    /**
     * Text parts go through as-is; attachments contribute the text the phone derived from them
     * (see [MessagePart.promptText]). Photos and sampled video frames are additionally sent as
     * base64 `images` when the request asks for it (vision-capable server model).
     */
    private fun ChatTurn.toWireMessage(sendImages: Boolean): MuseGlimmerMessage {
        val photos = if (sendImages) {
            parts.filterIsInstance<MessagePart.Image>().mapNotNull(imageEncoder)
        } else emptyList()
        return MuseGlimmerMessage(
            role = when (role) {
                MessageRole.USER -> "user"
                MessageRole.ASSISTANT -> "assistant"
                MessageRole.SYSTEM -> "system"
            },
            content = parts.joinToString("\n\n") { it.promptText() }.trim(),
            images = photos.ifEmpty { null },
        )
    }

    companion object {
        fun defaultHttp(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS) // streaming: the model may think for a long time
            .writeTimeout(30, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false)
            .build()
    }
}

/**
 * OkHttp's zero read timeout is intentional for long model pauses, but a blocking source read is
 * not coroutine-cancellable by itself. Keep the active [Call] attached to cancellation for every
 * line read so pressing Stop closes the socket even after response headers have arrived.
 */
private suspend fun BufferedSource.readUtf8LineCancellable(call: Call): String? =
    suspendCancellableCoroutine { cont ->
        cont.invokeOnCancellation { call.cancel() }
        try {
            val line = readUtf8Line()
            if (cont.isActive) cont.resume(line)
        } catch (e: IOException) {
            if (cont.isActive) {
                cont.resumeWithException(ServerException(e.message ?: "Connection failed", e))
            }
        }
    }

/** Suspend on an OkHttp call; cancelling the coroutine cancels the socket. */
private suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (!cont.isCancelled) cont.resumeWithException(ServerException(e.message ?: "Connection failed", e))
        }
        override fun onResponse(call: Call, response: Response) = cont.resume(response)
    })
    cont.invokeOnCancellation { cancel() }
}
