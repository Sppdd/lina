import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: LinaEngine

    var body: some View {
        TabView {
            AccountSettings().tabItem { Label("Account", systemImage: "person.crop.circle") }
            GeneralSettings(engine: engine).tabItem { Label("General", systemImage: "gearshape") }
            ModelSettings().tabItem { Label("Models", systemImage: "cpu") }
            SearchSettings().tabItem { Label("Search", systemImage: "globe") }
            MemorySettings().tabItem { Label("Memory", systemImage: "brain") }
            VoiceSettings().tabItem { Label("Voice", systemImage: "text.quote") }
            AppsSettings().tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock") }
        }
        .frame(width: 580)
        .tint(Theme.ink)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @ObservedObject var engine: LinaEngine
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Lina is on", isOn: $settings.enabled)
                Toggle("Check each sentence I finish", isOn: $settings.checkSentences)
                LabeledContent("Show fixes after I stop typing for") {
                    HStack {
                        Slider(value: $settings.checkDelay, in: 0.3...5, step: 0.1)
                            .frame(width: 170)
                        Text(String(format: "%.1f s", settings.checkDelay))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!settings.checkSentences)
                Toggle("Ask me a question when I pause", isOn: $settings.askOnPause)
                LabeledContent("After I stop typing for") {
                    HStack {
                        Slider(value: $settings.askPause, in: 3...30, step: 1)
                            .frame(width: 170)
                        Text("\(Int(settings.askPause)) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!settings.askOnPause)
                Toggle("Hold ⌃⌥ to say a command", isOn: $settings.talkEnabled)
                Toggle("Show tips under my text while I learn", isOn: $settings.showTips)
                Button("Show tips again") { engine.tips.reset() }
            } header: {
                Text("Lina")
            } footer: {
                Text("Lina reads only when you type /lina, hold ⌃⌥ and talk, or stop typing after a sentence (and, if you turn it on, after a longer pause). A /lina command stays in your text, tinted and underlined, and Return runs it. Fixes appear right above your mistakes; nothing goes into your text until you press ⌘1, ⌘2… or ⌘A for all of them.")
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                Picker("Start a /lina command", selection: $settings.hotKey) {
                    ForEach(LinaHotKey.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.hotKey) { _, k in HotKeyCenter.shared.register(k) }
                LabeledContent("Run a /lina command") { KeyCap("↩", size: 12) }
                LabeledContent("Take one fix or option") { HStack(spacing: 4) { KeyCap("⌘1", size: 12); KeyCap("⌘2", size: 12); KeyCap("⌘3", size: 12) } }
                LabeledContent("Take every fix") { KeyCap("⌘A", size: 12) }
                LabeledContent("Dismiss a card") { KeyCap("esc", size: 12) }
                LabeledContent("Remember the highlighted text") { KeyCap(HotKeyCenter.memoryTitle, size: 12) }
                LabeledContent("Say a command") { Text("Hold ⌃⌥").foregroundStyle(.secondary) }
                LabeledContent("Undo a choice") { KeyCap("⌘Z", size: 12) }
            }

            Section {
                Toggle("Send problem reports to the Lina team", isOn: $settings.shareReports)
                Toggle("Open Lina at login", isOn: Binding(
                    get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                LabeledContent("Accessibility") {
                    if engine.isTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(Mood.happy.hair)
                    } else {
                        Button("Grant Access…") { AX.grantAccess() }
                    }
                }
            } footer: {
                if !engine.isTrusted {
                    Text("Already switched on in System Settings? Click Grant Access: Lina clears the old entry left by an earlier build, so you can switch it on once more.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 500)
    }
}

// MARK: Models

struct ModelSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var account = Account.shared
    @State private var models: [ModelItem] = []
    @State private var testState: TestState = .idle
    @State private var keyDraft = ""

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(Provider.allCases) { p in Text(p.title).tag(p) }
                }
                .pickerStyle(.radioGroup)
                Text(settings.provider.subtitle).font(.callout).foregroundStyle(.secondary)
            }

            if settings.provider == .nebius && settings.isSignedIn {
                Section {
                    modelPicker("Commands", kind: .text, selection: $settings.commandModel)
                    modelPicker("Sentence checks", kind: .text, selection: $settings.checkModel)
                } header: {
                    Text("Nebius Token Factory, through your Lina account")
                } footer: {
                    Text("You're signed in, so no API key is needed. Lina's server only runs the models it allows.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if settings.provider == .nebius {
                Section {
                    SecureField("API key", text: $keyDraft, prompt: Text("Paste your Nebius API key"))
                        .onSubmit(saveKey)
                        .onChange(of: keyDraft) { _, _ in if testState != .testing { testState = .idle } }
                    modelPicker("Commands", kind: .text, selection: $settings.commandModel)
                    modelPicker("Sentence checks", kind: .text, selection: $settings.checkModel)
                } header: {
                    Text("Nebius Token Factory")
                } footer: {
                    HStack {
                        Link("Get an API key →", destination: URL(string: "https://tokenfactory.nebius.com/")!)
                        Spacer()
                        Text("Nemotron 3 Super answers commands; Nemotron 3 Nano checks sentences fast.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            } else {
                Section {
                    TextField("Server", text: $settings.localBaseURL)
                    modelPicker("Model", kind: .text, selection: $settings.localModel)
                } header: {
                    Text("Local server (OpenAI-compatible)")
                } footer: {
                    Text("Works with Ollama (`ollama serve`), LM Studio, or llama.cpp's server. Web search still uses Gemini when you add a key; pictures need Token Factory.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Models on this Mac") { LocalModelsList() }
            }

            Section {
                modelPicker("Pictures", kind: .image, selection: $settings.imageModel)
            } header: {
                Text("Images")
            } footer: {
                Text("Used by /lina image. FLUX models on Token Factory; needs your Lina account or a Nebius key.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    case let .ok(ms): Label("Connected · \(ms) ms", systemImage: "checkmark.circle.fill").foregroundStyle(Mood.happy.hair)
                    case let .failed(m): Label(m, systemImage: "xmark.octagon.fill").foregroundStyle(Mood.worried.hair).lineLimit(2)
                    }
                }
            } footer: {
                Text("Tip: type /lina model in any app to switch models without opening Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 500)
        .onAppear { keyDraft = settings.apiKey }
        .onDisappear(perform: saveKey)
    }

    @ViewBuilder
    private func modelPicker(_ title: String, kind: ModelItem.Kind, selection: Binding<String>) -> some View {
        let options = models.filter { $0.kind == kind }.map(\.id)
        HStack {
            if options.isEmpty {
                TextField(title, text: selection)
            } else {
                Picker(title, selection: selection) {
                    if !options.contains(selection.wrappedValue) { Text(selection.wrappedValue).tag(selection.wrappedValue) }
                    ForEach(options, id: \.self) { Text($0).tag($0) }
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
        let endpoint = settings.provider == .local ? settings.commandEndpoint : settings.nebiusEndpoint
        do { models = ModelCatalog.items(try await LLMClient(endpoint: endpoint).listModels()) }
        catch { testState = .failed(error.localizedDescription) }
    }

    private func test() {
        saveKey()
        testState = .testing
        let client = LLMClient(endpoint: settings.checkEndpoint)
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

// MARK: Search

private struct SearchSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var account = Account.shared
    @State private var keyDraft = ""
    @State private var testState: TestState = .idle

    var body: some View {
        Form {
            if settings.isSignedIn {
                Section {
                    Text("You're signed in: searches go through Lina's server, which picks the Gemini model and counts them toward today's limit.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Your Lina account")
                }
            }
            Section {
                SecureField("Gemini API key", text: $keyDraft, prompt: Text("Paste your Gemini API key"))
                    .onSubmit(saveKey)
                    .disabled(settings.isSignedIn)
                TextField("Model", text: $settings.geminiModel)
                    .disabled(settings.isSignedIn)
                HStack {
                    Button(action: test) {
                        if testState == .testing { ProgressView().controlSize(.small) } else { Text("Test Search") }
                    }
                    .disabled(testState == .testing)
                    Spacer()
                    switch testState {
                    case .idle: EmptyView()
                    case .testing: Text("Searching…").foregroundStyle(.secondary)
                    case let .ok(ms): Label("Search works · \(ms) ms", systemImage: "checkmark.circle.fill").foregroundStyle(Mood.happy.hair)
                    case let .failed(m): Label(m, systemImage: "xmark.octagon.fill").foregroundStyle(Mood.worried.hair).lineLimit(2)
                    }
                }
            } header: {
                Text(settings.isSignedIn ? "Developer key (not used while signed in)" : "Google Search via Gemini")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Anything after /lina that isn't a command is a question. Lina searches Google through Gemini's grounding, then words the answer to fit your sentence, with Google's search suggestions under it. You can also put GEMINI_API_KEY in the .env file next to Lina.")
                    Link("Get a Gemini API key →", destination: URL(string: "https://aistudio.google.com/apikey")!)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Look things up on Wikipedia", isOn: $settings.webLookup)
                    .disabled(settings.hasSearch)
            } header: {
                Text("Without Gemini")
            } footer: {
                Text(settings.hasSearch
                     ? "Gemini answers your searches, so Wikipedia isn't used."
                     : "Lina sends only your question to Wikipedia, in its language, and answers from those pages with a link. Off, the model answers from memory.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 500)
        .onAppear { keyDraft = settings.geminiKey }
        .onDisappear(perform: saveKey)
    }

    private func saveKey() {
        let k = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if k != settings.geminiKey { settings.geminiKey = k }
    }

    private func test() {
        saveKey()
        testState = .testing
        let gemini = settings.gemini
        Task {
            let start = Date()
            do {
                _ = try await gemini.ask(system: "Answer in a few words.", prompt: "Who won the most recent FIFA World Cup?")
                testState = .ok(Int(Date().timeIntervalSince(start) * 1000))
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
                Text("Highlight text anywhere and press \(HotKeyCenter.memoryTitle), or type “/lina remember …” and press return. Lina keeps these on this Mac and uses them whenever she answers you.")
                    .foregroundStyle(.secondary)
            }
            GatheredSection()
        }
        .formStyle(.grouped)
        .frame(height: 500)
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
            Text("Then type “/lina gathered” where you write. Screenshots are read on this Mac. Lina keeps the last \(Clippings.limit) items in memory only and forgets them when it quits. It skips passwords and apps you turn off.")
                .foregroundStyle(.secondary)
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
                Text("Lina's questions and rewrites follow the kind of writing you do.").foregroundStyle(.secondary)
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
        .frame(height: 500)
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
                Text("Lina works in these apps")
            } footer: {
                Text("Shows the apps that are open now. Lina never reads password fields or anything typed while secure input is on. Password managers and terminals are off by default.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 500)
    }
}

// MARK: Privacy

private struct PrivacySettings: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var account = Account.shared
    @ObservedObject var history = History.shared
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("What Lina reads") {
                PrivacyRow(symbol: "text.cursor", title: "Only when you ask",
                           detail: "When you type /lina or stop typing after a sentence, Lina reads the field you're in. Nothing is read while you're typing.")
                PrivacyRow(symbol: "lock.shield", title: "Never secure fields",
                           detail: "Password fields, secure input, and apps you turn off are ignored completely.")
            }
            Section("What gets sent, and where") {
                PrivacyRow(symbol: "checkmark.seal", title: "Sentence checks",
                           detail: "The sentence you finished and up to 600 characters before it, to \(settings.provider == .local ? "your local server at \(settings.localBaseURL)" : settings.isSignedIn ? "Lina's server, which passes it to Nebius Token Factory and keeps only a count" : "Nebius Token Factory").")
                PrivacyRow(symbol: "text.bubble", title: "/lina, fix, rewrite and edit",
                           detail: "The paragraph the command works on (for /lina, up to 4,000 characters before it), to the same place.")
                PrivacyRow(symbol: "globe", title: "Questions",
                           detail: settings.hasSearch
                               ? "Your question and the words around it (about 700 characters) go to Google Gemini, which searches the web. Google keeps search prompts for about 30 days."
                               : "Your question and the words around it go to your model. Add a Gemini key to search the web.")
                PrivacyRow(symbol: "photo", title: "Pictures",
                           detail: "Only the description you typed, to Nebius Token Factory.")
            }
            Section {
                PrivacyRow(symbol: "tray.full", title: "Saved stays here",
                           detail: "Searches, questions, rewrites and pictures are saved in a file on this Mac, never on Lina's server. No analytics.")
                Button("Show Saved Files in Finder") { NSWorkspace.shared.open(history.folder) }
                Button("Delete Everything Saved…", role: .destructive) { confirmClear = true }
                    .disabled(history.items.isEmpty)
                    .confirmationDialog("Delete everything Lina has saved?", isPresented: $confirmClear) {
                        Button("Delete All", role: .destructive) { history.clear() }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(height: 500)
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
