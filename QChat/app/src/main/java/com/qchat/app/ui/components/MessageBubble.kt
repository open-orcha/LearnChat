package com.qchat.app.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.qchat.app.domain.model.Message
import com.qchat.app.domain.model.MessagePart
import com.qchat.app.domain.model.MessageRole
import com.qchat.app.domain.model.MessageStatus

@Composable
fun MessageBubble(message: Message, showThinking: Boolean, modifier: Modifier = Modifier) {
    val isUser = message.role == MessageRole.USER
    val streaming = message.status == MessageStatus.STREAMING
    val bubbleColor = if (isUser) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceContainerHigh
    val textColor = if (isUser) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface
    val shape = RoundedCornerShape(
        topStart = 18.dp, topEnd = 18.dp,
        bottomStart = if (isUser) 18.dp else 4.dp,
        bottomEnd = if (isUser) 4.dp else 18.dp,
    )

    Row(modifier = modifier.fillMaxWidth(), horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start) {
        Column(
            modifier = Modifier
                .widthIn(max = 320.dp)
                .background(bubbleColor, shape)
                .padding(horizontal = 14.dp, vertical = 10.dp),
        ) {
            if (!isUser && !message.thinking.isNullOrBlank()) {
                ThinkingSection(message.thinking, expandedByDefault = showThinking, live = streaming && message.text.isEmpty())
            }
            if (streaming && message.text.isEmpty()) {
                TypingIndicator()
            } else {
                // Parts are rendered one by one so future image/file/audio parts slot in here.
                message.parts.forEachIndexed { i, part ->
                    if (i > 0) Spacer(Modifier.height(6.dp))
                    when (part) {
                        is MessagePart.Text -> {
                            val caretAlpha = if (streaming) blinkAlpha() else 0f
                            Text(
                                text = buildAnnotatedString {
                                    append(part.text)
                                    if (streaming) withStyle(SpanStyle(color = textColor.copy(alpha = caretAlpha))) { append("▍") }
                                },
                                color = textColor,
                                style = MaterialTheme.typography.bodyLarge,
                            )
                        }
                        is MessagePart.Image -> ImagePartView(part, textColor)
                        is MessagePart.File -> FilePartView(part, textColor)
                        is MessagePart.Audio -> PlaceholderPart("Audio clip", textColor)
                    }
                }
            }
            when (message.status) {
                MessageStatus.STOPPED -> StatusLine("Stopped", textColor)
                MessageStatus.FAILED -> StatusLine(message.error?.let { "Failed: $it" } ?: "Failed", MaterialTheme.colorScheme.error)
                else -> Unit
            }
        }
    }
}

@Composable
private fun ThinkingSection(thinking: String, expandedByDefault: Boolean, live: Boolean) {
    var expanded by remember { mutableStateOf(expandedByDefault) }
    Column(Modifier.padding(bottom = 6.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.clickable { expanded = !expanded },
        ) {
            Text(
                text = if (live) "Thinking…" else "Show reasoning",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Icon(
                if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        AnimatedVisibility(visible = expanded) {
            Box(
                Modifier
                    .padding(top = 4.dp)
                    .background(MaterialTheme.colorScheme.surfaceContainerLowest, RoundedCornerShape(10.dp))
                    .padding(10.dp),
            ) {
                Text(
                    thinking.trim(),
                    style = MaterialTheme.typography.bodySmall.copy(fontStyle = FontStyle.Italic),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun PlaceholderPart(label: String, color: Color) {
    Text(label, color = color.copy(alpha = 0.7f), style = MaterialTheme.typography.bodyMedium)
}

@Composable
private fun StatusLine(text: String, color: Color) {
    Spacer(Modifier.height(4.dp))
    Text(text, style = MaterialTheme.typography.labelSmall, color = color.copy(alpha = 0.8f))
}
