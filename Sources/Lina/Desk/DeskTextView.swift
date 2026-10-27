import AppKit
import Carbon.HIToolbox

extension NSAttributedString.Key {
    static let linaGhost = NSAttributedString.Key("LinaGhost")
}

/// The Desk's page: a calm, centered column of serif text with true inline ghost text,
/// typewriter scrolling and an optional focus mode that dims everything but the current paragraph.
final class DeskTextView: NSTextView {
    var onTextChange: ((String) -> Void)?
    var onPause: (() -> Void)?

    var focusMode = false { didSet { applyFocus() } }
    var typewriter = true { didSet { needsLayout = true; layoutInsets(); centerCaret(animated: true) } }

    static let columnWidth: CGFloat = 660
    private var mutatingGhost = false
    private var pauseTimer: Timer?

    static func make() -> (NSScrollView, DeskTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.nsPaper
        scroll.scrollerStyle = .overlay

        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: columnWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = DeskTextView(frame: .zero, textContainer: container)
        tv.minSize = .zero
        tv.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.isAutomaticDashSubstitutionEnabled = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.drawsBackground = true
        tv.backgroundColor = Theme.nsPaper
        tv.insertionPointColor = Theme.nsInk
        tv.selectedTextAttributes = [.backgroundColor: Theme.nsInk.withAlphaComponent(0.18)]
        tv.font = DeskTextView.bodyFont
        tv.typingAttributes = DeskTextView.baseAttributes
        tv.defaultParagraphStyle = DeskTextView.paragraph
        scroll.documentView = tv
        return (scroll, tv)
    }

    static let bodyFont = Theme.nsSerif(19)

    static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.42
        p.paragraphSpacing = 12
        return p
    }()

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
    }

    func load(_ text: String) {
        mutatingGhost = true
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.baseAttributes))
        mutatingGhost = false
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        applyFocus()
    }

    /// The page's text without any ghost.
    var cleanString: String {
        guard let g = ghostRange else { return string }
        return (string as NSString).replacingCharacters(in: g, with: "")
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        layoutInsets()
    }

    private func layoutInsets() {
        let w = enclosingScrollView?.contentSize.width ?? bounds.width
        let h = enclosingScrollView?.contentSize.height ?? 600
        let side = max(40, (w - Self.columnWidth) / 2)
        let vertical = typewriter ? max(80, h * 0.42) : 72
        let inset = NSSize(width: side, height: vertical)
        if textContainerInset != inset { textContainerInset = inset }
    }

    // MARK: Ghost text

    var ghostRange: NSRange? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.linaGhost, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value != nil { found = range; stop.pointee = true }
        }
        return found
    }

    var ghostText: String? { ghostRange.map { (string as NSString).substring(with: $0) } }

    func showGhost(_ text: String) {
        guard selectedRange().length == 0, !text.isEmpty, let storage = textStorage else { return }
        clearGhost()
        let loc = selectedRange().location
        var attrs = Self.baseAttributes
        attrs[.foregroundColor] = Theme.nsGhost
        attrs[.linaGhost] = true
        mutatingGhost = true
        storage.beginEditing()
        storage.insert(NSAttributedString(string: text, attributes: attrs), at: loc)
        storage.endEditing()
        setSelectedRange(NSRange(location: loc, length: 0))
        typingAttributes = Self.baseAttributes
        mutatingGhost = false
    }

    func clearGhost() {
        guard let g = ghostRange, let storage = textStorage else { return }
        let sel = selectedRange()
        mutatingGhost = true
        storage.beginEditing()
        storage.deleteCharacters(in: g)
        storage.endEditing()
        if sel.location > g.location {
            setSelectedRange(NSRange(location: max(g.location, sel.location - g.length), length: sel.length))
        }
        mutatingGhost = false
    }

    /// Keeps the ghost and turns it into real, undoable text.
    @discardableResult
    func acceptGhost(wordOnly: Bool = false) -> String? {
        guard let text = ghostText else { return nil }
        var take = text
        if wordOnly {
            let chars = Array(text)
            var i = 0
            while i < chars.count, chars[i] == " " { i += 1 }
            while i < chars.count, chars[i] != " " { i += 1 }
            take = String(chars[..<i])
        }
        let rest = String(text.dropFirst(take.count))
        clearGhost()
        insertText(take, replacementRange: selectedRange())
        if !rest.trimmingCharacters(in: .whitespaces).isEmpty { showGhost(rest) }
        return take
    }

    // MARK: Events

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .shift, .option])
        if let ghost = ghostText {
            if Int(event.keyCode) == kVK_Tab && (mods.isEmpty || mods == .option) {
                if let accepted = acceptGhost(wordOnly: mods == .option) {
                    WritingStats.shared.suggestionAccepted(words: WordCount.count(accepted))
                }
                if ghostRange == nil { schedulePause(after: 0.45) }
                return
            }
            if Int(event.keyCode) == kVK_Escape { clearGhost(); return }
            if let chars = event.characters, !chars.isEmpty, mods.isDisjoint(with: [.command, .control]),
               ghost.hasPrefix(chars), chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                // Typing along with the ghost: let the real text grow into it.
                let rest = String(ghost.dropFirst(chars.count))
                clearGhost()
                super.keyDown(with: event)
                if !rest.isEmpty { showGhost(rest) }
                return
            }
            clearGhost()
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self { clearGhost() }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        clearGhost()
        super.mouseDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        guard !mutatingGhost else { return }
        onTextChange?(cleanString)
        schedulePause()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !mutatingGhost else { return }
        applyFocus()
        if !stillSelecting { centerCaret(animated: true) }
    }

    private func schedulePause(after seconds: Double? = nil) {
        pauseTimer?.invalidate()
        let delay = seconds ?? max(0.35, AppSettings.sharedDebounce / 1000)
        pauseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.onPause?()
        }
    }

    // MARK: Focus & typewriter

    private func applyFocus() {
        guard let lm = layoutManager, let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        guard focusMode, storage.length > 0 else { return }
        let ns = string as NSString
        let current = ns.paragraphRange(for: NSRange(location: min(selectedRange().location, ns.length), length: 0))
        let dim = NSColor.tertiaryLabelColor
        if current.location > 0 {
            lm.addTemporaryAttribute(.foregroundColor, value: dim,
                                     forCharacterRange: NSRange(location: 0, length: current.location))
        }
        let end = NSMaxRange(current)
        if end < storage.length {
            lm.addTemporaryAttribute(.foregroundColor, value: dim,
                                     forCharacterRange: NSRange(location: end, length: storage.length - end))
        }
    }

    func centerCaret(animated: Bool) {
        guard typewriter, let lm = layoutManager, let tc = textContainer, let scroll = enclosingScrollView else { return }
        let loc = min(selectedRange().location, (string as NSString).length)
        var rect: NSRect
        if loc >= (string as NSString).length {
            rect = lm.extraLineFragmentRect
            if rect.height == 0, lm.numberOfGlyphs > 0 {
                rect = lm.lineFragmentRect(forGlyphAt: lm.numberOfGlyphs - 1, effectiveRange: nil)
            }
        } else {
            let glyph = lm.glyphIndexForCharacter(at: loc)
            rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        _ = tc
        let y = rect.midY + textContainerOrigin.y
        let visible = scroll.contentView.bounds.height
        let targetY = max(0, min(y - visible * 0.45, bounds.height - visible))
        let clip = scroll.contentView
        guard abs(clip.bounds.origin.y - targetY) > 2 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
            }
        } else {
            clip.setBoundsOrigin(NSPoint(x: 0, y: targetY))
        }
        scroll.reflectScrolledClipView(clip)
    }
}

extension AppSettings {
    /// Read without hopping actors from AppKit callbacks (always on main).
    nonisolated static var sharedDebounce: Double {
        let v = UserDefaults.standard.double(forKey: "debounceMs")
        return v > 0 ? v : 550
    }
}
