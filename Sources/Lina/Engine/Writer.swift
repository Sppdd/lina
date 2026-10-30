import AppKit

/// Puts Lina's results into the field the writer is in, only after they press ⌘ + a number.
///
/// It selects the exact text through Accessibility and pastes over it. Where an app won't let Lina read or select
/// (some search boxes and web fields), it falls back to keystrokes: Delete as many times as needed, then paste.
/// That works in any field, as long as the caret is still right after the text being replaced.
@MainActor
enum Writer {
    /// A stretch of the writer's text, remembered when Lina started working on it.
    struct Spot: Equatable {
        let pid: pid_t
        /// Where it is in the field; `NSNotFound` when the field can't be read.
        let range: NSRange
        let expected: String
        /// When the field can't be read: how many characters right before the caret to take back instead.
        var backspaces: Int? = nil
        /// The writer's text before the spot as Lina last knew it, to fit spacing when the field can't be read.
        var before: String = ""
    }

    static func spot(_ range: NSRange, in snap: FocusSnapshot) -> Spot {
        Spot(pid: snap.pid, range: range, expected: snap.text.substring(with: range))
    }

    /// For fields Lina can't read: the last `count` characters before the caret.
    static func typed(_ count: Int, pid: pid_t, before: String = "") -> Spot {
        Spot(pid: pid, range: NSRange(location: NSNotFound, length: 0), expected: "", backspaces: count, before: before)
    }

    /// Re-reads the field and finds where the remembered text is now. The writer may have kept typing.
    static func locate(_ spot: Spot) -> (FocusSnapshot, NSRange)? {
        guard spot.range.location != NSNotFound,
              let snap = AX.snapshot(requireCaret: false), snap.pid == spot.pid else { return nil }
        let text = snap.text
        if NSMaxRange(spot.range) <= text.length, text.substring(with: spot.range) == spot.expected {
            return (snap, spot.range)
        }
        guard !spot.expected.isEmpty else { return nil }
        let found = text.range(of: spot.expected, options: .backwards)
        return found.location == NSNotFound ? nil : (snap, found)
    }

    /// The few characters between the spot and the caret, when the caret sits just after it.
    private static func tail(after range: NSRange, in snap: FocusSnapshot) -> String? {
        let caret = snap.selection.location
        guard snap.selection.length == 0, caret >= NSMaxRange(range), caret - NSMaxRange(range) <= 3,
              caret <= snap.text.length else { return nil }
        return snap.text.substring(with: NSRange(location: NSMaxRange(range), length: caret - NSMaxRange(range)))
    }

    private static func inFront(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Replaces the spot. `build` gets the text before and after it, to fit spacing.
    /// If the field can't be edited at all, the text goes on the clipboard and this returns false.
    @discardableResult
    static func replace(_ spot: Spot, build: (String, String) -> String) -> Bool {
        if let found = locate(spot) {
            let (snap, range) = found
            let before = snap.text.substring(to: range.location)
            let after = snap.text.substring(from: NSMaxRange(range))
            let text = build(before, after)
            if AX.select(range, in: snap.element) {
                if text.isEmpty { TextInserter.deleteSelection() } else { TextInserter.paste(text) }
                return true
            }
            // The app won't take a selection: if the caret is just after the spot (maybe past a `,` or `.`),
            // keystrokes do the same job: take back to the spot's start, then type the new text and that tail.
            if let tail = tail(after: range, in: snap), inFront(spot.pid) {
                TextInserter.backspace(range.length + (tail as NSString).length)
                let typed = text + tail
                if !typed.isEmpty { TextInserter.paste(typed) }
                return true
            }
            if !text.isEmpty { TextInserter.copy(text) }
            return false
        }
        let text = build(spot.before, "")
        if let n = spot.backspaces, inFront(spot.pid) {
            TextInserter.backspace(n)
            if !text.isEmpty { TextInserter.paste(text) }
            return true
        }
        if !text.isEmpty { TextInserter.copy(text) }
        return false
    }

    @discardableResult
    static func replace(_ spot: Spot, with text: String) -> Bool {
        replace(spot) { _, _ in text }
    }

    /// Replaces the spot with a picture.
    @discardableResult
    static func insertImage(_ spot: Spot, png: Data) -> Bool {
        if let found = locate(spot) {
            let (snap, range) = found
            if AX.select(range, in: snap.element) {
                TextInserter.pasteImage(png)
                return true
            }
            if let tail = tail(after: range, in: snap), tail.isEmpty, inFront(spot.pid) {
                TextInserter.backspace(range.length)
                TextInserter.pasteImage(png)
                return true
            }
        } else if let n = spot.backspaces, inFront(spot.pid) {
            TextInserter.backspace(n)
            TextInserter.pasteImage(png)
            return true
        }
        TextInserter.copyImage(png)
        return false
    }
}
