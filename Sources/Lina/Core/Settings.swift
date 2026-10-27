import Foundation
import Combine
import ServiceManagement

enum Provider: String, CaseIterable, Identifiable, Codable {
    case nebius, local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nebius: "Nebius Token Factory"
        case .local: "On this Mac"
        }
    }

    var subtitle: String {
        switch self {
        case .nebius: "NVIDIA Nemotron in the cloud. Fast, no setup."
        case .local: "Ollama or LM Studio. Nothing leaves your Mac."
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .nebius: "https://api.tokenfactory.nebius.com/v1"
        case .local: "http://localhost:11434/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .nebius: "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B"
        case .local: "llama3.2"
        }
    }
}

enum SuggestionLength: String, CaseIterable, Identifiable, Codable {
    case words, phrase, sentence
    var id: String { rawValue }
    var title: String {
        switch self {
        case .words: "A few words"
        case .phrase: "A phrase"
        case .sentence: "A sentence"
        }
    }
    var maxTokens: Int {
        switch self {
        case .words: 10
        case .phrase: 20
        case .sentence: 40
        }
    }
    var instruction: String {
        switch self {
        case .words: "2 to 5 words"
        case .phrase: "a short phrase of at most 12 words"
        case .sentence: "at most one sentence"
        }
    }
}

enum PaletteHotKey: String, CaseIterable, Identifiable, Codable {
    case optionSpace, controlSpace, commandShiftL
    var id: String { rawValue }
    var title: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlSpace: "⌃ Space"
        case .commandShiftL: "⇧⌘ L"
        }
    }
}

/// All user preferences, persisted to UserDefaults. The API key lives in the Keychain.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var hasOnboarded: Bool { didSet { d.set(hasOnboarded, forKey: "hasOnboarded") } }
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    @Published var provider: Provider { didSet { d.set(provider.rawValue, forKey: "provider") } }
    @Published var nebiusModel: String { didSet { d.set(nebiusModel, forKey: "nebiusModel") } }
    @Published var localBaseURL: String { didSet { d.set(localBaseURL, forKey: "localBaseURL") } }
    @Published var localModel: String { didSet { d.set(localModel, forKey: "localModel") } }
    @Published var debounceMs: Double { didSet { d.set(debounceMs, forKey: "debounceMs") } }
    @Published var length: SuggestionLength { didSet { d.set(length.rawValue, forKey: "length") } }
    @Published var voice: VoicePreset { didSet { d.set(voice.rawValue, forKey: "voice") } }
    @Published var aboutMe: String { didSet { d.set(aboutMe, forKey: "aboutMe") } }
    @Published var dailyGoal: Int { didSet { d.set(dailyGoal, forKey: "dailyGoal") } }
    @Published var hotKey: PaletteHotKey { didSet { d.set(hotKey.rawValue, forKey: "hotKey") } }
    @Published var disabledApps: Set<String> { didSet { d.set(Array(disabledApps), forKey: "disabledApps") } }
    @Published var apiKey: String { didSet { Keychain.set(apiKey, for: "nebius-api-key") } }

    private init() {
        d.register(defaults: [
            "enabled": true,
            "debounceMs": 550.0,
            "dailyGoal": 500,
            "provider": Provider.nebius.rawValue,
            "length": SuggestionLength.phrase.rawValue,
            "voice": VoicePreset.journal.rawValue,
            "hotKey": PaletteHotKey.optionSpace.rawValue,
        ])
        hasOnboarded = d.bool(forKey: "hasOnboarded")
        enabled = d.bool(forKey: "enabled")
        provider = Provider(rawValue: d.string(forKey: "provider") ?? "") ?? .nebius
        nebiusModel = d.string(forKey: "nebiusModel") ?? Provider.nebius.defaultModel
        localBaseURL = d.string(forKey: "localBaseURL") ?? Provider.local.defaultBaseURL
        localModel = d.string(forKey: "localModel") ?? Provider.local.defaultModel
        debounceMs = d.double(forKey: "debounceMs")
        length = SuggestionLength(rawValue: d.string(forKey: "length") ?? "") ?? .phrase
        voice = VoicePreset(rawValue: d.string(forKey: "voice") ?? "") ?? .journal
        aboutMe = d.string(forKey: "aboutMe") ?? ""
        dailyGoal = d.integer(forKey: "dailyGoal")
        hotKey = PaletteHotKey(rawValue: d.string(forKey: "hotKey") ?? "") ?? .optionSpace
        disabledApps = Set(d.stringArray(forKey: "disabledApps") ?? [
            "com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess",
            "com.bitwarden.desktop", "com.apple.Terminal", "com.googlecode.iterm2",
        ])
        // Key from Keychain, falling back to the environment for development.
        let env = ProcessInfo.processInfo.environment
        apiKey = Keychain.get("nebius-api-key") ?? env["LINA_NEBIUS_API_KEY"] ?? env["NEBIUS_API_KEY"] ?? ""
    }

    /// The connection the LLM client should use right now.
    var endpoint: LLMEndpoint {
        switch provider {
        case .nebius:
            LLMEndpoint(baseURL: Provider.nebius.defaultBaseURL, apiKey: apiKey, model: nebiusModel)
        case .local:
            LLMEndpoint(baseURL: localBaseURL, apiKey: "local", model: localModel)
        }
    }

    var isModelConfigured: Bool {
        provider == .local || !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Lina: launch-at-login change failed: \(error)")
            }
        }
    }
}
