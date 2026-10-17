package com.qchat.app.data.local

import com.qchat.app.data.local.dao.MessageWithParts
import com.qchat.app.data.local.entity.ChatEntity
import com.qchat.app.data.local.entity.MessagePartEntity
import com.qchat.app.domain.model.Chat
import com.qchat.app.domain.model.Message
import com.qchat.app.domain.model.MessagePart
import com.qchat.app.domain.model.MessageRole
import com.qchat.app.domain.model.MessageStatus

fun ChatEntity.toDomain() = Chat(
    id = id, sessionId = sessionId, title = title, createdAt = createdAt, updatedAt = updatedAt,
    preview = preview, summary = summary, summaryThroughMessageId = summaryThroughMessageId,
)

fun MessageWithParts.toDomain() = Message(
    id = message.id,
    chatId = message.chatId,
    role = MessageRole.valueOf(message.role),
    parts = parts.sortedBy { it.position }.mapNotNull { it.toDomain() },
    status = MessageStatus.valueOf(message.status),
    thinking = message.thinking,
    error = message.error,
    createdAt = message.createdAt,
)

fun MessagePartEntity.toDomain(): MessagePart? = when (type) {
    "TEXT" -> MessagePart.Text(text.orEmpty())
    "IMAGE" -> MessagePart.Image(uri.orEmpty(), mimeType.orEmpty(), width, height, name, extractedText, thumbnailUri)
    "FILE" -> MessagePart.File(uri.orEmpty(), name.orEmpty(), mimeType.orEmpty(), sizeBytes, extractedText, pageCount)
    "AUDIO" -> MessagePart.Audio(uri.orEmpty(), mimeType.orEmpty(), durationMs, text)
    else -> null
}

fun MessagePart.toEntity(messageId: Long, position: Int): MessagePartEntity = when (this) {
    is MessagePart.Text -> MessagePartEntity(messageId = messageId, position = position, type = "TEXT", text = text)
    is MessagePart.Image -> MessagePartEntity(
        messageId = messageId, position = position, type = "IMAGE", uri = uri, mimeType = mimeType, width = width, height = height,
        name = name, extractedText = extractedText, thumbnailUri = thumbnailUri,
    )
    is MessagePart.File -> MessagePartEntity(
        messageId = messageId, position = position, type = "FILE", uri = uri, mimeType = mimeType, name = name, sizeBytes = sizeBytes,
        extractedText = extractedText, pageCount = pageCount,
    )
    is MessagePart.Audio -> MessagePartEntity(messageId = messageId, position = position, type = "AUDIO", uri = uri, mimeType = mimeType, durationMs = durationMs, text = transcript)
}
