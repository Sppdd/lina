import AppKit
import Carbon.HIToolbox
import Combine

/// Lina's main way of helping: a popup just above your cursor that reads what you're writing, in any app.
/// What it does depends on the mode, cycled with ⇧ + the companion shortcut:
/// - Understand thinks about it with you — what you seem to be saying, why, and where it could go —
///   and never types into your document; you can talk back to it.
/// - Edit offers a rewrite of each sentence you finish; ⇥ takes it, esc keeps yours.
/// - Auto rewrites each sentence you finish in place; ⌘Z undoes it like any edit.
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
        Publishers.CombineLatest3($state, $proposal, $listening)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncInkState() }
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

    /// Hide the popup; the writer keeps going.
    func dismiss() {
        ink.cancelPointing()
        dropProposal()
        announcingMode = false
        panel.hide()
    }

    /// Shows the popup just above the writer's cursor.
    private func present(at caret: CGRect? = nil) {
        unseen = false
        panel.show(above: caret ?? currentCaret())
    }

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
        panel.hide()
        schedule(after: settings.companionMode == .understand ? nil : Self.rewritePauseMs)
    }

    /// Called when the writer switches apps or windows.
    func focusChanged() {
        guard settings.companionEnabled else { return }
        if !panel.isKey { dismiss() }
        ink.hide()
        followCaretSoon()
        schedule(after: 900)
    }

    /// A click anywhere. Clicking outside the popup moves the cursor, so the popup goes away.
    func mouseDown() {
        ink.cancelPointing()
        followCaretSoon()
        guard panel.isVisible, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        dismiss()
    }

    /// Keys the writer presses in any app while the popup is up. Returns true to swallow the key.
    func handleKey(_ event: CGEvent) -> Bool {
        // A key while ⌃⌥ is held is a shortcut, not talking.
        if talkHeld { cancelTalking() }
        guard panel.isVisible else { return false }
        let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case kVK_Tab where proposal.map { !$0.streaming && !$0.applied && !$0.rewritten.isEmpty } ?? false:
            acceptProposal()
            return true
        case kVK_Escape:
            dismiss()
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
            if state != .thinking { state = .waiting }
            return
        }
        let words = WordCount.count(draft.text)
        let moved = draft.key != documentKey
        // Only speak up when there's something new to think about.
        guard words >= 12, force || moved || abs(words - lastReflectedWords) >= 12 else {
            document = draft.text
            wordCount = words
            if unseen && !panel.isVisible { present(at: draft.caret) }
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
        reflect(on: draft)
    }

    private func reflect(on draft: Draft) {
        let earlier = entries.compactMap { entry -> String? in
            if case let .reflection(r) = entry.kind { return r.ask.isEmpty ? r.hearing : r.ask }
            return nil
        }
        let messages = Prompts.reflection(document: draft.text, focus: draft.focus, appName: draft.appName,
                                          title: draft.title, voice: settings.voice, aboutMe: settings.aboutMe,
                                          earlier: earlier)
        let id = append(.init(kind: .reflection(Reflection()), streaming: true))
        let caret = draft.caret
        var shown = false
        run(messages, maxTokens: 400, temperature: 0.6, into: id, onPiece: { [weak self] in
            // Pop up above the cursor with the first words, unless the writer is already typing again.
            guard let self, !shown else { return }
            shown = true
            if Date().timeIntervalSince(self.lastTyped) * 1000 >= self.settings.companionPauseMs * 0.8 {
                self.present(at: caret)
            } else {
                self.unseen = true
            }
        }, onDone: { [weak self] kind in
            guard let self, case let .reflection(r) = kind else { return }
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
        remember(found.text)

        rewriteTask?.cancel()
        let target = RewriteTarget(pid: snap.pid, text: snap.text, caret: snap.selection.location, found: found)
        rewriteTarget = target
        proposal = Proposal(original: found.text)
        announcingMode = false
        present(at: snap.caretRect)

        let before = snap.text.substring(to: found.range.location)
        let messages = Prompts.rewriteSentence(found.text, before: before, instruction: instruction,
                                               voice: settings.voice, aboutMe: settings.aboutMe)
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
        else { dismiss(); return }
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
        guard settings.inkEnabled, settings.companionEnabled, settings.hasOnboarded else { ink.hide(); return }
        if ink.isPointing { return }
        // While the popup is up it's the one talking; the drop steps aside (unless it's listening).
        if panel.isVisible && !listening { ink.hide(); return }
        guard let caret = inkCaret() else { ink.hide(); return }
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
        else if state == .thinking || proposal?.streaming == true { ink.model.state = .thinking }
        else { ink.model.state = .resting }
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
                                            voice: settings.voice, aboutMe: settings.aboutMe)
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
                     onPiece: (() -> Void)?, onDone: ((Entry.Kind) -> Void)? = nil,
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
                    self.update(id, kind: shape(raw), streaming: true)
                    onPiece?()
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
