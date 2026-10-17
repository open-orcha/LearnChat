package com.qchat.app.domain.model

data class AppSettings(
    val serverBaseUrl: String,
    val modelName: String,
    val showThinking: Boolean,
    /** Number of most recent messages sent verbatim; older ones are summarised. */
    val verbatimWindow: Int,
    /**
     * Send photos / video frames as actual pixels in addition to the on-device
     * description. Only useful once the server runs a vision-capable model; off by default because
     * muse-glimmer is text-only.
     */
    val sendImagesToModel: Boolean = false,
) {
    companion object {
        // Defaults come from InfraAgent's managed Muse Glimmer service on the Mac's LAN address.
        const val DEFAULT_BASE_URL = "http://192.168.86.32:11434"
        const val DEFAULT_MODEL = "muse-glimmer:latest"
        const val DEFAULT_WINDOW = 12
        val DEFAULT = AppSettings(DEFAULT_BASE_URL, DEFAULT_MODEL, showThinking = true, verbatimWindow = DEFAULT_WINDOW)
    }
}
