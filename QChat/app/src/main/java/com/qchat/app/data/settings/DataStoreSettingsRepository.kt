package com.qchat.app.data.settings

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.qchat.app.domain.model.AppSettings
import com.qchat.app.domain.repository.SettingsRepository
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "qchat_settings")

class DataStoreSettingsRepository(context: Context) : SettingsRepository {
    private val store = context.applicationContext.dataStore

    private object Keys {
        val baseUrl = stringPreferencesKey("server_base_url")
        val model = stringPreferencesKey("model_name")
        val showThinking = booleanPreferencesKey("show_thinking")
        val window = intPreferencesKey("verbatim_window")
        val sendImages = booleanPreferencesKey("send_images_to_model")
    }

    override val settings: Flow<AppSettings> = store.data.map { p ->
        AppSettings(
            serverBaseUrl = p[Keys.baseUrl] ?: AppSettings.DEFAULT_BASE_URL,
            modelName = p[Keys.model] ?: AppSettings.DEFAULT_MODEL,
            showThinking = p[Keys.showThinking] ?: true,
            verbatimWindow = p[Keys.window] ?: AppSettings.DEFAULT_WINDOW,
            sendImagesToModel = p[Keys.sendImages] ?: false,
        )
    }

    override suspend fun current(): AppSettings = settings.first()

    override suspend fun update(transform: (AppSettings) -> AppSettings) {
        val next = transform(current())
        store.edit { p ->
            p[Keys.baseUrl] = next.serverBaseUrl
            p[Keys.model] = next.modelName
            p[Keys.showThinking] = next.showThinking
            p[Keys.window] = next.verbatimWindow
            p[Keys.sendImages] = next.sendImagesToModel
        }
    }
}
