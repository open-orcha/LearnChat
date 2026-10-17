package com.learnchat.app.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.learnchat.app.data.remote.museglimmer.MuseGlimmerChatClient
import com.learnchat.app.domain.model.AppSettings
import com.learnchat.app.domain.model.ServerInfo
import com.learnchat.app.domain.repository.SettingsRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class SettingsViewModel(private val repository: SettingsRepository) : ViewModel() {
    val settings: StateFlow<AppSettings> = repository.settings
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), AppSettings.DEFAULT)

    private val _testResult = MutableStateFlow<ServerInfo?>(null)
    val testResult: StateFlow<ServerInfo?> = _testResult
    private val _testing = MutableStateFlow(false)
    val testing: StateFlow<Boolean> = _testing

    fun save(baseUrl: String, model: String, showThinking: Boolean, window: Int, sendImages: Boolean) {
        viewModelScope.launch {
            repository.update {
                it.copy(
                    serverBaseUrl = normalize(baseUrl),
                    modelName = model.trim().ifBlank { AppSettings.DEFAULT_MODEL },
                    showThinking = showThinking,
                    verbatimWindow = window.coerceIn(2, 50),
                    sendImagesToModel = sendImages,
                )
            }
        }
    }

    fun testConnection(baseUrl: String) {
        viewModelScope.launch {
            _testing.value = true
            _testResult.value = try { MuseGlimmerChatClient(normalize(baseUrl)).ping() } catch (t: Throwable) {
                ServerInfo(false, emptyList(), t.message)
            }
            _testing.value = false
        }
    }

    fun resetDefaults() {
        viewModelScope.launch { repository.update { AppSettings.DEFAULT } }
    }

    private fun normalize(url: String): String {
        val t = url.trim().trimEnd('/')
        if (t.isBlank()) return AppSettings.DEFAULT_BASE_URL
        return if (t.startsWith("http://") || t.startsWith("https://")) t else "http://$t"
    }
}
