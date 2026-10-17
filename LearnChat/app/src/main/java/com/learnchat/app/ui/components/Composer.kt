package com.learnchat.app.ui.components

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.InputChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.learnchat.app.domain.preprocess.AttachmentKind
import com.learnchat.app.ui.chat.AttachmentState
import com.learnchat.app.ui.chat.PendingAttachment

/**
 * Message input bar: attach button, text field, send/stop. Picked files show as chips above the
 * field while the phone preprocesses them; Send waits until every chip is ready.
 */
@Composable
fun Composer(
    text: String,
    onTextChange: (String) -> Unit,
    sending: Boolean,
    pending: List<PendingAttachment>,
    canSend: Boolean,
    onSend: () -> Unit,
    onStop: () -> Unit,
    onAttach: () -> Unit,
    onRemoveAttachment: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(modifier = modifier, tonalElevation = 3.dp) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)) {
            if (pending.isNotEmpty()) {
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(bottom = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    pending.forEach { a -> AttachmentChip(a, onRemove = { onRemoveAttachment(a.id) }) }
                }
            }
            Row(verticalAlignment = Alignment.Bottom) {
                IconButton(onClick = onAttach, enabled = !sending, modifier = Modifier.size(48.dp)) {
                    Icon(Icons.Default.AttachFile, contentDescription = "Attach a PDF, photo or video")
                }
                OutlinedTextField(
                    value = text,
                    onValueChange = onTextChange,
                    modifier = Modifier.weight(1f).heightIn(min = 48.dp, max = 160.dp),
                    placeholder = { Text(if (pending.isNotEmpty()) "Ask about the attachment…" else "Message") },
                    shape = RoundedCornerShape(24.dp),
                    maxLines = 6,
                )
                FilledIconButton(
                    onClick = { if (sending) onStop() else onSend() },
                    enabled = sending || canSend,
                    modifier = Modifier.padding(start = 8.dp).size(48.dp),
                    colors = IconButtonDefaults.filledIconButtonColors(
                        containerColor = if (sending) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.primary,
                        contentColor = if (sending) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onPrimary,
                    ),
                ) {
                    if (sending) Icon(Icons.Default.Stop, contentDescription = "Stop")
                    else Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Send")
                }
            }
        }
    }
}

@Composable
private fun AttachmentChip(a: PendingAttachment, onRemove: () -> Unit) {
    val detail = when (a.state) {
        AttachmentState.PROCESSING -> a.progress ?: "Processing…"
        AttachmentState.READY -> a.summary ?: "Ready"
        AttachmentState.FAILED -> a.error ?: "Failed"
    }
    InputChip(
        selected = a.state == AttachmentState.READY,
        onClick = {},
        label = {
            Column {
                Text(a.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelLarge)
                Text(
                    detail, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelSmall,
                    color = if (a.state == AttachmentState.FAILED) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        leadingIcon = {
            when (a.state) {
                AttachmentState.PROCESSING -> CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                AttachmentState.FAILED -> Icon(Icons.Default.ErrorOutline, contentDescription = null, tint = MaterialTheme.colorScheme.error)
                AttachmentState.READY -> Icon(a.kind.icon(), contentDescription = null)
            }
        },
        trailingIcon = {
            IconButton(onClick = onRemove, modifier = Modifier.size(24.dp)) {
                Icon(Icons.Default.Close, contentDescription = "Remove attachment", modifier = Modifier.size(16.dp))
            }
        },
    )
}

fun AttachmentKind?.icon() = when (this) {
    AttachmentKind.PDF -> Icons.Default.Description
    AttachmentKind.VIDEO -> Icons.Default.Videocam
    AttachmentKind.IMAGE, null -> Icons.Default.Image
}
