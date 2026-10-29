import AppKit
import Carbon.HIToolbox
import Combine

/// Lina's brain. She stays quiet until the writer asks:
/// - typing `/lina` (or ⌥ Space) opens a command bar at the caret; the command never enters the text;
/// - after a sentence ends with `.` `?` or `!` and the writer stops typing for a moment, she checks it and puts
///   small fixes right on top of the mistakes.
/// Nothing goes into the text until the writer presses ⌘ + a number (or ⌘A for every fix).
@MainActor
final class LinaEngine: ObservableObject {
    enum Status: Equatable {
        case needsPermission, needsModel, off, paused, ready, listening
        case working(String)
        /// A card or fixes are waiting for the writer to choose.
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
    /// The fixes waiting on screen (read by the live test).
    var pendingFixes: [Fix] { fixState?.fixes ?? [] }

    let tips = TipCoach()
    private let settings = AppSettings.shared
    private let history = History.shared
    private let cards = CardPanel()
    private let fixPanel = FixPanel()
    private let marks = MarkPanel()
    private let bar = CommandBar()
    private let monitor = KeyMonitor()

    private var bag = Set<AnyCancellable>()
    private var pendingCommand: DispatchWorkItem?
    private var pendingSentence: DispatchWorkItem?
    private var sentenceWaiting = false
    private var relayout: DispatchWorkItem?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var handled: [String] = []
    private var handledSet = Set<String>()
    /// The last few characters the writer typed, to notice "/lina" as it's typed.
    private var typed = ""
    private var action: CardAction = .none
    private var fixState: FixState?
    /// The field and app the command bar was opened over.
    private var barSnap: FocusSnapshot?
    private var barApp: NSRunningApplication?
    private var barAnchor: CGRect = .zero
    private var celebrating = false
    private var errorUntil = Date.distantPast
    private var noticeTimer: DispatchWorkItem?

    /// What ⌘1, ⌘2… do for the card on screen.
    private enum CardAction {
        case none
        case replace(Writer.Spot, options: [String], history: UUID?)
        case answer(Writer.Spot, fit: String, withSource: String?, history: UUID?)
        case models([ModelItem])
        case image(Writer.Spot, png: Data, history: UUID?)

        var count: Int {
            switch self {
            case .none: 0
            case let .replace(_, options, _): options.count
            case let .answer(_, _, withSource, _): withSource == nil ? 1 : 2
            case let .models(items): min(9, items.count)
            case .image: 2
            }
        }
    }

    /// Fixes waiting on screen, kept in step with the text as each one goes in.
    private struct FixState {
        let pid: pid_t
        let element: AXUIElement
        let app: String
        var fixes: [Fix]
        /// The checked passage in the field, and its text, both updated as fixes go in.
        var passage: NSRange
        var text: String
        var anchor: CGRect
    }

    /// Where a command came from and where its result goes.
    private struct CommandContext {
        /// The field as it was when the command was given (without the command).
        let snap: FocusSnapshot
        /// Where the command sits: the caret for the bar, the command's start for an in-text command.
        let start: Int
        /// What an answer or a picture replaces: an empty range at the caret for the bar.
        let replace: NSRange
        /// An in-text command's own text, taken out when the command only talks to Lina.
        let remove: NSRange?
        let anchor: CGRect
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
        cards.onChoose = { [weak self] n in
            guard let self else { return }
            if self.fixState != nil { self.applyFix(n) } else { self.choose(n) }
        }
        fixPanel.onChoose = { [weak self] n in self?.applyFix(n) }
        fixPanel.onAll = { [weak self] in self?.applyAllFixes() }
        bar.onSubmit = { [weak self] text in self?.barSubmitted(text) }
        bar.onCancel = { [weak self] in self?.barCancelled() }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        let switched = app.processIdentifier != self.barApp?.processIdentifier
                        self.currentApp = (app.localizedName ?? "", app.bundleIdentifier ?? "")
                        self.typed = ""
                        if switched { self.dismiss() }
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
        // The command bar has focus: its keys are its own.
        if bar.isVisible { return false }

        let flags = event.flags
        let code = event.keyCode
        let cmd = flags.contains(.maskCommand)
        let otherMods = flags.contains(.maskControl) || flags.contains(.maskAlternate) || flags.contains(.maskShift)

        // Fixes on screen own esc, ⌘1–⌘9 and ⌘A.
        if fixState != nil {
            if code == kVK_Escape && !cmd { dismiss(); return true }
            if cmd, !otherMods, let n = Self.digits[code], n <= (fixState?.fixes.count ?? 0) { applyFix(n); return true }
            if cmd, !otherMods, code == kVK_ANSI_A { applyAllFixes(); return true }
        } else if cards.isVisible {
            // A card waiting for a choice owns esc, ⌘1–⌘9 and (for models) the arrows.
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
            if sentenceWaiting { scheduleSentenceCheck() }
            noticeListening()
            return false
        }
        if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
            typed += "\n"
            noticeListening()
            if !settings.commandBar { scheduleCommandCheck(after: 150) }
            if sentenceWaiting { scheduleSentenceCheck() }
            return false
        }
        let s = event.typedString
        guard let ch = s.last, !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }

        // "/lina": swallow the "a", take back "/lin", and open the bar where the writer is.
        if settings.commandBar, s.lowercased() == "a", startsCommand(typed) {
            typed = ""
            openBar(takingBack: 4)
            return true
        }

        let wasEmptyOrSpace = typed.last.map { $0.isWhitespace } ?? true
        typed += s
        if typed.count > 120 { typed.removeFirst(typed.count - 120) }
        if cards.model.content?.isNotice == true { hideCard() }
        if fixState != nil { scheduleRelayout() }

        if s == "/", wasEmptyOrSpace, !tips.hasSeen(.slash) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.tips.show(.slash, under: AX.snapshot()?.caretRect) }
            }
        }
        noticeListening()

        switch ch {
        case ".", "?", "!":
            sentenceWaiting = true
            scheduleSentenceCheck()
            if !settings.commandBar { scheduleCommandCheck(after: 650) }
        case ",":
            if !settings.commandBar { scheduleCommandCheck(after: 900) }
            if sentenceWaiting { scheduleSentenceCheck() }
        default:
            if sentenceWaiting { scheduleSentenceCheck() }
        }
        return false
    }

    /// Whether the characters typed so far end with "/lin" at the start of a word.
    private func startsCommand(_ typed: String) -> Bool {
        let lower = typed.lowercased()
        guard lower.hasSuffix("/lin") else { return false }
        let before = lower.dropLast(4).last
        return before == nil || before!.isWhitespace || "([\"'“‘".contains(before!)
    }

    /// With the bar off, Lina's face perks up while "/lina …" is being typed in the text.
    private func noticeListening() {
        guard !settings.commandBar else { return }
        let line = typed.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let listening = line.lowercased().contains(CommandParser.trigger)
        if listening, status == .ready {
            set(.listening)
        } else if !listening, status == .listening {
            set(.ready)
        }
    }

    private func mouseDown() {
        typed = ""
        if status == .listening && !bar.isVisible { set(.ready) }
        tips.hide()
        let p = NSEvent.mouseLocation
        // Clicking a fix or an option is a choice, not a dismissal.
        if (cards.isVisible && cards.frame.contains(p)) || (fixPanel.isVisible && fixPanel.frame.contains(p))
            || (bar.isVisible && bar.frame.contains(p)) { return }
        if cards.isVisible || fixState != nil { dismiss() }
    }

    private func scheduleCommandCheck(after ms: Int) {
        pendingCommand?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.checkTypedCommand() } }
        pendingCommand = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
    }

    /// Waits until the writer has stopped typing for the delay in Settings, then checks what they finished.
    private func scheduleSentenceCheck() {
        pendingSentence?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.checkSentences() } }
        pendingSentence = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.3, settings.checkDelay), execute: work)
    }

    private func scheduleRelayout() {
        relayout?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.layoutFixes() } }
        relayout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
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

    // MARK: Command bar

    /// The ⌥ Space shortcut opens the same bar as typing /lina.
    func askNow() {
        guard settings.enabled else { refreshStatus(); return }
        guard !bar.isVisible else { return }
        openBar(takingBack: 0)
    }

    private func openBar(takingBack count: Int) {
        tips.hide()
        hideCard()
        closeFixes()
        if count > 0 { TextInserter.backspace(count) }
        barApp = NSWorkspace.shared.frontmostApplication
        // Give the app a moment to take the characters back before reading where the caret is.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let snap = AX.snapshot(requireCaret: false)
                self.barSnap = snap
                if let snap {
                    self.barAnchor = snap.caretRect ?? self.anchor(snap, at: max(0, snap.selection.location - 1))
                } else {
                    let m = NSEvent.mouseLocation
                    self.barAnchor = CGRect(x: m.x, y: m.y - 10, width: 1, height: 18)
                }
                self.set(.listening)
                self.bar.show(at: self.barAnchor)
            }
        }
    }

    private func barSubmitted(_ text: String) {
        let app = barApp
        app?.activate()
        set(.ready)
        guard let snap = barSnap else {
            notice("I can't read this field, so I can't work here. Try Notes, Mail or a browser.", .worried, at: barAnchor)
            return
        }
        let caret = snap.selection
        let ctx = CommandContext(snap: snap, start: caret.location, replace: caret, remove: nil, anchor: barAnchor)
        let kind = CommandParser.parseBar(text)
        // Let the writer's app take focus back before anything reads or writes it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated { self?.run(kind, ctx) }
        }
    }

    private func barCancelled() {
        barApp?.activate()
        set(.ready)
        refreshStatus()
    }

    // MARK: What to do

    /// With the command bar off: a `/lina …` typed into the text and finished with a terminator.
    private func checkTypedCommand() {
        guard settings.enabled, isTrusted, !Self.linaIsInFront,
              let snap = AX.snapshot(requireCaret: false),
              !settings.disabledApps.contains(snap.bundleID), snap.selection.length == 0,
              let command = CommandParser.command(in: snap.text, caret: snap.selection.location)
        else { return }
        guard remember("\(snap.pid)|\(command.range.location)|\(command.text)") else { return }
        typed = ""
        var remove = command.range
        if remove.location > 0, snap.text.character(at: remove.location - 1) == 0x20 {
            remove = NSRange(location: remove.location - 1, length: remove.length + 1)
        }
        let isImage: Bool = switch command.kind {
        case .image: true
        default: false
        }
        let ctx = CommandContext(snap: snap, start: command.range.location,
                                 replace: isImage ? command.range : command.bodyRange, remove: remove,
                                 anchor: anchor(snap, at: max(0, command.range.location)))
        run(command.kind, ctx)
    }

    /// After the writer stops typing: check the sentences they finished since the last check.
    private func checkSentences() {
        sentenceWaiting = false
        guard settings.enabled, settings.checkSentences, settings.isModelConfigured, isTrusted, !Self.linaIsInFront,
              fixState == nil, !(cards.model.content?.isPersistent ?? false), !bar.isVisible,
              let snap = AX.snapshot(requireCaret: false),
              !settings.disabledApps.contains(snap.bundleID), snap.selection.length == 0
        else { return }
        let fresh = Sentences.recentFinished(in: snap.text, caret: snap.selection.location).filter { r in
            remember("\(snap.bundleID)|\(snap.text.substring(with: r))")
        }
        guard let first = fresh.first, let last = fresh.last else { return }
        let passage = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let end = NSRange(location: NSMaxRange(last) - 1, length: 1)
        tips.show(.sentence, under: AX.screenRect(of: end, in: snap.element))
        proofread(passage: passage, snap: snap, quiet: true)
    }

    private func run(_ kind: LinaCommand.Kind, _ ctx: CommandContext) {
        tips.hide()
        let snap = ctx.snap
        let anchor = ctx.anchor
        let needsModel: Bool = switch kind {
        case .help, .saved: false
        case .search: !settings.hasSearch
        default: true
        }
        if needsModel && !settings.isModelConfigured {
            notice("Lina isn't connected to a model yet. Add a key in Settings → Models.", .worried, at: anchor)
            return
        }
        let text = snap.text

        switch kind {
        case .help:
            removeCommand(ctx)
            show(.help, at: anchor)
            set(.waiting)
        case .saved:
            removeCommand(ctx)
            onOpenSaved?()
        case let .model(filter):
            removeCommand(ctx)
            showModels(filter: filter, anchor: anchor)
        case .ask:
            let about = text.substring(to: ctx.start).trimmingCharacters(in: .whitespacesAndNewlines)
            removeCommand(ctx)
            guard WordCount.count(about) >= 3 else {
                notice("Write a few sentences first, then ask me.", .idle, at: anchor)
                return
            }
            question(about: String(about.suffix(4000)), app: snap.appName, anchor: anchor)
        case .fix:
            removeCommand(ctx)
            guard let target = CommandParser.target(before: ctx.start, in: text) else {
                notice("There's nothing above to check yet.", .idle, at: anchor)
                return
            }
            proofread(passage: target, snap: snap, quiet: false)
        case let .rewrite(how):
            guard let target = CommandParser.target(before: ctx.start, in: text) else {
                notice("Write the paragraph first, then /lina rewrite.", .idle, at: anchor)
                return
            }
            let passage = text.substring(with: target)
            choices(title: how.isEmpty ? "Rewrites" : "Rewrites · \(how)", passage: passage,
                    messages: Prompts.rewrite(passage, how: how, voice: settings.voice, aboutMe: settings.aboutMe),
                    spot: Writer.spot(spanning(target, ctx), in: snap), kind: .rewrite, app: snap.appName,
                    prompt: "rewrite \(how)", anchor: anchor)
        case let .edit(instruction):
            guard let target = CommandParser.target(before: ctx.start, in: text) else {
                notice("Write the paragraph first, then /lina edit.", .idle, at: anchor)
                return
            }
            let passage = text.substring(with: target)
            choices(title: "Edit · \(instruction)", passage: passage,
                    messages: Prompts.edit(passage, instruction: instruction, voice: settings.voice, aboutMe: settings.aboutMe),
                    spot: Writer.spot(spanning(target, ctx), in: snap), kind: .edit, app: snap.appName,
                    prompt: instruction, anchor: anchor)
        case let .image(prompt):
            guard !prompt.isEmpty else {
                removeCommand(ctx)
                notice("Tell me what to draw: /lina image a red bicycle in the snow.", .idle, at: anchor)
                return
            }
            guard settings.hasNebiusKey else {
                notice("Pictures come from Token Factory. Add a Nebius key in Settings → Models.", .worried, at: anchor)
                return
            }
            image(prompt: prompt, spot: Writer.spot(ctx.replace, in: snap), app: snap.appName, anchor: anchor)
        case let .search(question):
            let start = max(0, ctx.start - 600)
            let before = text.substring(with: NSRange(location: start, length: ctx.start - start))
            let afterStart = NSMaxRange(ctx.replace)
            let para = text.paragraphRange(for: NSRange(location: min(afterStart, text.length), length: 0))
            let afterEnd = max(afterStart, min(text.length, NSMaxRange(para)))
            let after = text.substring(with: NSRange(location: afterStart, length: afterEnd - afterStart))
            search(question, before: before, after: after, spot: Writer.spot(ctx.replace, in: snap),
                   app: snap.appName, anchor: anchor)
        }
    }

    /// The paragraph plus, for an in-text command, the command after it: the whole thing a rewrite replaces.
    private func spanning(_ target: NSRange, _ ctx: CommandContext) -> NSRange {
        guard let remove = ctx.remove else { return target }
        return NSRange(location: target.location, length: NSMaxRange(remove) - target.location)
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
        if !quiet { notice(error.localizedDescription, .worried, at: anchor, seconds: 6) }
        set(.error(error.localizedDescription))
    }

    private func proofread(passage: NSRange, snap: FocusSnapshot, quiet: Bool) {
        let original = snap.text.substring(with: passage)
        let before = snap.text.substring(to: passage.location)
        let anchor = self.anchor(snap, at: NSMaxRange(passage) - 1)
        let client = LLMClient(endpoint: settings.checkEndpoint)
        let messages = Prompts.proofread(original, before: before)
        let gen = begin(quiet ? nil : "Checking your paragraph…", anchor: anchor)
        task = Task { [weak self] in
            do {
                let raw = try await client.complete(messages, maxTokens: 600, temperature: 0.1)
                guard let self, gen == self.generation else { return }
                let fixes = Proofread.parse(raw, original: original).fixes(in: original, at: passage.location)
                guard !fixes.isEmpty else {
                    if quiet { self.set(.ready) } else { self.notice("No mistakes. It reads well.", .happy, at: anchor) }
                    return
                }
                if !quiet { self.hideCard() }
                self.fixState = FixState(pid: snap.pid, element: snap.element, app: snap.appName, fixes: fixes,
                                         passage: passage, text: original, anchor: anchor)
                self.layoutFixes()
                self.set(.waiting)
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
                self.action = .replace(spot, options: options, history: id)
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

    // MARK: Fixes

    /// Puts each fix on top of its mistake; falls back to a short list when the app won't say where words are.
    private func layoutFixes() {
        guard let st = fixState else { return }
        let rects = st.fixes.map { AX.screenRect(of: $0.range, in: st.element) }
        if fixPanel.show(st.fixes, rects: rects) {
            cards.hide()
            marks.show(zip(st.fixes, rects).compactMap { fix, rect in
                rect.map { MarkPanel.Underline(rect: $0, color: CardView.color(fix.kind)) }
            })
        } else {
            marks.hide()
            show(.corrections(st.fixes), at: st.anchor)
        }
    }

    /// ⌘1, ⌘2…: one fix goes in; the rest move with the text.
    private func applyFix(_ n: Int) {
        guard var st = fixState, st.fixes.indices.contains(n - 1) else { return }
        let fix = st.fixes[n - 1]
        let ok = Writer.replace(Writer.Spot(pid: st.pid, range: fix.range, expected: fix.wrong), with: fix.right)
        history.add(HistoryItem(kind: .fix, app: st.app, prompt: fix.wrong, result: fix.right, inserted: ok))
        guard ok else { finish(false); return }
        let local = NSRange(location: fix.range.location - st.passage.location, length: fix.range.length)
        if local.location >= 0, NSMaxRange(local) <= (st.text as NSString).length {
            st.text = (st.text as NSString).replacingCharacters(in: local, with: fix.right)
        }
        st.passage.length += (fix.right as NSString).length - fix.range.length
        st.fixes.remove(at: n - 1)
        st.fixes = Fixes.shift(st.fixes, after: fix)
        if st.fixes.isEmpty {
            finish(true)
            return
        }
        fixState = st
        fixPanel.hide()
        marks.hide()
        // Let the app redraw before asking where the remaining words are.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated { self?.layoutFixes() }
        }
    }

    /// ⌘A: every fix at once, as one change the writer can undo with one ⌘Z.
    private func applyAllFixes() {
        guard let st = fixState else { return }
        let relative = st.fixes.map { f -> Fix in
            var f = f
            f.range.location -= st.passage.location
            return f
        }
        guard let all = Fixes.all(relative, in: st.text as NSString) else { return }
        let span = NSRange(location: st.passage.location + all.span.location, length: all.span.length)
        let original = (st.text as NSString).substring(with: all.span)
        let ok = Writer.replace(Writer.Spot(pid: st.pid, range: span, expected: original), with: all.replacement)
        history.add(HistoryItem(kind: .fix, app: st.app, prompt: original, result: all.replacement, inserted: ok))
        finish(ok)
    }

    private func closeFixes() {
        fixState = nil
        relayout?.cancel()
        fixPanel.hide()
        marks.hide()
    }

    // MARK: Choosing

    private func choose(_ n: Int) {
        switch action {
        case .none:
            return
        case let .replace(spot, options, id):
            guard options.indices.contains(n - 1) else { return }
            let text = options[n - 1]
            let ok = Writer.replace(spot, with: text)
            history.update(id, result: text)
            if ok { history.markInserted(id) }
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
        let anchor = fixState?.anchor ?? CGRect(x: cards.frame.minX + 30, y: cards.frame.maxY - 16, width: 1, height: 16)
        hideCard()
        closeFixes()
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
        action = .none
        if status == .waiting || status == .listening { set(.ready) }
        if case .working = status { set(.ready) }
    }

    /// Esc, a click elsewhere, or switching apps: stop and put everything away. The writer's text stays as it is.
    func dismiss() {
        task?.cancel()
        generation += 1
        hideCard()
        closeFixes()
        tips.hide()
        refreshStatus()
    }

    /// Takes an in-text command out of the text (with the space before it). Bar commands were never in the text.
    private func removeCommand(_ ctx: CommandContext) {
        guard let remove = ctx.remove else { return }
        Writer.replace(Writer.spot(remove, in: ctx.snap), with: "")
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
