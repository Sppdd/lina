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

    /// The companion thinks about the whole draft, so it gets the larger Nemotron on Nebius.
    static let defaultCompanionModel = "nvidia/nemotron-3-super-120b-a12b"
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

    /// The shortcut that cycles Understand → Edit → Auto: the same keys plus ⇧ (or ⌥ for ⇧⌘L).
    var modeTitle: String {
        switch self {
        case .optionSpace: "⇧⌥ Space"
        case .controlSpace: "⇧⌃ Space"
        case .commandShiftL: "⌥⇧⌘ L"
        }
    }
}

/// How much Lina does on its own, cycled with ⇧ + the companion shortcut (like Claude Code's modes).
enum CompanionMode: String, CaseIterable, Identifiable, Codable {
    /// Reads along and thinks with you. Never touches the draft.
    case understand
    /// When you finish a sentence, offers a rewrite of the whole sentence. ⇥ takes it.
    case edit
    /// Rewrites each sentence you finish in place. ⌘Z undoes it, like any edit.
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .understand: "Understand"
        case .edit: "Edit"
        case .auto: "Auto"
        }
    }

    var symbol: String {
        switch self {
        case .understand: "text.bubble"
        case .edit: "pencil.line"
        case .auto: "wand.and.stars"
        }
    }

    var blurb: String {
        switch self {
        case .understand: "Reads along and asks questions. Never edits."
        case .edit: "Offers a rewrite of each sentence you finish. ⇥ takes it."
        case .auto: "Rewrites each sentence you finish. ⌘Z undoes."
        }
    }

    var next: CompanionMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// All user preferences, persisted to UserDefaults. The API key lives in `Secrets`.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var hasOnboarded: Bool { didSet { d.set(hasOnboarded, forKey: "hasOnboarded") } }
    /// Inline ghost text at the caret. Off by default: the companion window is Lina's main way of helping.
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    /// The popup above the cursor that thinks with the writer about what they're writing and why.
    @Published var companionEnabled: Bool { didSet { d.set(companionEnabled, forKey: "companionEnabled") } }
    @Published var companionMode: CompanionMode { didSet { d.set(companionMode.rawValue, forKey: "companionMode") } }
    @Published var companionModel: String { didSet { d.set(companionModel, forKey: "companionModel") } }
    /// How long a pause before the companion reads the draft again.
    @Published var companionPauseMs: Double { didSet { d.set(companionPauseMs, forKey: "companionPauseMs") } }
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
    @Published var apiKey: String { didSet { Secrets.set(apiKey, for: "nebius-api-key") } }

    private init() {
        // Lina moved from autocomplete to a thinking companion: switch ghost text off once for existing installs.
        if !d.bool(forKey: "migratedToCompanion") {
            d.set(false, forKey: "enabled")
            d.set(true, forKey: "migratedToCompanion")
        }
        d.register(defaults: [
            "enabled": false,
            "companionEnabled": true,
            "companionPauseMs": 2500.0,
            "debounceMs": 550.0,
            "dailyGoal": 500,
            "provider": Provider.nebius.rawValue,
            "length": SuggestionLength.phrase.rawValue,
            "voice": VoicePreset.journal.rawValue,
            "hotKey": PaletteHotKey.optionSpace.rawValue,
        ])
        hasOnboarded = d.bool(forKey: "hasOnboarded")
        enabled = d.bool(forKey: "enabled")
        companionEnabled = d.bool(forKey: "companionEnabled")
        companionMode = CompanionMode(rawValue: d.string(forKey: "companionMode") ?? "") ?? .understand
        companionModel = d.string(forKey: "companionModel") ?? Provider.defaultCompanionModel
        companionPauseMs = d.double(forKey: "companionPauseMs")
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
        // Saved key first, falling back to the environment and then a project .env for development.
        let names = ["LINA_NEBIUS_API_KEY", "NEBIUS_API_KEY", "TOKEN-FACTOR-API"]
        let env = ProcessInfo.processInfo.environment
        apiKey = Secrets.get("nebius-api-key")
            ?? names.lazy.compactMap { env[$0] }.first { !$0.isEmpty }
            ?? DotEnv.first(of: names)
            ?? ""
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

    /// The connection the companion window uses: Nemotron Super on Nebius, or the same local model.
    var companionEndpoint: LLMEndpoint {
        switch provider {
        case .nebius:
            LLMEndpoint(baseURL: Provider.nebius.defaultBaseURL, apiKey: apiKey, model: companionModel)
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

/// Reads `KEY=value` lines from the nearest `.env`, looking in the working directory and then
/// up from the executable — so `.build/debug/Lina` and `build/Lina.app` both find the repo's file.
enum DotEnv {
    static func first(of names: [String]) -> String? {
        guard let values = load() else { return nil }
        return names.lazy.compactMap { values[$0] }.first { !$0.isEmpty }
    }

    private static func load() -> [String: String]? {
        let fm = FileManager.default
        var dirs = [URL(fileURLWithPath: fm.currentDirectoryPath)]
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            guard let d = dir else { break }
            dirs.append(d)
            dir = d.deletingLastPathComponent()
        }
        guard let file = dirs.lazy.map({ $0.appendingPathComponent(".env") }).first(where: { fm.fileExists(atPath: $0.path) }),
              let text = try? String(contentsOf: file, encoding: .utf8)
        else { return nil }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "export ", with: "")
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }
}
