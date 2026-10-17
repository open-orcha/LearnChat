package com.learnchat.app.ui.chatlist

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.learnchat.app.domain.model.Chat
import com.learnchat.app.domain.repository.ChatRepository
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class ChatListViewModel(private val repository: ChatRepository) : ViewModel() {
    val chats: StateFlow<List<Chat>> = repository.observeChats()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    fun newChat(onCreated: (Long) -> Unit) {
        viewModelScope.launch { onCreated(repository.createChat()) }
    }

    fun rename(chatId: Long, title: String) {
        viewModelScope.launch { repository.renameChat(chatId, title.trim().ifBlank { "Untitled chat" }) }
    }

    fun delete(chatId: Long) {
        viewModelScope.launch { repository.deleteChat(chatId) }
    }
}
