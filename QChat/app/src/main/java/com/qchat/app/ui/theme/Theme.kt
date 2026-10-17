package com.qchat.app.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

private val Indigo = Color(0xFF3F51B5)
private val IndigoDark = Color(0xFF9FA8DA)
private val Sky = Color(0xFF7CE0FF)

private val LightScheme = lightColorScheme(
    primary = Indigo,
    secondary = Color(0xFF00838F),
    tertiary = Color(0xFF6A1B9A),
)

private val DarkScheme = darkColorScheme(
    primary = IndigoDark,
    secondary = Sky,
    tertiary = Color(0xFFCE93D8),
)

@Composable
fun QChatTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit,
) {
    val scheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val ctx = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(ctx) else dynamicLightColorScheme(ctx)
        }
        darkTheme -> DarkScheme
        else -> LightScheme
    }
    MaterialTheme(colorScheme = scheme, content = content)
}
