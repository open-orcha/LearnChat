import Foundation

protocol SettingsRepository: AnyObject, Sendable {
    /// Emits the current settings immediately, then again after every change.
    var settings: AsyncStream<AppSettings> { get }
    func current() async -> AppSettings
    func update(_ transform: @Sendable (AppSettings) -> AppSettings) async
}
