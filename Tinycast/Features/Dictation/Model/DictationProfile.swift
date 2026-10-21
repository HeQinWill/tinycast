import Foundation

enum DictationAudioFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case m4a
    case wav

    var id: String { rawValue }

    var mimeType: String {
        switch self {
        case .m4a: "audio/m4a"
        case .wav: "audio/wav"
        }
    }

    var displayName: String {
        switch self {
        case .m4a: "M4A (AAC)"
        case .wav: "WAV (PCM)"
        }
    }
}

struct DictationProfile: Identifiable, Codable, Sendable, Hashable, Equatable {
    var id: UUID
    var name: String
    var baseURL: String
    var model: String
    var systemPrompt: String
    var userPrompt: String
    var audioFormat: DictationAudioFormat
    var disableThinking: Bool
    var maxTokens: Int

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        model: String,
        systemPrompt: String = Self.defaultSystemPrompt,
        userPrompt: String = Self.defaultUserPrompt,
        audioFormat: DictationAudioFormat = .m4a,
        disableThinking: Bool = true,
        maxTokens: Int = 1024
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.audioFormat = audioFormat
        self.disableThinking = disableThinking
        self.maxTokens = maxTokens
    }

    static let defaultSystemPrompt =
        "You are an accurate voice transcription assistant. Transcribe the user's speech directly and accurately without adding any extra commentary, greetings, or explanations."
    static let defaultUserPrompt = "Please transcribe this audio verbatim."

    static let defaultProfile = DictationProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
        name: "AskDianDian",
        baseURL: "https://note3-prev-api.askdiandian.com/v1/chat/completions",
        model: "dots3-note-prev",
        systemPrompt: defaultSystemPrompt,
        userPrompt: defaultUserPrompt,
        audioFormat: .m4a,
        disableThinking: true,
        maxTokens: 1024
    )

    var endpointURL: URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.hasPrefix("http://") && !trimmed.hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        if let queryIndex = trimmed.firstIndex(of: "?") {
            var basePath = String(trimmed[..<queryIndex])
            let queryString = String(trimmed[queryIndex...])
            while basePath.hasSuffix("/") {
                basePath = String(basePath.dropLast())
            }
            if !basePath.hasSuffix("/chat/completions") {
                basePath += "/chat/completions"
            }
            return URL(string: basePath + queryString)
        }
        while trimmed.hasSuffix("/") {
            trimmed = String(trimmed.dropLast())
        }
        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed)
        }
        return URL(string: trimmed + "/chat/completions")
    }
}
