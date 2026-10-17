import Foundation

/// `SettingsRepository` on top of UserDefaults (Android's DataStore equivalent).
final class UserDefaultsSettingsRepository: SettingsRepository, @unchecked Sendable {
    private let defaults: UserDefaults
    private let bus = ChangeBus()

    private enum Keys {
        static let baseUrl = "server_base_url"
        static let model = "model_name"
        static let showThinking = "show_thinking"
        static let window = "verbatim_window"
        static let sendImages = "send_images_to_model"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var settings: AsyncStream<AppSettings> {
        bus.observing { [self] in read() }
    }

    func current() async -> AppSettings { read() }

    func update(_ transform: @Sendable (AppSettings) -> AppSettings) async {
        let next = transform(read())
        defaults.set(next.serverBaseUrl, forKey: Keys.baseUrl)
        defaults.set(next.modelName, forKey: Keys.model)
        defaults.set(next.showThinking, forKey: Keys.showThinking)
        defaults.set(next.verbatimWindow, forKey: Keys.window)
        defaults.set(next.sendImagesToModel, forKey: Keys.sendImages)
        await bus.notify()
    }

    private func read() -> AppSettings {
        AppSettings(
            serverBaseUrl: defaults.string(forKey: Keys.baseUrl) ?? AppSettings.defaultBaseUrl,
            modelName: defaults.string(forKey: Keys.model) ?? AppSettings.defaultModel,
            showThinking: defaults.object(forKey: Keys.showThinking) as? Bool ?? true,
            verbatimWindow: defaults.object(forKey: Keys.window) as? Int ?? AppSettings.defaultWindow,
            sendImagesToModel: defaults.bool(forKey: Keys.sendImages)
        )
    }
}
