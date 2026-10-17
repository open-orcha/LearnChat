package com.qchat.app.di

import android.content.Context
import android.util.Base64
import com.qchat.app.data.local.QChatDatabase
import com.qchat.app.data.preprocess.AndroidAttachmentPreprocessor
import com.qchat.app.data.remote.museglimmer.MuseGlimmerChatClient
import com.qchat.app.data.repository.RoomChatRepository
import com.qchat.app.data.settings.DataStoreSettingsRepository
import com.qchat.app.domain.context.ContextCompactor
import com.qchat.app.domain.context.ModelSummarizer
import com.qchat.app.domain.context.WindowedSummaryCompactor
import com.qchat.app.domain.model.MessagePart
import com.qchat.app.domain.preprocess.AttachmentPreprocessor
import com.qchat.app.domain.repository.ChatRepository
import com.qchat.app.domain.repository.ChatServerClient
import com.qchat.app.domain.repository.SettingsRepository
import com.qchat.app.domain.usecase.SendMessageUseCase
import com.qchat.app.domain.usecase.ConversationLeaseCoordinator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import okhttp3.OkHttpClient
import java.io.File
import java.net.URI

/**
 * Hand-rolled dependency container (no Hilt) — small enough to read in one screen.
 * The server client is created per-call from the current settings so a URL change in
 * Settings takes effect on the next message without restarting the app.
 */
class AppContainer(context: Context) {
    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val db = QChatDatabase.build(context)
    private val http: OkHttpClient = MuseGlimmerChatClient.defaultHttp()

    val settings: SettingsRepository = DataStoreSettingsRepository(context)
    val chats: ChatRepository = RoomChatRepository(db)

    /** PDF / photo / video → text, all on the phone. */
    val preprocessor: AttachmentPreprocessor = AndroidAttachmentPreprocessor(context.applicationContext)

    val clientProvider: suspend () -> ChatServerClient = {
        MuseGlimmerChatClient(settings.current().serverBaseUrl, http, imageEncoder = ::encodeImage)
    }

    val compactor: ContextCompactor = WindowedSummaryCompactor(
        repository = chats,
        settingsRepository = settings,
        summarizer = ModelSummarizer(clientProvider, settings),
    )

    val leases = ConversationLeaseCoordinator(appScope, clientProvider)
    val sendMessage = SendMessageUseCase(chats, settings, clientProvider, compactor, leases, appScope)

    /** Read a stored photo, or a video's sampled preview frame, as base64 for the server. */
    private fun encodeImage(part: MessagePart.Image): String? = runCatching {
        val source = if (part.isVideo) part.thumbnailUri else part.uri
        val file = File(URI(source ?: return null))
        Base64.encodeToString(file.readBytes(), Base64.NO_WRAP)
    }.getOrNull()
}
