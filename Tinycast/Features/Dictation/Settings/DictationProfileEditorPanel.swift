import AppKit
import SwiftUI

struct DictationProfileEditorTarget: Identifiable {
    let profile: DictationProfile
    let isNew: Bool
    let hasStoredKey: Bool
    var id: UUID { profile.id }
}

struct DictationProfileEditorPanel: View {
    let target: DictationProfileEditorTarget
    let onlineService: DictationOnlineService
    let onSave: (DictationProfile, String?) -> Void
    let onCancel: () -> Void

    private enum TestStatus: Equatable {
        case idle
        case testing
        case success(String)
        case failed(String)
    }

    @State private var profile: DictationProfile
    @State private var apiKey: String = ""
    @State private var clearStoredKey = false
    @State private var testStatus: TestStatus = .idle
    @State private var errorMessage: String?

    init(
        target: DictationProfileEditorTarget,
        onlineService: DictationOnlineService,
        onSave: @escaping (DictationProfile, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.target = target
        self.onlineService = onlineService
        self.onSave = onSave
        self.onCancel = onCancel
        _profile = State(initialValue: target.profile)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsEditorHeader(
                title: target.isNew ? "Add Dictation Profile" : "Edit Dictation Profile"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.dialogInset)
            .padding(.top, Theme.Spacing.dialogInset)
            .padding(.bottom, Theme.Spacing.xl)

            Form {
                Section {
                    LabeledContent {
                        TextField("Name", text: $profile.name, prompt: Text("e.g. AskDianDian"))
                            .settingsEditorTextField()
                    } label: {
                        Text("Profile Name")
                    }

                    LabeledContent {
                        TextField(
                            "Base URL", text: $profile.baseURL,
                            prompt: Text("https://note3-prev-api.askdiandian.com/v1/chat/completions")
                        )
                        .settingsEditorTextField()
                    } label: {
                        Text("Base URL")
                    }

                    LabeledContent {
                        TextField(
                            "Model", text: $profile.model,
                            prompt: Text("dots3-note-prev")
                        )
                        .settingsEditorTextField()
                    } label: {
                        Text("Model")
                    }

                    LabeledContent {
                        RevealableSecureField(
                            title: String(localized: "API Key"),
                            text: $apiKey,
                            prompt: Text((target.hasStoredKey && !clearStoredKey) ? "••••••••" : "sk-...")
                        )
                        .settingsEditorTextField()
                    } label: {
                        Text("API Key")
                    }

                    if target.hasStoredKey && !clearStoredKey && apiKey.isEmpty {
                        HStack {
                            Label("A key is already stored in Keychain", systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear Key") {
                                clearStoredKey = true
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                        }
                    }

                    Picker("Audio Format", selection: $profile.audioFormat) {
                        ForEach(DictationAudioFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }

                    Toggle(isOn: $profile.disableThinking) {
                        Text("Disable Thinking")
                        Text("Adds enable_thinking: false to chat_template_kwargs.")
                    }

                    LabeledContent {
                        TextField("Max Tokens", value: $profile.maxTokens, format: .number)
                            .settingsEditorTextField()
                    } label: {
                        Text("Max Tokens")
                    }
                } header: {
                    Text("Connection")
                }

                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("System Prompt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $profile.systemPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 64)
                            .settingsEditorTextField()
                    }

                    LabeledContent {
                        TextField(
                            "User Prompt", text: $profile.userPrompt,
                            prompt: Text("Please transcribe this audio verbatim.")
                        )
                        .settingsEditorTextField()
                    } label: {
                        Text("User Prompt")
                    }
                } header: {
                    Text("Prompts")
                }

                Section {
                    HStack(spacing: Theme.Spacing.md) {
                        Button(action: runConnectionTest) {
                            HStack(spacing: Theme.Spacing.xs) {
                                if testStatus == .testing {
                                    ProgressView().controlSize(.small)
                                }
                                Text("Test Connection")
                            }
                        }
                        .disabled(testStatus == .testing)

                        Spacer()

                        switch testStatus {
                        case .idle:
                            EmptyView()
                        case .testing:
                            Text("Testing endpoint…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .success(let msg):
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(msg)
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        case .failed(let err):
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .lineLimit(2)
                            }
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Diagnostics")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack(spacing: Theme.Spacing.md) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.modalAction(.cancel))
                    .keyboardShortcut(.cancelAction)

                Button("Save", action: save)
                    .buttonStyle(.modalAction(.primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.dialogInset)
        }
        .frame(width: 580, height: 560)
        .settingsEditorPanelSurface()
    }

    private func runConnectionTest() {
        testStatus = .testing
        errorMessage = nil
        Task {
            do {
                let keyToTest: String
                if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    keyToTest = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if target.hasStoredKey && !clearStoredKey {
                    keyToTest = (try? KeychainSecretStore.dictationAPIKeys.secret(for: target.id)) ?? ""
                } else {
                    keyToTest = ""
                }
                guard !keyToTest.isEmpty else {
                    testStatus = .failed(String(localized: "Enter an API Key to test connection."))
                    return
                }
                let msg = try await onlineService.testConnection(profile: profile, apiKey: keyToTest)
                testStatus = .success(msg)
            } catch {
                testStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func save() {
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = String(localized: "Profile name cannot be empty.")
            return
        }
        guard profile.endpointURL != nil else {
            errorMessage = String(localized: "Please enter a valid Base URL.")
            return
        }
        let trimmedModel = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            errorMessage = String(localized: "Model name cannot be empty.")
            return
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isNew && trimmedKey.isEmpty {
            errorMessage = String(localized: "Please enter an API Key for the new profile.")
            return
        }

        profile.name = trimmedName
        profile.model = trimmedModel
        let keyToSave: String? =
            clearStoredKey ? "" : (trimmedKey.isEmpty ? nil : trimmedKey)
        onSave(profile, keyToSave)
    }
}
