package com.qchat.app.data.repository

import com.qchat.app.data.local.QChatDatabase
import com.qchat.app.data.local.entity.ChatEntity
import com.qchat.app.data.local.entity.MessageEntity
import com.qchat.app.data.local.toDomain
import com.qchat.app.data.local.toEntity
import com.qchat.app.domain.model.Chat
import com.qchat.app.domain.model.Message
import com.qchat.app.domain.model.MessagePart
import com.qchat.app.domain.model.MessageRole
import com.qchat.app.domain.model.MessageStatus
import com.qchat.app.domain.repository.ChatRepository
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import java.util.UUID

class RoomChatRepository(private val db: QChatDatabase) : ChatRepository {
    private val chats = db.chatDao()
    private val messages = db.messageDao()

    override fun observeChats(): Flow<List<Chat>> = chats.observeAll().map { list -> list.map { it.toDomain() } }
    override fun observeChat(chatId: Long): Flow<Chat?> = chats.observe(chatId).map { it?.toDomain() }
    override fun observeMessages(chatId: Long): Flow<List<Message>> =
        messages.observeForChat(chatId).map { list -> list.map { it.toDomain() } }

    override suspend fun getChat(chatId: Long): Chat? = chats.get(chatId)?.toDomain()
    override suspend fun getMessages(chatId: Long): List<Message> = messages.listForChat(chatId).map { it.toDomain() }

    override suspend fun createChat(title: String): Long {
        val now = System.currentTimeMillis()
        return chats.insert(ChatEntity(sessionId = UUID.randomUUID().toString(), title = title, createdAt = now, updatedAt = now))
    }

    override suspend fun renameChat(chatId: Long, title: String) = chats.rename(chatId, title, System.currentTimeMillis())
    override suspend fun deleteChat(chatId: Long) = chats.delete(chatId)
    override suspend fun deleteChatIfEmpty(chatId: Long) = chats.deleteIfEmpty(chatId)

    override suspend fun addMessage(chatId: Long, role: MessageRole, parts: List<MessagePart>, status: MessageStatus): Long {
        val now = System.currentTimeMillis()
        val id = messages.insert(MessageEntity(chatId = chatId, role = role.name, status = status.name, createdAt = now))
        messages.insertParts(parts.mapIndexed { i, p -> p.toEntity(id, i) })
        // Chat-list preview: the typed text, or "[attached: …]" when the message is attachment-only.
        val preview = Message(id, chatId, role, parts, status, createdAt = now).briefText.replace('\n', ' ').take(120)
        if (preview.isNotBlank()) chats.touch(chatId, preview, now)
        return id
    }

    override suspend fun updateMessageContent(messageId: Long, text: String, thinking: String?, status: MessageStatus, error: String?) {
        messages.updateContent(messageId, text, thinking, status.name, error)
        // Once a reply settles, surface it as the chat-list preview.
        if (status != MessageStatus.STREAMING && text.isNotBlank()) {
            messages.chatIdOf(messageId)?.let { chats.touch(it, text.take(120), System.currentTimeMillis()) }
        }
    }

    override suspend fun updateSummary(chatId: Long, summary: String, throughMessageId: Long) =
        chats.updateSummary(chatId, summary, throughMessageId)
}
