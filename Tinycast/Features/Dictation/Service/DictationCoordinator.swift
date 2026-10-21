import AppKit
import AVFoundation

@MainActor
@Observable
final class DictationCoordinator {
    private enum Phase { case idle, starting, listening, transcribing, stopping }

    private let settings: AppSettings
    private let hotKeys: HotKeyManager
    let profiles: DictationProfileStore
    let onlineService: DictationOnlineService
    private let capture = DictationCapture()
    private let audioDucker: DictationAudioDucker
    private let panel = DictationPanelController()
    private let injector: TextInjector
    private let showMessage: (String, DialogTone) -> Void
    private let confirmEnable: () async -> Bool
    @ObservationIgnored private var phase: Phase = .idle
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var enableTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var finishWhenStarted = false
    @ObservationIgnored private var target: InjectionTarget?
    /// The field a mic button is dictating into; nil for a shortcut's session.
    private(set) var field: DictationField?

    init(
        settings: AppSettings, hotKeys: HotKeyManager,
        profiles: DictationProfileStore,
        onlineService: DictationOnlineService,
        injector: TextInjector, audioDucker: DictationAudioDucker,
        confirmEnable: @escaping () async -> Bool,
        showMessage: @escaping (String, DialogTone) -> Void
    ) {
        self.settings = settings
        self.hotKeys = hotKeys
        self.profiles = profiles
        self.onlineService = onlineService
        self.injector = injector
        self.audioDucker = audioDucker
        self.confirmEnable = confirmEnable
        self.showMessage = showMessage
        panel.onAccept = { [weak self] in self?.accept() }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onNextProfile = { [weak self] in self?.cycleProfile(forward: true) }
        panel.onPreviousProfile = { [weak self] in self?.cycleProfile(forward: false) }
        capture.onLevels = { [weak self] in self?.panel.state.levels = $0 }
        capture.onLimit = { [weak self] in self?.accept() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != settings.dictationEnabled else { return }
        guard enabled else {
            settings.dictationEnabled = false
            enableTask?.cancel()
            cancel()
            return
        }
        guard enableTask == nil else { return }
        NSApp.activate()
        enableTask = Task { [weak self] in
            guard let self else { return }
            defer { enableTask = nil }
            guard await confirmEnable(), !Task.isCancelled else { return }
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard !Task.isCancelled else { return }
            guard granted else {
                showMessage(
                    String(localized: "Allow Tinycast to use the microphone in System Settings"),
                    .danger)
                return
            }
            settings.dictationEnabled = true
            if settings.dictationDestination.pastes { Permissions.ensureAccessibility() }
        }
    }

    var holdShortcutIssue: String? {
        guard let binding = hotKeys.binding(for: .dictation) else { return nil }
        guard binding.shortcut != nil || binding.holdKey != nil else {
            return String(localized: "Record a single modifier or a key combination for hold to talk.")
        }
        if let owner = hotKeys.conflictOwner(of: binding, excluding: .dictation) {
            return String(localized: "This shortcut is also used by \(owner). Record another shortcut.")
        }
        return nil
    }

    func pressed() {
        guard settings.dictationEnabled else { return }
        if phase == .stopping { return }
        if settings.dictationMode == .pushToTalk,
            hotKeys.binding(for: .dictation)?.shortcut == nil,
            hotKeys.binding(for: .dictation)?.holdKey == nil
        {
            showMessage(
                String(localized: "Hold to talk needs a key combination or a single modifier"),
                .danger)
            return
        }
        if phase != .idle {
            if settings.dictationMode == .toggle { finish() }
            return
        }
        begin(target: InjectionTarget.current())
    }

    var isEnabled: Bool { settings.dictationEnabled }
    var hasProfile: Bool { profiles.activeProfile != nil }
    var hasModel: Bool { hasProfile }
    var activeProfile: DictationProfile? { profiles.activeProfile }

    func cycleProfile(forward: Bool = true) {
        profiles.cycleProfile(forward: forward)
        panel.state.profileName = profiles.activeProfile?.name ?? ""
    }

    /// A field's own mic: click to start and click to finish, whatever the shortcut's mode or focus.
    func toggle(into editor: any InjectableTextView) {
        guard settings.dictationEnabled, phase != .stopping else { return }
        guard phase == .idle else {
            if field?.editor == ObjectIdentifier(editor) { finish() }
            return
        }
        field = DictationField(editor: ObjectIdentifier(editor))
        begin(target: .ownEditor(editor))
    }

    private func finish() {
        if phase == .starting {
            finishWhenStarted = true
        } else {
            accept()
        }
    }

    private func begin(target: InjectionTarget?) {
        guard let profile = profiles.activeProfile else {
            field = nil
            showMessage(
                String(localized: "Configure a dictation profile in Settings first"), .danger)
            return
        }
        guard profiles.hasApiKey(for: profile.id) else {
            field = nil
            showMessage(
                String(localized: "Enter an API Key for \(profile.name) in Settings"), .danger)
            return
        }
        token = UUID()
        let current = token
        phase = .starting
        finishWhenStarted = false
        self.target = target
        audioDucker.begin()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await capture.start(microphoneID: settings.dictationMicrophone)
                guard token == current, settings.dictationEnabled else {
                    _ = await capture.stop()
                    return
                }
                phase = .listening
                panel.show(profileName: profile.name)
                if finishWhenStarted { accept() }
            } catch {
                guard token == current else { return }
                reset()
                showMessage(error.localizedDescription, .danger)
            }
        }
    }

    func released() {
        guard settings.dictationMode == .pushToTalk else { return }
        if phase == .starting { finishWhenStarted = true }
        if phase == .listening { accept() }
    }

    func accept() {
        guard phase == .listening else { return }
        phase = .transcribing
        panel.state.phase = .transcribing
        field?.isTranscribing = true
        audioDucker.end()
        let current = token
        guard let profile = profiles.activeProfile else {
            reset()
            return
        }
        let apiKey = profiles.apiKey(for: profile.id) ?? ""
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            let samples = await capture.stop()
            guard token == current else { return }
            let destination = field == nil ? settings.dictationDestination : .paste
            if samples.count < 1_600 {
                reset(cancelTranscription: false)
                showMessage(String(localized: "No speech was recorded"), .danger)
                return
            }
            do {
                let transcript = try await onlineService.transcribe(
                    samples: samples, profile: profile, apiKey: apiKey)
                guard token == current else { return }
                let context = destination.pastes ? insertionContext() : nil
                let text = DictationTextFormatter.format(
                    transcript, context: context,
                    adaptCapitalization: settings.dictationAdaptsCapitalization)
                let target = self.target
                guard !text.isEmpty else {
                    reset(cancelTranscription: false)
                    return
                }
                panel.close()
                if destination.pastes {
                    injector.deliver(
                        InjectedText(text), target: target, expectedKeyword: nil,
                        keywordLength: 0, automaticGeneration: nil,
                        isValid: { [weak self] in self?.token == current },
                        onDelivered: { [weak self] in
                            guard let self, token == current else { return }
                            if destination.copies { Paster.copyPlainText(text) }
                            reset(cancelTranscription: false)
                        },
                        onFailed: { [weak self] in
                            guard let self, token == current else { return }
                            reset(cancelTranscription: false)
                            if destination.copies { Paster.copyPlainText(text) }
                            showMessage(
                                String(localized: "Couldn't paste dictation into this app"),
                                .danger)
                        })
                } else {
                    Paster.copyPlainText(text)
                    reset(cancelTranscription: false)
                }
            } catch is CancellationError {
                reset(cancelTranscription: false)
            } catch let error as URLError where error.code == .cancelled {
                reset(cancelTranscription: false)
            } catch {
                guard token == current else { return }
                reset(cancelTranscription: false)
                showMessage(error.localizedDescription, .danger)
            }
        }
    }

    private func insertionContext() -> DictationTextFormatter.Context? {
        DictationInsertionContext.read(in: target)
    }

    func cancel(in editor: any InjectableTextView) {
        guard let target = target?.ownEditor, target === editor else { return }
        cancel()
    }

    func cancel() {
        guard phase != .stopping, phase != .idle || !settings.dictationEnabled else { return }
        let pendingStart = startTask
        let pendingTranscription = transcriptionTask
        reset()
        phase = .stopping
        let current = token
        stopTask = Task { [weak self] in
            guard let self else { return }
            await pendingStart?.value
            _ = await capture.stop()
            await pendingTranscription?.value
            if token == current { phase = .idle; stopTask = nil }
        }
    }

    func prepareForTermination() {
        enableTask?.cancel()
        cancel()
        audioDucker.restoreImmediately()
    }

    private func reset(cancelTranscription: Bool = true) {
        token = UUID()
        if cancelTranscription { transcriptionTask?.cancel() }
        startTask = nil
        transcriptionTask = nil
        phase = .idle
        target = nil
        field = nil
        panel.close()
        audioDucker.end()
    }
}

/// Which editor a mic session belongs to, so only that field's button shows it running.
struct DictationField: Equatable {
    let editor: ObjectIdentifier
    var isTranscribing = false
}
