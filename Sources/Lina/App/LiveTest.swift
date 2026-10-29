import AppKit
import Carbon.HIToolbox

/// `Lina --livetest [--local MODEL]` drives a real TextEdit window end to end:
/// types a sentence with mistakes, waits for Lina's fixes, presses ⌘A and checks they landed.
/// Then it types `/lina help` inline, presses Return, and checks the command took itself out of the text.
/// With web search set up, it also asks a question in an empty document and inserts the answer with ⌘1.
@MainActor
enum LiveTest {
    static func runIfRequested(engine: LinaEngine) {
        let args = CommandLine.arguments
        guard args.contains("--livetest") else { return }
        let settings = AppSettings.shared
        // The test flips a few persisted settings; put the writer's own back before exiting.
        let saved = (settings.enabled, settings.checkSentences, settings.provider, settings.localModel, settings.disabledApps, settings.showTips)
        if let i = args.firstIndex(of: "--local"), args.count > i + 1 {
            settings.provider = .local
            settings.localModel = args[i + 1]
        }
        settings.enabled = true
        settings.checkSentences = true
        settings.showTips = false
        settings.disabledApps.remove("com.apple.TextEdit")
        Task { @MainActor in
            let ok = await run(engine: engine)
            await cleanUp()
            (settings.enabled, settings.checkSentences, settings.provider, settings.localModel, settings.disabledApps, settings.showTips) = saved
            print(ok ? "\n✓ LIVE TEST PASSED" : "\n✗ LIVE TEST FAILED")
            exit(ok ? 0 : 1)
        }
    }

    private static func say(_ s: String) { print("· \(s)"); fflush(stdout) }

    private static func run(engine: LinaEngine) async -> Bool {
        guard AX.isTrusted else { say("Accessibility not granted to this process"); return false }
        say("Checks with: \(AppSettings.shared.checkEndpoint.model)")
        engine.start()
        guard engine.status != .needsPermission else { say("Event tap could not start"); return false }
        quitTextEdit = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty

        let sentence = "Thank you for you're help, I realy apreciate it."
        var ready = false
        for attempt in 1...4 {
            guard await freshDocument() else { say("Attempt \(attempt): TextEdit not ready, retrying"); continue }
            say("Typing a sentence with mistakes…")
            engine.dismiss()
            await typeAsUser(sentence)
            if let snap = AX.snapshot(requireCaret: false), (snap.text as String) == sentence {
                ready = true
                break
            }
            say("Attempt \(attempt): keystrokes didn't all land, retrying")
            closeDocument()
        }
        guard ready else { say("Could not get a clean TextEdit document"); return false }

        // Wait for the fixes to appear over the mistakes.
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 30 {
            if !engine.pendingFixes.isEmpty { break }
            if case let .error(m) = engine.status { say("Model error: \(m)"); return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let fixes = engine.pendingFixes
        guard !fixes.isEmpty else { say("No fixes within 30 s (status: \(engine.status))"); return false }
        say("Fixes after \(Int(Date().timeIntervalSince(t0) * 1000)) ms: " + fixes.map { $0.wrong + " → " + $0.right }.joined(separator: ", "))

        say("Pressing ⌘A…")
        postKey(CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
        try? await Task.sleep(for: .seconds(1.5))
        let fixed = (AX.snapshot(requireCaret: false)?.text as String?) ?? ""
        guard fixed.contains("really"), !fixed.contains("realy") else { say("⌘A did not apply the fixes: “\(fixed)”"); return false }
        say("Fixed ✓ “\(fixed)”")

        say("Typing /lina help in the text, then Return…")
        await typeAsUser("\n/lina help")
        try? await Task.sleep(for: .seconds(0.4))
        let typed = (AX.snapshot(requireCaret: false)?.text as String?) ?? ""
        guard typed.hasSuffix("/lina help") else { say("The command didn't stay in the text while typing: “\(typed)”"); return false }
        guard engine.status == .listening else { say("Lina wasn't listening to the command (status: \(engine.status))"); return false }
        await typeAsUser("\n")
        let t1 = Date()
        while Date().timeIntervalSince(t1) < 5 {
            if engine.card == .help { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard engine.card == .help else { say("No help card"); return false }
        try? await Task.sleep(for: .seconds(0.5))
        let after = (AX.snapshot(requireCaret: false)?.text as String?) ?? ""
        guard !after.contains("/lin"), !after.hasSuffix("\n\n") else { say("The command was left in the text: “\(after)”"); return false }
        say("Help card shown, and the command took itself out ✓")
        postKey(CGKeyCode(kVK_Escape), flags: [])

        guard AppSettings.shared.hasSearch else {
            say("No web search set up; skipping the question test")
            return true
        }
        // The case from the field: a question typed into an empty field must get an answer, not "can't read".
        closeDocument()
        guard await freshDocument() else { say("TextEdit not ready for the question test"); return false }
        say("Asking a question in an empty document…")
        await typeAsUser("/lina what is the capital of France")
        try? await Task.sleep(for: .seconds(0.3))
        await typeAsUser("\n")
        let t2 = Date()
        var answered = false
        while Date().timeIntervalSince(t2) < 30 {
            if case .answer? = engine.card { answered = true; break }
            if case let .error(m) = engine.status { say("Search error: \(m)"); return false }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard answered else { say("No answer within 30 s (status: \(engine.status))"); return false }
        postKey(CGKeyCode(kVK_ANSI_1), flags: .maskCommand)
        try? await Task.sleep(for: .seconds(1.2))
        let answer = (AX.snapshot(requireCaret: false)?.text as String?) ?? ""
        guard answer.lowercased().contains("paris"), !answer.contains("/lina") else {
            say("⌘1 didn't put the answer in place of the question: “\(answer)”"); return false
        }
        say("Answer inserted ✓ “\(answer)”")
        return true
    }

    /// Keystrokes are posted system-wide, so only send one while TextEdit is in front.
    private static var textEditInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit"
    }

    /// Posts keystrokes without Lina's marker, exactly as if the writer typed them.
    private static func typeAsUser(_ s: String) async {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in s.utf16 {
            guard textEditInFront else { say("TextEdit lost focus — stopped typing"); return }
            let code: CGKeyCode = ch == 32 ? CGKeyCode(kVK_Space) : ch == 10 ? CGKeyCode(kVK_Return) : 0
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
                if ch != 10 {
                    var u = [ch]
                    e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
                }
                e?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 20...45)))
        }
    }

    private static func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        guard textEditInFront else { say("TextEdit is not in front — key not sent"); return }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Opens a new TextEdit document and waits until its empty text view has focus, stably.
    private static func freshDocument() async -> Bool {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lina-livetest-\(UUID().uuidString.prefix(6)).txt")
        try? "".write(to: file, atomically: true, encoding: .utf8)
        tempFiles.append(file)
        NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        var stable = 0
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(150))
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first?.activate()
            if textEditInFront, let s = AX.snapshot(requireCaret: false), s.text.length == 0 {
                stable += 1
                if stable >= 3 { return true }
            } else {
                stable = 0
            }
        }
        return false
    }

    private static func closeDocument() {
        postKey(CGKeyCode(kVK_ANSI_W), flags: .maskCommand)
    }

    private static var tempFiles: [URL] = []
    private static var quitTextEdit = false

    private static func cleanUp() async {
        guard !tempFiles.isEmpty else { return }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit")
        if quitTextEdit { apps.forEach { $0.terminate() } } else { closeDocument() }
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            if quitTextEdit && apps.allSatisfy(\.isTerminated) { break }
        }
        for file in tempFiles { try? FileManager.default.removeItem(at: file) }
        tempFiles.removeAll()
    }
}
