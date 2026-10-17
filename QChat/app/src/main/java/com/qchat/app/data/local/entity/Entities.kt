package com.qchat.app.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(tableName = "chats", indices = [Index(value = ["sessionId"], unique = true)])
data class ChatEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    @ColumnInfo(defaultValue = "''") val sessionId: String,
    val title: String,
    val createdAt: Long,
    val updatedAt: Long,
    val preview: String = "",
    val summary: String? = null,
    val summaryThroughMessageId: Long? = null,
)

@Entity(
    tableName = "messages",
    foreignKeys = [ForeignKey(entity = ChatEntity::class, parentColumns = ["id"], childColumns = ["chatId"], onDelete = ForeignKey.CASCADE)],
    indices = [Index("chatId")],
)
data class MessageEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val chatId: Long,
    /** MessageRole.name */
    val role: String,
    /** MessageStatus.name */
    val status: String,
    val thinking: String? = null,
    val error: String? = null,
    val createdAt: Long,
)

/**
 * One row per message part. `type` selects which columns are meaningful:
 *  TEXT  -> text
 *  IMAGE -> uri, mimeType, width, height, name, extractedText, thumbnailUri (also used for videos)
 *  FILE  -> uri, mimeType, name, sizeBytes, extractedText, pageCount
 *  AUDIO -> uri, mimeType, durationMs, text (transcript)
 */
@Entity(
    tableName = "message_parts",
    foreignKeys = [ForeignKey(entity = MessageEntity::class, parentColumns = ["id"], childColumns = ["messageId"], onDelete = ForeignKey.CASCADE)],
    indices = [Index("messageId")],
)
data class MessagePartEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val messageId: Long,
    val position: Int,
    val type: String,
    val text: String? = null,
    val uri: String? = null,
    val mimeType: String? = null,
    val name: String? = null,
    val sizeBytes: Long? = null,
    val width: Int? = null,
    val height: Int? = null,
    val durationMs: Long? = null,
    // v2: on-device preprocessing output for attachments
    @ColumnInfo(defaultValue = "NULL") val extractedText: String? = null,
    @ColumnInfo(defaultValue = "NULL") val pageCount: Int? = null,
    @ColumnInfo(defaultValue = "NULL") val thumbnailUri: String? = null,
)
