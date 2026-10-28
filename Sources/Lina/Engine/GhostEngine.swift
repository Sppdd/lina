import AppKit
import Carbon.HIToolbox
import Combine

/// The heart of Lina: watches you write in any app, waits for a natural pause,
/// and offers what might come next as ghost text at the caret.
@MainActor
final class GhostEngine: ObservableObject {
    enum Status: Equatable {
        case needsPermission, needsModel, paused, listening, thinking, showing
        case error(String)
    }

    @Published private(set) var status: Status = .listening
    @Published private(set) var currentApp: (name: String, bundleID: String) = ("", "")
    @Published private(set) var lastLatencyMs: Int?
    /// Whether macOS currently lets Lina read other apps. Re-checked on a timer, so the UI follows
    /// the switch in System Settings without a relaunch.
    @Published private(set) var isTrusted = AX.isTrusted

    /// Every keystroke the writer makes in another app (not Lina's own windows).
    var onTyped: (() -> Void)?
    /// The writer switched to another app.
    var onAppChanged: (() -> Void)?
    /// A click anywhere.
    var onMouseDown: (() -> Void)?
    /// Modifier keys changed (hold ⌃⌥ to talk).
    var onModifiers: ((CGEventFlags) -> Void)?
    /// Sees every key first; returns true to swallow it (the companion popup's ⇥ and esc).
    var interceptKey: ((CGEvent) -> Bool)?

    private let settings = AppSettings.shared
    private let stats = WritingStats.shared
    private let panel = GhostPanel()
    private let monitor = KeyMonitor()

    private(set) var suggestion = ""
    var isStreaming: Bool { panel.model.streaming }
    private var caret: CGRect = .zero
    private var debounce: DispatchWorkItem?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var quietUntil = Date.distantPast
    private var lastWasWordChar = false
    private var bag = Set<AnyCancellable>()

    init() {
        monitor.onKeyDown = { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? false }
        }
        monitor.onFlagsChanged = { [weak self] flags in
            MainActor.assumeIsolated { self?.onModifiers?(flags) }
        }
        monitor.onMouseDown = { [weak self] in
            MainActor.assumeIsolated {
                self?.reset()
                self?.onMouseDown?()
            }
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        self?.currentApp = (app.localizedName ?? "", app.bundleIdentifier ?? "")
                        self?.refreshStatus()
                        self?.onAppChanged?()
                    }
                    self?.reset()
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
            status = .needsPermission
            return
        }
        if !monitor.isRunning {
            monitor.start()
            if !monitor.isRunning { status = .needsPermission; return }
        }
        if !settings.isModelConfigured { status = .needsModel; return }
        if !settings.enabled || settings.disabledApps.contains(currentApp.bundleID) { status = .paused; return }
        if case .error = status, Date() < quietUntil { return }
        if status != .thinking && status != .showing { status = .listening }
    }

    // MARK: Keys

    private func handleKey(_ event: CGEvent) -> Bool {
        let flags = event.flags
        let code = event.keyCode
        let commandish = flags.contains(.maskCommand) || flags.contains(.maskControl)
        let visible = panel.isVisible && !suggestion.isEmpty

        if HotKeyCenter.shared.matches(event) { return false }
        if !visible, interceptKey?(event) == true { return true }

        if visible && !commandish && !flags.contains(.maskShift) {
            if code == kVK_Tab {
                flags.contains(.maskAlternate) ? acceptWord() : acceptAll()
                return true
            }
            if code == kVK_Escape {
                reset()
                return true
            }
        }

        if commandish { reset(); return false }
        // Typing into Lina's own companion popup isn't writing in the draft.
        if NSApp.keyWindow?.identifier == CompanionPanel.identifier { return false }
        onTyped?()

        let typed = event.typedString
        countWords(typed, keyCode: code)

        // Typing what Lina suggested keeps the rest of the suggestion alive.
        if visible, !typed.isEmpty, !typed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
           suggestion.hasPrefix(typed) {
            suggestion.removeFirst(typed.count)
            if suggestion.trimmingCharacters(in: .whitespaces).isEmpty { reset() } else { follow() }
            return false
        }

        reset()
        schedule()
        return false
    }

    private func countWords(_ typed: String, keyCode: Int) {
        guard let ch = typed.unicodeScalars.first else { return }
        let isWordChar = CharacterSet.alphanumerics.contains(ch) || ch == "'"
        if !isWordChar && lastWasWordChar && keyCode != kVK_Delete { stats.addWords(1) }
        lastWasWordChar = isWordChar
    }

    // MARK: Suggesting

    private func schedule(after ms: Double? = nil) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fire() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (ms ?? settings.debounceMs) / 1000, execute: work)
    }

    private func fire() {
        guard settings.enabled, settings.isModelConfigured, Date() >= quietUntil else { return }
        guard let snap = AX.snapshot(), let caretRect = snap.caretRect,
              !settings.disabledApps.contains(snap.bundleID), snap.selection.length == 0,
              Suggestion.isGoodMoment(before: snap.before, after: snap.after)
        else { return }

        let ctx = snap.context()
        let messages = Prompts.continuation(ctx, voice: settings.voice, aboutMe: settings.aboutMe,
                                            length: settings.length)
        let client = LLMClient(endpoint: settings.endpoint)
        let length = settings.length
        generation += 1
        let gen = generation
        caret = caretRect
        status = .thinking
        let started = Date()

        task = Task { [weak self] in
            var raw = ""
            do {
                for try await piece in client.stream(messages, maxTokens: length.maxTokens + 8,
                                                     temperature: 0.45, stop: ["\n\n"]) {
                    guard let self, gen == self.generation else { return }
                    raw += piece
                    let cleaned = Suggestion.clean(raw, before: ctx.before, length: length)
                    if cleaned.trimmingCharacters(in: .whitespaces).count >= 3 {
                        self.present(cleaned, streaming: true)
                    }
                    if raw.contains("\n"), !cleaned.isEmpty { break }
                }
                guard let self, gen == self.generation else { return }
                let final = Suggestion.clean(raw, before: ctx.before, length: length)
                self.lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
                if final.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.reset()
                } else {
                    self.present(final, streaming: false)
                    self.stats.suggestionShown()
                }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                guard let self, gen == self.generation else { return }
                self.reset()
                self.status = .error(error.localizedDescription)
                self.quietUntil = Date().addingTimeInterval(15)
            }
        }
    }

    private func present(_ text: String, streaming: Bool) {
        suggestion = text
        panel.show(text, caret: caret, streaming: streaming)
        status = .showing
    }

    /// After the writer types along with the suggestion, move it to the new caret.
    private func follow() {
        panel.model.text = suggestion
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.suggestion.isEmpty, let rect = AX.snapshot()?.caretRect else { return }
                self.caret = rect
                self.panel.show(self.suggestion, caret: rect, streaming: false)
            }
        }
    }

    private func acceptAll() {
        let text = suggestion
        task?.cancel()
        reset()
        TextInserter.type(text)
        stats.suggestionAccepted(words: WordCount.count(text))
        lastWasWordChar = text.last.map { $0.isLetter || $0.isNumber } ?? false
        // Keep the flow going: offer the next piece shortly after.
        schedule(after: max(350, settings.debounceMs))
    }

    private func acceptWord() {
        task?.cancel()
        let scalars = Array(suggestion)
        var i = 0
        while i < scalars.count, scalars[i] == " " { i += 1 }
        while i < scalars.count, scalars[i] != " " { i += 1 }
        let word = String(scalars[..<i])
        suggestion = String(scalars[i...])
        TextInserter.type(word)
        stats.suggestionAccepted(words: 1)
        if suggestion.trimmingCharacters(in: .whitespaces).isEmpty { reset() } else { follow() }
    }

    /// Hide everything and cancel in-flight work.
    func reset() {
        debounce?.cancel()
        task?.cancel()
        generation += 1
        suggestion = ""
        panel.hide()
        if status == .thinking || status == .showing { status = .listening }
        if case .error = status, Date() >= quietUntil { status = .listening }
    }

    /// Clears a sticky error so the next pause tries again.
    func clearError() {
        quietUntil = .distantPast
        if case .error = status { status = .listening }
        refreshStatus()
    }
}
