import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Drives the ⌥Space palette: pick an action, watch Lina write, put it back with one key.
@MainActor
final class PaletteController: ObservableObject {
    enum Phase: Equatable { case choosing, working, done, failed(String) }

    enum Row: Identifiable, Equatable {
        case ask(String)
        case action(WritingAction)
        var id: String {
            switch self {
            case .ask: "ask"
            case let .action(a): a.rawValue
            }
        }
    }

    @Published var query = ""
    @Published var selectedIndex = 0
    @Published private(set) var phase: Phase = .choosing
    @Published private(set) var running: WritingAction?
    @Published private(set) var runningCustom: String?
    @Published private(set) var result = ""
    @Published private(set) var options: [String] = []
    @Published var optionIndex = 0
    @Published private(set) var target: WritingTarget?

    private let settings = AppSettings.shared
    private var panel: PalettePanel?
    private var task: Task<Void, Never>?
    private var keyMonitor: Any?
    var deskTargetProvider: (() -> WritingTarget?)?

    var rows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return WritingAction.allCases.map(Row.action) }
        let matching = WritingAction.allCases.filter { $0.title.localizedCaseInsensitiveContains(q) }
        let rest = WritingAction.allCases.filter { !matching.contains($0) }
        return matching.map(Row.action) + [.ask(q)] + rest.map(Row.action)
    }

    func isAvailable(_ action: WritingAction) -> Bool {
        guard let target else { return false }
        if action == .lookUp { return !query.isEmpty || !target.focusText.isEmpty }
        if action.needsTarget { return !target.focusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if action == .keepGoing || action == .stuck {
            return !target.context.before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !target.focusText.isEmpty
        }
        return true
    }

    // MARK: Open / close

    func toggle() {
        if panel?.isVisible == true { close(restore: true) } else { open() }
    }

    func open(preselect: WritingAction? = nil) {
        target = deskTargetProvider?() ?? ExternalTarget()
        query = ""
        phase = .choosing
        result = ""
        options = []
        running = nil
        runningCustom = nil
        selectedIndex = preselect.flatMap { a in rows.firstIndex(of: .action(a)) } ?? firstAvailableIndex()

        let panel = self.panel ?? PalettePanel(controller: self)
        self.panel = panel
        panel.present()
        installKeys()
        if let preselect { run(preselect) }
    }

    func close(restore: Bool) {
        task?.cancel()
        removeKeys()
        panel?.dismiss()
        if restore { target?.restore() }
    }

    private func firstAvailableIndex() -> Int {
        rows.firstIndex { if case let .action(a) = $0 { return isAvailable(a) }; return true } ?? 0
    }

    // MARK: Running

    func activate(_ row: Row) {
        switch row {
        case let .ask(text): runCustom(text)
        case let .action(a): if isAvailable(a) { run(a) } else { NSSound.beep() }
        }
    }

    func run(_ action: WritingAction) {
        guard let target else { return }
        running = action
        runningCustom = nil
        let messages = Prompts.action(action, ctx: target.context,
                                      query: query.trimmingCharacters(in: .whitespaces),
                                      voice: settings.voice, aboutMe: settings.aboutMe)
        start(messages, maxTokens: action.maxTokens, temperature: action.temperature) { [weak self] text in
            if action == .findWord { self?.options = Suggestion.options(text) }
        }
    }

    func runCustom(_ instruction: String) {
        guard let target, !instruction.isEmpty else { return }
        running = nil
        runningCustom = instruction
        let messages = Prompts.custom(instruction, ctx: target.context, voice: settings.voice, aboutMe: settings.aboutMe)
        start(messages, maxTokens: 700, temperature: 0.6, onUpdate: nil)
    }

    func retry() {
        if let running { run(running) } else if let runningCustom { runCustom(runningCustom) }
    }

    private func start(_ messages: [ChatMessage], maxTokens: Int, temperature: Double,
                       onUpdate: ((String) -> Void)?) {
        task?.cancel()
        result = ""
        options = []
        optionIndex = 0
        guard settings.isModelConfigured else {
            phase = .failed(LLMError.notConfigured.localizedDescription)
            return
        }
        phase = .working
        let client = LLMClient(endpoint: settings.endpoint)
        task = Task { [weak self] in
            do {
                var text = ""
                for try await piece in client.stream(messages, maxTokens: maxTokens, temperature: temperature) {
                    text += piece
                    guard let self, !Task.isCancelled else { return }
                    self.result = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    onUpdate?(text)
                }
                guard let self, !Task.isCancelled else { return }
                self.result = self.cleanResult(text)
                onUpdate?(text)
                self.phase = self.result.isEmpty ? .failed("Lina came back empty-handed. Try again?") : .done
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func cleanResult(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["<passage>", "</passage>", "<text>", "</text>"] { s = s.replacingOccurrences(of: tag, with: "") }
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count > 2, !(target?.focusText.hasPrefix("\"") ?? false) {
            s = String(s.dropFirst().dropLast())
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func back() {
        task?.cancel()
        phase = .choosing
        result = ""
        options = []
    }

    // MARK: Applying

    var primaryOutcome: WritingAction.Outcome {
        running?.outcome ?? ((target?.focusText.isEmpty ?? true) ? .insert : .replace)
    }

    var applyText: String {
        if running == .findWord { return options.indices.contains(optionIndex) ? options[optionIndex] : "" }
        return result
    }

    func applyPrimary() {
        guard phase == .done, let target else { return }
        let text = applyText
        guard !text.isEmpty else { return }
        switch primaryOutcome {
        case .replace, .choose:
            close(restore: false)
            target.replaceFocus(with: text)
        case .insert:
            close(restore: false)
            target.insertAfterFocus(text)
        case .note:
            copyResult()
        }
    }

    func applyInsert() {
        guard phase == .done, let target, !applyText.isEmpty else { return }
        let text = applyText
        close(restore: false)
        target.insertAfterFocus(text)
    }

    func copyResult() {
        guard !applyText.isEmpty else { return }
        TextInserter.copy(applyText)
        panel?.flash("Copied")
    }

    // MARK: Keyboard

    private func installKeys() {
        removeKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        let code = Int(e.keyCode)
        let digit = e.charactersIgnoringModifiers.flatMap(Int.init)

        if code == kVK_Escape {
            switch phase {
            case .choosing:
                if query.isEmpty { close(restore: true) } else { query = "" }
            default: back()
            }
            return true
        }

        switch phase {
        case .choosing:
            let count = rows.count
            if code == kVK_DownArrow { selectedIndex = (selectedIndex + 1) % count; return true }
            if code == kVK_UpArrow { selectedIndex = (selectedIndex - 1 + count) % count; return true }
            if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
                if rows.indices.contains(selectedIndex) { activate(rows[selectedIndex]) }
                return true
            }
            if cmd, let d = digit, (1...WritingAction.allCases.count).contains(d) {
                activate(.action(WritingAction.allCases[d - 1]))
                return true
            }
        case .working, .done, .failed:
            if running == .findWord, !options.isEmpty {
                if code == kVK_DownArrow || code == kVK_RightArrow { optionIndex = (optionIndex + 1) % options.count; return true }
                if code == kVK_UpArrow || code == kVK_LeftArrow { optionIndex = (optionIndex - 1 + options.count) % options.count; return true }
                if !cmd, let d = digit, options.indices.contains(d - 1) { optionIndex = d - 1; applyPrimary(); return true }
            }
            if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
                if case .failed = phase { retry(); return true }
                cmd ? applyInsert() : applyPrimary()
                return true
            }
            if cmd && code == kVK_ANSI_C { copyResult(); return true }
            if cmd && code == kVK_ANSI_R { retry(); return true }
            if code == kVK_Delete && cmd { back(); return true }
        }
        return false
    }
}

// MARK: - Panel

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PalettePanel {
    private let panel: KeyablePanel
    private let toast = ToastModel()
    private unowned let controller: PaletteController
    static let width: CGFloat = 640

    init(controller: PaletteController) {
        self.controller = controller
        panel = KeyablePanel(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 420),
                             styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = PaletteView(controller: controller, toast: toast) { [weak self] height in
            self?.resize(to: height)
        }
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                               queue: .main) { [weak controller] _ in
            MainActor.assumeIsolated {
                // Clicking elsewhere closes the palette, like Spotlight.
                if controller?.phase != .working { controller?.close(restore: false) }
            }
        }
    }

    var isVisible: Bool { panel.isVisible }
    var isKeyWindow: Bool { panel.isKeyWindow }

    func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        let height = panel.frame.height
        let top = vf.maxY - vf.height * 0.2
        panel.setFrame(CGRect(x: vf.midX - Self.width / 2, y: top - height, width: Self.width, height: height),
                       display: true)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    func flash(_ message: String) { toast.show(message) }

    private func resize(to height: CGFloat) {
        let h = ceil(height)
        guard abs(panel.frame.height - h) > 0.5 else { return }
        var f = panel.frame
        f.origin.y += f.height - h // keep the top edge fixed
        f.size.height = h
        panel.setFrame(f, display: true, animate: false)
    }
}

final class ToastModel: ObservableObject {
    @Published var message: String?
    func show(_ m: String) {
        message = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.message == m { self?.message = nil }
        }
    }
}
