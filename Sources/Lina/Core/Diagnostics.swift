import AppKit
import AVFoundation
import Speech

/// A plain record of what Lina noticed and decided, so a problem can be explained without the writer
/// having to describe it. It never holds what you wrote: only apps, lengths, decisions and errors.
///
/// Events go to ~/Library/Logs/Lina/lina.log. "Report a problem…" (or `/lina bug …`) bundles the latest
/// ones with the app's state into ~/Library/Logs/Lina/reports/, and copies the report to the clipboard.
@MainActor
enum Diagnostics {
    struct Event {
        let date: Date
        let area: String
        let message: String
    }

    private static var events: [Event] = []
    /// The last app the writer used other than Lina: reports opened from Lina's menu describe that one.
    static var lastApp: NSRunningApplication?
    private static let limit = 400

    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Lina", isDirectory: true)
    static var reports: URL { folder.appendingPathComponent("reports", isDirectory: true) }
    private static var logFile: URL { folder.appendingPathComponent("lina.log") }

    /// Notes one thing Lina did or decided. Keep messages free of the writer's text.
    static func log(_ area: String, _ message: String) {
        let event = Event(date: Date(), area: area, message: message)
        // Don't repeat the same line over and over (the ink drop checks the caret every 0.4 s).
        if let last = events.last, last.area == area, last.message == message, event.date.timeIntervalSince(last.date) < 30 { return }
        events.append(event)
        if events.count > limit { events.removeFirst(events.count - limit) }
        append(line(event) + "\n")
    }

    private static func line(_ e: Event) -> String {
        "\(stamp.string(from: e.date))  [\(e.area)] \(e.message)"
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func append(_ text: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Start over past 2 MB, keeping one older file.
        if let size = try? fm.attributesOfItem(atPath: logFile.path)[.size] as? Int, size > 2_000_000 {
            let old = folder.appendingPathComponent("lina.old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: logFile, to: old)
        }
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logFile)
        }
    }

    // MARK: Reports

    /// Writes a report of what the writer saw plus everything Lina knows about the moment, and copies it.
    @discardableResult
    static func report(_ note: String, kind: String, focus: String? = nil) -> URL? {
        let s = AppSettings.shared
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev build"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let mic = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "allowed"
        case .denied, .restricted: "denied"
        default: "not asked yet"
        }
        let speech = switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: "allowed"
        case .denied, .restricted: "denied"
        default: "not asked yet"
        }
        let hasKey = !s.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        let recent = events.suffix(150).map(line).joined(separator: "\n")

        let text = """
        # Lina problem report

        **What happened:** \(kind)
        **In the writer's words:** \(note.isEmpty ? "(nothing added)" : note)
        **When:** \(stamp.string(from: Date()))

        ## Setup
        - Lina \(version), \(os)
        - Accessibility: \(AX.isTrusted ? "granted" : "NOT granted")
        - Microphone: \(mic) · Speech recognition: \(speech) · Talk available in this build: \(VoiceInput.isAvailable)
        - Provider: \(s.provider.title) · API key: \(hasKey ? "set" : "missing")
        - Models: companion \(s.companionModel) · ghost \(s.nebiusModel) · pictures \(s.imageModel)\(s.provider == .local ? " · local \(s.localModel) at \(s.localBaseURL)" : "")
        - Companion: \(s.companionEnabled ? "on" : "off") · mode \(s.companionMode.title) · pause \(Int(s.companionPauseMs)) ms
        - Ink drop: \(s.inkEnabled ? "on" : "off") · hold to talk: \(s.talkEnabled ? "on" : "off") · read aloud: \(s.speakAloud ? "on" : "off") · ghost text: \(s.enabled ? "on" : "off")
        - Shortcut: \(s.hotKey.title) · paused in: \(s.disabledApps.sorted().joined(separator: ", "))
        - Memory: \(MemoryStore.shared.items.count) items

        ## The text field in front of the writer
        \(focus ?? AX.describeFocus())

        ## What Lina did (most recent last)
        ```
        \(recent.isEmpty ? "(nothing logged yet)" : recent)
        ```

        _This report has no document text in it: only app names, lengths, settings and Lina's decisions._
        """

        let fm = FileManager.default
        try? fm.createDirectory(at: reports, withIntermediateDirectories: true)
        let name = "report-" + stamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "_") + ".md"
        let url = reports.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try? fm.removeItem(at: reports.appendingPathComponent("latest.md"))
            try? text.write(to: reports.appendingPathComponent("latest.md"), atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        log("report", "saved \(name)")
        return url
    }
}
