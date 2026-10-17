package com.learnchat.app.ui.components

import android.graphics.BitmapFactory
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.learnchat.app.domain.model.MessagePart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.net.URI

/** Renders a PDF attachment inside a bubble: name + page count, tap to reveal the extracted text. */
@Composable
fun FilePartView(part: MessagePart.File, textColor: Color) {
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Description, contentDescription = null, tint = textColor)
            Column(Modifier.padding(start = 8.dp)) {
                Text(part.name, color = textColor, style = MaterialTheme.typography.bodyMedium)
                val meta = listOfNotNull(
                    part.pageCount?.let { "$it page${if (it == 1) "" else "s"}" },
                    part.sizeBytes?.let { humanSize(it) },
                ).joinToString(" · ")
                if (meta.isNotEmpty()) Text(meta, color = textColor.copy(alpha = 0.7f), style = MaterialTheme.typography.labelSmall)
            }
        }
        DerivedTextSection(title = "Text extracted on this phone", text = part.extractedText, color = textColor)
    }
}

/** Renders a photo or video attachment: thumbnail, then what the phone made of it. */
@Composable
fun ImagePartView(part: MessagePart.Image, textColor: Color) {
    Column {
        val bitmap = rememberFileBitmap(part.thumbnailUri ?: part.uri)
        Box(Modifier.clip(RoundedCornerShape(12.dp))) {
            if (bitmap != null) {
                Image(
                    bitmap = bitmap, contentDescription = part.name,
                    modifier = Modifier.fillMaxWidth().heightIn(max = 220.dp),
                    contentScale = ContentScale.Fit,
                )
            } else {
                Box(Modifier.fillMaxWidth().heightIn(min = 80.dp).background(textColor.copy(alpha = 0.1f)))
            }
            if (part.isVideo) {
                Box(
                    Modifier.align(Alignment.Center).size(40.dp).background(Color.Black.copy(alpha = 0.5f), CircleShape),
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Default.PlayArrow, contentDescription = "Video", tint = Color.White) }
            }
        }
        part.name?.let { Text(it, color = textColor.copy(alpha = 0.7f), style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(top = 4.dp)) }
        DerivedTextSection(
            title = if (part.isVideo) "What this phone saw in the video" else "What this phone saw in the photo",
            text = part.extractedText, color = textColor,
        )
    }
}

/** Collapsible block showing the text that was sent to the model on the user's behalf. */
@Composable
private fun DerivedTextSection(title: String, text: String?, color: Color, previewChars: Int = 1500) {
    if (text.isNullOrBlank()) return
    var expanded by remember { mutableStateOf(false) }
    Column(Modifier.padding(top = 6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable { expanded = !expanded }) {
            Text(title, style = MaterialTheme.typography.labelMedium, color = color.copy(alpha = 0.8f))
            Icon(if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore, contentDescription = null, tint = color.copy(alpha = 0.8f))
        }
        AnimatedVisibility(visible = expanded) {
            val shown = if (text.length > previewChars) text.take(previewChars) + "\n… (${text.length - previewChars} more characters were sent)" else text
            Box(
                Modifier.padding(top = 4.dp).background(color.copy(alpha = 0.08f), RoundedCornerShape(10.dp)).padding(10.dp),
            ) {
                Text(shown, style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace), color = color.copy(alpha = 0.9f))
            }
        }
    }
}

/** Decodes a `file://` JPEG in app storage off the main thread; null until loaded or if missing. */
@Composable
fun rememberFileBitmap(uri: String?): ImageBitmap? {
    val state by produceState<ImageBitmap?>(initialValue = null, key1 = uri) {
        value = uri?.let {
            withContext(Dispatchers.IO) {
                runCatching { BitmapFactory.decodeFile(File(URI(it)).path)?.asImageBitmap() }.getOrNull()
            }
        }
    }
    return state
}

private fun humanSize(bytes: Long): String = when {
    bytes >= 1_000_000 -> "%.1f MB".format(bytes / 1_000_000.0)
    bytes >= 1_000 -> "${bytes / 1_000} KB"
    else -> "$bytes B"
}
