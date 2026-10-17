package com.qchat.app.data.local

import android.content.Context
import androidx.room.AutoMigration
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import com.qchat.app.data.local.dao.ChatDao
import com.qchat.app.data.local.dao.MessageDao
import com.qchat.app.data.local.entity.ChatEntity
import com.qchat.app.data.local.entity.MessageEntity
import com.qchat.app.data.local.entity.MessagePartEntity

@Database(
    entities = [ChatEntity::class, MessageEntity::class, MessagePartEntity::class],
    version = 3,
    exportSchema = true,
    // v2 adds the on-device preprocessing columns to message_parts; existing chats are kept.
    autoMigrations = [AutoMigration(from = 1, to = 2)],
)
abstract class QChatDatabase : RoomDatabase() {
    abstract fun chatDao(): ChatDao
    abstract fun messageDao(): MessageDao

    companion object {
        fun build(context: Context): QChatDatabase =
            Room.databaseBuilder(context.applicationContext, QChatDatabase::class.java, "qchat.db")
                .addMigrations(MIGRATION_2_3)
                .fallbackToDestructiveMigration(dropAllTables = true)
                .build()

        /** Preserve existing chats and assign each one a globally unique opaque session ID. */
        val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE chats ADD COLUMN sessionId TEXT NOT NULL DEFAULT ''")
                db.execSQL("UPDATE chats SET sessionId = lower(hex(randomblob(16))) WHERE sessionId = ''")
                db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_chats_sessionId ON chats(sessionId)")
            }
        }
    }
}
