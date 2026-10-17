package com.qchat.app.ui.navigation

import androidx.compose.runtime.Composable
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.qchat.app.ui.chat.ChatScreen
import com.qchat.app.ui.chatlist.ChatListScreen
import com.qchat.app.ui.settings.SettingsScreen

object Routes {
    const val CHAT_LIST = "chats"
    const val CHAT = "chat/{chatId}"
    const val SETTINGS = "settings"
    fun chat(id: Long) = "chat/$id"
}

@Composable
fun QChatNavHost() {
    val nav = rememberNavController()
    NavHost(navController = nav, startDestination = Routes.CHAT_LIST) {
        composable(Routes.CHAT_LIST) {
            ChatListScreen(
                onOpenChat = { nav.navigate(Routes.chat(it)) },
                onOpenSettings = { nav.navigate(Routes.SETTINGS) },
            )
        }
        composable(Routes.CHAT, arguments = listOf(navArgument("chatId") { type = NavType.LongType })) { entry ->
            val chatId = entry.arguments?.getLong("chatId") ?: return@composable
            ChatScreen(chatId = chatId, onBack = { nav.popBackStack() }, onOpenSettings = { nav.navigate(Routes.SETTINGS) })
        }
        composable(Routes.SETTINGS) {
            SettingsScreen(onBack = { nav.popBackStack() })
        }
    }
}
