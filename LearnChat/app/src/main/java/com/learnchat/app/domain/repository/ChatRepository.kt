package com.learnchat.app.domain.repository

import com.learnchat.app.domain.model.Chat
import com.learnchat.app.domain.model.Message
import com.learnchat.app.domain.model.MessagePart
import com.learnchat.app.domain.model.MessageRole
import com.learnchat.app.domain.model.MessageStatus
import kotlinx.coroutines.flow.Flow

interface ChatRepository {
    fun observeChats(): Flow<List<Chat>>
    fun observeChat(chatId: Long): Flow<Chat?>
    fun observeMessages(chatId: Long): Flow<List<Message>>

    suspend fun getChat(chatId: Long): Chat?
    suspend fun getMessages(chatId: Long): List<Message>

    suspend fun createChat(title: String = "New chat"): Long
    suspend fun renameChat(chatId: Long, title: String)
    suspend fun deleteChat(chatId: Long)
    /** Removes the chat only if it never received a message (backing out of a fresh "New chat"). */
    suspend fun deleteChatIfEmpty(chatId: Long)

    suspend fun addMessage(chatId: Long, role: MessageRole, parts: List<MessagePart>, status: MessageStatus = MessageStatus.COMPLETE): Long
    suspend fun updateMessageContent(messageId: Long, text: String, thinking: String?, status: MessageStatus, error: String? = null)

    suspend fun updateSummary(chatId: Long, summary: String, throughMessageId: Long)
}
