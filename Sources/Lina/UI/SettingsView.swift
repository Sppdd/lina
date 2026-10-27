import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: GhostEngine

    var body: some View {
        TabView {
            GeneralSettings(engine: engine).tabItem { Label("General", systemImage: "gearshape") }
            ModelSettings().tabItem { Label("Model", systemImage: "cpu") }
            VoiceSettings().tabItem { Label("Voice", systemImage: "text.quote") }
            AppsSettings().tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock") }
        }
        .frame(width: 560)
        .tint(Theme.ink)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @ObservedObject var engine: GhostEngine
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Suggest as I write", isOn: $settings.enabled)
                Picker("Suggestion length", selection: $settings.length) {
                    ForEach(SuggestionLength.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Wait before suggesting") {
                    HStack {
                        Slider(value: $settings.debounceMs, in: 250...1500, step: 50)
                            .frame(width: 180)
                        Text("\(Int(settings.debounceMs)) ms")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            } footer: {
                Text("Lina only speaks up when you pause after a word or a comma — never mid-word.")
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                Picker("Ask Lina", selection: $settings.hotKey) {
                    ForEach(PaletteHotKey.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.hotKey) { _, k in HotKeyCenter.shared.register(k) }
                LabeledContent("Keep suggestion") { KeyCap("tab", size: 12) }
                LabeledContent("Keep one word") { HStack(spacing: 4) { KeyCap("⌥", size: 12); KeyCap("tab", size: 12) } }
                LabeledContent("Dismiss") { KeyCap("esc", size: 12) }
            }

            Section("Daily goal") {
                Stepper(value: $settings.dailyGoal, in: 100...5000, step: 50) {
                    Text("\(settings.dailyGoal) words a day")
                }
                Toggle("Open Lina at login", isOn: Binding(
                    get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            }

            Section("Accessibility") {
                LabeledContent("Status") {
                    if AX.isTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { AX.requestTrust(); AX.openAccessibilitySettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}

// MARK: Model

struct ModelSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var models: [String] = []
    @State private var testState: TestState = .idle
    @State private var keyDraft = ""

    enum TestState: Equatable { case idle, testing, ok(Int), failed(String) }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(Provider.allCases) { p in
                        VStack(alignment: .leading) { Text(p.title) }.tag(p)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(settings.provider.subtitle).font(.callout).foregroundStyle(.secondary)
            }

            if settings.provider == .nebius {
                Section {
                    SecureField("API key", text: $keyDraft, prompt: Text("Paste your Nebius API key"))
                        .onSubmit(saveKey)
                        .onChange(of: keyDraft) { _, _ in if testState != .testing { testState = .idle } }
                    modelPicker(selection: $settings.nebiusModel)
                } header: {
                    Text("Nebius Token Factory")
                } footer: {
                    HStack {
                        Link("Get an API key →", destination: URL(string: "https://tokenfactory.nebius.com/")!)
                        Spacer()
                        Text("Default: NVIDIA Nemotron 3 Nano — fast enough to keep up with your typing.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            } else {
                Section {
                    TextField("Server", text: $settings.localBaseURL)
                    modelPicker(selection: $settings.localModel)
                } header: {
                    Text("Local server (OpenAI-compatible)")
                } footer: {
                    Text("Works with Ollama (`ollama serve`), LM Studio, or llama.cpp's server. Try `ollama pull llama3.2`.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Button(action: test) {
                        if testState == .testing { ProgressView().controlSize(.small) } else { Text("Test Connection") }
                    }
                    .disabled(testState == .testing)
                    Spacer()
                    switch testState {
                    case .idle: EmptyView()
                    case .testing: Text("Asking the model…").foregroundStyle(.secondary)
                    case let .ok(ms): Label("Connected · \(ms) ms", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case let .failed(m): Label(m, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
        .onAppear { keyDraft = settings.apiKey }
        .onDisappear(perform: saveKey)
    }

    @ViewBuilder
    private func modelPicker(selection: Binding<String>) -> some View {
        HStack {
            if models.isEmpty {
                TextField("Model", text: selection)
            } else {
                Picker("Model", selection: selection) {
                    if !models.contains(selection.wrappedValue) { Text(selection.wrappedValue).tag(selection.wrappedValue) }
                    let nvidia = models.filter { $0.lowercased().contains("nvidia") || $0.lowercased().contains("nemotron") }
                    if !nvidia.isEmpty {
                        Section("NVIDIA") { ForEach(nvidia, id: \.self) { Text($0).tag($0) } }
                    }
                    Section("Other") {
                        ForEach(models.filter { !nvidia.contains($0) }, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            Button { Task { await loadModels() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Load available models")
        }
    }

    private func saveKey() {
        let k = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if k != settings.apiKey { settings.apiKey = k }
    }

    private func loadModels() async {
        saveKey()
        do { models = try await LLMClient(endpoint: settings.endpoint).listModels() }
        catch { testState = .failed(error.localizedDescription) }
    }

    private func test() {
        saveKey()
        testState = .testing
        let client = LLMClient(endpoint: settings.endpoint)
        Task {
            let start = Date()
            do {
                let out = try await client.complete(
                    [.system("Reply with exactly one word."), .user("Say: ready")], maxTokens: 8, temperature: 0)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                testState = out.isEmpty ? .failed("Empty reply") : .ok(ms)
                if models.isEmpty { await loadModels() }
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: Voice

struct VoiceSettings: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                VoicePicker(selection: $settings.voice)
                    .padding(.vertical, 4)
            } header: {
                Text("What do you write most?")
            } footer: {
                Text("Lina adapts its suggestions to the kind of writing you do.").foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: $settings.aboutMe)
                    .font(Theme.serif(14))
                    .frame(height: 110)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("About you and how you write")
            } footer: {
                Text("Optional. e.g. “I'm a nurse writing a memoir. I like short sentences and plain words. British spelling.”")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}

struct VoicePicker: View {
    @Binding var selection: VoicePreset
    var columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(VoicePreset.allCases) { v in
                let on = v == selection
                Button { withAnimation(Theme.spring) { selection = v } } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: v.symbol)
                            .font(.system(size: 18))
                            .foregroundStyle(on ? .white : Theme.ink)
                        Text(v.title).font(Theme.serif(15, weight: .semibold))
                        Text(v.blurb).font(.system(size: 11)).foregroundStyle(on ? .white.opacity(0.8) : .secondary)
                            .lineLimit(2, reservesSpace: true)
                    }
                    .foregroundStyle(on ? .white : .primary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(on ? Theme.ink : Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(on ? .clear : Color.primary.opacity(0.08), lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: Apps

private struct AppsSettings: View {
    @ObservedObject var settings = AppSettings.shared

    private var apps: [(name: String, id: String, icon: NSImage?)] {
        var seen = Set<String>()
        var out: [(String, String, NSImage?)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { continue }
            out.append((app.localizedName ?? id, id, app.icon))
        }
        for id in settings.disabledApps where !seen.contains(id) {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? id
            out.append((name.replacingOccurrences(of: ".app", with: ""), id, url.map { NSWorkspace.shared.icon(forFile: $0.path) }))
        }
        return out.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                ForEach(apps, id: \.id) { app in
                    Toggle(isOn: Binding(
                        get: { !settings.disabledApps.contains(app.id) },
                        set: { on in if on { settings.disabledApps.remove(app.id) } else { settings.disabledApps.insert(app.id) } }
                    )) {
                        HStack(spacing: 8) {
                            if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
                            Text(app.name)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            } header: {
                Text("Suggest in these apps")
            } footer: {
                Text("Lina never reads password fields or anything typed while secure input is on. Password managers and terminals are off by default.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}

// MARK: Privacy

private struct PrivacySettings: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var stats = WritingStats.shared

    var body: some View {
        Form {
            Section("What Lina reads") {
                PrivacyRow(symbol: "text.cursor", title: "Only the field you're typing in",
                           detail: "Up to ~3,000 characters before your cursor and a little after, plus the app's name.")
                PrivacyRow(symbol: "lock.shield", title: "Never secure fields",
                           detail: "Password fields, secure input, and apps you turn off are ignored completely.")
            }
            Section("Where it goes") {
                if settings.provider == .nebius {
                    PrivacyRow(symbol: "cloud", title: "Nebius Token Factory",
                               detail: "That context is sent over HTTPS to generate a suggestion. Switch to “On this Mac” in Model to keep everything local.")
                } else {
                    PrivacyRow(symbol: "desktopcomputer", title: "Stays on this Mac",
                               detail: "Suggestions come from your local model server at \(settings.localBaseURL).")
                }
                PrivacyRow(symbol: "chart.bar", title: "Stats are local",
                           detail: "Word counts and streaks are stored only on this Mac. No analytics, no account.")
            }
            Section {
                Button("Reset Writing Stats", role: .destructive) { stats.reset() }
                Button("Show Desk Pages in Finder") { NSWorkspace.shared.open(DeskStore.shared.folder) }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}

private struct PrivacyRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Theme.ink).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
