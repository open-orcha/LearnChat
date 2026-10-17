package com.qchat.app.data.remote.museglimmer

import com.qchat.app.domain.model.ChatRequest
import com.qchat.app.domain.model.ChatTurn
import com.qchat.app.domain.model.MessagePart
import com.qchat.app.domain.model.MessageRole
import com.qchat.app.domain.model.HeartbeatResult
import com.qchat.app.domain.model.StreamEvent
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class MuseGlimmerChatClientTest {

    @Test
    fun `vision requests include photos and sampled video frames`() = runBlocking {
        val capture = CapturingInterceptor()
        val http = OkHttpClient.Builder().addInterceptor(capture).build()
        val client = MuseGlimmerChatClient("http://localhost:11434", http) { part ->
            "encoded-${part.name}"
        }
        val turn = ChatTurn(
            MessageRole.USER,
            listOf(
                MessagePart.Text("What is shown?"),
                MessagePart.Image("file:///photo.jpg", "image/jpeg", name = "photo"),
                MessagePart.Image(
                    "file:///clip.mp4",
                    "video/mp4",
                    name = "video-frame",
                    thumbnailUri = "file:///frame.jpg",
                ),
            ),
        )

        assertEquals(
            "ok",
            client.complete(
                ChatRequest(
                    model = "vision",
                    turns = listOf(turn),
                    includeThinking = false,
                    sendImages = true,
                    contextTokens = 8_192,
                ),
            ),
        )

        val root = Json.parseToJsonElement(capture.body).jsonObject
        val images = root["messages"]!!.jsonArray.single().jsonObject["images"]!!.jsonArray
        assertEquals("/api/chat", capture.path)
        assertEquals("vision", root["model"]!!.jsonPrimitive.content)
        assertEquals("false", root["stream"]!!.jsonPrimitive.content)
        assertEquals("false", root["think"]!!.jsonPrimitive.content)
        assertEquals("8192", root["options"]!!.jsonObject["num_ctx"]!!.jsonPrimitive.content)
        assertEquals(listOf("encoded-photo", "encoded-video-frame"), images.map { it.jsonPrimitive.content })
    }

    @Test
    fun `chat sends the stable conversation session header`() = runBlocking {
        val capture = CapturingInterceptor()
        val client = MuseGlimmerChatClient(
            "http://localhost:11434",
            OkHttpClient.Builder().addInterceptor(capture).build(),
        )

        client.complete(
            ChatRequest(
                model = "muse-glimmer:latest",
                turns = listOf(ChatTurn.text(MessageRole.USER, "hello")),
                sessionId = "conversation-123",
            ),
        )

        assertEquals("conversation-123", capture.sessionId)
    }

    @Test
    fun `heartbeat treats an expired session as recoverable`() = runBlocking {
        val capture = CapturingInterceptor(responseCode = 404, responseBody = """{"error":"session not found or expired"}""")
        val client = MuseGlimmerChatClient(
            "http://localhost:11434",
            OkHttpClient.Builder().addInterceptor(capture).build(),
        )

        assertEquals(HeartbeatResult.MISSING, client.heartbeat("conversation-123"))
        assertEquals("/api/sessions/conversation-123/heartbeat", capture.path)
    }

    @Test
    fun `cancelling between streaming chunks closes the active call`() = runBlocking {
        val releaseServer = CountDownLatch(1)
        val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val serverThread = thread(isDaemon = true) {
            try {
                server.accept().use { socket ->
                    val reader = socket.getInputStream().bufferedReader()
                    var contentLength = 0
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (line.isEmpty()) break
                        if (line.startsWith("Content-Length:", ignoreCase = true)) {
                            contentLength = line.substringAfter(':').trim().toInt()
                        }
                    }
                    repeat(contentLength) { reader.read() }
                    socket.getOutputStream().apply {
                        write("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n".toByteArray())
                        write("{\"message\":{\"role\":\"assistant\",\"content\":\"first\"},\"done\":false}\n".toByteArray())
                        flush()
                        releaseServer.await(5, TimeUnit.SECONDS)
                        write("{\"done\":true}\n".toByteArray())
                        flush()
                    }
                }
            } catch (_: Exception) {
                // Cancelling the client is expected to close the socket while the server is paused.
            }
        }
        val http = MuseGlimmerChatClient.defaultHttp()
        val client = MuseGlimmerChatClient("http://127.0.0.1:${server.localPort}", http)
        val receivedFirstChunk = CompletableDeferred<Unit>()
        val collector = launch(Dispatchers.Default) {
            client.streamChat(
                ChatRequest(
                    model = "muse-glimmer:latest",
                    turns = listOf(ChatTurn.text(MessageRole.USER, "hello")),
                    sessionId = "cancel-regression",
                ),
            ).collect { event ->
                if (event is StreamEvent.ContentDelta) receivedFirstChunk.complete(Unit)
            }
        }

        val stoppedBeforeServerContinued: Boolean
        try {
            withTimeout(3_000) { receivedFirstChunk.await() }
            delay(100) // Ensure the client is waiting for the next response line.
            collector.cancel()
            stoppedBeforeServerContinued = withTimeoutOrNull(800) {
                collector.join()
                true
            } ?: false
        } finally {
            releaseServer.countDown()
            withTimeout(3_000) { collector.join() }
            server.close()
            serverThread.join(1_000)
            http.connectionPool.evictAll()
            http.dispatcher.executorService.shutdownNow()
        }

        assertTrue(
            "Stop should cancel a body read without waiting for the server's next chunk",
            stoppedBeforeServerContinued,
        )
    }

    private class CapturingInterceptor(
        private val responseCode: Int = 200,
        private val responseBody: String = """{"message":{"role":"assistant","content":"ok"},"done":true}""",
    ) : Interceptor {
        lateinit var body: String
        var sessionId: String? = null
        var path: String? = null

        override fun intercept(chain: Interceptor.Chain): Response {
            val buffer = Buffer()
            chain.request().body?.writeTo(buffer)
            body = buffer.readUtf8()
            sessionId = chain.request().header("X-Muse-Session-ID")
            path = chain.request().url.encodedPath
            return Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(responseCode)
                .message(if (responseCode == 200) "OK" else "Not Found")
                .body(responseBody.toResponseBody("application/json".toMediaType()))
                .build()
        }
    }
}
