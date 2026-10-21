import AppKit
import AVFoundation
import SwiftUI

struct DictationSettingsView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @State private var microphones: [AVCaptureDevice] = []
    @State private var microphoneAccess = Permissions.microphoneAccess()
    @State private var editorTarget: DictationProfileEditorTarget?

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Toggle(isOn: enabledBinding) {
                    SettingsFeatureToggleLabel(
                        anchor: .dictationDictation, title: "Enable Dictation",
                        subtitle: "Transcribe speech online with multimodal audio LLMs.")
                }
                if microphoneAccess != .authorized {
                    HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .frame(width: SettingsListMetrics.iconSize)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text("Microphone access required")
                                .foregroundStyle(.orange)
                            Text("Needed to record your dictation.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.Spacing.lg)
                        Button(
                            microphoneAccess == .notDetermined
                                ? "Grant Access…" : "Open System Settings"
                        ) {
                            if microphoneAccess == .notDetermined {
                                Task {
                                    _ = await Permissions.requestMicrophoneAccess()
                                    microphoneAccess = Permissions.microphoneAccess()
                                }
                            } else {
                                Permissions.openMicrophoneSettings()
                            }
                        }
                    }
                }
            }
            .settingsAnchor(.dictationDictation)

            if settings.dictationEnabled {
                Section {
                    Picker(selection: $settings.dictationMode) {
                        ForEach(DictationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    } label: {
                        SettingsRowTitle(.dictationCommands, "Shortcut behavior")
                    }
                    HStack {
                        SettingsRowTitle(.dictationCommands, "Shortcut")
                        Spacer()
                        ShortcutRecorder(action: .dictation)
                    }
                    if settings.dictationMode == .pushToTalk {
                        let issue = coordinator.holdShortcutIssue
                        Text(
                            issue
                                ?? String(
                                    localized: """
                                        Hold a key combination or a single modifier; release it to \
                                        transcribe. Double taps work in toggle mode.
                                        """)
                        )
                        .font(.caption)
                        .foregroundStyle(issue == nil ? Color.secondary : Color.orange)
                    }
                } header: {
                    SettingsSectionHeader(.dictationCommands)
                }

                Section {
                    ForEach(coordinator.profiles.profiles) { profile in
                        HStack(alignment: .center, spacing: Theme.Spacing.md) {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                HStack(spacing: Theme.Spacing.xs) {
                                    Text(profile.name)
                                        .font(.body.weight(.medium))
                                    if profile.id == coordinator.profiles.activeProfileID {
                                        Text("Active")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.tint)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(
                                                Color.accentColor.opacity(0.12), in: Capsule())
                                    }
                                }
                                Text("\(profile.model) · \(profile.audioFormat.displayName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if profile.id != coordinator.profiles.activeProfileID {
                                Button("Set Active") {
                                    coordinator.profiles.selectProfile(id: profile.id)
                                }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }

                            Button {
                                editorTarget = DictationProfileEditorTarget(
                                    profile: profile,
                                    isNew: false,
                                    hasStoredKey: coordinator.profiles.hasApiKey(for: profile.id)
                                )
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit profile")

                            Button(role: .destructive) {
                                coordinator.profiles.deleteProfile(id: profile.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .disabled(coordinator.profiles.profiles.count <= 1)
                            .accessibilityLabel("Delete profile")
                        }
                        .padding(.vertical, Theme.Spacing.xxs)
                    }
                } header: {
                    HStack {
                        SettingsSectionHeader(.dictationProfiles)
                        Spacer()
                        Button {
                            editorTarget = DictationProfileEditorTarget(
                                profile: DictationProfile(
                                    name: "",
                                    baseURL:
                                        "https://note3-prev-api.askdiandian.com/v1/chat/completions",
                                    model: "dots3-note-prev"
                                ),
                                isNew: true,
                                hasStoredKey: false
                            )
                        } label: {
                            Label("Add Profile", systemImage: "plus")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }

                Section {
                    Picker(selection: microphoneBinding) {
                        Text(microphones.isEmpty ? "No microphone available" : "System default")
                            .tag("")
                        if !microphones.isEmpty { Divider() }
                        ForEach(microphones, id: \.uniqueID) { microphone in
                            Text(microphone.localizedName).tag(microphone.uniqueID)
                        }
                    } label: {
                        SettingsRowTitle(.dictationOutput, "Microphone")
                    }
                    Picker(selection: $settings.dictationDestination) {
                        ForEach(DictationDestination.allCases) { destination in
                            Text(destination.title).tag(destination)
                        }
                    } label: {
                        SettingsRowTitle(.dictationOutput, "When finished")
                    }
                    Toggle(isOn: $settings.dictationAdaptsCapitalization) {
                        SettingsRowTitle(.dictationOutput, "Adapt capitalization")
                        Text("Match the first letter to the text before the cursor.")
                    }
                } header: {
                    SettingsSectionHeader(.dictationOutput)
                } footer: {
                    Text(
                        "Press Return to finish dictating or Escape to cancel. Use Up/Down arrows to cycle profiles while dictating."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.dictation)
        .onAppear {
            microphoneAccess = Permissions.microphoneAccess()
            if settings.dictationEnabled { microphones = DictationCapture.microphones }
        }
        .onChange(of: settings.dictationEnabled) { _, enabled in
            if enabled { microphones = DictationCapture.microphones }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification)
            {
                microphoneAccess = Permissions.microphoneAccess()
                if settings.dictationEnabled { microphones = DictationCapture.microphones }
            }
        }
        .settingsEditorPanel(item: $editorTarget) { target in
            DictationProfileEditorPanel(
                target: target,
                onlineService: coordinator.onlineService,
                onSave: { updatedProfile, newKey in
                    if target.isNew {
                        coordinator.profiles.addProfile(updatedProfile, apiKey: newKey)
                    } else {
                        coordinator.profiles.updateProfile(updatedProfile, apiKey: newKey)
                    }
                    editorTarget = nil
                },
                onCancel: {
                    editorTarget = nil
                }
            )
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.dictationEnabled },
            set: { coordinator.setEnabled($0) })
    }

    private var microphoneBinding: Binding<String> {
        Binding(
            get: { settings.dictationMicrophone ?? "" },
            set: { settings.dictationMicrophone = $0.isEmpty ? nil : $0 })
    }
}
