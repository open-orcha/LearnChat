import SwiftUI

struct SettingsScreen: View {
    @State private var viewModel: SettingsViewModel
    private let onBack: () -> Void

    @State private var baseUrl = ""
    @State private var model = ""
    @State private var showThinking = true
    @State private var window = ""
    @State private var sendImages = false
    @State private var loaded = false

    init(container: AppContainer, onBack: @escaping () -> Void) {
        _viewModel = State(initialValue: SettingsViewModel(repository: container.settings))
        self.onBack = onBack
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle("Server")
                OutlinedField(
                    label: "Server address", text: $baseUrl,
                    supporting: "Your Mac's Wi-Fi address and Muse Glimmer port, e.g. http://192.168.86.32:11434",
                    keyboard: .URL
                )
                OutlinedField(label: "Model", text: $model)
                HStack(alignment: .center, spacing: 12) {
                    Button { viewModel.testConnection(baseUrl: baseUrl) } label: {
                        Text(viewModel.testing ? "Testing…" : "Test connection")
                            .font(QChatType.labelLarge)
                            .padding(.horizontal, 24)
                            .frame(height: 40)
                            .overlay(Capsule().stroke(QChatTheme.outline, lineWidth: 1))
                    }
                    .disabled(viewModel.testing)
                    .foregroundStyle(QChatTheme.primary)
                    if let r = viewModel.testResult {
                        Text(r.reachable
                             ? "Connected ✓  models: \(r.models.isEmpty ? "none" : r.models.joined(separator: ", "))"
                             : "Not reachable: \(r.detail ?? "unknown error")")
                            .font(QChatType.bodySmall)
                            .foregroundStyle(r.reachable ? QChatTheme.primary : QChatTheme.error)
                    }
                }

                Divider().overlay(QChatTheme.outlineVariant)
                SectionTitle("Chat")
                SwitchRow(
                    title: "Show reasoning by default",
                    subtitle: "Expand the model's thinking trace under each reply.",
                    isOn: $showThinking
                )
                OutlinedField(
                    label: "Recent messages sent word-for-word", text: $window,
                    supporting: "Older messages are folded into a short summary so long chats stay fast.",
                    keyboard: .numberPad
                )
                .onChange(of: window) { _, v in
                    let digits = String(v.filter(\.isNumber).prefix(2))
                    if digits != v { window = digits }
                }

                Divider().overlay(QChatTheme.outlineVariant)
                SectionTitle("Attachments")
                Text("PDFs, photos and videos are processed on this phone: PDF text is extracted, and photos/video frames are described (text read + objects recognised) before anything is sent. Nothing but that text leaves the phone.")
                    .font(QChatType.bodySmall)
                    .foregroundStyle(QChatTheme.onSurfaceVariant)
                SwitchRow(
                    title: "Server model can see images",
                    subtitle: "Also send the actual photo / video frames. Turn on only if the Model above is a vision model (muse-glimmer is text-only and will ignore or reject them).",
                    isOn: $sendImages
                )

                Spacer().frame(height: 8)
                Button {
                    viewModel.save(baseUrl: baseUrl, model: model, showThinking: showThinking, window: Int(window) ?? 12, sendImages: sendImages)
                    onBack()
                } label: {
                    Text("Save")
                        .font(QChatType.labelLarge)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(QChatTheme.primary, in: Capsule())
                        .foregroundStyle(QChatTheme.onPrimary)
                }
                Button { viewModel.resetDefaults() } label: {
                    Text("Reset to defaults")
                        .font(QChatType.labelLarge)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                .foregroundStyle(QChatTheme.primary)
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(QChatTheme.surface.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(QChatTheme.surface, for: .navigationBar)
        // Re-sync the form when persisted values arrive (first load / reset).
        .onChange(of: viewModel.settings, initial: true) { _, saved in
            baseUrl = saved.serverBaseUrl
            model = saved.modelName
            showThinking = saved.showThinking
            window = String(saved.verbatimWindow)
            sendImages = saved.sendImagesToModel
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(QChatType.titleMedium).foregroundStyle(QChatTheme.onSurface)
    }
}

/// Material outlined text field: floating label on the border, optional supporting text below.
private struct OutlinedField: View {
    let label: String
    @Binding var text: String
    var supporting: String? = nil
    var keyboard: UIKeyboardType = .default
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                TextField("", text: $text)
                    .font(QChatType.bodyLarge)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .padding(.horizontal, 16)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(focused ? QChatTheme.primary : QChatTheme.outline, lineWidth: focused ? 2 : 1)
                    )
                Text(label)
                    .font(QChatType.bodySmall)
                    .foregroundStyle(focused ? QChatTheme.primary : QChatTheme.onSurfaceVariant)
                    .padding(.horizontal, 4)
                    .background(QChatTheme.surface)
                    .offset(x: 12, y: -8)
            }
            if let supporting {
                Text(supporting)
                    .font(QChatType.bodySmall)
                    .foregroundStyle(QChatTheme.onSurfaceVariant)
                    .padding(.horizontal, 16)
            }
        }
    }
}

private struct SwitchRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(QChatType.bodyLarge).foregroundStyle(QChatTheme.onSurface)
                Text(subtitle).font(QChatType.bodySmall).foregroundStyle(QChatTheme.onSurfaceVariant)
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().tint(QChatTheme.primary)
        }
    }
}
