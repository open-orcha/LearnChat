import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Creates the view model once per visit (SwiftUI may rebuild the view struct many times; a
/// throwaway ChatViewModel would delete the empty chat from its deinit).
struct ChatScreen: View {
    let chatId: Int64
    let container: AppContainer
    let onOpenSettings: () -> Void
    @State private var viewModel: ChatViewModel?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let viewModel {
                ChatContent(viewModel: viewModel, onOpenSettings: onOpenSettings)
            } else {
                QChatTheme.surface.ignoresSafeArea()
            }
        }
        .onAppear {
            if viewModel == nil {
                viewModel = ChatViewModel(
                    chatId: chatId, repository: container.chats, settings: container.settings,
                    sendMessage: container.sendMessage, leases: container.leases,
                    preprocessor: container.preprocessor
                )
            }
            viewModel?.setScreenVisible(scenePhase == .active)
        }
        .onDisappear { viewModel?.setScreenVisible(false) }
        .onChange(of: scenePhase) { _, phase in
            viewModel?.setScreenVisible(phase == .active)
        }
    }
}

private struct ChatContent: View {
    let viewModel: ChatViewModel
    let onOpenSettings: () -> Void

    @State private var input = ""
    @FocusState private var inputFocused: Bool
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var snackbar: String?

    // Auto-scroll: follow the bottom while streaming unless the user has scrolled up.
    @State private var followBottom = true
    @State private var atBottom = true

    private var messages: [Message] { viewModel.messages }
    private var lastSignature: String { messages.last.map { "\($0.id):\($0.text.count):\($0.status.rawValue)" } ?? "" }

    var body: some View {
        ZStack(alignment: .bottom) {
            QChatTheme.surface.ignoresSafeArea()
            if messages.isEmpty {
                Text("Ask anything — replies come from the model running on your Mac.")
                    .font(QChatType.bodyMedium)
                    .foregroundStyle(QChatTheme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(32)
            }
            ScrollViewReader { proxy in
                GeometryReader { outer in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(messages) { message in
                                MessageBubble(message: message, showThinking: viewModel.showThinking)
                                    .id(message.id)
                            }
                            // Sentinel: reports whether the very bottom is on screen.
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: BottomVisibleKey.self,
                                    value: g.frame(in: .named("chatScroll")).maxY <= outer.size.height + 8
                                )
                            }
                            .frame(height: 1)
                            .id("bottom")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                    }
                    .coordinateSpace(name: "chatScroll")
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12).onChanged { value in
                            if value.translation.height > 0 && !atBottom { followBottom = false }
                        }
                    )
                    .onPreferenceChange(BottomVisibleKey.self) { visible in
                        atBottom = visible
                        if visible { followBottom = true }
                    }
                    .onChange(of: lastSignature) { _, _ in
                        if followBottom && !messages.isEmpty { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: messages.count) { _, _ in
                        if followBottom && !messages.isEmpty { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onAppear {
                        if !messages.isEmpty { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: inputFocused) { _, focused in
                        if focused && followBottom && !messages.isEmpty {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if !followBottom && !messages.isEmpty {
                        Button {
                            followBottom = true
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 40, height: 40)
                                .background(QChatTheme.primaryContainer, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .foregroundStyle(QChatTheme.onPrimaryContainer)
                                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                        }
                        .padding(.bottom, 12)
                        .accessibilityLabel("Jump to latest")
                    }
                }
            }
            if let snackbar {
                Snackbar(text: snackbar)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Composer(
                text: $input,
                sending: viewModel.isSending,
                pending: viewModel.pending,
                canSend: !viewModel.isPreprocessing && (!input.isBlank || viewModel.hasReadyAttachment),
                onSend: { viewModel.send(input); input = ""; followBottom = true },
                onStop: viewModel.stop,
                onAttachPhoto: { showPhotoPicker = true },
                onAttachFile: { showFilePicker = true },
                onRemoveAttachment: viewModel.removeAttachment,
                focused: $inputFocused
            )
        }
        .navigationTitle(viewModel.chat?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(QChatTheme.surface, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenSettings) { Image(systemName: "gearshape.fill") }
                    .accessibilityLabel("Settings")
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await attachPhoto(item) }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.pdf, .image, .movie]) { result in
            if case .success(let url) = result {
                let mime = UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType
                viewModel.attach(url: url, mimeType: mime, displayName: url.lastPathComponent)
            }
        }
        .onChange(of: viewModel.error) { _, error in
            guard let error else { return }
            withAnimation { snackbar = error }
            viewModel.dismissError()
            Task {
                try? await Task.sleep(for: .seconds(4))
                withAnimation { if snackbar == error { snackbar = nil } }
            }
        }
    }

    /// Photo-library picks arrive as data, not a file: write it to a temp file the preprocessor can open.
    private func attachPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let media = try await item.loadTransferable(type: PickedMedia.self) else {
                withAnimation { snackbar = "Couldn't load that item" }
                return
            }
            viewModel.attach(url: media.url, mimeType: media.mimeType, displayName: media.url.lastPathComponent)
        } catch {
            withAnimation { snackbar = "Couldn't load that item: \(error.localizedDescription)" }
        }
    }
}

private struct BottomVisibleKey: PreferenceKey {
    static let defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

/// Material snackbar look (inverse surface).
private struct Snackbar: View {
    let text: String

    var body: some View {
        Text(text)
            .font(QChatType.bodyMedium)
            .foregroundStyle(QChatTheme.inverseOnSurface)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(QChatTheme.inverseSurface, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }
}

/// A photo or video copied out of the Photos library into a temp file, keeping its original name.
private struct PickedMedia: Transferable {
    let url: URL
    let mimeType: String?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in try copyToTemp(received.file) }
        FileRepresentation(importedContentType: .image) { received in try copyToTemp(received.file) }
    }

    private static func copyToTemp(_ file: URL) throws -> PickedMedia {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: target)
        let mime = UTType(filenameExtension: target.pathExtension.lowercased())?.preferredMIMEType
        return PickedMedia(url: target, mimeType: mime)
    }
}
