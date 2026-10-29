import AppKit

/// Puts Lina's results into the field the writer is in, only after they press ⌘ + a number.
@MainActor
enum Writer {
    /// A stretch of the writer's text, remembered when Lina started working on it.
    struct Spot: Equatable {
        let pid: pid_t
        let range: NSRange
        let expected: String
    }

    static func spot(_ range: NSRange, in snap: FocusSnapshot) -> Spot {
        Spot(pid: snap.pid, range: range, expected: snap.text.substring(with: range))
    }

    /// Re-reads the field and finds where the remembered text is now. The writer may have kept typing.
    static func locate(_ spot: Spot) -> (FocusSnapshot, NSRange)? {
        guard let snap = AX.snapshot(requireCaret: false), snap.pid == spot.pid else { return nil }
        let text = snap.text
        if NSMaxRange(spot.range) <= text.length, text.substring(with: spot.range) == spot.expected {
            return (snap, spot.range)
        }
        guard !spot.expected.isEmpty else { return nil }
        let found = text.range(of: spot.expected, options: .backwards)
        return found.location == NSNotFound ? nil : (snap, found)
    }

    /// Replaces the spot. `build` gets the text before and after it, to fit spacing.
    /// If the field can't be edited, the text goes on the clipboard and this returns false.
    @discardableResult
    static func replace(_ spot: Spot, build: (String, String) -> String) -> Bool {
        guard let found = locate(spot) else {
            let fallback = build("", "")
            if !fallback.isEmpty { TextInserter.copy(fallback) }
            return false
        }
        let (snap, range) = found
        let before = snap.text.substring(to: range.location)
        let after = snap.text.substring(from: NSMaxRange(range))
        let text = build(before, after)
        guard AX.select(range, in: snap.element) else {
            if !text.isEmpty { TextInserter.copy(text) }
            return false
        }
        if text.isEmpty { TextInserter.deleteSelection() } else { TextInserter.paste(text) }
        return true
    }

    @discardableResult
    static func replace(_ spot: Spot, with text: String) -> Bool {
        replace(spot) { _, _ in text }
    }

    /// Replaces the spot with a picture.
    @discardableResult
    static func insertImage(_ spot: Spot, png: Data) -> Bool {
        guard let found = locate(spot), AX.select(found.1, in: found.0.element) else {
            TextInserter.copyImage(png)
            return false
        }
        TextInserter.pasteImage(png)
        return true
    }
}
