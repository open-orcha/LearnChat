import Foundation
import Observation

@Observable
@MainActor
final class ChatListViewModel {
    private(set) var chats: [Chat] = []
    private let repository: ChatRepository
    /// Cancelled from deinit (nonisolated), hence the unsafe marker.
    nonisolated(unsafe) private var observer: Task<Void, Never>?

    init(repository: ChatRepository) {
        self.repository = repository
        observer = Task { [weak self, repository] in
            for await list in repository.observeChats() {
                guard let self else { break }
                self.chats = list
            }
        }
    }

    deinit { observer?.cancel() }

    func newChat(onCreated: @escaping (Int64) -> Void) {
        Task {
            if let id = try? await repository.createChat() { onCreated(id) }
        }
    }

    func rename(_ chatId: Int64, title: String) {
        let t = title.trimmed
        Task { try? await repository.renameChat(chatId, title: t.isBlank ? "Untitled chat" : t) }
    }

    func delete(_ chatId: Int64) {
        Task { try? await repository.deleteChat(chatId) }
    }
}
