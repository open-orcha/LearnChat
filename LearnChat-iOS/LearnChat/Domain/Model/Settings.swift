import Foundation

struct AppSettings: Equatable, Sendable {
    var serverBaseUrl: String
    var modelName: String
    var showThinking: Bool
    /// Number of most recent messages sent verbatim; older ones are summarised.
    var verbatimWindow: Int
    /// Send photos / video frames as actual pixels in addition to the on-device
    /// description. Only useful once the server runs a vision-capable model; off by default because
    /// muse-glimmer is text-only.
    var sendImagesToModel: Bool = false

    // Defaults come from InfraAgent's Muse Glimmer service on the Mac's LAN address.
    static let defaultBaseUrl = "http://192.168.86.32:11434"
    static let defaultModel = "muse-glimmer"
    static let defaultWindow = 12
    static let `default` = AppSettings(serverBaseUrl: defaultBaseUrl, modelName: defaultModel, showThinking: true, verbatimWindow: defaultWindow)
}
