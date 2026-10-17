import SwiftUI

enum Route: Hashable {
    case chat(Int64)
    case settings
}

/// Navigation stack: chat list → chat → settings (also reachable from the list).
struct LearnChatNavHost: View {
    let container: AppContainer
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            ChatListScreen(
                container: container,
                onOpenChat: { path.append(.chat($0)) },
                onOpenSettings: { path.append(.settings) }
            )
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .chat(let id):
                    ChatScreen(chatId: id, container: container, onOpenSettings: { path.append(.settings) })
                case .settings:
                    SettingsScreen(container: container, onBack: { _ = path.popLast() })
                }
            }
        }
        .background(LearnChatTheme.surface)
    }
}
