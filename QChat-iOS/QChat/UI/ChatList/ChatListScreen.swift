import SwiftUI

struct ChatListScreen: View {
    @State private var viewModel: ChatListViewModel
    private let onOpenChat: (Int64) -> Void
    private let onOpenSettings: () -> Void

    @State private var renaming: Chat?
    @State private var renameTitle = ""
    @State private var confirmDelete: Chat?

    init(container: AppContainer, onOpenChat: @escaping (Int64) -> Void, onOpenSettings: @escaping () -> Void) {
        _viewModel = State(initialValue: ChatListViewModel(repository: container.chats))
        self.onOpenChat = onOpenChat
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            QChatTheme.surface.ignoresSafeArea()
            if viewModel.chats.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.chats) { chat in
                            ChatRow(chat: chat)
                                .onTapGesture { onOpenChat(chat.id) }
                                .contextMenu {
                                    Button { renameTitle = chat.title; renaming = chat } label: { Label("Rename", systemImage: "pencil") }
                                    Button(role: .destructive) { confirmDelete = chat } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                        Spacer().frame(height: 72)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            // Extended FAB
            Button { viewModel.newChat(onCreated: onOpenChat) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("New chat").font(QChatType.labelLarge)
                }
                .padding(.horizontal, 20)
                .frame(height: 56)
                .background(QChatTheme.primaryContainer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(QChatTheme.onPrimaryContainer)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            }
            .padding(16)
        }
        .navigationTitle("QChat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(QChatTheme.surface, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { Text("QChat").font(.system(size: 22, weight: .semibold)) }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenSettings) { Image(systemName: "gearshape.fill") }
                    .accessibilityLabel("Settings")
            }
        }
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameTitle)
            Button("Save") { if let c = renaming { viewModel.rename(c.id, title: renameTitle) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert(confirmDelete?.title ?? "", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let c = confirmDelete { viewModel.delete(c.id) }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("Delete this chat and its messages?")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "bubble.left")
                .font(.system(size: 28))
                .foregroundStyle(QChatTheme.primary)
                .padding(.bottom, 12)
            Text("No chats yet").font(QChatType.titleMedium).foregroundStyle(QChatTheme.onSurface)
            Text("Tap “New chat” to start talking to your local model.")
                .font(QChatType.bodyMedium)
                .foregroundStyle(QChatTheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChatRow: View {
    let chat: Chat

    private var date: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(chat.updatedAt) / 1000))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(chat.title)
                .font(QChatType.titleMedium)
                .foregroundStyle(QChatTheme.onSurface)
                .lineLimit(1)
            if !chat.preview.isBlank {
                Text(chat.preview)
                    .font(QChatType.bodyMedium)
                    .foregroundStyle(QChatTheme.onSurfaceVariant)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
            Text(date)
                .font(QChatType.labelSmall)
                .foregroundStyle(QChatTheme.outline)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(QChatTheme.surfaceContainer, in: RoundedRectangle(cornerRadius: QChatTheme.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: QChatTheme.cardRadius, style: .continuous))
    }
}

extension Chat: Identifiable {}
