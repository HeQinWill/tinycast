import Foundation

// URLProtocol mock for online dictation service testing
final class MockDictationURLProtocol: URLProtocol {
    nonisolated(unsafe) static var mockHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.mockHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@main
@MainActor
struct DictationOnlineTest {
    static func main() async throws {
        testProfileEndpointNormalization()
        testAudioEncoderWAV()
        try testAudioEncoderM4A()
        testStripThinkTags()
        testProfileStore()
        try await testOnlineServiceWithMock()
        print("ALL DICTATION ONLINE TESTS PASSED")
    }

    private static func check(_ condition: Bool, _ message: String) {
        guard condition else {
            print("FAILED: \(message)")
            exit(1)
        }
    }

    private static func testProfileEndpointNormalization() {
        // Standard full URL
        let p1 = DictationProfile(
            name: "P1",
            baseURL: "https://note3-prev-api.askdiandian.com/v1/chat/completions",
            model: "dots3-note-prev"
        )
        check(
            p1.endpointURL?.absoluteString
                == "https://note3-prev-api.askdiandian.com/v1/chat/completions",
            "URL ending with /chat/completions remains intact"
        )

        // Trailing slash after /chat/completions
        let p1Slash = DictationProfile(
            name: "P1Slash",
            baseURL: "https://note3-prev-api.askdiandian.com/v1/chat/completions/",
            model: "dots3-note-prev"
        )
        check(
            p1Slash.endpointURL?.absoluteString
                == "https://note3-prev-api.askdiandian.com/v1/chat/completions",
            "URL ending with /chat/completions/ does not duplicate /chat/completions"
        )

        // Multiple trailing slashes
        let p1MultiSlash = DictationProfile(
            name: "P1MultiSlash",
            baseURL: "https://note3-prev-api.askdiandian.com/v1/chat/completions///",
            model: "dots3-note-prev"
        )
        check(
            p1MultiSlash.endpointURL?.absoluteString
                == "https://note3-prev-api.askdiandian.com/v1/chat/completions",
            "Multiple trailing slashes trimmed"
        )

        // URL ending with /v1
        let p2 = DictationProfile(
            name: "P2",
            baseURL: "https://note3-prev-api.askdiandian.com/v1",
            model: "dots3-note-prev"
        )
        check(
            p2.endpointURL?.absoluteString
                == "https://note3-prev-api.askdiandian.com/v1/chat/completions",
            "URL ending with /v1 appends /chat/completions"
        )

        // URL ending with /v1/
        let p3 = DictationProfile(
            name: "P3",
            baseURL: "https://note3-prev-api.askdiandian.com/v1/",
            model: "dots3-note-prev"
        )
        check(
            p3.endpointURL?.absoluteString
                == "https://note3-prev-api.askdiandian.com/v1/chat/completions",
            "Trailing slashes trimmed before appending /chat/completions"
        )

        // URL with query parameter (e.g. Azure OpenAI)
        let pAzure = DictationProfile(
            name: "Azure",
            baseURL:
                "https://my-res.openai.azure.com/openai/deployments/m/chat/completions?api-version=2024-02",
            model: "dots3"
        )
        check(
            pAzure.endpointURL?.absoluteString
                == "https://my-res.openai.azure.com/openai/deployments/m/chat/completions?api-version=2024-02",
            "URL with query params preserves /chat/completions and query string"
        )

        // URL with query parameter needing /chat/completions
        let pAzureBare = DictationProfile(
            name: "AzureBare",
            baseURL: "https://my-res.openai.azure.com/openai/deployments/m/?api-version=2024-02",
            model: "dots3"
        )
        check(
            pAzureBare.endpointURL?.absoluteString
                == "https://my-res.openai.azure.com/openai/deployments/m/chat/completions?api-version=2024-02",
            "URL with query params correctly inserts /chat/completions"
        )

        // Missing scheme defaults to https://
        let p4 = DictationProfile(
            name: "P4",
            baseURL: "api.example.com/v1",
            model: "test"
        )
        check(
            p4.endpointURL?.absoluteString == "https://api.example.com/v1/chat/completions",
            "Missing scheme defaults to https://"
        )

        // Empty URL
        let pEmpty = DictationProfile(name: "Empty", baseURL: "   ", model: "test")
        check(pEmpty.endpointURL == nil, "Empty base URL returns nil")

        print("Endpoint normalization passed")
    }

    private static func testAudioEncoderWAV() {
        let samples: [Float] = (0..<16_000).map { sin(Float($0) * 0.1) }
        let wavData = DictationAudioEncoder.encodeWAV(samples: samples, sampleRate: 16_000)
        check(wavData.count == 44 + 32_000, "WAV header is 44 bytes, 1s of 16kHz 16-bit mono is 32000 bytes")

        let headerStr = String(decoding: wavData.prefix(4), as: UTF8.self)
        check(headerStr == "RIFF", "WAV starts with RIFF")

        let waveStr = String(decoding: wavData[8..<12], as: UTF8.self)
        check(waveStr == "WAVE", "WAV contains WAVE marker")

        let fmtStr = String(decoding: wavData[12..<16], as: UTF8.self)
        check(fmtStr == "fmt ", "WAV contains fmt chunk marker")

        let dataStr = String(decoding: wavData[36..<40], as: UTF8.self)
        check(dataStr == "data", "WAV contains data chunk marker")

        // Test sample clamping: values > 1.0 or < -1.0 must not overflow Int16
        let extremeSamples: [Float] = [2.5, -3.0, 0.0]
        let extremeWav = DictationAudioEncoder.encodeWAV(samples: extremeSamples, sampleRate: 16_000)
        check(extremeWav.count == 44 + 6, "Extreme WAV data count matches")

        let sample1 = extremeWav.subdata(in: 44..<46).withUnsafeBytes { $0.load(as: Int16.self) }
        let sample2 = extremeWav.subdata(in: 46..<48).withUnsafeBytes { $0.load(as: Int16.self) }
        check(sample1 == 32767, "Positive overflow clamped to 32767")
        check(sample2 == -32767, "Negative overflow clamped to -32767")

        do {
            let dataURI = try DictationAudioEncoder.encodeDataURI(samples: samples, format: .wav)
            check(dataURI.hasPrefix("data:audio/wav;base64,"), "WAV dataURI prefix correct")
        } catch {
            check(false, "WAV dataURI encoding threw: \(error)")
        }

        do {
            _ = try DictationAudioEncoder.encode(samples: [], format: .wav)
            check(false, "Empty audio should throw")
        } catch is DictationAudioEncoder.Failure {
            // expected
        } catch {
            check(false, "Unexpected error: \(error)")
        }

        print("WAV encoder passed")
    }

    private static func testAudioEncoderM4A() throws {
        // Short audio
        let shortSamples: [Float] = (0..<500).map { sin(Float($0) * 0.1) }
        let shortM4a = try DictationAudioEncoder.encode(samples: shortSamples, format: .m4a)
        check(!shortM4a.isEmpty, "Short M4A data is not empty")

        // 1-second audio
        let samples: [Float] = (0..<16_000).map { sin(Float($0) * 0.1) }
        let m4aData = try DictationAudioEncoder.encode(samples: samples, format: .m4a)
        check(!m4aData.isEmpty, "1s M4A data is not empty")

        let dataURI = try DictationAudioEncoder.encodeDataURI(samples: samples, format: .m4a)
        check(dataURI.hasPrefix("data:audio/m4a;base64,"), "M4A dataURI prefix correct")

        print("M4A encoder passed")
    }

    private static func testStripThinkTags() {
        let plain = "Hello world!"
        check(DictationOnlineService.stripThinkTags(plain) == "Hello world!", "Plain text untouched")

        let simple = "<think>Transcribing audio...</think>Hello world!"
        check(DictationOnlineService.stripThinkTags(simple) == "Hello world!", "Think tag stripped")

        let caseInsensitive = "<THINK>Thinking...</THINK>Hello world!"
        check(
            DictationOnlineService.stripThinkTags(caseInsensitive) == "Hello world!",
            "Uppercase think tag stripped")

        let multiline = """
            <think>
            The user said something in English.
            Let me write it down accurately.
            </think>
            Good morning everyone!
            """
        check(
            DictationOnlineService.stripThinkTags(multiline) == "Good morning everyone!",
            "Multiline think tag stripped")

        let unclosed = "<think>Still thinking about this speech..."
        check(DictationOnlineService.stripThinkTags(unclosed) == "", "Unclosed think tag stripped")

        let stray = "Result with stray </think> tag."
        check(
            DictationOnlineService.stripThinkTags(stray) == "Result with stray  tag.",
            "Stray closing tag removed")

        print("Strip think tags passed")
    }

    private static func testProfileStore() {
        let defaults = UserDefaults(suiteName: "test-dictation-\(UUID().uuidString)")!
        let store = DictationProfileStore(
            defaults: defaults,
            keychain: KeychainSecretStore(scope: "test-\(UUID().uuidString)")
        )

        check(!store.profiles.isEmpty, "Store initializes with default profile")
        check(store.activeProfile != nil, "Store has active profile")

        let newProfile = DictationProfile(
            name: "Custom Profile",
            baseURL: "https://custom.api.com/v1",
            model: "custom-model"
        )
        store.addProfile(newProfile, apiKey: "test-key-123")
        check(store.profiles.count == 2, "Profile added")
        check(store.apiKey(for: newProfile.id) == "test-key-123", "API key saved")
        check(store.hasApiKey(for: newProfile.id), "hasApiKey returns true")

        store.selectProfile(id: newProfile.id)
        check(store.activeProfileID == newProfile.id, "Active profile selected")
        check(store.activeProfile?.name == "Custom Profile", "Active profile matches")

        store.cycleProfile(forward: true)
        check(store.activeProfileID != newProfile.id, "Cycled forward")

        store.cycleProfile(forward: false)
        check(store.activeProfileID == newProfile.id, "Cycled backward")

        // Update profile with cleared API key
        store.updateProfile(newProfile, apiKey: "")
        check(!store.hasApiKey(for: newProfile.id), "API key removed when empty string passed")

        store.deleteProfile(id: newProfile.id)
        check(store.profiles.count == 1, "Profile deleted")
        check(store.apiKey(for: newProfile.id) == nil, "API key deleted on profile removal")

        print("Profile store passed")
    }

    private static func testOnlineServiceWithMock() async throws {
        let service = DictationOnlineService()

        // 1. Test transcribeHandler mock hook
        service.transcribeHandler = { samples, profile, apiKey in
            check(apiKey == "secret-key", "transcribeHandler receives apiKey")
            return "Mock transcription text"
        }

        let profile = DictationProfile.defaultProfile
        let result = try await service.transcribe(
            samples: [Float](repeating: 0.1, count: 16_000),
            profile: profile,
            apiKey: "secret-key"
        )
        check(result == "Mock transcription text", "transcribe returns result from transcribeHandler")
        service.transcribeHandler = nil

        // 2. Missing API key validation
        do {
            _ = try await service.transcribe(
                samples: [0.1, 0.2],
                profile: profile,
                apiKey: "   "
            )
            check(false, "Empty API key should throw missingAPIKey")
        } catch DictationOnlineService.Failure.missingAPIKey {
            // expected
        } catch {
            check(false, "Unexpected error: \(error)")
        }

        // 3. Invalid endpoint validation
        let badProfile = DictationProfile(name: "Bad", baseURL: "   ", model: "model")
        do {
            _ = try await service.transcribe(
                samples: [0.1, 0.2],
                profile: badProfile,
                apiKey: "key"
            )
            check(false, "Empty endpoint should throw invalidEndpoint")
        } catch DictationOnlineService.Failure.invalidEndpoint {
            // expected
        } catch {
            check(false, "Unexpected error: \(error)")
        }

        print("Online service mock passed")
    }
}
