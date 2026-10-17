package com.qchat.app.data.local.dao

import androidx.room.Dao
import androidx.room.Embedded
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Relation
import androidx.room.Transaction
import androidx.room.Update
import com.qchat.app.data.local.entity.ChatEntity
import com.qchat.app.data.local.entity.MessageEntity
import com.qchat.app.data.local.entity.MessagePartEntity
import kotlinx.coroutines.flow.Flow

data class MessageWithParts(
    @Embedded val message: MessageEntity,
    @Relation(parentColumn = "id", entityColumn = "messageId") val parts: List<MessagePartEntity>,
)

@Dao
interface ChatDao {
    @Query("SELECT * FROM chats ORDER BY updatedAt DESC")
    fun observeAll(): Flow<List<ChatEntity>>

    @Query("SELECT * FROM chats WHERE id = :id")
    fun observe(id: Long): Flow<ChatEntity?>

    @Query("SELECT * FROM chats WHERE id = :id")
    suspend fun get(id: Long): ChatEntity?

    @Insert
    suspend fun insert(chat: ChatEntity): Long

    @Update
    suspend fun update(chat: ChatEntity)

    @Query("UPDATE chats SET title = :title, updatedAt = :now WHERE id = :id")
    suspend fun rename(id: Long, title: String, now: Long)

    @Query("UPDATE chats SET preview = :preview, updatedAt = :now WHERE id = :id")
    suspend fun touch(id: Long, preview: String, now: Long)

    @Query("UPDATE chats SET summary = :summary, summaryThroughMessageId = :through WHERE id = :id")
    suspend fun updateSummary(id: Long, summary: String, through: Long)

    @Query("DELETE FROM chats WHERE id = :id")
    suspend fun delete(id: Long)

    @Query("DELETE FROM chats WHERE id = :id AND NOT EXISTS (SELECT 1 FROM messages WHERE chatId = :id)")
    suspend fun deleteIfEmpty(id: Long)
}

@Dao
interface MessageDao {
    @Transaction
    @Query("SELECT * FROM messages WHERE chatId = :chatId ORDER BY createdAt ASC, id ASC")
    fun observeForChat(chatId: Long): Flow<List<MessageWithParts>>

    @Transaction
    @Query("SELECT * FROM messages WHERE chatId = :chatId ORDER BY createdAt ASC, id ASC")
    suspend fun listForChat(chatId: Long): List<MessageWithParts>

    @Insert
    suspend fun insert(message: MessageEntity): Long

    @Insert
    suspend fun insertParts(parts: List<MessagePartEntity>)

    @Query("DELETE FROM message_parts WHERE messageId = :messageId AND type = 'TEXT'")
    suspend fun deleteTextParts(messageId: Long)

    @Query("SELECT chatId FROM messages WHERE id = :id")
    suspend fun chatIdOf(id: Long): Long?

    @Query("UPDATE messages SET status = :status, thinking = :thinking, error = :error WHERE id = :id")
    suspend fun updateStatus(id: Long, status: String, thinking: String?, error: String?)

    /** Replace the text of a streaming message and update its status in one transaction. */
    @Transaction
    suspend fun updateContent(id: Long, text: String, thinking: String?, status: String, error: String?) {
        deleteTextParts(id)
        insertParts(listOf(MessagePartEntity(messageId = id, position = 0, type = "TEXT", text = text)))
        updateStatus(id, status, thinking, error)
    }
}
