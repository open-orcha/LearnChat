package com.learnchat.app.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.keyframes
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** Three bouncing dots, like the "assistant is typing" affordance in ChatGPT / Claude. */
@Composable
fun TypingIndicator(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "typing")
    val color = MaterialTheme.colorScheme.onSurfaceVariant
    Row(modifier = modifier.padding(horizontal = 4.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
        repeat(3) { i ->
            val offset by transition.animateFloat(
                initialValue = 0f, targetValue = 0f,
                animationSpec = infiniteRepeatable(
                    animation = keyframes {
                        durationMillis = 900
                        0f at 0
                        -5f at 150 + i * 120
                        0f at 300 + i * 120
                        0f at 900
                    },
                    repeatMode = RepeatMode.Restart,
                ),
                label = "dot$i",
            )
            Box(Modifier.offset(y = offset.dp).size(7.dp).background(color, CircleShape))
        }
    }
}

/** Blinking caret appended to the streaming text. */
@Composable
fun blinkAlpha(): Float {
    val transition = rememberInfiniteTransition(label = "caret")
    val alpha by transition.animateFloat(
        initialValue = 1f, targetValue = 0f,
        animationSpec = infiniteRepeatable(animation = keyframes { durationMillis = 800; 1f at 0; 1f at 400 using LinearEasing; 0f at 401; 0f at 800 }, repeatMode = RepeatMode.Restart),
        label = "caretAlpha",
    )
    return alpha
}
