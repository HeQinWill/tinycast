import Foundation
import Observation

@MainActor
@Observable
final class DictationProfileStore {
    private let defaults: UserDefaults
    private let keychain: KeychainSecretStore

    private(set) var profiles: [DictationProfile] {
        didSet { persistProfiles() }
    }

    private(set) var activeProfileID: UUID? {
        didSet {
            defaults.set(
                activeProfileID?.uuidString,
                forKey: AppSettingsKey.dictationActiveProfileID.rawValue)
        }
    }

    var activeProfile: DictationProfile? {
        if let id = activeProfileID, let profile = profiles.first(where: { $0.id == id }) {
            return profile
        }
        return profiles.first
    }

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainSecretStore = .dictationAPIKeys
    ) {
        self.defaults = defaults
        self.keychain = keychain

        let saved = Self.decodeProfiles(
            defaults.data(forKey: AppSettingsKey.dictationProfiles.rawValue))
        if saved.isEmpty {
            let initial = [DictationProfile.defaultProfile]
            self.profiles = initial
            self.activeProfileID = DictationProfile.defaultProfile.id
            if let encoded = try? JSONEncoder().encode(initial) {
                defaults.set(encoded, forKey: AppSettingsKey.dictationProfiles.rawValue)
            }
            defaults.set(
                DictationProfile.defaultProfile.id.uuidString,
                forKey: AppSettingsKey.dictationActiveProfileID.rawValue)
        } else {
            self.profiles = saved
            let savedActiveID = defaults.string(
                forKey: AppSettingsKey.dictationActiveProfileID.rawValue
            ).flatMap(UUID.init)
            if let savedActiveID, saved.contains(where: { $0.id == savedActiveID }) {
                self.activeProfileID = savedActiveID
            } else {
                self.activeProfileID = saved.first?.id
            }
        }
    }

    func apiKey(for id: UUID) -> String? {
        try? keychain.secret(for: id)
    }

    func setApiKey(_ key: String, for id: UUID) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? keychain.removeSecret(for: id)
        } else {
            try? keychain.setSecret(trimmed, for: id)
        }
    }

    func hasApiKey(for id: UUID) -> Bool {
        (try? keychain.hasSecret(for: id)) ?? false
    }

    func addProfile(_ profile: DictationProfile, apiKey: String? = nil) {
        profiles.append(profile)
        if let apiKey { setApiKey(apiKey, for: profile.id) }
        if activeProfileID == nil || profiles.count == 1 {
            activeProfileID = profile.id
        }
    }

    func updateProfile(_ profile: DictationProfile, apiKey: String? = nil) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        if let apiKey { setApiKey(apiKey, for: profile.id) }
    }

    func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        try? keychain.removeSecret(for: id)
        if activeProfileID == id {
            activeProfileID = profiles.first?.id
        }
        if profiles.isEmpty {
            let fallback = DictationProfile.defaultProfile
            profiles = [fallback]
            activeProfileID = fallback.id
        }
    }

    func selectProfile(id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
    }

    func cycleProfile(forward: Bool = true) {
        guard !profiles.isEmpty else { return }
        let currentIndex = profiles.firstIndex(where: { $0.id == activeProfileID }) ?? 0
        let nextIndex: Int
        if forward {
            nextIndex = (currentIndex + 1) % profiles.count
        } else {
            nextIndex = (currentIndex - 1 + profiles.count) % profiles.count
        }
        activeProfileID = profiles[nextIndex].id
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: AppSettingsKey.dictationProfiles.rawValue)
    }

    private static func decodeProfiles(_ data: Data?) -> [DictationProfile] {
        guard let data, let decoded = try? JSONDecoder().decode([DictationProfile].self, from: data)
        else { return [] }
        return decoded
    }
}
