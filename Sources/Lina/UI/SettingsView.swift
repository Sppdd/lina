import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: GhostEngine

    var body: some View {
        TabView {
            GeneralSettings(engine: engine).tabItem { Label("General", systemImage: "gearshape") }
            ModelSettings().tabItem { Label("Model", systemImage: "cpu") }
            VoiceSettings().tabItem { Label("Voice", systemImage: "text.quote") }
            MemorySettings().tabItem { Label("Memory", systemImage: "brain") }
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
                Toggle("Think with me above the cursor", isOn: $settings.companionEnabled)
                Picker("Mode", selection: $settings.companionMode) {
                    ForEach(CompanionMode.allCases) { mode in
                        Text("\(mode.title) — \(mode.blurb)").tag(mode)
                    }
                }
                LabeledContent("Read again after a pause of") {
                    HStack {
                        Slider(value: $settings.companionPauseMs, in: 1000...8000, step: 250)
                            .frame(width: 180)
                        Text(String(format: "%.1f s", settings.companionPauseMs / 1000))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            } header: {
                Text("Companion")
            } footer: {
                Text("Lina writes in ink just above your cursor. Understand: it tells you what it hears and a question to take it further, and never types into your document. Edit and Auto rewrite each sentence you finish: Edit asks first (⇥ takes it), Auto just does it (⌘Z undoes). \(settings.hotKey.modeTitle) cycles the modes.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Ghost text at the cursor", isOn: $settings.enabled)
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
                Text("Optional autocomplete: a short continuation when you pause after a word or comma. Tab keeps it.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show Lina's ink drop beside the cursor", isOn: $settings.inkEnabled)
                Toggle("Hold ⌃⌥ to talk to Lina", isOn: $settings.talkEnabled)
                    .disabled(!VoiceInput.isAvailable)
                Toggle("Read Lina's questions aloud", isOn: $settings.speakAloud)
            } header: {
                Text("Presence")
            } footer: {
                Text(VoiceInput.isAvailable
                     ? "The drop rides beside your cursor, writes what Lina thinks just above it, swirls while Lina works, and points at the words worth following. With it off, Lina uses a popup. Hold ⌃⌥ and speak to answer Lina, or in Edit and Auto, to say how to rewrite the sentence. Speech is recognized on this Mac when your language supports it."
                     : "The drop rides beside your cursor, writes what Lina thinks just above it, swirls while Lina works, and points at the words worth following. Talking needs the app bundle: build it with scripts/build-app.sh.")
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                Picker("Show or hide Lina", selection: $settings.hotKey) {
                    ForEach(PaletteHotKey.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.hotKey) { _, k in HotKeyCenter.shared.register(k) }
                LabeledContent("Switch mode") { KeyCap(settings.hotKey.modeTitle, size: 12) }
                LabeledContent("Talk to Lina (hold)") { KeyCap("⌃⌥", size: 12) }
                LabeledContent("Remember the highlighted text") { KeyCap(HotKeyCenter.memoryTitle, size: 12) }
                LabeledContent("Ask Lina right where you write") {
                    HStack(spacing: 4) {
                        Text("/lina edit this").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        KeyCap("return", size: 12)
                    }
                }
                LabeledContent("Use Lina's rewrite (Edit)") { KeyCap("tab", size: 12) }
                LabeledContent("Keep suggestion") { KeyCap("tab", size: 12) }
                LabeledContent("Keep one word") { HStack(spacing: 4) { KeyCap("⌥", size: 12); KeyCap("tab", size: 12) } }
                LabeledContent("Dismiss") { KeyCap("esc", size: 12) }
            }

            Section {
                Toggle("Send problem reports to the Lina team", isOn: $settings.shareReports)
            } header: {
                Text("Problem reports")
            } footer: {
                Text("When you create a report or type /lina bug, Lina saves it on this Mac and, with this on, sends a copy so the problem can be fixed. Reports have no document text in them: only app names, lengths, settings and Lina's decisions.")
                    .foregroundStyle(.secondary)
            }

            Section("Daily goal") {
                Stepper(value: $settings.dailyGoal, in: 100...5000, step: 50) {
                    Text("\(settings.dailyGoal) words a day")
                }
                Toggle("Open Lina at login", isOn: Binding(
                    get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            }

            Section {
                LabeledContent("Status") {
                    if engine.isTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { AX.grantAccess() }
                    }
                }
            } header: {
                Text("Accessibility")
            } footer: {
                if !engine.isTrusted {
                    Text("Already switched on in System Settings? Click Grant Access: Lina clears the old entry left by an earlier build, so you can switch it on once more.")
                        .foregroundStyle(.secondary)
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
                    modelPicker("Companion", selection: $settings.companionModel)
                    modelPicker("Ghost text", selection: $settings.nebiusModel)
                    TextField("Pictures", text: $settings.imageModel, prompt: Text(Provider.defaultImageModel))
                } header: {
                    Text("Nebius Token Factory")
                } footer: {
                    HStack {
                        Link("Get an API key →", destination: URL(string: "https://tokenfactory.nebius.com/")!)
                        Spacer()
                        Text("Defaults: Nemotron 3 Super thinks with you, Nemotron 3 Nano keeps up with ghost text, and FLUX schnell draws for /lina … photo.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            } else {
                Section {
                    TextField("Server", text: $settings.localBaseURL)
                    modelPicker("Model", selection: $settings.localModel)
                } header: {
                    Text("Local server (OpenAI-compatible)")
                } footer: {
                    Text("Works with Ollama (`ollama serve`), LM Studio, or llama.cpp's server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Models on this Mac") { LocalModelsList() }
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
    private func modelPicker(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            if models.isEmpty {
                TextField(title, text: selection)
            } else {
                Picker(title, selection: selection) {
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

/// Ollama's models on this Mac: download the recommended one with progress, switch, or delete.
struct LocalModelsList: View {
    @ObservedObject var models = LocalModels.shared
    @ObservedObject var settings = AppSettings.shared
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch models.status {
            case .unknown:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for Ollama…").foregroundStyle(.secondary) }
            case .offline:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ollama isn't running at \(settings.localBaseURL).").font(.callout)
                    HStack {
                        Link("Get Ollama →", destination: URL(string: "https://ollama.com/download")!)
                        Spacer()
                        Button("Check again") { Task { await models.refresh() } }
                    }
                    .font(.callout)
                }
            case .ready:
                if !compact {
                    ForEach(models.installed) { m in
                        HStack {
                            Image(systemName: isCurrent(m.name) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isCurrent(m.name) ? Theme.ink : .secondary)
                            Text(m.name)
                            Text(m.size).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if !isCurrent(m.name) { Button("Use") { settings.localModel = m.name }.buttonStyle(.borderless) }
                            Button { Task { await models.delete(m.name) } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Delete \(m.name) from this Mac")
                        }
                    }
                }
                ForEach(LocalModels.suggestions.filter { !models.has($0.name) }) { s in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(s.name).font(.system(size: 13, weight: .medium))
                                if s.name == LocalModels.recommended.name {
                                    Text("Recommended for this Mac").font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Theme.ink.opacity(0.12)))
                                }
                            }
                            Text(s.blurb).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if models.pulling == s.name {
                            Button("Stop") { models.cancelPull() }.buttonStyle(.borderless)
                        } else {
                            Button("Download") { models.pull(s.name) }.disabled(models.pulling != nil)
                        }
                    }
                }
                if compact, let m = models.installed.first(where: { isCurrent($0.name) }) {
                    Label("Using \(m.name)", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ink).font(.callout)
                }
            }
            if let name = models.pulling {
                VStack(alignment: .leading, spacing: 4) {
                    if let p = models.progress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
                    Text("\(name): \(models.pullStatus)\(models.progress.map { " · \(Int($0 * 100))%" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let e = models.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
        }
        .task { await models.refresh() }
        .onChange(of: settings.localBaseURL) { _, _ in Task { await models.refresh() } }
    }

    private func isCurrent(_ name: String) -> Bool {
        name == settings.localModel || name == settings.localModel + ":latest"
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

// MARK: Memory

struct MemorySettings: View {
    @ObservedObject var memory = MemoryStore.shared

    var body: some View {
        Form {
            Section {
                if memory.items.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(memory.items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.text).font(Theme.serif(13)).lineLimit(4).textSelection(.enabled)
                            Text("\(item.source) · \(item.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { memory.remove(item.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Forget this")
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                HStack {
                    Text("What Lina remembers")
                    Spacer()
                    if !memory.items.isEmpty { Button("Forget all") { memory.removeAll() }.buttonStyle(.borderless) }
                }
            } footer: {
                Text("Highlight text anywhere and press \(HotKeyCenter.memoryTitle), or type “/lina remember …” and press return. Lina keeps these on this Mac and uses them whenever it writes or thinks with you.")
                    .foregroundStyle(.secondary)
            }
            GatheredSection()
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}

/// Clipboard and screenshot history for "Use what I gathered" in the palette.
private struct GatheredSection: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var clippings = Clippings.shared

    var body: some View {
        Section {
            Toggle("Keep what I copy and screenshot", isOn: $settings.gatherClippings)
            if settings.gatherClippings {
                if clippings.items.isEmpty {
                    Text("Nothing gathered yet. Copy a quote or take a screenshot.").foregroundStyle(.secondary)
                }
                ForEach(clippings.items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.kind == .screenshot ? "camera.viewfinder" : "doc.on.clipboard")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.text).font(Theme.serif(13)).lineLimit(3).textSelection(.enabled)
                            Text("\(item.source) · \(item.date.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { clippings.remove(item.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            HStack {
                Text("What you gathered")
                Spacer()
                if !clippings.items.isEmpty { Button("Clear") { clippings.removeAll() }.buttonStyle(.borderless) }
            }
        } footer: {
            Text("Then pick “Use what I gathered” in the palette. Screenshots are read on this Mac. Lina keeps the last \(Clippings.limit) items in memory only and forgets them when it quits. It skips passwords and apps you turn off.")
                .foregroundStyle(.secondary)
        }
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
                Toggle(isOn: $settings.webLookup) {
                    PrivacyRow(symbol: "globe", title: "Look it up on Wikipedia",
                               detail: "Off by default. When on, “Look it up” sends only your question to Wikipedia and answers with a source.")
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
