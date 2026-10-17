import Foundation
import Observation

@Observable
@MainActor
final class SettingsViewModel {
    private let repository: SettingsRepository
    private(set) var settings: AppSettings = .default
    private(set) var testResult: ServerInfo?
    private(set) var testing = false
    nonisolated(unsafe) private var observer: Task<Void, Never>?

    init(repository: SettingsRepository) {
        self.repository = repository
        observer = Task { [weak self, repository] in
            for await s in repository.settings {
                guard let self else { break }
                self.settings = s
            }
        }
    }

    deinit { observer?.cancel() }

    func save(baseUrl: String, model: String, showThinking: Bool, window: Int, sendImages: Bool) {
        let url = Self.normalize(baseUrl)
        let modelName = model.trimmed.isBlank ? AppSettings.defaultModel : model.trimmed
        let window = min(max(window, 2), 50)
        Task {
            await repository.update { s in
                var next = s
                next.serverBaseUrl = url
                next.modelName = modelName
                next.showThinking = showThinking
                next.verbatimWindow = window
                next.sendImagesToModel = sendImages
                return next
            }
        }
    }

    func testConnection(baseUrl: String) {
        let url = Self.normalize(baseUrl)
        testing = true
        Task {
            testResult = await MuseGlimmerChatClient(baseUrl: url).ping()
            testing = false
        }
    }

    func resetDefaults() {
        Task { await repository.update { _ in .default } }
    }

    static func normalize(_ url: String) -> String {
        var t = url.trimmed
        while t.hasSuffix("/") { t.removeLast() }
        if t.isBlank { return AppSettings.defaultBaseUrl }
        return t.hasPrefix("http://") || t.hasPrefix("https://") ? t : "http://\(t)"
    }
}
