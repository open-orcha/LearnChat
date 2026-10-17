import SwiftUI

@main
struct QChatApp: App {
    private let container = AppContainer()

    var body: some Scene {
        WindowGroup {
            QChatNavHost(container: container)
                .tint(QChatTheme.primary)
        }
    }
}
