import AppKit
import Combine

/// Lina's main way of helping: a floating window that reads what you're writing, in any app,
/// and thinks about it with you — what you seem to be saying, why, and where it could go.
/// It never types into your document; you can talk back to it.
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

    private let settings = AppSettings.shared
    private var debounce: DispatchWorkItem?
    private var task: Task<Void, Never>?
    private var generation = 0
    /// The draft as Lina last read it, and where it came from.
    private var document = ""
    private var documentKey = ""
    private var lastReflectedWords = 0
    private var bag = Set<AnyCancellable>()

    lazy var panel = CompanionPanel(companion: self)

    init() {
        settings.$companionEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                guard let self else { return }
                if on { self.show() } else { self.cancel(); self.panel.hide() }
            }
            .store(in: &bag)
        // Appear as soon as the writer finishes onboarding.
        settings.$hasOnboarded
            .dropFirst()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in if self?.settings.companionEnabled == true { self?.show() } }
            .store(in: &bag)
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.show()
        if entries.isEmpty { schedule(after: 300) }
    }

    func toggle() {
        if panel.isVisible { panel.hide() } else { show(); panel.focusInput() }
    }

    // MARK: Watching

    /// Called for every keystroke the writer makes anywhere. Lina reads again once they pause.
    func writerTyped() {
        guard settings.companionEnabled, !panel.isKey else { return }
        schedule()
    }

    /// Called when the writer switches apps or windows.
    func focusChanged() {
        guard settings.companionEnabled else { return }
        schedule(after: 900)
    }

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
        var key: String { "\(appName)|\(title)" }
    }

    /// The draft in front of the writer: any app through Accessibility, or Lina's own Desk.
    private func currentDraft() -> Draft? {
        if let desk = DeskRegistry.shared.activeTarget {
            let ctx = desk.context
            return Draft(text: ctx.before + ctx.after, focus: desk.focusText, appName: "Desk",
                         title: DeskStore.shared.current?.title ?? "")
        }
        guard let snap = AX.snapshot(requireCaret: false), !settings.disabledApps.contains(snap.bundleID) else { return nil }
        return Draft(text: snap.text as String, focus: snap.paragraph, appName: snap.appName, title: snap.windowTitle)
    }

    private func read(force: Bool) {
        guard settings.companionEnabled else { state = .paused; return }
        guard settings.isModelConfigured else { state = .error(LLMError.notConfigured.localizedDescription); return }
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
        run(messages, maxTokens: 400, temperature: 0.6, into: id) { raw in .reflection(Reflection.parse(raw)) }
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
        run(messages, maxTokens: 300, temperature: 0.7, into: id) { raw in .reply(raw.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func clear() {
        cancel()
        entries.removeAll()
        lastReflectedWords = 0
        documentKey = ""
    }

    // MARK: Model

    private func run(_ messages: [ChatMessage], maxTokens: Int, temperature: Double, into id: UUID,
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
                }
                guard let self, gen == self.generation else { return }
                self.update(id, kind: shape(raw), streaming: false)
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.remove(id) }
                self.state = .waiting
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

    /// Fills the window with sample content, for screenshots.
    func preview(place: String, entries kinds: [Entry.Kind]) {
        self.place = place
        entries = kinds.map { Entry(kind: $0) }
    }
}
