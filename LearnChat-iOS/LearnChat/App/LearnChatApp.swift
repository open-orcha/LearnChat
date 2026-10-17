import SwiftUI

@main
struct LearnChatApp: App {
    private let container = AppContainer()

    var body: some Scene {
        WindowGroup {
            LearnChatNavHost(container: container)
                .tint(LearnChatTheme.primary)
        }
    }
}
