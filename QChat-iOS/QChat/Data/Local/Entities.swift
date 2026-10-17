import Foundation
import SwiftData

/// SwiftData models mirroring the Android Room tables (`chats`, `messages`, `message_parts`).
/// Foreign keys are plain ids (no SwiftData relationships) so deletes are explicit and predictable.

@Model
final class ChatEntity {
    @Attribute(.unique) var id: Int64
    /// Optional only for lightweight migration from stores created before session caching.
    /// `ChatStore` fills and saves it before an entity reaches the domain layer.
    var sessionId: String?
    var title: String
    var createdAt: Int64
    var updatedAt: Int64
    var preview: String
    var summary: String?
    var summaryThroughMessageId: Int64?

    init(id: Int64, sessionId: String? = nil, title: String, createdAt: Int64, updatedAt: Int64, preview: String = "", summary: String? = nil, summaryThroughMessageId: Int64? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.preview = preview
        self.summary = summary
        self.summaryThroughMessageId = summaryThroughMessageId
    }
}

@Model
final class MessageEntity {
    @Attribute(.unique) var id: Int64
    var chatId: Int64
    /// MessageRole.rawValue
    var role: String
    /// MessageStatus.rawValue
    var status: String
    var thinking: String?
    var error: String?
    var createdAt: Int64

    init(id: Int64, chatId: Int64, role: String, status: String, thinking: String? = nil, error: String? = nil, createdAt: Int64) {
        self.id = id
        self.chatId = chatId
        self.role = role
        self.status = status
        self.thinking = thinking
        self.error = error
        self.createdAt = createdAt
    }
}

/// One row per message part. `type` selects which columns are meaningful:
///  TEXT  -> text
///  IMAGE -> uri, mimeType, width, height, name, extractedText, thumbnailUri (also used for videos)
///  FILE  -> uri, mimeType, name, sizeBytes, extractedText, pageCount
///  AUDIO -> uri, mimeType, durationMs, text (transcript)
@Model
final class MessagePartEntity {
    var messageId: Int64
    var chatId: Int64
    var position: Int
    var type: String
    var text: String?
    var uri: String?
    var mimeType: String?
    var name: String?
    var sizeBytes: Int64?
    var width: Int?
    var height: Int?
    var durationMs: Int64?
    var extractedText: String?
    var pageCount: Int?
    var thumbnailUri: String?

    init(
        messageId: Int64, chatId: Int64, position: Int, type: String,
        text: String? = nil, uri: String? = nil, mimeType: String? = nil, name: String? = nil, sizeBytes: Int64? = nil,
        width: Int? = nil, height: Int? = nil, durationMs: Int64? = nil,
        extractedText: String? = nil, pageCount: Int? = nil, thumbnailUri: String? = nil
    ) {
        self.messageId = messageId
        self.chatId = chatId
        self.position = position
        self.type = type
        self.text = text
        self.uri = uri
        self.mimeType = mimeType
        self.name = name
        self.sizeBytes = sizeBytes
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.extractedText = extractedText
        self.pageCount = pageCount
        self.thumbnailUri = thumbnailUri
    }
}

// MARK: - Mappers

extension ChatEntity {
    func toDomain() -> Chat {
        precondition(sessionId?.isEmpty == false, "ChatStore must migrate session IDs before mapping")
        return Chat(id: id, sessionId: sessionId!, title: title, createdAt: createdAt, updatedAt: updatedAt, preview: preview, summary: summary, summaryThroughMessageId: summaryThroughMessageId)
    }
}

extension MessageEntity {
    func toDomain(parts: [MessagePartEntity]) -> Message {
        Message(
            id: id,
            chatId: chatId,
            role: MessageRole(rawValue: role) ?? .user,
            parts: parts.sorted { $0.position < $1.position }.compactMap { $0.toDomain() },
            status: MessageStatus(rawValue: status) ?? .complete,
            thinking: thinking,
            error: error,
            createdAt: createdAt
        )
    }
}

extension MessagePartEntity {
    func toDomain() -> MessagePart? {
        switch type {
        case "TEXT": return .text(text ?? "")
        case "IMAGE": return .image(ImagePart(uri: uri ?? "", mimeType: mimeType ?? "", width: width, height: height, name: name, extractedText: extractedText, thumbnailUri: thumbnailUri))
        case "FILE": return .file(FilePart(uri: uri ?? "", name: name ?? "", mimeType: mimeType ?? "", sizeBytes: sizeBytes, extractedText: extractedText, pageCount: pageCount))
        case "AUDIO": return .audio(AudioPart(uri: uri ?? "", mimeType: mimeType ?? "", durationMs: durationMs, transcript: text))
        default: return nil
        }
    }
}

extension MessagePart {
    func toEntity(messageId: Int64, chatId: Int64, position: Int) -> MessagePartEntity {
        switch self {
        case .text(let t):
            return MessagePartEntity(messageId: messageId, chatId: chatId, position: position, type: "TEXT", text: t)
        case .image(let p):
            return MessagePartEntity(
                messageId: messageId, chatId: chatId, position: position, type: "IMAGE", uri: p.uri, mimeType: p.mimeType, name: p.name,
                width: p.width, height: p.height, extractedText: p.extractedText, thumbnailUri: p.thumbnailUri
            )
        case .file(let p):
            return MessagePartEntity(
                messageId: messageId, chatId: chatId, position: position, type: "FILE", uri: p.uri, mimeType: p.mimeType, name: p.name,
                sizeBytes: p.sizeBytes, extractedText: p.extractedText, pageCount: p.pageCount
            )
        case .audio(let p):
            return MessagePartEntity(messageId: messageId, chatId: chatId, position: position, type: "AUDIO", text: p.transcript, uri: p.uri, mimeType: p.mimeType, durationMs: p.durationMs)
        }
    }
}
