package com.learnchat.app.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.learnchat.app.ui.containerViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onBack: () -> Unit,
    viewModel: SettingsViewModel = containerViewModel { SettingsViewModel(it.settings) },
) {
    val saved by viewModel.settings.collectAsStateWithLifecycle()
    val testResult by viewModel.testResult.collectAsStateWithLifecycle()
    val testing by viewModel.testing.collectAsStateWithLifecycle()

    var baseUrl by remember { mutableStateOf(saved.serverBaseUrl) }
    var model by remember { mutableStateOf(saved.modelName) }
    var showThinking by remember { mutableStateOf(saved.showThinking) }
    var window by remember { mutableStateOf(saved.verbatimWindow.toString()) }
    var sendImages by remember { mutableStateOf(saved.sendImagesToModel) }
    // Re-sync the form when persisted values arrive (first load / reset).
    LaunchedEffect(saved) {
        baseUrl = saved.serverBaseUrl; model = saved.modelName; showThinking = saved.showThinking; window = saved.verbatimWindow.toString()
        sendImages = saved.sendImagesToModel
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Server", style = MaterialTheme.typography.titleMedium)
            OutlinedTextField(
                value = baseUrl, onValueChange = { baseUrl = it }, singleLine = true,
                label = { Text("Server address") },
                supportingText = { Text("Your Mac's Wi-Fi address and Muse Glimmer port, e.g. http://192.168.86.32:11434") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = model, onValueChange = { model = it }, singleLine = true,
                label = { Text("Model") }, modifier = Modifier.fillMaxWidth(),
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = { viewModel.testConnection(baseUrl) }, enabled = !testing) {
                    Text(if (testing) "Testing…" else "Test connection")
                }
                testResult?.let { r ->
                    Text(
                        if (r.reachable) "Connected ✓  models: ${r.models.joinToString().ifBlank { "none" }}"
                        else "Not reachable: ${r.detail ?: "unknown error"}",
                        style = MaterialTheme.typography.bodySmall,
                        color = if (r.reachable) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
                    )
                }
            }

            HorizontalDivider()
            Text("Chat", style = MaterialTheme.typography.titleMedium)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Show reasoning by default")
                    Text("Expand the model's thinking trace under each reply.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Switch(checked = showThinking, onCheckedChange = { showThinking = it })
            }
            OutlinedTextField(
                value = window, onValueChange = { window = it.filter(Char::isDigit).take(2) }, singleLine = true,
                label = { Text("Recent messages sent word-for-word") },
                supportingText = { Text("Older messages are folded into a short summary so long chats stay fast.") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth(),
            )

            HorizontalDivider()
            Text("Attachments", style = MaterialTheme.typography.titleMedium)
            Text(
                "PDFs, photos and videos are processed on this phone: PDF text is extracted, and photos/video frames are " +
                    "described (text read + objects recognised) before anything is sent. Nothing but that text leaves the phone.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Server model can see images")
                    Text(
                        "Also send the actual photo / video frames. Turn on only if the Model above is a vision model " +
                            "(muse-glimmer is text-only and will ignore or reject them).",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(checked = sendImages, onCheckedChange = { sendImages = it })
            }

            Spacer(Modifier.height(8.dp))
            Button(
                onClick = { viewModel.save(baseUrl, model, showThinking, window.toIntOrNull() ?: 12, sendImages); onBack() },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Save") }
            TextButton(onClick = viewModel::resetDefaults, modifier = Modifier.fillMaxWidth()) { Text("Reset to defaults") }
        }
    }
}
