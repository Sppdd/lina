import AppKit
import Carbon.HIToolbox
import Combine

/// Lina's main way of helping: it reads what you're writing in any app and answers in ink, in a card just
/// above your cursor (or in the popup when the ink drop is off). What it does depends on the mode, cycled
/// with ⇧ + the companion shortcut:
/// - Understand thinks about it with you — what you seem to be saying, why, and where it could go —
///   and never types into your document; you can talk back to it.
/// - Edit offers a rewrite of each sentence you finish; ⇥ takes it, esc keeps yours.
/// - Auto rewrites each sentence you finish in place; ⌘Z undoes it like any edit.
///
/// In every mode, `/lina <instruction>` then Return works on the text right there: edit it, write
/// something new, turn it into a picture, or remember it.
@MainActor
final class Companion: ObservableObject {
    enum State: Equatable { case waiting, reading, thinking, paused, error(String) }

    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Lina's reading of the draft.
            case reflection(Reflection)
            /// The writer talking back.
            case writer(String)
            /// Lina answering the writer.
            case reply(String)
            /// The writer moved to another document.
            case place(String)
        }
        let id = UUID()
        var kind: Kind
        var streaming = false
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var state: State = .waiting
    /// Where the draft Lina is reading lives, e.g. "Notes · Letter to Dad".
    @Published private(set) var place = ""
    @Published private(set) var wordCount = 0
    /// Edit and Auto modes: Lina's rewrite of the sentence the writer just finished.
    @Published private(set) var proposal: Proposal?
    /// Briefly true after the mode changes, so the popup can say which mode Lina is in now.
    @Published private(set) var announcingMode = false

    struct Proposal: Equatable {
        var original: String
        var rewritten = ""
        var streaming = true
        /// Auto mode: already written into the draft.
        var applied = false
    }

    /// Where a proposal goes back to, and the draft exactly as Lina read it.
    private struct RewriteTarget {
        let pid: pid_t
        let text: NSString
        let caret: Int
        let found: Sentence.Found
    }

    private let settings = AppSettings.shared
    private var debounce: DispatchWorkItem?
    private var task: Task<Void, Never>?
    private var generation = 0
    /// The draft as Lina last read it, and where it came from.
    private var document = ""
    private var documentKey = ""
    private var lastReflectedWords = 0
    private var rewriteTarget: RewriteTarget?
    private var rewriteTask: Task<Void, Never>?
    /// Sentences already offered or written, so Lina doesn't rewrite its own rewrite.
    private var handledSentences: [String] = []
    private var lastTyped = Date.distantPast
    /// A reflection arrived while the writer was typing; show it at the next pause.
    private var unseen = false
    private var announceToken = UUID()
    private var bag = Set<AnyCancellable>()

    lazy var panel = CompanionPanel(companion: self)
    /// Lina's ink drop beside the caret.
    let ink = InkBuddy()
    private let voice = VoiceInput()
    private let speaker = Speaker()
    private var inkTimer: Timer?
    private var inkFollow: DispatchWorkItem?
    /// ⌃⌥ is down; Lina starts listening after a short hold so ⌃⌥-shortcuts don't trigger it.
    private var talkHeld = false
    private var talkPending: DispatchWorkItem?
    @Published private(set) var listening = false
    /// A `/lina` command is being carried out.
    @Published private(set) var working = false
    private var commandTask: Task<Void, Never>?
    /// The last things typed, so Return only looks for a `/lina` command after one was typed.
    private var typedTail = ""
    /// Whether the current rewrite is shown in ink (or in the popup, when the drop is off).
    private var proposalInInk = false
    /// The last reflection, to show at the next pause if it arrived while the writer was typing.
    private var lastReflection: Reflection?

    init() {
        settings.$companionEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                guard let self else { return }
                if on { self.schedule(after: 300) } else { self.cancel(); self.panel.hide() }
            }
            .store(in: &bag)
        // Start reading as soon as the writer finishes onboarding.
        settings.$hasOnboarded
            .dropFirst()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.start() }
            .store(in: &bag)
        settings.$companionMode
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.dropProposal() }
            .store(in: &bag)
        // The drop's mood follows what Lina is doing.
        Publishers.CombineLatest4($state, $proposal, $listening, $working)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncInkState() }
            .store(in: &bag)
        $proposal
            .receive(on: RunLoop.main)
            .sink { [weak self] p in self?.renderProposal(p) }
            .store(in: &bag)
        voice.onLevel = { [weak self] level in self?.ink.model.audioLevel = level }
        inkTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInk() }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func start() {
        if settings.companionEnabled { schedule(after: 300) }
    }

    /// The companion shortcut: in Edit or Auto, rewrite the sentence at the cursor now;
    /// otherwise open the popup above the cursor to talk with Lina.
    func toggle() {
        if panel.isVisible {
            // Already showing a reflection: the shortcut moves into the reply field. Otherwise it closes.
            if panel.isKey || proposal != nil || announcingMode { dismiss() } else { panel.focusInput() }
            return
        }
        if settings.companionMode != .understand, rewriteSentence(finishedOnly: false) { return }
        present()
        panel.focusInput()
        if entries.isEmpty { read(force: true) }
    }

    /// ⇧ + the companion shortcut: Understand → Edit → Auto, like cycling modes in Claude Code.
    func cycleMode() {
        settings.companionMode = settings.companionMode.next
        if ink.isVisible && !panel.isVisible {
            ink.say(Self.modeNote(settings.companionMode))
            return
        }
        let wasVisible = panel.isVisible
        announcingMode = true
        present()
        let token = UUID()
        announceToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.announceToken == token else { return }
                self.announcingMode = false
                if !wasVisible && !self.panel.isKey && self.proposal == nil { self.panel.hide() }
            }
        }
    }

    private static func modeNote(_ mode: CompanionMode) -> String {
        switch mode {
        case .understand: "understand · I'll read along"
        case .edit: "edit · ⇥ takes my rewrite"
        case .auto: "auto · I'll polish as you go"
        }
    }

    /// Hide the popup and Lina's card; the writer keeps going.
    func dismiss() {
        ink.cancelPointing()
        dropProposal()
        announcingMode = false
        if !working { ink.clearCard() }
        panel.hide()
    }

    /// Shows the popup just above the writer's cursor. It takes over from the ink card.
    private func present(at caret: CGRect? = nil) {
        unseen = false
        if !working { ink.clearCard() }
        panel.show(above: caret ?? currentCaret())
    }

    /// Lina writes in ink above the caret whenever the drop is there to do it.
    private var useInk: Bool { settings.inkEnabled && ink.isVisible && !panel.isVisible }

    private func currentCaret() -> CGRect? {
        if DeskRegistry.shared.activeTarget != nil, let tv = DeskRegistry.shared.textView {
            let r = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
            return r == .zero ? nil : r
        }
        return AX.snapshot(requireCaret: false)?.caretRect
    }

    // MARK: Watching

    /// Called for every keystroke the writer makes anywhere. Lina reads again once they pause.
    func writerTyped() {
        guard settings.companionEnabled, !panel.isKey else { return }
        lastTyped = Date()
        ink.cancelPointing()
        followCaretSoon()
        // Get out of the way while they write; Lina speaks again at the next pause.
        // (An offered rewrite no longer matches the draft once they type, so it goes too.)
        dropProposal()
        announcingMode = false
        if !working { ink.clearCard() }
        panel.hide()
        schedule(after: settings.companionMode == .understand ? nil : Self.rewritePauseMs)
    }

    /// Called when the writer switches apps or windows.
    func focusChanged() {
        typedTail = ""
        guard settings.companionEnabled else { return }
        if !panel.isKey { dismiss() }
        ink.hide()
        followCaretSoon()
        schedule(after: 900)
    }

    /// A click anywhere. Clicking outside the popup moves the cursor, so the popup goes away.
    func mouseDown() {
        typedTail = ""
        ink.cancelPointing()
        followCaretSoon()
        guard panel.isVisible, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        dismiss()
    }

    /// Keys the writer presses in any app while the popup is up. Returns true to swallow the key.
    func handleKey(_ event: CGEvent) -> Bool {
        // A key while ⌃⌥ is held is a shortcut, not talking.
        if talkHeld { cancelTalking() }
        if watchForCommand(event) { return true }
        guard panel.isVisible || ink.hasCard else { return false }
        let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case kVK_Tab where proposal.map { !$0.streaming && !$0.applied && !$0.rewritten.isEmpty } ?? false:
            acceptProposal()
            return true
        case kVK_Escape:
            if working { cancelCommand() } else { dismiss() }
            return true
        default:
            return false
        }
    }

    /// How long a pause after a finished sentence before Edit and Auto rewrite it.
    static let rewritePauseMs = 1000.0

    private func schedule(after ms: Double? = nil) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.read(force: false) }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (ms ?? settings.companionPauseMs) / 1000, execute: work)
    }

    /// "Think again" from the window: read the draft now, even if little has changed.
    func thinkNow() { read(force: true) }

    private struct Draft {
        var text: String
        var focus: String
        var appName: String
        var title: String
        var caret: CGRect?
        var key: String { "\(appName)|\(title)" }
    }

    /// The draft in front of the writer: any app through Accessibility, or Lina's own Desk.
    private func currentDraft() -> Draft? {
        if let desk = DeskRegistry.shared.activeTarget {
            let ctx = desk.context
            return Draft(text: ctx.before + ctx.after, focus: desk.focusText, appName: "Desk",
                         title: DeskStore.shared.current?.title ?? "", caret: currentCaret())
        }
        guard let snap = AX.snapshot(requireCaret: false), !settings.disabledApps.contains(snap.bundleID) else { return nil }
        return Draft(text: snap.text as String, focus: snap.paragraph, appName: snap.appName, title: snap.windowTitle,
                     caret: snap.caretRect)
    }

    private func read(force: Bool) {
        guard settings.companionEnabled else { state = .paused; return }
        guard settings.isModelConfigured else { state = .error(LLMError.notConfigured.localizedDescription); return }
        if settings.companionMode != .understand && !force {
            rewriteSentence(finishedOnly: true)
            return
        }
        guard let draft = currentDraft() else {
            Diagnostics.log("read", "no readable text field in front")
            if state != .thinking { state = .waiting }
            return
        }
        let words = WordCount.count(draft.text)
        let moved = draft.key != documentKey
        // Only speak up when there's something new to think about.
        guard words >= 12, force || moved || abs(words - lastReflectedWords) >= 12 else {
            document = draft.text
            wordCount = words
            if unseen && !panel.isVisible {
                if useInk, let r = lastReflection { unseen = false; ink.show(reflectionCard(r)) } else { present(at: draft.caret) }
            }
            return
        }
        if moved {
            documentKey = draft.key
            place = draft.title.isEmpty ? draft.appName : "\(draft.appName) · \(draft.title)"
            if !entries.isEmpty { append(.init(kind: .place(place))) }
        }
        document = draft.text
        wordCount = words
        lastReflectedWords = words
        Diagnostics.log("read", "reflecting on \(words) words in \(draft.appName) (\(useInk ? "ink card" : "popup"))")
        reflect(on: draft)
    }

    private func reflect(on draft: Draft) {
        let earlier = entries.compactMap { entry -> String? in
            if case let .reflection(r) = entry.kind { return r.ask.isEmpty ? r.hearing : r.ask }
            return nil
        }
        let messages = Prompts.reflection(document: draft.text, focus: draft.focus, appName: draft.appName,
                                          title: draft.title, voice: settings.voice, aboutMe: settings.writerNotes,
                                          earlier: earlier)
        let id = append(.init(kind: .reflection(Reflection()), streaming: true))
        let caret = draft.caret
        let inInk = useInk
        var shown = false
        run(messages, maxTokens: 400, temperature: 0.6, into: id, onPiece: { [weak self] kind in
            // Speak up with the first words, unless the writer is already typing again.
            guard let self, case let .reflection(r) = kind else { return }
            self.lastReflection = r
            let paused = Date().timeIntervalSince(self.lastTyped) * 1000 >= self.settings.companionPauseMs * 0.8
            guard paused else { self.unseen = true; return }
            if inInk {
                // Written in ink just above the caret, as it comes.
                self.unseen = false
                if !self.working { self.ink.show(self.reflectionCard(r, streaming: true)) }
            } else if !shown {
                shown = true
                self.present(at: caret)
            }
        }, onDone: { [weak self] kind in
            guard let self, case let .reflection(r) = kind else { return }
            self.lastReflection = r
            if inInk, !self.unseen, !self.working, self.ink.hasCard { self.ink.show(self.reflectionCard(r)) }
            if self.settings.speakAloud { self.speaker.say(r.ask) }
            // Like Clicky pointing at a button: show the writer where the thread lives in their own words.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, Date().timeIntervalSince(self.lastTyped) > 1.5 else { return }
                    self.showThread(r.quote)
                }
            }
        }) { raw in .reflection(Reflection.parse(raw)) }
    }

    // MARK: Rewriting (Edit and Auto)

    /// Rewrites the sentence at the cursor. Returns false when there's no sentence to work on.
    @discardableResult
    private func rewriteSentence(finishedOnly: Bool, instruction: String? = nil) -> Bool {
        guard settings.isModelConfigured,
              let snap = AX.snapshot(requireCaret: false), !settings.disabledApps.contains(snap.bundleID),
              snap.selection.length == 0,
              let found = Sentence.find(in: snap.text, caret: snap.selection.location, finishedOnly: finishedOnly)
        else { return false }
        // Don't go around again on a sentence Lina already offered or wrote — unless asked to.
        if finishedOnly && handledSentences.contains(found.text) { return false }
        // Only right after the writer finished it, not when they come back to a document later.
        if finishedOnly && Date().timeIntervalSince(lastTyped) > 10 { return false }
        Diagnostics.log("rewrite", "sentence of \(found.text.count) chars, \(settings.companionMode.title) mode\(instruction == nil ? "" : ", spoken instruction")")
        remember(found.text)

        rewriteTask?.cancel()
        let target = RewriteTarget(pid: snap.pid, text: snap.text, caret: snap.selection.location, found: found)
        rewriteTarget = target
        proposalInInk = useInk
        proposal = Proposal(original: found.text)
        announcingMode = false
        if !proposalInInk { present(at: snap.caretRect) }

        let before = snap.text.substring(to: found.range.location)
        let messages = Prompts.rewriteSentence(found.text, before: before, instruction: instruction,
                                               voice: settings.voice, aboutMe: settings.writerNotes)
        let client = LLMClient(endpoint: settings.endpoint)
        let auto = settings.companionMode == .auto
        rewriteTask = Task { [weak self] in
            var raw = ""
            do {
                for try await piece in client.stream(messages, maxTokens: 200, temperature: 0.3) {
                    guard let self, !Task.isCancelled, self.proposal?.original == found.text else { return }
                    raw += piece
                    self.proposal?.rewritten = Sentence.clean(raw, original: found.text)
                }
                guard let self, !Task.isCancelled, self.proposal?.original == found.text else { return }
                let rewritten = Sentence.clean(raw, original: found.text)
                // Nothing worth changing: stay quiet.
                guard !rewritten.isEmpty, rewritten != found.text else { self.dismiss(); return }
                self.remember(rewritten)
                self.proposal?.rewritten = rewritten
                self.proposal?.streaming = false
                if auto { self.acceptProposal() }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                guard let self, self.proposal?.original == found.text else { return }
                self.dropProposal()
                Diagnostics.log("model", "error: \(error.localizedDescription)")
                self.state = .error(error.localizedDescription)
                self.panel.hide()
            }
        }
        return true
    }

    /// Writes the rewrite over the writer's sentence, if the draft is still exactly as Lina read it.
    func acceptProposal() {
        guard let p = proposal, !p.streaming, !p.applied, !p.rewritten.isEmpty, let t = rewriteTarget else { return }
        guard let now = AX.snapshot(requireCaret: false), now.pid == t.pid, now.text.isEqual(to: t.text as String),
              now.selection.location == t.caret
        else {
            Diagnostics.log("rewrite", "not written: the draft changed since Lina read it")
            dismiss()
            return
        }
        AX.select(t.found.range, in: now.element)
        TextInserter.paste(p.rewritten + t.found.trailing)
        if settings.companionMode == .auto {
            // Show what changed for a moment, then get out of the way.
            proposal?.applied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let shown = self.proposal, shown.applied, shown.original == p.original else { return }
                    self.dismiss()
                }
            }
        } else {
            dismiss()
        }
    }

    private func dropProposal() {
        rewriteTask?.cancel()
        proposal = nil
        rewriteTarget = nil
    }

    private func remember(_ sentence: String) {
        handledSentences.append(sentence)
        if handledSentences.count > 40 { handledSentences.removeFirst() }
    }

    // MARK: Ink

    private func followCaretSoon() {
        inkFollow?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshInk() } }
        inkFollow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Keeps the drop beside the caret, and out of sight when there's nowhere to write.
    private func refreshInk() {
        // With the drop switched off it still comes out to say something, like a `/lina` command finishing.
        let busy = working || ink.hasCard || ink.isSaying
        guard settings.hasOnboarded, (settings.inkEnabled && settings.companionEnabled) || busy else { ink.hide(); return }
        if ink.isPointing { return }
        // While the popup is up it's the one talking; the drop steps aside (unless it's listening).
        if panel.isVisible && !listening { ink.hide(); return }
        guard let caret = inkCaret() else {
            if ink.isVisible { Diagnostics.log("ink", "hid: no caret reported in \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")") }
            ink.hide()
            return
        }
        let appearing = !ink.isVisible
        ink.follow(caret)
        if appearing && !UserDefaults.standard.bool(forKey: "inkWelcomed") {
            UserDefaults.standard.set(true, forKey: "inkWelcomed")
            ink.say("hi, i'm lina", hold: 2.5)
        }
    }

    private func inkCaret() -> CGRect? {
        if DeskRegistry.shared.activeTarget != nil { return currentCaret() }
        guard let found = AX.caret(), !settings.disabledApps.contains(found.bundleID) else { return nil }
        return found.rect
    }

    private func syncInkState() {
        guard !ink.isPointing else { return }
        if listening { ink.model.state = .listening }
        else if working || state == .thinking || proposal?.streaming == true { ink.model.state = .thinking }
        else { ink.model.state = .resting }
    }

    private func reflectionCard(_ r: Reflection, streaming: Bool = false) -> InkCard {
        InkCard(eyebrow: "lina hears", text: r.hearing, detail: r.ask,
                hint: streaming ? "" : "\(settings.hotKey.title) to reply · hold ⌃⌥ to talk · esc", streaming: streaming)
    }

    /// Edit and Auto: the rewrite, written in ink over the sentence it would replace.
    private func renderProposal(_ p: Proposal?) {
        guard proposalInInk, !working else { return }
        guard let p else { ink.clearCard(); return }
        let hint = p.applied ? "⌘Z undoes it" : p.streaming ? "" : "⇥ use it · esc keep mine"
        ink.show(InkCard(eyebrow: p.applied ? "rewritten" : "rewrite", text: p.rewritten.isEmpty ? "…" : p.rewritten,
                         original: p.original, hint: hint, streaming: p.streaming))
    }

    private static let threadNotes = ["stay with this", "this thread", "there's more here", "follow this"]

    /// Flies the drop to the words the reflection's thread lives in, and underlines them.
    func showThread(_ quote: String) {
        guard settings.inkEnabled, !quote.isEmpty, let caret = currentCaret(), let phrase = rectOfPhrase(quote) else { return }
        ink.follow(caret)
        ink.point(at: phrase, note: Self.threadNotes.randomElement() ?? "this thread")
    }

    /// Where the writer's own words sit on screen. Falls back to the quote's first words if the model
    /// changed the ending a little.
    private func rectOfPhrase(_ quote: String) -> CGRect? {
        let words = quote.split(separator: " ")
        let tries = [quote] + (words.count > 4 ? [words.prefix(4).joined(separator: " ")] : [])
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let rect: CGRect?
        if DeskRegistry.shared.activeTarget != nil, let tv = DeskRegistry.shared.textView {
            let text = tv.string as NSString
            guard let range = tries.lazy.map({ text.range(of: $0, options: options) }).first(where: { $0.location != NSNotFound })
            else { return nil }
            rect = tv.firstRect(forCharacterRange: range, actualRange: nil)
        } else {
            guard let snap = AX.snapshot(requireCaret: false),
                  let range = tries.lazy.map({ snap.text.range(of: $0, options: options) }).first(where: { $0.location != NSNotFound })
            else { return nil }
            rect = AX.screenRect(for: range, in: snap.element)
        }
        // Only point at words the writer can actually see.
        guard let rect, rect.width > 1, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) else { return nil }
        return rect
    }

    // MARK: Hold ⌃⌥ to talk

    func modifiersChanged(_ flags: CGEventFlags) {
        guard settings.talkEnabled, settings.companionEnabled, VoiceInput.isAvailable else { return }
        let held = flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]) == [.maskControl, .maskAlternate]
        if held && !talkHeld {
            talkHeld = true
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.startTalking() } }
            talkPending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        } else if !held && talkHeld {
            talkHeld = false
            talkPending?.cancel()
            if listening { finishTalking() }
        }
    }

    private func startTalking() {
        guard talkHeld, !listening else { return }
        speaker.stop()
        ink.cancelPointing()
        let caret = currentCaret()
        listening = true
        if !panel.isKey { panel.hide() }
        if let caret, settings.inkEnabled { ink.follow(caret) }
        Task { [weak self] in
            guard let self else { return }
            let started = await self.voice.start()
            guard started else {
                Diagnostics.log("talk", "couldn't start listening (microphone or speech permission)")
                self.listening = false
                self.ink.say("I need the microphone and speech recognition", hold: 3)
                return
            }
            // Let go while macOS was asking for permission.
            if !self.talkHeld { self.finishTalking() }
        }
    }

    private func finishTalking() {
        Task { [weak self] in
            guard let self else { return }
            let said = await self.voice.stop()
            self.listening = false
            guard !said.isEmpty else { self.ink.say("I didn't catch that"); return }
            self.heard(said)
        }
    }

    private func cancelTalking() {
        talkHeld = false
        talkPending?.cancel()
        guard listening else { return }
        voice.cancel()
        listening = false
    }

    /// In Edit or Auto, what you say is how to rewrite the sentence at the cursor; otherwise it's your answer.
    private func heard(_ said: String) {
        if settings.companionMode != .understand, rewriteSentence(finishedOnly: false, instruction: said) { return }
        present()
        send(said)
    }

    // MARK: /lina commands

    /// Where a `/lina` command was typed, and the draft exactly as Lina read it.
    private struct CommandSite {
        let text: NSString
        let caret: Int
        let caretRect: CGRect?
        let source: String
        /// The field in another app; nil for the Desk.
        let element: AXUIElement?
        let pid: pid_t
    }

    private enum Writing {
        case text(String)
        case image(Data, fallback: String)
    }

    /// Keeps a short memory of what was typed; on Return after a `/lina …`, carries the command out
    /// instead of starting a new line. Returns true to swallow the key.
    private func watchForCommand(_ event: CGEvent) -> Bool {
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { typedTail = ""; return false }
        switch event.keyCode {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            defer { typedTail = "" }
            guard typedTail.lowercased().contains("/lina "), !flags.contains(.maskShift), !flags.contains(.maskAlternate)
            else { return false }
            return runCommandAtCaret()
        case kVK_Delete:
            if !typedTail.isEmpty { typedTail.removeLast() }
        default:
            let typed = event.typedString
            guard !typed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { break }
            typedTail = String((typedTail + typed).suffix(400))
        }
        return false
    }

    private func runCommandAtCaret() -> Bool {
        guard let site = commandSite() else {
            Diagnostics.log("command", "return after /lina, but the text field couldn't be read (selection, paused app, or no Accessibility)")
            return false
        }
        guard let cmd = LinaCommand.find(in: site.text, caret: site.caret) else {
            Diagnostics.log("command", "return after /lina, but no command ends at the caret (caret \(site.caret) of \(site.text.length))")
            return false
        }
        if let rect = site.caretRect { ink.follow(rect) }
        guard settings.isModelConfigured || cmd.kind == .remember else {
            ink.say("add your Nebius key in Settings first", hold: 3)
            return true
        }
        perform(cmd, at: site)
        return true
    }

    private func commandSite() -> CommandSite? {
        if DeskRegistry.shared.activeTarget != nil, let tv = DeskRegistry.shared.textView {
            let sel = tv.selectedRange()
            guard sel.length == 0 else { return nil }
            return CommandSite(text: NSString(string: tv.string), caret: sel.location, caretRect: currentCaret(),
                               source: "Desk", element: nil, pid: 0)
        }
        guard let snap = AX.snapshot(requireCaret: false), !settings.disabledApps.contains(snap.bundleID),
              snap.selection.length == 0
        else { return nil }
        let source = snap.windowTitle.isEmpty ? snap.appName : "\(snap.appName) · \(snap.windowTitle)"
        return CommandSite(text: snap.text, caret: snap.selection.location, caretRect: snap.caretRect,
                           source: source, element: snap.element, pid: snap.pid)
    }

    private func perform(_ cmd: LinaCommand, at site: CommandSite) {
        commandTask?.cancel()
        ink.cancelPointing()
        dropProposal()
        panel.hide()
        let commandText = site.text.substring(with: cmd.range)
        Diagnostics.log("command", "\(cmd.kind) in \(site.source.split(separator: "·").first.map(String.init) ?? site.source): instruction \(cmd.instruction.count) chars, target \(cmd.target.length) chars, same line \(cmd.targetOnSameLine)")
        switch cmd.kind {
        case .report:
            // Describe the field before touching it, so the report shows the moment the writer saw.
            let focus = site.element == nil ? "- The Desk: \(site.text.length) characters, caret at \(site.caret)" : AX.describeFocus()
            write(.text(""), over: cmd.range, expecting: commandText, in: site)
            let kind = "Reported with /lina bug, right where it happened"
            let saved = Diagnostics.report(cmd.reportNote, kind: kind, focus: focus)
            guard let saved else { ink.say("I couldn't save the report", hold: 3); return }
            guard settings.shareReports else { ink.say("report copied · paste it to Claude", hold: 3); return }
            ink.say("report copied · sending it…", hold: 3)
            let note = cmd.reportNote
            Task { [weak self] in
                let ok = await Cloud.send(reportAt: saved, kind: kind, note: note)
                self?.ink.say(ok ? "report sent to the Lina team" : "couldn't send it · it's saved and copied", hold: 3)
            }
        case .remember:
            let text = cmd.memoryText
            guard !text.isEmpty else { ink.say("there's nothing above to remember"); return }
            MemoryStore.shared.add(text, source: site.source)
            // The command has done its job; take it out of the draft.
            write(.text(""), over: cmd.range, expecting: commandText, in: site)
            ink.say("I'll remember that", hold: 2.4)
        case .write, .image:
            working = true
            let doing = cmd.kind == .image ? "drawing it…" : cmd.target.length > 0 ? "working on the text above…" : "writing…"
            ink.show(InkCard(eyebrow: "/lina " + cmd.instruction, text: doing, hint: "esc stops", streaming: true))
            commandTask = Task { [weak self] in await self?.carryOut(cmd, at: site, commandText: commandText) }
        }
    }

    private func carryOut(_ cmd: LinaCommand, at site: CommandSite, commandText: String) async {
        let client = LLMClient(endpoint: settings.companionEndpoint)
        do {
            switch cmd.kind {
            case .image:
                let described = try await client.complete(
                    Prompts.imagePrompt(description: cmd.targetText, instruction: cmd.instruction),
                    maxTokens: 200, temperature: 0.7)
                let prompt = described.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
                try Task.checkCancellation()
                ink.show(InkCard(eyebrow: "/lina " + cmd.instruction, text: "drawing it…",
                                 detail: "", original: "", hint: prompt.isEmpty ? "esc stops" : prompt, streaming: true))
                let png = try await settings.imageClient.generate(prompt.isEmpty ? cmd.instruction : prompt)
                try Task.checkCancellation()
                let file = try ImageClient.save(png, named: prompt.isEmpty ? cmd.instruction : prompt)
                let alt = String((cmd.targetText.isEmpty ? cmd.instruction : cmd.targetText).prefix(60))
                    .replacingOccurrences(of: "\n", with: " ")
                guard write(.image(png, fallback: "![\(alt)](\(file.absoluteString))"), over: cmd.range,
                            expecting: commandText, in: site)
                else { return finishCommand("the text changed, so I kept the picture in Pictures/Lina") }
                finishCommand("there it is · also in Pictures/Lina")
            case .write:
                let before = site.text.substring(to: cmd.target.length > 0 ? cmd.target.location : cmd.range.location)
                let after = site.text.substring(from: NSMaxRange(cmd.range))
                let raw = try await client.complete(
                    Prompts.command(cmd.instruction, target: cmd.targetText, before: before, after: after,
                                    voice: settings.voice, aboutMe: settings.writerNotes),
                    maxTokens: 1500, temperature: 0.5)
                try Task.checkCancellation()
                let reply = CommandReply.parse(raw, hasTarget: cmd.target.length > 0)
                Diagnostics.log("command", "model answered \(raw.count) chars → \(reply.replace ? "replace" : "insert") \(reply.text.count) chars")
                guard !reply.text.isEmpty else { return finishCommand("I couldn't do that one") }
                let wrote: Bool
                if reply.replace {
                    // Keep the line breaks between the paragraph and the command, so the caret lands below it.
                    let replacement = reply.text + (cmd.targetOnSameLine ? "" : cmd.gap)
                    wrote = write(.text(replacement), over: cmd.replaceRange,
                                  expecting: site.text.substring(with: cmd.replaceRange), in: site)
                } else {
                    wrote = write(.text(reply.text), over: cmd.range, expecting: commandText, in: site)
                }
                finishCommand(wrote ? "done · ⌘Z undoes" : "the text changed, so I left it")
            case .remember, .report:
                break
            }
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            guard !Task.isCancelled else { return }
            Diagnostics.log("command", "failed: \(error.localizedDescription)")
            working = false
            let card = InkCard(eyebrow: "couldn't finish /lina " + cmd.instruction, text: error.localizedDescription, hint: "esc")
            ink.show(card)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                MainActor.assumeIsolated { if self?.ink.model.card == card { self?.ink.clearCard() } }
            }
        }
    }

    private func finishCommand(_ note: String) {
        Diagnostics.log("command", "finished: \(note)")
        working = false
        commandTask = nil
        ink.clearCard()
        ink.say(note, hold: 2.8)
    }

    private func cancelCommand() {
        commandTask?.cancel()
        commandTask = nil
        working = false
        ink.clearCard()
        ink.say("stopped")
    }

    /// Writes over `range`, but only if that part of the draft still says what Lina read.
    @discardableResult
    private func write(_ writing: Writing, over range: NSRange, expecting original: String, in site: CommandSite) -> Bool {
        guard let element = site.element else {
            guard let tv = DeskRegistry.shared.textView else { return false }
            let now = tv.string as NSString
            guard NSMaxRange(range) <= now.length, now.substring(with: range) == original else { return false }
            switch writing {
            case let .text(s): tv.insertText(s, replacementRange: range)
            // The Desk is plain text: a link to the picture.
            case let .image(_, fallback): tv.insertText(fallback, replacementRange: range)
            }
            return true
        }
        guard let now = AX.snapshot(requireCaret: false), now.pid == site.pid,
              NSMaxRange(range) <= now.text.length, now.text.substring(with: range) == original
        else {
            Diagnostics.log("write", "skipped: the field changed or lost focus since Lina read it")
            return false
        }
        AX.select(range, in: CFEqual(now.element, element) ? element : now.element)
        switch writing {
        case let .text(s) where s.isEmpty: TextInserter.deleteSelection()
        case let .text(s): TextInserter.paste(s)
        case let .image(png, fallback): TextInserter.paste(image: png, fallback: fallback)
        }
        return true
    }

    // MARK: Memory

    /// ⌃⌥M: whatever the writer highlighted goes into Lina's memory.
    func rememberSelection() {
        cancelTalking()
        var text = ""
        var rect: CGRect?
        var source = "Desk"
        if DeskRegistry.shared.activeTarget != nil, let tv = DeskRegistry.shared.textView {
            let sel = tv.selectedRange()
            if sel.length > 0 {
                text = (tv.string as NSString).substring(with: sel)
                rect = tv.firstRect(forCharacterRange: sel, actualRange: nil)
            }
        } else if let snap = AX.snapshot(requireCaret: false) {
            text = snap.selectedText
            rect = AX.screenRect(for: snap.selection, in: snap.element) ?? snap.caretRect
            source = snap.windowTitle.isEmpty ? snap.appName : "\(snap.appName) · \(snap.windowTitle)"
        }
        if let rect, rect != .zero { ink.follow(rect) } else if let caret = currentCaret() { ink.follow(caret) }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            Diagnostics.log("memory", "⌃⌥M with no readable selection")
            ink.say("highlight something first, then ⌃⌥M", hold: 2.6)
            return
        }
        Diagnostics.log("memory", "saved \(clean.count) chars")
        MemoryStore.shared.add(clean, source: source)
        ink.say("saved to my memory", hold: 2.4)
    }

    // MARK: Talking back

    func send(_ text: String) {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        if let draft = currentDraft() { document = draft.text }
        append(.init(kind: .writer(said)))
        var history: [ChatMessage] = []
        for entry in entries {
            switch entry.kind {
            case let .reflection(r) where !r.isEmpty:
                history.append(.assistant([r.hearing, r.why, r.ask, r.next].filter { !$0.isEmpty }.joined(separator: "\n")))
            case let .writer(s): history.append(.user(s))
            case let .reply(s) where !s.isEmpty: history.append(.assistant(s))
            default: break
            }
        }
        let messages = Prompts.conversation(document: document, history: history,
                                            voice: settings.voice, aboutMe: settings.writerNotes)
        let id = append(.init(kind: .reply(""), streaming: true))
        run(messages, maxTokens: 300, temperature: 0.7, into: id, onPiece: nil, onDone: { [weak self] kind in
            guard let self, self.settings.speakAloud, case let .reply(text) = kind else { return }
            self.speaker.say(text)
        }) { raw in .reply(raw.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func clear() {
        cancel()
        entries.removeAll()
        lastReflectedWords = 0
        documentKey = ""
    }

    // MARK: Model

    private func run(_ messages: [ChatMessage], maxTokens: Int, temperature: Double, into id: UUID,
                     onPiece: ((Entry.Kind) -> Void)?, onDone: ((Entry.Kind) -> Void)? = nil,
                     shape: @escaping (String) -> Entry.Kind) {
        task?.cancel()
        generation += 1
        let gen = generation
        let client = LLMClient(endpoint: settings.companionEndpoint)
        state = .thinking
        task = Task { [weak self] in
            var raw = ""
            do {
                for try await piece in client.stream(messages, maxTokens: maxTokens, temperature: temperature) {
                    guard let self, gen == self.generation else { return }
                    raw += piece
                    let kind = shape(raw)
                    self.update(id, kind: kind, streaming: true)
                    onPiece?(kind)
                }
                guard let self, gen == self.generation else { return }
                self.update(id, kind: shape(raw), streaming: false)
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.remove(id) }
                self.state = .waiting
                if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onDone?(shape(raw)) }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                guard let self, gen == self.generation else { return }
                self.remove(id)
                Diagnostics.log("model", "error: \(error.localizedDescription)")
                self.state = .error(error.localizedDescription)
            }
        }
    }

    private func cancel() {
        debounce?.cancel()
        task?.cancel()
        dropProposal()
        cancelTalking()
        ink.hide()
        generation += 1
        entries.removeAll { $0.streaming }
        if state == .thinking { state = .waiting }
    }

    @discardableResult
    private func append(_ entry: Entry) -> UUID {
        entries.append(entry)
        if entries.count > 60 { entries.removeFirst(entries.count - 60) }
        return entry.id
    }

    private func update(_ id: UUID, kind: Entry.Kind, streaming: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].kind = kind
        entries[i].streaming = streaming
    }

    private func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// Fills the popup with sample content, for screenshots.
    func preview(place: String, entries kinds: [Entry.Kind]) {
        self.place = place
        entries = kinds.map { Entry(kind: $0) }
    }

    func preview(proposal: Proposal) {
        self.proposal = proposal
    }
}
