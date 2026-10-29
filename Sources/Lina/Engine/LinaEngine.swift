import AppKit
import Carbon.HIToolbox
import Combine

/// Lina's brain. She stays quiet until the writer asks:
/// - `/lina …` typed anywhere, finished with `.` `,` `?` `!` or Return, runs a command;
/// - a sentence finished with `.` `?` or `!` gets a quiet check for typos and grammar.
/// Results appear in a card under the line. Nothing goes into the text until the writer presses ⌘ + a number.
@MainActor
final class LinaEngine: ObservableObject {
    enum Status: Equatable {
        case needsPermission, needsModel, off, paused, ready, listening
        case working(String)
        /// A card is waiting for the writer to choose.
        case waiting
        case error(String)
    }

    @Published private(set) var status: Status = .ready
    @Published private(set) var mood: Mood = .idle
    @Published private(set) var currentApp: (name: String, bundleID: String) = ("", "")
    /// Whether macOS lets Lina read other apps. Re-checked on a timer.
    @Published private(set) var isTrusted = AX.isTrusted

    /// Opens Lina's window on Saved (`/lina saved`).
    var onOpenSaved: (() -> Void)?

    /// What the card at the cursor shows right now (read by the live test).
    var card: CardContent? { cards.model.content }

    let tips = TipCoach()
    private let settings = AppSettings.shared
    private let history = History.shared
    private let cards = CardPanel()
    private let marks = MarkPanel()
    private let monitor = KeyMonitor()

    private var bag = Set<AnyCancellable>()
    private var pendingCheck: DispatchWorkItem?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var handled: [String] = []
    private var handledSet = Set<String>()
    /// The last few characters the writer typed, to notice "/lina" while it's being typed.
    private var typed = ""
    private var action: CardAction = .none
    private var celebrating = false
    private var errorUntil = Date.distantPast
    private var noticeTimer: DispatchWorkItem?

    /// What ⌘1, ⌘2… do for the card on screen.
    private enum CardAction {
        case none
        case replace(Writer.Spot, options: [String], kind: HistoryItem.Kind, history: UUID?)
        case answer(Writer.Spot, fit: String, withSource: String?, history: UUID?)
        case models([ModelItem])
        case image(Writer.Spot, png: Data, history: UUID?)

        var count: Int {
            switch self {
            case .none: 0
            case let .replace(_, options, _, _): options.count
            case let .answer(_, _, withSource, _): withSource == nil ? 1 : 2
            case let .models(items): min(9, items.count)
            case .image: 2
            }
        }
    }

    private static let digits: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]

    init() {
        monitor.onKeyDown = { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? false }
        }
        monitor.onMouseDown = { [weak self] in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        cards.onChoose = { [weak self] n in self?.choose(n) }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        self.currentApp = (app.localizedName ?? "", app.bundleIdentifier ?? "")
                        self.typed = ""
                        self.dismiss()
                    }
                    self.refreshStatus()
                }
            }
            .store(in: &bag)
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshStatus() }
            .store(in: &bag)
        if let app = NSWorkspace.shared.frontmostApplication {
            currentApp = (app.localizedName ?? "", app.bundleIdentifier ?? "")
        }
    }

    /// Starts the global key monitor once Accessibility is granted. Safe to call repeatedly.
    func start() {
        if AX.isTrusted { monitor.start() }
        refreshStatus()
    }

    func refreshStatus() {
        let trusted = AX.isTrusted
        if trusted != isTrusted { isTrusted = trusted }
        if !trusted {
            // A tap made before access was revoked never works again; drop it so a fresh one is made later.
            monitor.stop()
            set(.needsPermission)
            return
        }
        if !monitor.isRunning {
            monitor.start()
            if !monitor.isRunning { set(.needsPermission); return }
        }
        if !settings.isModelConfigured && !settings.hasSearch { set(.needsModel); return }
        if !settings.enabled { set(.off); return }
        if settings.disabledApps.contains(currentApp.bundleID) { set(.paused); return }
        switch status {
        case .working, .waiting, .listening: return
        case .error where Date() < errorUntil: return
        default: set(.ready)
        }
    }

    private func set(_ s: Status) {
        if status != s { status = s }
        updateMood()
    }

    private func updateMood() {
        let m: Mood = switch status {
        case .needsPermission, .needsModel, .error: .worried
        case .off, .paused: .sleeping
        case .listening: .listening
        case .working: .thinking
        case .waiting: .found
        case .ready: celebrating ? .happy : .idle
        }
        if mood != m { mood = m }
    }

    private func celebrate() {
        celebrating = true
        set(.ready)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            MainActor.assumeIsolated {
                self?.celebrating = false
                self?.updateMood()
            }
        }
    }

    // MARK: Keys

    private static var linaIsInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private func handleKey(_ event: CGEvent) -> Bool {
        let flags = event.flags
        let code = event.keyCode
        let cmd = flags.contains(.maskCommand)
        let otherMods = flags.contains(.maskControl) || flags.contains(.maskAlternate) || flags.contains(.maskShift)

        // While a card waits for a choice, it owns esc, ⌘1–⌘9 and (for models) the arrows.
        if cards.isVisible {
            if code == kVK_Escape && !cmd { dismiss(); return true }
            if cmd, !otherMods, let n = Self.digits[code], n <= action.count { choose(n); return true }
            if case let .models(items) = action, !cmd {
                if code == kVK_DownArrow { cards.select(min(items.count - 1, cards.model.selected + 1)); return true }
                if code == kVK_UpArrow { cards.select(max(0, cards.model.selected - 1)); return true }
                if code == kVK_Return || code == kVK_ANSI_KeypadEnter { choose(cards.model.selected + 1); return true }
            }
        }

        if cmd || flags.contains(.maskControl) { return false }
        // Typing in Lina's own windows isn't writing.
        if Self.linaIsInFront { return false }
        guard settings.enabled, !settings.disabledApps.contains(currentApp.bundleID) else { return false }

        if code == kVK_Delete {
            if !typed.isEmpty { typed.removeLast() }
            noticeListening()
            return false
        }
        if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
            typed += "\n"
            noticeListening()
            scheduleCheck(after: 150)
            return false
        }
        let s = event.typedString
        guard let ch = s.last, !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        let wasEmptyOrSpace = typed.last.map { $0.isWhitespace } ?? true
        typed += s
        if typed.count > 120 { typed.removeFirst(typed.count - 120) }
        if cards.model.content?.isNotice == true { hideCard() }

        if s == "/", wasEmptyOrSpace, !tips.hasSeen(.slash) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.tips.show(.slash, under: AX.snapshot()?.caretRect) }
            }
        }
        noticeListening()

        switch ch {
        case ".", "?", "!": scheduleCheck(after: 650)
        case ",": scheduleCheck(after: 900)
        default: break
        }
        return false
    }

    /// Lina's face perks up while "/lina …" is being typed on the current line.
    private func noticeListening() {
        let line = typed.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let listening = line.lowercased().contains(CommandParser.trigger)
        if listening, status == .ready {
            set(.listening)
            if !tips.hasSeen(.listening) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    MainActor.assumeIsolated { self?.tips.show(.listening, under: AX.snapshot()?.caretRect) }
                }
            }
        } else if !listening, status == .listening {
            set(.ready)
        }
    }

    private func mouseDown() {
        typed = ""
        if status == .listening { set(.ready) }
        tips.hide()
        // Clicking an option on the card is a choice, not a dismissal.
        if cards.isVisible, cards.frame.contains(NSEvent.mouseLocation) { return }
        if cards.isVisible { dismiss() }
    }

    private func scheduleCheck(after ms: Int) {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.check() } }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
    }

    /// Returns true the first time it sees `key`.
    private func remember(_ key: String) -> Bool {
        guard !handledSet.contains(key) else { return false }
        handledSet.insert(key)
        handled.append(key)
        if handled.count > 300 {
            let old = handled.removeFirst()
            handledSet.remove(old)
        }
        return true
    }

    // MARK: What to do

    private func check() {
        guard settings.enabled, isTrusted, !Self.linaIsInFront,
              let snap = AX.snapshot(requireCaret: false),
              !settings.disabledApps.contains(snap.bundleID), snap.selection.length == 0
        else { return }
        let caret = snap.selection.location

        if let command = CommandParser.command(in: snap.text, caret: caret) {
            guard remember("\(snap.pid)|\(command.range.location)|\(command.text)") else { return }
            typed = ""
            run(command, in: snap)
            return
        }

        guard settings.checkSentences, settings.isModelConfigured,
              !(cards.model.content?.isPersistent ?? false),
              let range = Sentences.lastFinished(in: snap.text, caret: caret)
        else { return }
        let sentence = snap.text.substring(with: range)
        guard remember("\(snap.bundleID)|\(sentence)") else { return }
        let end = NSRange(location: NSMaxRange(range) - 1, length: 1)
        tips.show(.sentence, under: AX.screenRect(of: end, in: snap.element))
        proofread(passage: range, spot: Writer.spot(range, in: snap), snap: snap, quiet: true)
    }

    /// The ⌥Space shortcut: the same question `/lina` asks, about what's before the caret.
    func askNow() {
        guard settings.enabled, settings.isModelConfigured else { refreshStatus(); return }
        guard let snap = AX.snapshot(requireCaret: false), !settings.disabledApps.contains(snap.bundleID) else {
            NSSound.beep()
            return
        }
        let text = snap.before.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchor = self.anchor(snap, at: max(0, snap.selection.location - 1))
        guard WordCount.count(text) >= 3 else {
            notice("Write a few sentences first, then ask me.", .idle, at: anchor)
            return
        }
        question(about: text, app: snap.appName, anchor: anchor)
    }

    private func run(_ command: LinaCommand, in snap: FocusSnapshot) {
        tips.hide()
        let anchor = self.anchor(snap, at: max(0, command.range.location))
        let needsModel: Bool = switch command.kind {
        case .help, .saved: false
        case .search: !settings.hasSearch
        default: true
        }
        if needsModel && !settings.isModelConfigured {
            notice("Add a Nebius API key in Settings → Models first.", .worried, at: anchor)
            return
        }

        switch command.kind {
        case .help:
            removeCommand(command, in: snap)
            show(.help, at: anchor)
            set(.waiting)
        case .saved:
            removeCommand(command, in: snap)
            onOpenSaved?()
        case let .model(filter):
            removeCommand(command, in: snap)
            showModels(filter: filter, anchor: anchor)
        case .ask:
            let text = CommandParser.context(before: command, in: snap.text).trimmingCharacters(in: .whitespacesAndNewlines)
            removeCommand(command, in: snap)
            guard WordCount.count(text) >= 3 else {
                notice("Write a few sentences first. Then type /lina and I'll ask you something.", .idle, at: anchor)
                return
            }
            question(about: text, app: snap.appName, anchor: anchor)
        case .fix:
            guard let target = CommandParser.target(for: command, in: snap.text) else {
                notice("There's nothing above to check yet.", .idle, at: anchor)
                return
            }
            let whole = NSRange(location: target.location, length: NSMaxRange(command.range) - target.location)
            proofread(passage: target, spot: Writer.spot(whole, in: snap), snap: snap, quiet: false)
        case let .rewrite(how):
            guard let target = CommandParser.target(for: command, in: snap.text) else {
                notice("Write the paragraph first, then /lina rewrite.", .idle, at: anchor)
                return
            }
            let passage = snap.text.substring(with: target)
            let whole = NSRange(location: target.location, length: NSMaxRange(command.range) - target.location)
            choices(title: how.isEmpty ? "Rewrites" : "Rewrites · \(how)", passage: passage,
                    messages: Prompts.rewrite(passage, how: how, voice: settings.voice, aboutMe: settings.aboutMe),
                    spot: Writer.spot(whole, in: snap), kind: .rewrite, app: snap.appName, prompt: "rewrite \(how)", anchor: anchor)
        case let .edit(instruction):
            guard let target = CommandParser.target(for: command, in: snap.text) else {
                notice("Write the paragraph first, then /lina edit.", .idle, at: anchor)
                return
            }
            let passage = snap.text.substring(with: target)
            let whole = NSRange(location: target.location, length: NSMaxRange(command.range) - target.location)
            choices(title: "Edit · \(instruction)", passage: passage,
                    messages: Prompts.edit(passage, instruction: instruction, voice: settings.voice, aboutMe: settings.aboutMe),
                    spot: Writer.spot(whole, in: snap), kind: .edit, app: snap.appName, prompt: instruction, anchor: anchor)
        case let .image(prompt):
            guard !prompt.isEmpty else {
                notice("Tell me what to draw: /lina image a red bicycle in the snow.", .idle, at: anchor)
                return
            }
            guard settings.hasNebiusKey else {
                notice("Pictures come from Token Factory. Add a Nebius API key in Settings → Models.", .worried, at: anchor)
                return
            }
            image(prompt: prompt, spot: Writer.spot(command.range, in: snap), app: snap.appName, anchor: anchor)
        case let .search(question):
            let before = CommandParser.context(before: command, in: snap.text, limit: 600)
            let afterStart = NSMaxRange(command.bodyRange)
            let para = snap.text.paragraphRange(for: NSRange(location: command.range.location, length: 0))
            let afterEnd = max(afterStart, min(snap.text.length, NSMaxRange(para)))
            let after = snap.text.substring(with: NSRange(location: afterStart, length: afterEnd - afterStart))
            search(question, before: before, after: after, spot: Writer.spot(command.bodyRange, in: snap),
                   app: snap.appName, anchor: anchor)
        }
    }

    // MARK: Jobs

    private func begin(_ label: String?, anchor: CGRect) -> Int {
        task?.cancel()
        generation += 1
        tips.hide()
        marks.hide()
        action = .none
        if let label {
            show(.working(label), at: anchor)
        }
        set(.working(label ?? "Checking"))
        return generation
    }

    private func fail(_ error: Error, gen: Int, anchor: CGRect, quiet: Bool) {
        guard gen == generation else { return }
        if error is CancellationError { return }
        if let e = error as? URLError, e.code == .cancelled { return }
        errorUntil = Date().addingTimeInterval(10)
        if quiet {
            set(.error(error.localizedDescription))
        } else {
            notice(error.localizedDescription, .worried, at: anchor, seconds: 6)
            set(.error(error.localizedDescription))
        }
    }

    private func proofread(passage: NSRange, spot: Writer.Spot, snap: FocusSnapshot, quiet: Bool) {
        let original = snap.text.substring(with: passage)
        let before = snap.text.substring(to: passage.location)
        let anchor = self.anchor(snap, at: NSMaxRange(passage) - 1)
        let element = snap.element
        let client = LLMClient(endpoint: settings.checkEndpoint)
        let messages = Prompts.proofread(original, before: before)
        let gen = begin(quiet ? nil : "Checking your paragraph…", anchor: anchor)
        task = Task { [weak self] in
            do {
                let raw = try await client.complete(messages, maxTokens: 700, temperature: 0.1)
                guard let self, gen == self.generation else { return }
                let result = Proofread.parse(raw, original: original)
                guard !result.isEmpty else {
                    if quiet { self.set(.ready) } else { self.notice("No mistakes. It reads well.", .happy, at: anchor) }
                    return
                }
                let found = result.marks(in: original)
                self.action = .replace(spot, options: result.options, kind: .fix, history: nil)
                self.show(.corrections(original: original, marks: found, options: result.options), at: anchor)
                self.set(.waiting)
                // Underline each mistake in the writer's own text, where the app tells us where it is.
                let lines = found.compactMap { (m: Proofread.Mark) -> MarkPanel.Underline? in
                    let r = NSRange(location: passage.location + m.range.location, length: m.range.length)
                    guard let rect = AX.screenRect(of: r, in: element) else { return nil }
                    return MarkPanel.Underline(rect: rect, color: CardView.color(m.kind))
                }
                self.marks.show(lines)
            } catch {
                self?.fail(error, gen: gen, anchor: anchor, quiet: quiet)
            }
        }
    }

    private func question(about text: String, app: String, anchor: CGRect) {
        let client = LLMClient(endpoint: settings.commandEndpoint)
        let messages = Prompts.question(text: text, appName: app, voice: settings.voice, aboutMe: settings.aboutMe)
        let gen = begin("Reading what you wrote…", anchor: anchor)
        task = Task { [weak self] in
            do {
                let raw = try await client.complete(messages, maxTokens: 120, temperature: 0.7)
                guard let self, gen == self.generation else { return }
                let q = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"“” \n"))
                guard !q.isEmpty else { throw LLMError.message("Lina came back empty-handed. Try /lina again.") }
                self.history.add(HistoryItem(kind: .question, app: app, prompt: String(text.suffix(200)), result: q))
                self.show(.question(q), at: anchor)
                self.set(.waiting)
            } catch {
                self?.fail(error, gen: gen, anchor: anchor, quiet: false)
            }
        }
    }

    private func choices(title: String, passage: String, messages: [ChatMessage], spot: Writer.Spot,
                         kind: HistoryItem.Kind, app: String, prompt: String, anchor: CGRect) {
        let client = LLMClient(endpoint: settings.commandEndpoint)
        let gen = begin(kind == .edit ? "Editing…" : "Writing three versions…", anchor: anchor)
        task = Task { [weak self] in
            do {
                let raw = try await client.complete(messages, maxTokens: 900, temperature: kind == .edit ? 0.3 : 0.8)
                guard let self, gen == self.generation else { return }
                let options = kind == .edit
                    ? [raw.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
                    : Answers.options(raw)
                guard !options.isEmpty else { throw LLMError.message("Lina came back empty-handed. Try again.") }
                let id = self.history.add(HistoryItem(kind: kind, app: app, prompt: prompt.trimmingCharacters(in: .whitespaces),
                                                      result: options[0]))
                self.action = .replace(spot, options: options, kind: kind, history: id)
                self.show(.choices(title: title, original: passage, options: options), at: anchor)
                self.set(.waiting)
            } catch {
                self?.fail(error, gen: gen, anchor: anchor, quiet: false)
            }
        }
    }

    private func search(_ question: String, before: String, after: String, spot: Writer.Spot, app: String, anchor: CGRect) {
        let grounded = settings.hasSearch
        let gemini = settings.gemini
        let client = LLMClient(endpoint: settings.commandEndpoint)
        let voice = settings.voice, aboutMe = settings.aboutMe
        let gen = begin(grounded ? "Searching the web…" : "Thinking it over…", anchor: anchor)
        task = Task { [weak self] in
            do {
                let raw: String
                var sources: [WebSource] = []
                if grounded {
                    let answer = try await gemini.ask(
                        system: Prompts.searchSystem(voice: voice, aboutMe: aboutMe, grounded: true),
                        prompt: Prompts.searchUser(question: question, before: before, after: after))
                    raw = answer.text
                    sources = answer.sources
                } else {
                    raw = try await client.complete(Prompts.search(question: question, before: before, after: after,
                                                                  voice: voice, aboutMe: aboutMe),
                                                    maxTokens: 220, temperature: 0.3)
                }
                guard let self, gen == self.generation else { return }
                let (fit, answer) = Answers.fitAndAnswer(raw)
                guard !fit.isEmpty else { throw LLMError.message("No answer came back. Try asking another way.") }
                let id = self.history.add(HistoryItem(kind: .search, app: app, prompt: question, result: answer, sources: sources))
                let withSource = sources.first.map { "\(fit) (\($0.site))" }
                self.action = .answer(spot, fit: fit, withSource: withSource, history: id)
                self.show(.answer(question: question, text: fit, sources: sources, grounded: grounded), at: anchor)
                self.set(.waiting)
            } catch {
                self?.fail(error, gen: gen, anchor: anchor, quiet: false)
            }
        }
    }

    private func image(prompt: String, spot: Writer.Spot, app: String, anchor: CGRect) {
        let client = LLMClient(endpoint: settings.nebiusEndpoint)
        let model = settings.imageModel
        let gen = begin("Drawing with \(model.split(separator: "/").last.map(String.init) ?? model)…", anchor: anchor)
        task = Task { [weak self] in
            do {
                let png = try await client.generateImage(prompt: prompt, model: model)
                guard let self, gen == self.generation else { return }
                guard let picture = NSImage(data: png) else { throw LLMError.message("The picture couldn't be read.") }
                var item = HistoryItem(kind: .image, app: app, prompt: prompt, result: model)
                item.imageFile = self.history.storeImage(png)
                let id = self.history.add(item)
                self.action = .image(spot, png: png, history: id)
                self.show(.image(prompt: prompt, image: picture), at: anchor)
                self.set(.waiting)
            } catch {
                self?.fail(error, gen: gen, anchor: anchor, quiet: false)
            }
        }
    }

    private func showModels(filter: String, anchor: CGRect) {
        let endpoint = settings.provider == .local ? settings.commandEndpoint : settings.nebiusEndpoint
        let gen = begin("Asking \(settings.provider == .local ? "your local server" : "Token Factory") for models…", anchor: anchor)
        task = Task { [weak self] in
            do {
                let ids = try await LLMClient(endpoint: endpoint).listModels()
                guard let self, gen == self.generation else { return }
                var items = ModelCatalog.items(ids)
                if self.settings.provider == .local { items = items.filter { $0.kind == .text } }
                if !filter.isEmpty { items = items.filter { $0.id.localizedCaseInsensitiveContains(filter) } }
                // Writing models first, then image models.
                items = items.filter { $0.kind == .text } + items.filter { $0.kind == .image }
                guard !items.isEmpty else {
                    self.notice(filter.isEmpty ? "No models came back." : "No models match “\(filter)”.", .worried, at: anchor)
                    return
                }
                let current = self.settings.activeTextModel
                let selected = items.firstIndex { $0.id == current } ?? 0
                self.action = .models(items)
                self.show(.models(items: items, currentText: current, currentImage: self.settings.imageModel),
                          at: anchor, selected: selected)
                self.set(.waiting)
            } catch {
                self?.fail(error, gen: gen, anchor: anchor, quiet: false)
            }
        }
    }

    // MARK: Choosing

    private func choose(_ n: Int) {
        let current = action
        switch current {
        case .none:
            return
        case let .replace(spot, options, kind, id):
            guard options.indices.contains(n - 1) else { return }
            let text = options[n - 1]
            let ok = Writer.replace(spot, with: text)
            if kind == .fix {
                history.add(HistoryItem(kind: .fix, app: currentApp.name, prompt: spot.expected, result: text, inserted: ok))
            } else {
                history.update(id, result: text)
                if ok { history.markInserted(id) }
            }
            finish(ok)
        case let .answer(spot, fit, withSource, id):
            let text = n == 2 ? (withSource ?? fit) : fit
            let ok = Writer.replace(spot) { before, after in Answers.fit(text, before: before, after: after) }
            if ok { history.markInserted(id) }
            finish(ok)
        case let .models(items):
            guard items.indices.contains(n - 1) else { return }
            let item = items[n - 1]
            let anchor = CGRect(x: cards.frame.minX + 30, y: cards.frame.maxY - 16, width: 1, height: 16)
            if item.kind == .text { settings.activeTextModel = item.id } else { settings.imageModel = item.id }
            hideCard()
            notice(item.kind == .text ? "Now writing with \(item.shortName)." : "Now drawing with \(item.shortName).",
                   .happy, at: anchor)
            celebrate()
        case let .image(spot, png, id):
            if n == 2 {
                TextInserter.copyImage(png)
                hideCard()
                celebrate()
                return
            }
            let ok = Writer.insertImage(spot, png: png)
            if ok { history.markInserted(id) }
            finish(ok)
        }
    }

    private func finish(_ ok: Bool) {
        let anchor = CGRect(x: cards.frame.minX + 30, y: cards.frame.maxY - 16, width: 1, height: 16)
        hideCard()
        if ok {
            celebrate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.tips.show(.inserted, under: AX.snapshot()?.caretRect) }
            }
        } else {
            notice("I couldn't edit this field, so it's on your clipboard. Paste with ⌘V.", .worried, at: anchor, seconds: 5)
        }
    }

    // MARK: Cards

    private func show(_ content: CardContent, at anchor: CGRect, selected: Int = 0) {
        noticeTimer?.cancel()
        tips.hide()
        cards.show(content, at: anchor, selected: selected)
    }

    private func notice(_ message: String, _ mood: Mood, at anchor: CGRect, seconds: Double = 3.5) {
        action = .none
        show(.notice(message, mood), at: anchor)
        if mood == .worried { set(.error(message)); errorUntil = Date().addingTimeInterval(seconds) } else { set(.ready) }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.cards.model.content?.isNotice == true else { return }
                self.hideCard()
            }
        }
        noticeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hideCard() {
        cards.hide()
        marks.hide()
        action = .none
        if status == .waiting || status == .listening { set(.ready) }
        if case .working = status { set(.ready) }
    }

    /// Esc, a click elsewhere, or switching apps: stop and put everything away. The writer's text stays as it is.
    func dismiss() {
        task?.cancel()
        generation += 1
        hideCard()
        tips.hide()
        refreshStatus()
    }

    /// Removes a command that only controls Lina (`/lina model`, `/lina help`, `/lina`), with the space before it.
    private func removeCommand(_ command: LinaCommand, in snap: FocusSnapshot) {
        var r = command.range
        if r.location > 0, snap.text.character(at: r.location - 1) == 0x20 {
            r = NSRange(location: r.location - 1, length: r.length + 1)
        }
        Writer.replace(Writer.spot(r, in: snap), with: "")
    }

    /// Where to put a card: under the line holding `index`, or wherever the app lets us look.
    private func anchor(_ snap: FocusSnapshot, at index: Int) -> CGRect {
        let i = max(0, min(index, snap.text.length - 1))
        if snap.text.length > 0, let r = AX.screenRect(of: NSRange(location: i, length: 1), in: snap.element) {
            return CGRect(x: r.minX, y: r.minY, width: max(1, r.width), height: r.height)
        }
        if let caret = snap.caretRect { return caret }
        if let frame = AX.frame(of: snap.element) {
            return CGRect(x: frame.minX + 16, y: max(frame.minY, frame.maxY - 60), width: 1, height: 18)
        }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(x: screen.midX - CardView.width / 2, y: screen.midY + 120, width: 1, height: 18)
    }
}
