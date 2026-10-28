import AppKit
import Carbon.HIToolbox

/// `Lina --livetest [--local MODEL]` drives a real TextEdit window end to end:
/// types like a writer, waits for ghost text, presses Tab, and checks the words landed.
/// Then it exercises the palette's write-back by replacing a word through Accessibility.
@MainActor
enum LiveTest {
    static func runIfRequested(engine: GhostEngine) {
        let args = CommandLine.arguments
        guard args.contains("--livetest") else { return }
        let settings = AppSettings.shared
        // The test flips a few persisted settings; put the writer's own back before exiting.
        let saved = (settings.enabled, settings.provider, settings.localModel, settings.disabledApps)
        if let i = args.firstIndex(of: "--local"), args.count > i + 1 {
            settings.provider = .local
            settings.localModel = args[i + 1]
        }
        settings.enabled = true
        settings.disabledApps.remove("com.apple.TextEdit")
        Task { @MainActor in
            let ok = await run(engine: engine)
            await cleanUp()
            (settings.enabled, settings.provider, settings.localModel, settings.disabledApps) = saved
            print(ok ? "\n✓ LIVE TEST PASSED" : "\n✗ LIVE TEST FAILED")
            exit(ok ? 0 : 1)
        }
    }

    private static func say(_ s: String) { print("· \(s)"); fflush(stdout) }

    private static func run(engine: GhostEngine) async -> Bool {
        guard AX.isTrusted else { say("Accessibility not granted to this process"); return false }
        say("Model: \(AppSettings.shared.endpoint.model) @ \(AppSettings.shared.endpoint.baseURL)")

        engine.start()
        guard engine.status != .needsPermission else { say("Event tap could not start"); return false }
        // Leave the writer's own TextEdit documents alone: quit it only if we launched it.
        quitTextEdit = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty

        let before = "I didn't expect the city to feel so quiet after the rain. The streets were empty, and "
        // Getting a fresh, focused, empty document is the flaky part of driving another app — retry it.
        var ready = false
        for attempt in 1...4 {
            guard await freshDocument() else { say("Attempt \(attempt): TextEdit not ready, retrying"); continue }
            say("Typing like a writer…")
            engine.reset()
            await typeAsUser(before)
            if let snap = AX.snapshot(requireCaret: false), (snap.text as String) == before {
                ready = true
                break
            }
            let got = (AX.snapshot(requireCaret: false)?.text as String?) ?? "<unreadable>"
            say("Attempt \(attempt): keystrokes didn't all land in TextEdit (got \(got.count) chars: “\(got.prefix(40))…”), retrying")
            closeDocument()
        }
        guard ready else { say("Could not get a clean TextEdit document"); return false }
        // Wait for a finished suggestion.
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 30 {
            if engine.status == .showing, !engine.isStreaming, !engine.suggestion.isEmpty { break }
            if case let .error(m) = engine.status { say("Model error: \(m)"); return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let suggestion = engine.suggestion
        guard !suggestion.isEmpty else { say("No ghost text appeared within 30 s (status: \(engine.status))"); return false }
        say("Ghost text appeared after \(Int(Date().timeIntervalSince(t0) * 1000)) ms: “\(suggestion)”")

        say("Pressing Tab…")
        postKey(CGKeyCode(kVK_Tab))
        try? await Task.sleep(for: .seconds(1.2))

        guard let snap = AX.snapshot(requireCaret: false) else { say("Could not read TextEdit back"); return false }
        let text = snap.text as String
        let accepted = text.hasPrefix(before) && text.dropFirst(before.count).hasPrefix(suggestion.trimmingCharacters(in: .whitespaces).prefix(10))
        say("Document now reads: “\(text)”")
        guard accepted else { say("Tab did not insert the suggestion"); return false }
        say("Tab inserted the suggestion ✓")

        // Palette write-back: replace the word “quiet” via Accessibility, as Find the word does.
        let ns = snap.text
        let r = ns.range(of: "quiet")
        guard r.location != NSNotFound else { return false }
        AX.select(r, in: snap.element)
        try? await Task.sleep(for: .milliseconds(300))
        let target = ExternalTarget()
        say("Palette target sees: \(target.displayName) · \(target.focusDescription) · “\(target.focusText)”")
        guard textEditInFront else { say("TextEdit is not in front — skipped the palette paste"); return false }
        target.replaceFocus(with: "hushed")
        try? await Task.sleep(for: .seconds(1.5))
        let after = (AX.snapshot(requireCaret: false)?.text as String?) ?? ""
        let replaced = after.contains("feel so hushed after the rain")
        say(replaced ? "Palette replacement landed ✓ — “\(after.prefix(70))…”" : "Palette replacement failed: “\(after)”")
        return replaced
    }

    /// Keystrokes are posted system-wide, so only send one while TextEdit is in front —
    /// never into whatever app the writer may have switched to.
    private static var textEditInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit"
    }

    /// Posts keystrokes without Lina's marker, exactly as if the writer typed them.
    private static func typeAsUser(_ s: String) async {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in s.utf16 {
            guard textEditInFront else { say("TextEdit lost focus — stopped typing"); return }
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: ch == 32 ? CGKeyCode(kVK_Space) : 0, keyDown: down)
                var u = [ch]
                e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
                e?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 20...45)))
        }
    }

    private static func postKey(_ code: CGKeyCode) {
        guard textEditInFront else { say("TextEdit is not in front — key not sent"); return }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = []
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Opens a new TextEdit document and waits until its empty text view has focus, stably.
    private static func freshDocument() async -> Bool {
        // Each attempt opens its own empty file, so TextEdit always shows a fresh, focused window.
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
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit",
               let s = AX.snapshot(requireCaret: false), s.text.length == 0 {
                stable += 1
                if stable >= 3 { return true }
            } else {
                stable = 0
            }
        }
        return false
    }

    private static func closeDocument() {
        // ⌘W closes the window; the file is a throwaway temp file that TextEdit autosaves.
        guard textEditInFront else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_W), keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    private static var tempFiles: [URL] = []
    private static var quitTextEdit = false

    private static func cleanUp() async {
        guard !tempFiles.isEmpty else { return }  // never opened a document, so nothing of ours to close
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit")
        if quitTextEdit {
            apps.forEach { $0.terminate() }
        } else {
            closeDocument()
        }
        // TextEdit autosaves as it closes; wait for that before deleting, or it writes the files back.
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            if quitTextEdit ? apps.allSatisfy(\.isTerminated) : false { break }
        }
        for file in tempFiles { try? FileManager.default.removeItem(at: file) }
        tempFiles.removeAll()
    }
}
