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
        let typos = ["realy", "apreciate"]
        // macOS autocorrect may fix some of the typos as they're typed (it turned "realy" into "really" on one Mac),
        // so the test works with whatever landed, as long as a typo is still there for Lina to find.
        var landed = ""
        for attempt in 1...4 {
            guard await freshDocument() else { say("Attempt \(attempt): TextEdit not ready, retrying"); continue }
            say("Typing a sentence with mistakes…")
            engine.dismiss()
            await typeAsUser(sentence)
            try? await Task.sleep(for: .milliseconds(300))
            let snap = AX.snapshot(requireCaret: false)
            let got = (snap?.text as String?) ?? ""
            if got.hasPrefix("Thank you for"), got.hasSuffix("it."), abs(got.count - sentence.count) <= 4 {
                landed = got
                break
            }
            say("Attempt \(attempt): keystrokes didn't all land in “\(snap?.windowTitle ?? "?")”: got \(got.count) chars “\(got.prefix(60))”, retrying")
            closeDocument()
        }
        guard !landed.isEmpty else { say("Could not get a clean TextEdit document"); return false }
        let left = typos.filter { landed.contains($0) }
        if landed != sentence { say("Autocorrect changed the sentence to “\(landed)”") }
        guard !left.isEmpty else { say("Autocorrect fixed every typo before Lina could; turn off Correct Spelling Automatically"); return false }

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
        guard !fixed.isEmpty, left.allSatisfy({ !fixed.contains($0) }) else { say("⌘A did not apply the fixes: “\(fixed)”"); return false }
        say("Fixed ✓ “\(fixed)”")

        say("Typing /lina help in the text, then Return…")
        try? await Task.sleep(for: .seconds(0.8))
        if !textEditInFront {
            let front = NSWorkspace.shared.frontmostApplication
            say("Before typing the command, \(front?.localizedName ?? "nothing") was in front; bringing TextEdit back")
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first?.activate()
            try? await Task.sleep(for: .seconds(0.6))
        }
        await typeAsUser("\n/lina help")
        try? await Task.sleep(for: .seconds(0.4))
        let typed = (AX.snapshot(requireCaret: false)?.text as String?) ?? ""
        guard typed.lowercased().hasSuffix("/lina help") else { say("The command didn't stay in the text while typing: “\(typed)”"); return false }
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
            guard textEditInFront else {
                let front = NSWorkspace.shared.frontmostApplication
                say("TextEdit lost focus to \(front?.localizedName ?? "nothing") (\(front?.bundleIdentifier ?? "?")) — stopped typing")
                return
            }
            let code: CGKeyCode = ch == 32 ? CGKeyCode(kVK_Space) : ch == 10 ? CGKeyCode(kVK_Return) : 0
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
                // Events from the HID state source can inherit the ⌘ from the ⌘A posted just before, which turns
                // "h" into ⌘H (Hide TextEdit). A writer typing holds no modifiers.
                e?.flags = []
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
    /// The focused window must be that document: an empty search field (TextEdit's Open panel) also reads as empty.
    private static func freshDocument() async -> Bool {
        let name = "lina-livetest-\(UUID().uuidString.prefix(6))"
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name + ".txt")
        try? "".write(to: file, atomically: true, encoding: .utf8)
        tempFiles.append(file)
        NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        var stable = 0
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(150))
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first?.activate()
            if textEditInFront, let s = AX.snapshot(requireCaret: false), s.text.length == 0, s.windowTitle.contains(name) {
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
