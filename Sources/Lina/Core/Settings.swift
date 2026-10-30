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
        case .nebius: "NVIDIA Nemotron and FLUX in the cloud. Fast, no setup."
        case .local: "Ollama or LM Studio. Your text stays on your Mac."
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .nebius: "https://api.tokenfactory.nebius.com/v1"
        case .local: "http://localhost:11434/v1"
        }
    }

    /// Answers /lina commands: the larger Nemotron.
    static let defaultCommandModel = "nvidia/nemotron-3-super-120b-a12b"
    /// Checks each finished sentence: the fast Nemotron.
    static let defaultCheckModel = "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B"
    static let defaultLocalModel = "llama3.2"
}

/// A system-wide shortcut that does what `/lina` does: one question about the paragraph you're in.
enum LinaHotKey: String, CaseIterable, Identifiable, Codable {
    case optionSpace, controlSpace, commandShiftL, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlSpace: "⌃ Space"
        case .commandShiftL: "⇧⌘ L"
        case .off: "Off"
        }
    }
}

/// All user preferences, persisted to UserDefaults. Development API keys live in `Secrets`.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var hasOnboarded: Bool { didSet { d.set(hasOnboarded, forKey: "hasOnboarded") } }
    /// Lina as a whole. Off means she ignores every command and sentence.
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "linaEnabled") } }
    /// Check each sentence for typos and grammar when it ends with . ? or !
    @Published var checkSentences: Bool { didSet { d.set(checkSentences, forKey: "checkSentences") } }
    /// Little ^ hints under your text while you learn the commands.
    @Published var showTips: Bool { didSet { d.set(showTips, forKey: "showTips") } }
    /// How long the writer has to stop typing after a sentence before Lina shows its fixes, in seconds.
    @Published var checkDelay: Double { didSet { d.set(checkDelay, forKey: "checkDelay") } }
    @Published var provider: Provider { didSet { d.set(provider.rawValue, forKey: "provider") } }
    @Published var commandModel: String { didSet { d.set(commandModel, forKey: "commandModel") } }
    @Published var checkModel: String { didSet { d.set(checkModel, forKey: "checkModel") } }
    @Published var imageModel: String { didSet { d.set(imageModel, forKey: "imageModel") } }
    @Published var localBaseURL: String { didSet { d.set(localBaseURL, forKey: "localBaseURL") } }
    @Published var localModel: String { didSet { d.set(localModel, forKey: "localModel") } }
    @Published var geminiModel: String { didSet { d.set(geminiModel, forKey: "geminiModel") } }
    @Published var voice: VoicePreset { didSet { d.set(voice.rawValue, forKey: "voice") } }
    @Published var aboutMe: String { didSet { d.set(aboutMe, forKey: "aboutMe") } }
    @Published var hotKey: LinaHotKey { didSet { d.set(hotKey.rawValue, forKey: "linaHotKey") } }
    @Published var disabledApps: Set<String> { didSet { d.set(Array(disabledApps), forKey: "disabledApps") } }
    @Published var apiKey: String { didSet { Secrets.set(apiKey, for: "nebius-api-key") } }
    @Published var geminiKey: String { didSet { Secrets.set(geminiKey, for: "gemini-api-key") } }

    private init() {
        d.register(defaults: [
            "linaEnabled": true,
            "checkSentences": true,
            "showTips": true,
            "checkDelay": 1.2,
            "provider": Provider.nebius.rawValue,
            "voice": VoicePreset.journal.rawValue,
            "linaHotKey": LinaHotKey.optionSpace.rawValue,
        ])
        hasOnboarded = d.bool(forKey: "hasOnboarded")
        enabled = d.bool(forKey: "linaEnabled")
        checkSentences = d.bool(forKey: "checkSentences")
        showTips = d.bool(forKey: "showTips")
        checkDelay = d.double(forKey: "checkDelay")
        provider = Provider(rawValue: d.string(forKey: "provider") ?? "") ?? .nebius
        // Earlier versions called these the companion and ghost-text models.
        commandModel = d.string(forKey: "commandModel") ?? d.string(forKey: "companionModel") ?? Provider.defaultCommandModel
        checkModel = d.string(forKey: "checkModel") ?? d.string(forKey: "nebiusModel") ?? Provider.defaultCheckModel
        imageModel = d.string(forKey: "imageModel") ?? ModelCatalog.defaultImageModel
        localBaseURL = d.string(forKey: "localBaseURL") ?? Provider.local.defaultBaseURL
        localModel = d.string(forKey: "localModel") ?? Provider.defaultLocalModel
        // Earlier versions defaulted to Gemini 2.5 Flash; move them to the current default.
        let savedGemini = d.string(forKey: "geminiModel") ?? ""
        geminiModel = savedGemini.isEmpty || savedGemini == "gemini-2.5-flash" ? GeminiClient.defaultModel : savedGemini
        voice = VoicePreset(rawValue: d.string(forKey: "voice") ?? "") ?? .journal
        aboutMe = d.string(forKey: "aboutMe") ?? ""
        hotKey = LinaHotKey(rawValue: d.string(forKey: "linaHotKey") ?? "") ?? .optionSpace
        disabledApps = Set(d.stringArray(forKey: "disabledApps") ?? [
            "com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess",
            "com.bitwarden.desktop", "com.apple.Terminal", "com.googlecode.iterm2",
        ])
        // Development keys: Lina's private secrets file, then the environment, then a project .env.
        // Release builds won't hold provider keys at all; see docs/PRODUCTION.md.
        let env = ProcessInfo.processInfo.environment
        let nebiusNames = ["LINA_NEBIUS_API_KEY", "NEBIUS_API_KEY", "TOKEN-FACTOR-API"]
        apiKey = Secrets.get("nebius-api-key")
            ?? nebiusNames.lazy.compactMap { env[$0] }.first { !$0.isEmpty }
            ?? DotEnv.first(of: nebiusNames)
            ?? ""
        let geminiNames = ["GEMINI_API_KEY", "GOOGLE_API_KEY", "LINA_GEMINI_API_KEY"]
        geminiKey = Secrets.get("gemini-api-key")
            ?? geminiNames.lazy.compactMap { env[$0] }.first { !$0.isEmpty }
            ?? DotEnv.first(of: geminiNames)
            ?? ""
    }

    /// Signed in, everything goes through Lina's server and no provider key is needed on this Mac.
    /// Signed out, developer keys (`.env` or Settings) are used directly.
    private var cloud: Account? { Account.shared.isSignedIn ? Account.shared : nil }
    var isSignedIn: Bool { cloud != nil }

    private func nebius(_ model: String, task: String) -> LLMEndpoint {
        cloud?.endpoint(model: model, task: task)
            ?? LLMEndpoint(baseURL: Provider.nebius.defaultBaseURL, apiKey: apiKey, model: model)
    }

    private var local: LLMEndpoint { LLMEndpoint(baseURL: localBaseURL, apiKey: "local", model: localModel) }

    /// The model that answers /lina commands.
    var commandEndpoint: LLMEndpoint {
        provider == .local ? local : nebius(commandModel, task: "command")
    }

    /// The fast model that checks finished sentences.
    var checkEndpoint: LLMEndpoint {
        provider == .local ? local : nebius(checkModel, task: "check")
    }

    /// Images and the model list always come from Token Factory.
    var nebiusEndpoint: LLMEndpoint { nebius(commandModel, task: "image") }

    var gemini: GeminiClient {
        if let cloud { return GeminiClient(apiKey: cloud.accessToken, model: geminiModel, gateway: cloud.gateway) }
        return GeminiClient(apiKey: geminiKey, model: geminiModel)
    }

    var isModelConfigured: Bool {
        provider == .local || hasNebiusKey || isSignedIn
    }

    var hasNebiusKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
    var hasGeminiKey: Bool { !geminiKey.trimmingCharacters(in: .whitespaces).isEmpty }
    var hasSearch: Bool { hasGeminiKey || isSignedIn }
    /// `/lina image` needs Token Factory, whichever provider writes.
    var canMakePictures: Bool { hasNebiusKey || isSignedIn }

    /// The model `/lina model` changes, for the current provider.
    var activeTextModel: String {
        get { provider == .local ? localModel : commandModel }
        set { if provider == .local { localModel = newValue } else { commandModel = newValue } }
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
