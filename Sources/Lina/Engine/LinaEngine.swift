import AppKit
import Carbon.HIToolbox
import Combine

/// Lina's brain. She stays quiet until the writer asks:
/// - `/lina …` typed right in the text is marked as Lina's (a tinted, underlined band). Return, or a pause after
///   `,` `.` `?`, runs it; the command then disappears, or the answer takes its place;
/// - after a sentence ends with `.` `?` or `!` and the writer stops typing for a moment, she checks it and puts
///   small fixes right on top of the mistakes.
/// Nothing goes into the text until the writer presses ⌘ + a number (or ⌘A for every fix).
/// Fields Lina can't read still work: she follows the keystrokes and pastes at the caret.
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
    private let commandMark = CommandMark()
    private let monitor = KeyMonitor()

    private var bag = Set<AnyCancellable>()
    private var inlineRun: DispatchWorkItem?
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
    /// The `/lina …` command being typed or run in the writer's text.
    private var inline: Inline?
    /// A command still sitting in the text while its card waits; taken out if the writer dismisses the card.
    private var commandLeft: Writer.Spot?
    private var celebrating = false
    private var errorUntil = Date.distantPast
    private var noticeTimer: DispatchWorkItem?
    /// Hold ⌃⌥ to say a command.
    private let voiceInput = VoiceInput()
    private var talkHold: DispatchWorkItem?
    /// "Ask me when I pause": the writer's last keystroke, and the question waiting for the pause.
    private var pendingAsk: DispatchWorkItem?

    /// What ⌘1, ⌘2… do for the card on screen.
    private enum CardAction {
        case none
        case replace(Writer.Spot, options: [String], history: UUID?)
        case answer(Writer.Spot, fit: String, withSource: String?, suffix: String, history: UUID?)
        case models([ModelItem])
        case image(Writer.Spot, png: Data, history: UUID?)

        var count: Int {
            switch self {
            case .none: 0
            case let .replace(_, options, _): options.count
            case let .answer(_, _, withSource, _, _): withSource == nil ? 1 : 2
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

    /// A `/lina …` command typed in the writer's own text.
    private struct Inline {
        let pid: pid_t
        /// The command as typed so far, starting with "/lina".
        var text: String
        /// What the writer typed before it, for fields Lina can't read.
        let before: String
        var running = false
        /// The writer typed or clicked after it ran, so taking characters back by keystroke would hit the wrong ones.
        var dirty = false
        var anchor: CGRect?
    }

    /// Where a command sits and where its result goes.
    private struct CommandContext {
        /// The field as it was when the command ran; nil when the field can't be read.
        let snap: FocusSnapshot?
        /// Where the command starts in the field.
        let start: Int
        /// What an answer replaces: the command without a trailing `,` `.` `!`.
        let answer: Writer.Spot
        /// The whole command: what a picture replaces.
        let whole: Writer.Spot
        /// The command and the space before it: taken out when the command only talks to Lina.
        let remove: Writer.Spot
        /// Punctuation to put back after an answer when the field can't be read.
        let suffix: String
        let before: String
        let after: String
        let anchor: CGRect
        let app: String
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
        monitor.onFlagsChanged = { [weak self] flags in
            MainActor.assumeIsolated { self?.flagsChanged(flags) }
        }
        cards.onChoose = { [weak self] n in
            guard let self else { return }
            if self.fixState != nil { self.applyFix(n) } else { self.choose(n) }
        }
        fixPanel.onChoose = { [weak self] n in self?.applyFix(n) }
        fixPanel.onAll = { [weak self] in self?.applyAllFixes() }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        self.currentApp = (app.localizedName ?? "", app.bundleIdentifier ?? "")
                        Diagnostics.lastApp = app
                        self.typed = ""
                        self.inline?.dirty = true
                        self.dismiss()
                    }
                    self.refreshStatus()
                }
            }
            .store(in: &bag)
        settings.objectWillChange.merge(with: Account.shared.objectWillChange)
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
        // A key pressed while ⌃⌥ is held is a shortcut (like ⌃⌥M), not the start of talking.
        talkHold?.cancel()
        talkHold = nil
        scheduleAsk()
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

        // A /lina command being typed: Return runs it (and never reaches the app, so a search box won't submit),
        // esc takes it back out.
        if var command = inline, !command.running {
            switch code {
            case kVK_Return, kVK_ANSI_KeypadEnter:
                runInline()
                return true
            case kVK_Escape:
                cancelInline()
                return true
            case kVK_Delete:
                command.text.removeLast()
                if command.text.lowercased().hasPrefix(CommandParser.trigger) {
                    inline = command
                    inlineRun?.cancel()
                    markSoon()
                } else {
                    endInline()
                }
                if !typed.isEmpty { typed.removeLast() }
                return false
            case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Tab:
                endInline()
                return false
            default:
                let s = event.typedString
                guard let ch = s.last, !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    return false
                }
                command.text += s
                inline = command
                typed += s
                markSoon()
                inlineRun?.cancel()
                // Moving on with , . ? ! and a pause runs it, as the writer would end a thought.
                if ",.?!".contains(ch) {
                    let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.runInline() } }
                    inlineRun = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
                }
                return false
            }
        }
        if inline?.running == true { inline?.dirty = true }

        if code == kVK_Delete {
            if !typed.isEmpty { typed.removeLast() }
            if sentenceWaiting { scheduleSentenceCheck() }
            return false
        }
        if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
            typed += "\n"
            if sentenceWaiting { scheduleSentenceCheck() }
            return false
        }
        let s = event.typedString
        guard let ch = s.last, !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }

        let wasEmptyOrSpace = typed.last.map { $0.isWhitespace } ?? true
        let startsInline = s.lowercased() == "a" && startsCommand(typed) && inline == nil
        let before = String(typed.dropLast(4))
        typed += s
        if typed.count > 600 { typed.removeFirst(typed.count - 600) }
        if cards.model.content?.isNotice == true { hideCard() }
        if fixState != nil { scheduleRelayout() }

        if startsInline {
            beginInline("/lina", before: before)
            return false
        }
        if s == "/", wasEmptyOrSpace, !tips.hasSeen(.slash) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.tips.show(.slash, under: AX.snapshot()?.caretRect) }
            }
        }

        switch ch {
        case ".", "?", "!":
            sentenceWaiting = true
            scheduleSentenceCheck()
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

    private func mouseDown() {
        typed = ""
        tips.hide()
        let p = NSEvent.mouseLocation
        // Clicking a fix or an option is a choice, not a dismissal.
        if (cards.isVisible && cards.frame.contains(p)) || (fixPanel.isVisible && fixPanel.frame.contains(p)) { return }
        if let command = inline {
            if command.running { inline?.dirty = true } else { endInline() }
        }
        if cards.isVisible || fixState != nil { dismiss() }
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

    // MARK: Talking

    /// Holding ⌃⌥ on their own for a moment starts listening; letting go runs what was said as a command.
    private func flagsChanged(_ flags: CGEventFlags) {
        let held = flags.contains(.maskControl) && flags.contains(.maskAlternate)
            && !flags.contains(.maskCommand) && !flags.contains(.maskShift)
        if held {
            guard settings.talkEnabled, settings.enabled, talkHold == nil, !voiceInput.isListening,
                  !Self.linaIsInFront, inline == nil, isTrusted else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.startListening() }
            }
            talkHold = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        } else {
            talkHold?.cancel()
            talkHold = nil
            if voiceInput.isListening { stopListening() }
        }
    }

    private func startListening() {
        talkHold = nil
        tips.hide()
        hideCard()
        Task { [weak self] in
            guard let self else { return }
            guard await self.voiceInput.start() else {
                Diagnostics.log("voice", "couldn't start listening")
                self.notice(VoiceInput.isAvailable
                            ? "I need the microphone and speech recognition. Allow them in System Settings → Privacy & Security."
                            : "Talking needs the app build (scripts/build-app.sh).",
                            .worried, at: AX.snapshot(requireCaret: false)?.caretRect ?? self.mouseAnchor, seconds: 5)
                return
            }
            Diagnostics.log("voice", "listening")
            self.set(.listening)
        }
    }

    private func stopListening() {
        Task { [weak self] in
            guard let self else { return }
            let said = await self.voiceInput.stop()
            self.set(.ready)
            Diagnostics.log("voice", "heard \(said.count) chars")
            guard !said.isEmpty else { return }
            self.runSpoken(said)
        }
    }

    /// What the writer said becomes a `/lina …` command at the caret, run just as if they had typed it.
    private func runSpoken(_ said: String) {
        guard settings.enabled, !Self.linaIsInFront, inline == nil,
              let app = NSWorkspace.shared.frontmostApplication else { return }
        var body = said
        if body.lowercased().hasPrefix("lina") { body = String(body.dropFirst(4)).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }
        let text = "/lina " + body
        let before = typed
        TextInserter.type(text)
        typed += text
        inline = Inline(pid: app.processIdentifier, text: text, before: before)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                self?.markInline()
                self?.runInline()
            }
        }
    }

    private var mouseAnchor: CGRect {
        CGRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - 20, width: 1, height: 18)
    }

    // MARK: Ask when I pause

    /// Opt-in: after the writer stops for `askPause` seconds, Lina asks her one question, as if they typed /lina.
    private func scheduleAsk() {
        pendingAsk?.cancel()
        guard settings.askOnPause, settings.enabled else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.askAfterPause() }
        }
        pendingAsk = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(2, settings.askPause), execute: work)
    }

    private func askAfterPause() {
        guard settings.askOnPause, settings.enabled, settings.isModelConfigured, isTrusted, !Self.linaIsInFront,
              inline == nil, fixState == nil, cards.model.content == nil, !voiceInput.isListening,
              let snap = AX.snapshot(requireCaret: false), !settings.disabledApps.contains(snap.bundleID),
              snap.selection.length == 0
        else { return }
        let about = snap.text.substring(to: snap.selection.location).trimmingCharacters(in: .whitespacesAndNewlines)
        // Only once per stretch of new writing, and only when there's enough to think about.
        guard WordCount.count(about) >= 25, remember("ask|\(snap.bundleID)|\(about.suffix(160))") else { return }
        Diagnostics.log("ask", "asking after a pause in \(snap.appName)")
        question(about: String(about.suffix(4000)), app: snap.appName, anchor: anchor(snap, at: max(0, snap.selection.location - 1)))
    }

    // MARK: Inline commands

    /// The ⌥ Space shortcut types "/lina " for the writer and starts a command right there.
    func askNow() {
        guard settings.enabled, !Self.linaIsInFront, inline == nil else { refreshStatus(); return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let before = typed
        TextInserter.type("/lina ")
        typed += "/lina "
        inline = Inline(pid: app.processIdentifier, text: "/lina ", before: before)
        set(.listening)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated { self?.markInline() }
        }
    }

    private func beginInline(_ text: String, before: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        tips.hide()
        hideCard()
        closeFixes()
        inline = Inline(pid: app.processIdentifier, text: text, before: before)
        set(.listening)
        markSoon()
        if !tips.hasSeen(.listening) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.tips.show(.listening, under: AX.snapshot()?.caretRect) }
            }
        }
    }

    /// Redraws the mark after the app has taken the keystroke.
    private func markSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated { self?.markInline() }
        }
    }

    private func markInline() {
        guard let command = inline else { commandMark.hide(); return }
        let waiting = cards.isVisible && cards.model.content?.isPersistent == true
        let state: CommandMark.State = command.running ? (waiting ? .waiting : .running) : .typing
        guard let snap = AX.snapshot(requireCaret: false), snap.pid == command.pid else {
            commandMark.show(band: nil, caret: command.anchor, state: state)
            return
        }
        var band: CGRect?
        if let range = commandRange(command, in: snap) {
            band = AX.screenRect(of: range, in: snap.element)
        }
        var caret = snap.caretRect
        if band == nil, caret == nil, let frame = AX.frame(of: snap.element) {
            // Some search boxes won't say where their text is: put the tag inside the field's right end.
            caret = CGRect(x: max(frame.minX + 8, frame.maxX - 130), y: frame.midY - 9, width: 1, height: 18)
        }
        inline?.anchor = band ?? caret ?? command.anchor
        commandMark.show(band: band, caret: caret, state: state)
    }

    /// Where the command is in the field: right before the caret, or the last "/lina" before it.
    private func commandRange(_ command: Inline, in snap: FocusSnapshot) -> NSRange? {
        let text = snap.text
        let caret = min(snap.selection.location, text.length)
        let len = (command.text as NSString).length
        if caret >= len {
            let r = NSRange(location: caret - len, length: len)
            if text.substring(with: r).lowercased() == command.text.lowercased() { return r }
        }
        let window = NSRange(location: max(0, caret - 600), length: min(caret, 600))
        let found = text.range(of: CommandParser.trigger, options: [.backwards, .caseInsensitive], range: window)
        guard found.location != NSNotFound else { return nil }
        return NSRange(location: found.location, length: caret - found.location)
    }

    /// Stops treating the text as a command; the writer's text stays as it is.
    private func endInline() {
        inlineRun?.cancel()
        inline = nil
        commandMark.hide()
        if status == .listening { set(.ready) }
    }

    /// Esc while typing a command: it comes back out of the text.
    private func cancelInline() {
        guard let command = inline else { return }
        let spot = removalSpot(command)
        endInline()
        Writer.replace(spot, with: "")
    }

    /// The command and the space before it, in the field if it can be read, otherwise by keystrokes.
    private func removalSpot(_ command: Inline) -> Writer.Spot {
        if let snap = AX.snapshot(requireCaret: false), snap.pid == command.pid, var r = commandRange(command, in: snap) {
            if r.location > 0, snap.text.character(at: r.location - 1) == 0x20 {
                r = NSRange(location: r.location - 1, length: r.length + 1)
            }
            return Writer.spot(r, in: snap)
        }
        let len = (command.text as NSString).length + (command.before.hasSuffix(" ") ? 1 : 0)
        var spot = Writer.typed(len, pid: command.pid)
        if command.dirty { spot.backspaces = nil }
        return spot
    }

    /// Return, or a pause after , . ? !: run the command where it was typed.
    private func runInline() {
        guard var command = inline, !command.running else { return }
        inlineRun?.cancel()
        command.running = true
        inline = command
        let kind = CommandParser.parseBar(command.text)
        let len = (command.text as NSString).length
        let last = command.text.last
        let keepsMark = last.map { ",.!".contains($0) } ?? false
        let suffix = keepsMark ? String(last!) : ""
        let fallbackAnchor = command.anchor ?? CGRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - 20, width: 1, height: 18)

        let ctx: CommandContext
        if let snap = AX.snapshot(requireCaret: false), snap.pid == command.pid, let range = commandRange(command, in: snap) {
            var remove = range
            if remove.location > 0, snap.text.character(at: remove.location - 1) == 0x20 {
                remove = NSRange(location: remove.location - 1, length: remove.length + 1)
            }
            let body = keepsMark ? NSRange(location: range.location, length: range.length - 1) : range
            let text = snap.text
            let beforeStart = max(0, range.location - 600)
            let para = text.paragraphRange(for: NSRange(location: min(NSMaxRange(body), text.length), length: 0))
            let afterEnd = max(NSMaxRange(body), min(text.length, NSMaxRange(para)))
            let anchor = AX.screenRect(of: range, in: snap.element) ?? snap.caretRect ?? command.anchor
                ?? self.anchor(snap, at: range.location)
            ctx = CommandContext(snap: snap, start: range.location,
                                 answer: Writer.spot(body, in: snap), whole: Writer.spot(range, in: snap),
                                 remove: Writer.spot(remove, in: snap), suffix: "",
                                 before: text.substring(with: NSRange(location: beforeStart, length: range.location - beforeStart)),
                                 after: text.substring(with: NSRange(location: NSMaxRange(body), length: afterEnd - NSMaxRange(body))),
                                 anchor: anchor, app: snap.appName)
        } else {
            // The field can't be read: follow the keystrokes. The command is the last `len` characters typed.
            let pid = command.pid
            let spaceBefore = command.before.hasSuffix(" ") ? 1 : 0
            ctx = CommandContext(snap: nil, start: 0,
                                 answer: Writer.typed(len, pid: pid, before: command.before),
                                 whole: Writer.typed(len, pid: pid, before: command.before),
                                 remove: Writer.typed(len + spaceBefore, pid: pid),
                                 suffix: suffix, before: String(command.before.suffix(600)), after: "",
                                 anchor: fallbackAnchor, app: currentApp.name)
        }
        markInline()
        run(kind, ctx)
    }

    /// The command is done with: forget it and take down its mark.
    private func finishInline() {
        inlineRun?.cancel()
        inline = nil
        commandLeft = nil
        commandMark.hide()
    }

    /// The writer dismissed a command's card: take the command back out of the text.
    private func removeLeftCommand() {
        guard var spot = commandLeft else { return }
        if inline?.dirty == true, spot.range.location == NSNotFound { spot.backspaces = nil }
        commandLeft = nil
        Writer.replace(spot, with: "")
    }

    // MARK: What to do

    /// After the writer stops typing: check the sentences they finished since the last check.
    private func checkSentences() {
        sentenceWaiting = false
        guard settings.enabled, settings.checkSentences, settings.isModelConfigured, isTrusted, !Self.linaIsInFront,
              fixState == nil, !(cards.model.content?.isPersistent ?? false), inline == nil,
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
        Diagnostics.log("command", "\(Self.name(of: kind)) in \(ctx.app), field \(ctx.snap == nil ? "not readable" : "readable")")
        let anchor = ctx.anchor
        let needsModel: Bool = switch kind {
        case .help, .saved, .remember, .bug: false
        case .search: !settings.hasSearch
        default: true
        }
        if needsModel && !settings.isModelConfigured {
            Writer.replace(ctx.remove, with: "")
            finishInline()
            notice("Lina isn't connected yet. Sign in, or add a key in Settings.", .worried, at: anchor)
            return
        }
        let snap = ctx.snap

        switch kind {
        case .help:
            Writer.replace(ctx.remove, with: "")
            finishInline()
            show(.help, at: anchor)
            set(.waiting)
        case .saved:
            Writer.replace(ctx.remove, with: "")
            finishInline()
            onOpenSaved?()
        case let .model(filter):
            Writer.replace(ctx.remove, with: "")
            finishInline()
            showModels(filter: filter, anchor: anchor)
        case .ask:
            let about = (snap.map { $0.text.substring(to: ctx.start) } ?? ctx.before)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Writer.replace(ctx.remove, with: "")
            finishInline()
            guard WordCount.count(about) >= 3 else {
                notice("Write a few sentences first, then ask me.", .idle, at: anchor)
                return
            }
            question(about: String(about.suffix(4000)), app: ctx.app, anchor: anchor)
        case .fix:
            Writer.replace(ctx.remove, with: "")
            finishInline()
            guard let snap, let target = CommandParser.target(before: ctx.start, in: snap.text) else {
                notice(snap == nil ? "I can't read this field, so I can't check it. Questions and search still work here."
                                   : "There's nothing above to check yet.", .idle, at: anchor)
                return
            }
            proofread(passage: target, snap: snap, quiet: false)
        case .rewrite, .edit:
            guard let snap, let target = CommandParser.target(before: ctx.start, in: snap.text) else {
                Writer.replace(ctx.remove, with: "")
                finishInline()
                notice(ctx.snap == nil ? "I can't read this field, so I can't rewrite it here. Questions and search still work."
                                       : "Write the paragraph first, then ask me to rewrite it.", .idle, at: anchor)
                return
            }
            let passage = snap.text.substring(with: target)
            let whole = NSRange(location: target.location, length: NSMaxRange(ctx.whole.range) - target.location)
            commandLeft = ctx.remove
            if case let .rewrite(how) = kind {
                choices(title: how.isEmpty ? "Rewrites" : "Rewrites · \(how)", passage: passage,
                        messages: Prompts.rewrite(passage, how: how, voice: settings.voice, aboutMe: settings.writerNotes),
                        spot: Writer.spot(whole, in: snap), kind: .rewrite, app: ctx.app, prompt: "rewrite \(how)", anchor: anchor)
            } else if case let .edit(instruction) = kind {
                choices(title: "Edit · \(instruction)", passage: passage,
                        messages: Prompts.edit(passage, instruction: instruction, voice: settings.voice, aboutMe: settings.writerNotes),
                        spot: Writer.spot(whole, in: snap), kind: .edit, app: ctx.app, prompt: instruction, anchor: anchor)
            }
        case let .image(prompt):
            guard !prompt.isEmpty else {
                Writer.replace(ctx.remove, with: "")
                finishInline()
                notice("Tell me what to draw: /lina image a red bicycle in the snow.", .idle, at: anchor)
                return
            }
            guard settings.canMakePictures else {
                Writer.replace(ctx.remove, with: "")
                finishInline()
                notice("Pictures need a Lina account or a Nebius key.", .worried, at: anchor)
                return
            }
            commandLeft = ctx.remove
            image(prompt: prompt, spot: ctx.whole, app: ctx.app, anchor: anchor)
        case let .remember(note):
            Writer.replace(ctx.remove, with: "")
            finishInline()
            remember(note: note, ctx: ctx)
        case let .bug(note):
            Writer.replace(ctx.remove, with: "")
            finishInline()
            report(note: note, anchor: anchor)
        case let .gathered(how):
            let clippings = Clippings.shared.promptText
            guard !clippings.isEmpty else {
                Writer.replace(ctx.remove, with: "")
                finishInline()
                notice(settings.gatherClippings
                       ? "Nothing gathered yet. Copy a quote or take a screenshot, then ask again."
                       : "Turn on “Keep what I copy and screenshot” in Settings → Memory first.", .idle, at: anchor)
                return
            }
            let before = (snap.map { $0.text.substring(to: ctx.start) } ?? ctx.before)
            commandLeft = ctx.remove
            choices(title: how.isEmpty ? "From what you gathered" : "From what you gathered · \(how)",
                    passage: "\(Clippings.shared.items.count) clippings",
                    messages: Prompts.gathered(before: before, clippings: clippings, how: how,
                                               voice: settings.voice, aboutMe: settings.writerNotes),
                    spot: ctx.whole, kind: .edit, app: ctx.app, prompt: "gathered \(how)", anchor: anchor)
        case let .search(question):
            commandLeft = ctx.remove
            search(question, before: ctx.before, after: ctx.after, spot: ctx.answer, suffix: ctx.suffix,
                   app: ctx.app, anchor: anchor)
        }
    }

    /// The command's name without what the writer typed, for the log.
    private static func name(of kind: LinaCommand.Kind) -> String {
        switch kind {
        case .ask: "ask"
        case .fix: "fix"
        case .rewrite: "rewrite"
        case .edit: "edit"
        case .model: "model"
        case .image: "image"
        case .help: "help"
        case .saved: "saved"
        case .remember: "remember"
        case .gathered: "gathered"
        case .bug: "bug"
        case .search: "search"
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
        removeLeftCommand()
        finishInline()
        Diagnostics.log("error", error.localizedDescription)
        errorUntil = Date().addingTimeInterval(10)
        var message = error.localizedDescription
        if settings.isSignedIn && Self.isSignedOut(error) {
            // Usually a session that ran out while the Mac slept: renew it and let the writer try again.
            Account.shared.refreshSoon(force: true)
            message = "Lina is signing you back in. Try again in a moment."
        }
        if !quiet { notice(message, .worried, at: anchor, seconds: 6) }
        set(.error(message))
    }

    private static func isSignedOut(_ error: Error) -> Bool {
        if case .http(401, _)? = error as? LLMError { return true }
        if case .http(401, _)? = error as? GeminiError { return true }
        return false
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
        let messages = Prompts.question(text: text, appName: app, voice: settings.voice, aboutMe: settings.writerNotes)
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

    private func search(_ question: String, before: String, after: String, spot: Writer.Spot, suffix: String,
                        app: String, anchor: CGRect) {
        let grounded = settings.hasSearch
        let wikipedia = !grounded && settings.webLookup
        let gemini = settings.gemini
        let client = LLMClient(endpoint: settings.commandEndpoint)
        let voice = settings.voice, aboutMe = settings.writerNotes
        let gen = begin(grounded ? "Searching the web…" : wikipedia ? "Looking it up on Wikipedia…" : "Thinking it over…",
                        anchor: anchor)
        task = Task { [weak self] in
            do {
                let raw: String
                var sources: [WebSource] = []
                var suggestions = ""
                if grounded {
                    let answer = try await gemini.ask(
                        system: Prompts.searchSystem(voice: voice, aboutMe: aboutMe, grounded: true),
                        prompt: Prompts.searchUser(question: question, before: before, after: after))
                    raw = answer.text
                    sources = answer.sources
                    suggestions = answer.suggestionsHTML
                } else {
                    let pages = wikipedia ? ((try? await WebLookup.search(question)) ?? []) : []
                    sources = pages.map { WebSource(title: $0.title, url: $0.url.absoluteString) }
                    raw = try await client.complete(Prompts.search(question: question, before: before, after: after,
                                                                  voice: voice, aboutMe: aboutMe, pages: pages),
                                                    maxTokens: 220, temperature: 0.3)
                }
                guard let self, gen == self.generation else { return }
                let (fit, answer) = Answers.fitAndAnswer(raw)
                guard !fit.isEmpty else { throw LLMError.message("No answer came back. Try asking another way.") }
                let id = self.history.add(HistoryItem(kind: .search, app: app, prompt: question, result: answer, sources: sources))
                let withSource = sources.first.map { "\(fit) (\($0.site))" }
                self.action = .answer(spot, fit: fit, withSource: withSource, suffix: suffix, history: id)
                self.show(.answer(question: question, text: fit, sources: sources, grounded: grounded,
                                  suggestions: suggestions), at: anchor)
                self.set(.waiting)
            } catch {
                self?.fail(error, gen: gen, anchor: anchor, quiet: false)
            }
        }
    }

    /// `/lina remember`: the note typed after it, or the paragraph above when it says "this" or nothing.
    private func remember(note: String, ctx: CommandContext) {
        var text = note
        if ["", "this", "that", "it"].contains(note.lowercased()) {
            text = ctx.snap.flatMap { snap in
                CommandParser.target(before: ctx.start, in: snap.text).map { snap.text.substring(with: $0) }
            } ?? ""
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice("Tell me what to remember: /lina remember my sister's name is Noor.", .idle, at: ctx.anchor)
            return
        }
        let title = ctx.snap?.windowTitle ?? ""
        MemoryStore.shared.add(text, source: title.isEmpty ? ctx.app : "\(ctx.app) · \(title)")
        Diagnostics.log("memory", "saved \(text.count) chars")
        notice("Saved to my memory.", .happy, at: ctx.anchor, seconds: 2.4)
    }

    /// ⌃⌥M: whatever the writer highlighted goes into Lina's memory.
    func rememberSelection() {
        guard let snap = AX.snapshot(requireCaret: false), snap.selection.length > 0 else {
            Diagnostics.log("memory", "⌃⌥M with no readable selection")
            NSSound.beep()
            return
        }
        let text = snap.text.substring(with: snap.selection)
        MemoryStore.shared.add(text, source: snap.windowTitle.isEmpty ? snap.appName : "\(snap.appName) · \(snap.windowTitle)")
        Diagnostics.log("memory", "saved \(text.count) chars")
        notice("Saved to my memory.", .happy, at: anchor(snap, at: NSMaxRange(snap.selection) - 1), seconds: 2.4)
    }

    /// `/lina bug`: a report about this exact moment, saved, copied, and sent if the writer allows it.
    private func report(note: String, anchor: CGRect) {
        guard let url = Diagnostics.report(note, kind: "/lina bug") else {
            notice("I couldn't save the report.", .worried, at: anchor)
            return
        }
        guard settings.shareReports else {
            notice("Report copied. It's in ~/Library/Logs/Lina/reports.", .happy, at: anchor)
            return
        }
        notice("Report copied. Sending it to the Lina team…", .happy, at: anchor)
        Task { [weak self] in
            let sent = await Cloud.send(reportAt: url, kind: "/lina bug", note: note)
            self?.notice(sent ? "Report sent. Thank you." : "Couldn't send it, but it's copied and saved.",
                         sent ? .happy : .worried, at: anchor)
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
        case let .answer(spot, fit, withSource, suffix, id):
            let text = n == 2 ? (withSource ?? fit) : fit
            let ok = Writer.replace(spot) { before, after in Answers.fit(text, before: before, after: after) + suffix }
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
                removeLeftCommand()
                finishInline()
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
        // A successful choice replaced the command along with everything else; a failed one leaves it to be taken out.
        if ok { commandLeft = nil } else { removeLeftCommand() }
        finishInline()
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
        if inline != nil { markInline() }
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
        removeLeftCommand()
        finishInline()
        hideCard()
        closeFixes()
        tips.hide()
        refreshStatus()
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
