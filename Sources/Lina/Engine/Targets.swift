import AppKit

/// Where the palette's help goes back to: another app (via Accessibility) or Lina's own Desk.
@MainActor
protocol WritingTarget: AnyObject {
    var displayName: String { get }
    var icon: NSImage? { get }
    /// The text the palette works on: the selection, or else the paragraph around the caret.
    var focusText: String { get }
    var hasSelection: Bool { get }
    var context: WritingContext { get }
    var canWrite: Bool { get }
    func replaceFocus(with text: String)
    func insertAfterFocus(_ text: String)
    /// Bring the writer back to where they were.
    func restore()
}

extension WritingTarget {
    var focusDescription: String {
        let words = WordCount.count(focusText)
        if hasSelection { return "Selection · \(words) word\(words == 1 ? "" : "s")" }
        if words == 0 { return "Nothing selected" }
        return "This paragraph · \(words) word\(words == 1 ? "" : "s")"
    }
}

/// Any app, read and written through macOS Accessibility.
@MainActor
final class ExternalTarget: WritingTarget {
    private let app: NSRunningApplication?
    private let snap: FocusSnapshot?

    init() {
        app = NSWorkspace.shared.frontmostApplication
        snap = AX.snapshot(requireCaret: false)
    }

    var displayName: String { app?.localizedName ?? "Your writing" }
    var icon: NSImage? { app?.icon }
    var canWrite: Bool { snap != nil }
    var hasSelection: Bool { (snap?.selection.length ?? 0) > 0 }

    var focusText: String {
        guard let snap else { return "" }
        return hasSelection ? snap.selectedText : snap.paragraph
    }

    var context: WritingContext {
        guard let snap else { return WritingContext(before: "", appName: displayName) }
        var ctx = snap.context()
        ctx.selection = focusText
        return ctx
    }

    private var focusRange: NSRange? {
        guard let snap else { return nil }
        if hasSelection { return snap.selection }
        var r = snap.paragraphRange
        // Leave the paragraph's trailing newline in place.
        let s = snap.text.substring(with: r)
        let trailing = s.count - s.trimmingCharacters(in: .newlines).count
        r.length = max(0, r.length - (s.hasSuffix("\n") ? min(trailing, 1) : 0))
        return r
    }

    func restore() {
        app?.activate()
    }

    func replaceFocus(with text: String) {
        guard let snap, let range = focusRange else { TextInserter.copy(text); return }
        writeBack {
            AX.select(range, in: snap.element)
            TextInserter.paste(text)
        }
    }

    func insertAfterFocus(_ text: String) {
        guard let snap else { TextInserter.copy(text); return }
        let end = hasSelection ? NSMaxRange(snap.selection) : snap.selection.location
        let before = snap.text.substring(to: min(end, snap.text.length))
        let joined = Suggestion.joinSpacing(text, before: before)
        writeBack {
            AX.select(NSRange(location: end, length: 0), in: snap.element)
            TextInserter.paste(joined)
        }
    }

    private func writeBack(_ work: @escaping () -> Void) {
        restore()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }
}
