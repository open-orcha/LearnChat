package com.learnchat.app.data.remote.museglimmer

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Wire format of the Muse Glimmer service's POST /api/chat endpoint. */
@Serializable
internal data class MuseGlimmerMessage(
    val role: String,
    val content: String = "",
    val thinking: String? = null,
    /** Base64 photos, only honoured by vision-capable models. */
    val images: List<String>? = null,
)

@Serializable
internal data class MuseGlimmerChatRequest(
    val model: String,
    val messages: List<MuseGlimmerMessage>,
    val stream: Boolean,
    val think: Boolean? = null,
    val options: MuseGlimmerOptions? = null,
)

@Serializable
internal data class MuseGlimmerOptions(
    @SerialName("num_ctx") val numCtx: Int? = null,
)

@Serializable
internal data class MuseGlimmerChatChunk(
    val model: String? = null,
    val message: MuseGlimmerMessage? = null,
    val done: Boolean = false,
    @SerialName("done_reason") val doneReason: String? = null,
    @SerialName("total_duration") val totalDurationNs: Long? = null,
    @SerialName("eval_count") val evalCount: Int? = null,
    val error: String? = null,
)

@Serializable
internal data class MuseGlimmerModelsResponse(val models: List<MuseGlimmerModel> = emptyList())

@Serializable
internal data class MuseGlimmerModel(val name: String)
