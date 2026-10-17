import Foundation
import SwiftData
import SwiftUI

/// Hand-rolled dependency container — small enough to read in one screen.
/// The server client is created per-call from the current settings so a URL change in
/// Settings takes effect on the next message without restarting the app.
final class AppContainer: @unchecked Sendable {
    let settings: SettingsRepository
    let chats: ChatRepository
    /// PDF / photo / video → text, all on the phone.
    let preprocessor: AttachmentPreprocessor
    let clientProvider: ChatServerClientProvider
    let compactor: ContextCompactor
    let leases: ConversationLeaseCoordinator
    let sendMessage: SendMessageUseCase

    init() {
        let container: ModelContainer
        do {
            container = try SwiftDataChatRepository.makeContainer()
        } catch {
            // Never erase chat history to recover from a migration error. The session-id field is
            // optional at the storage layer specifically so existing stores migrate in place.
            fatalError("Unable to open the QChat store without risking user data: \(error)")
        }

        let settings = UserDefaultsSettingsRepository()
        let chats = SwiftDataChatRepository(container: container)
        let session = MuseGlimmerChatClient.defaultSession()
        let clientProvider: ChatServerClientProvider = {
            MuseGlimmerChatClient(baseUrl: await settings.current().serverBaseUrl, session: session, imageEncoder: AppContainer.encodeImage)
        }
        let compactor = WindowedSummaryCompactor(
            repository: chats,
            settingsRepository: settings,
            summarizer: ModelSummarizer(clientProvider: clientProvider, settings: settings)
        )
        let leases = ConversationLeaseCoordinator(clientProvider: clientProvider)

        self.settings = settings
        self.chats = chats
        self.preprocessor = IOSAttachmentPreprocessor()
        self.clientProvider = clientProvider
        self.compactor = compactor
        self.leases = leases
        self.sendMessage = SendMessageUseCase(
            repository: chats,
            settings: settings,
            clientProvider: clientProvider,
            compactor: compactor,
            leases: leases
        )
    }

    /// Read a stored photo, or a video's sampled preview frame, as base64 for the server.
    private static func encodeImage(_ part: ImagePart) -> String? {
        let source = part.isVideo ? part.thumbnailUri : part.uri
        guard let source, let url = URL(string: source), let data = try? Data(contentsOf: url) else { return nil }
        return data.base64EncodedString()
    }
}
