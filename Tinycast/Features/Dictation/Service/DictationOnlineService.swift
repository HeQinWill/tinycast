import Foundation

@MainActor
final class DictationOnlineService {
    enum Failure: LocalizedError {
        case invalidEndpoint
        case missingAPIKey
        case serverError(Int, String)
        case emptyResponse
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: String(localized: "Invalid dictation endpoint URL.")
            case .missingAPIKey: String(localized: "No API key configured for this profile.")
            case .serverError(let code, let message):
                message.isEmpty
                    ? String(localized: "Server returned error \(code).")
                    : "\(message) (\(code))"
            case .emptyResponse: String(localized: "The dictation service returned an empty response.")
            case .invalidResponse: String(localized: "Invalid response from dictation service.")
            }
        }
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    var transcribeHandler:
        ((_ samples: [Float], _ profile: DictationProfile, _ apiKey: String) async throws -> String)?

    func transcribe(samples: [Float], profile: DictationProfile, apiKey: String) async throws -> String {
        if let transcribeHandler {
            return try await transcribeHandler(samples, profile, apiKey)
        }
        let audioURI = try DictationAudioEncoder.encodeDataURI(
            samples: samples, format: profile.audioFormat)
        return try await transcribe(audioURI: audioURI, profile: profile, apiKey: apiKey)
    }

    func transcribe(audioURI: String, profile: DictationProfile, apiKey: String) async throws -> String {
        guard let url = profile.endpointURL else { throw Failure.invalidEndpoint }
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { throw Failure.missingAPIKey }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let payload = RequestPayload(
            model: profile.model,
            systemPrompt: profile.systemPrompt,
            userPrompt: profile.userPrompt,
            audioURI: audioURI,
            disableThinking: profile.disableThinking,
            maxTokens: profile.maxTokens
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }

        if !(200...299).contains(http.statusCode) {
            let errorMsg = Self.parseErrorMessage(from: data)
            throw Failure.serverError(http.statusCode, errorMsg)
        }

        let decoded = try JSONDecoder().decode(ResponsePayload.self, from: data)
        guard let rawText = decoded.firstChoiceContent else {
            throw Failure.emptyResponse
        }

        let cleaned = Self.stripThinkTags(rawText)
        return cleaned
    }

    func testConnection(profile: DictationProfile, apiKey: String) async throws -> String {
        let silenceSamples = [Float](repeating: 0, count: 8_000)
        let audioURI = try DictationAudioEncoder.encodeDataURI(
            samples: silenceSamples, format: profile.audioFormat)
        guard let url = profile.endpointURL else { throw Failure.invalidEndpoint }
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { throw Failure.missingAPIKey }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let payload = RequestPayload(
            model: profile.model,
            systemPrompt: profile.systemPrompt,
            userPrompt: profile.userPrompt,
            audioURI: audioURI,
            disableThinking: profile.disableThinking,
            maxTokens: min(profile.maxTokens, 16)
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }

        if !(200...299).contains(http.statusCode) {
            let errorMsg = Self.parseErrorMessage(from: data)
            throw Failure.serverError(http.statusCode, errorMsg)
        }

        guard let decoded = try? JSONDecoder().decode(ResponsePayload.self, from: data),
            let choices = decoded.choices, !choices.isEmpty
        else {
            throw Failure.invalidResponse
        }

        return String(localized: "Connection successful!")
    }

    static func stripThinkTags(_ input: String) -> String {
        let normalized =
            input
            .replacingOccurrences(of: "<think>", with: "<think>", options: .caseInsensitive)
            .replacingOccurrences(of: "</think>", with: "</think>", options: .caseInsensitive)
        var decoder = AIThinkTagDecoder()
        let events = decoder.feed(normalized) + decoder.finish()
        var text = events.compactMap { event in
            if case .text(let str) = event { return str }
            return nil
        }.joined()
        text = text.replacingOccurrences(of: "</think>", with: "", options: .caseInsensitive)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseErrorMessage(from data: Data) -> String {
        if let root = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
            let msg = root.error?.message, !msg.isEmpty
        {
            return msg
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private struct RequestPayload: Encodable {
    let model: String
    let messages: [Message]
    let stream: Bool = false
    let maxTokens: Int
    let chatTemplateKwargs: ChatTemplateKwargs?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case maxTokens = "max_tokens"
        case chatTemplateKwargs = "chat_template_kwargs"
    }

    init(
        model: String,
        systemPrompt: String,
        userPrompt: String,
        audioURI: String,
        disableThinking: Bool,
        maxTokens: Int
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.chatTemplateKwargs = disableThinking ? ChatTemplateKwargs(enableThinking: false) : nil

        var msgs: [Message] = []
        let trimmedSys = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSys.isEmpty {
            msgs.append(Message(role: "system", content: [.text(trimmedSys)]))
        }

        let trimmedUser = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveUser = trimmedUser.isEmpty ? "Please transcribe this audio verbatim." : trimmedUser
        msgs.append(
            Message(
                role: "user",
                content: [
                    .audio(audioURI),
                    .text(effectiveUser)
                ]
            ))
        self.messages = msgs
    }
}

private struct ChatTemplateKwargs: Encodable {
    let enableThinking: Bool

    enum CodingKeys: String, CodingKey {
        case enableThinking = "enable_thinking"
    }
}

private struct Message: Encodable {
    let role: String
    let content: [ContentPart]
}

private enum ContentPart: Encodable {
    case text(String)
    case audio(String)

    enum CodingKeys: String, CodingKey {
        case type, text
        case audioUrl = "audio_url"
    }

    struct AudioURL: Encodable {
        let url: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let str):
            try container.encode("text", forKey: .type)
            try container.encode(str, forKey: .text)
        case .audio(let uri):
            try container.encode("audio_url", forKey: .type)
            try container.encode(AudioURL(url: uri), forKey: .audioUrl)
        }
    }
}

private struct ResponsePayload: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let role: String?
            let content: FlexibleContent?
        }
        let message: Message?
        let delta: Message?
        let text: String?
    }
    let choices: [Choice]?

    var firstChoiceContent: String? {
        guard let choice = choices?.first else { return nil }
        if let text = choice.message?.content?.textValue { return text }
        if let text = choice.delta?.content?.textValue { return text }
        if let text = choice.text { return text }
        return nil
    }
}

private enum FlexibleContent: Decodable {
    case text(String)
    case parts([Part])

    struct Part: Decodable {
        let type: String?
        let text: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
            return
        }
        if let parts = try? container.decode([Part].self) {
            self = .parts(parts)
            return
        }
        self = .text("")
    }

    var textValue: String {
        switch self {
        case .text(let str): return str
        case .parts(let parts): return parts.compactMap(\.text).joined()
        }
    }
}

private struct ErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String?
    }
    let error: APIError?
}
