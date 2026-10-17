package com.learnchat.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.learnchat.app.ui.navigation.LearnChatNavHost
import com.learnchat.app.ui.theme.LearnChatTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            LearnChatTheme { LearnChatNavHost() }
        }
    }
}
