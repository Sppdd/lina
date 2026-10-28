import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// A moment captured from whatever text field the writer is focused on, in any app.
struct FocusSnapshot {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let appName: String
    let windowTitle: String
    /// Full field value. Indices below are UTF-16 offsets, as Accessibility reports them.
    let text: NSString
    let selection: NSRange
    /// Caret rectangle in Cocoa screen coordinates (origin bottom-left).
    let caretRect: CGRect?

    var before: String { text.substring(to: min(selection.location, text.length)) }
    var after: String {
        let start = min(selection.location + selection.length, text.length)
        return text.substring(from: start)
    }
    var selectedText: String {
        guard selection.length > 0, NSMaxRange(selection) <= text.length else { return "" }
        return text.substring(with: selection)
    }

    /// The paragraph that contains the caret.
    var paragraphRange: NSRange {
        text.paragraphRange(for: NSRange(location: min(selection.location, text.length), length: 0))
    }

    var paragraph: String {
        text.substring(with: paragraphRange).trimmingCharacters(in: .newlines)
    }

    func context() -> WritingContext {
        WritingContext(before: before, after: after, selection: selectedText,
                       appName: appName, windowTitle: windowTitle)
    }
}

enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that deep-links to Privacy & Security → Accessibility.
    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Asks for access in a way that also repairs a stale entry. Each rebuild of an ad-hoc-signed app
    /// changes its signature, so System Settings can show Lina switched on while macOS still says no.
    /// Clearing Lina's entry first makes the next request add a fresh one that matches this build.
    static func grantAccess() {
        if !isTrusted, let id = Bundle.main.bundleIdentifier {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", id]
            try? reset.run()
            reset.waitUntilExit()
        }
        requestTrust()
        openAccessibilitySettings()
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reads the focused text element of the frontmost app. Returns nil if there isn't a readable,
    /// non-secure text field in focus.
    static func snapshot(requireCaret: Bool = true) -> FocusSnapshot? {
        guard isTrusted, !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        // Electron apps only build their accessibility tree when asked.
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard let focused: AXUIElement = copy(appEl, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.25)

        let role: String = copy(focused, kAXRoleAttribute) ?? ""
        let subrole: String = copy(focused, kAXSubroleAttribute) ?? ""
        if subrole == (kAXSecureTextFieldSubrole as String) { return nil }
        let textRoles: Set<String> = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"]
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        guard textRoles.contains(role) || settable.boolValue else { return nil }

        guard let value: String = copy(focused, kAXValueAttribute) else { return nil }
        guard let rangeValue: AXValue = copy(focused, kAXSelectedTextRangeAttribute) else { return nil }
        var cf = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &cf) else { return nil }

        let ns = value as NSString
        let sel = NSRange(location: max(0, min(cf.location, ns.length)), length: max(0, cf.length))
        let caret = caretRect(focused, at: sel.location, textLength: ns.length)
        if requireCaret && caret == nil { return nil }

        var windowTitle = ""
        if let win: AXUIElement = copy(appEl, kAXFocusedWindowAttribute) {
            windowTitle = copy(win, kAXTitleAttribute) ?? ""
        }

        return FocusSnapshot(element: focused, pid: app.processIdentifier,
                             bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? "",
                             windowTitle: windowTitle, text: ns, selection: sel, caretRect: caret)
    }

    /// Just the caret of the focused text field and which app it's in, without copying the whole text.
    /// Cheap enough to call a few times a second for the ink drop.
    static func caret() -> (rect: CGRect, bundleID: String)? {
        guard isTrusted, !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.1)
        guard let focused: AXUIElement = copy(appEl, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.1)
        let subrole: String = copy(focused, kAXSubroleAttribute) ?? ""
        guard subrole != (kAXSecureTextFieldSubrole as String),
              let rangeValue: AXValue = copy(focused, kAXSelectedTextRangeAttribute)
        else { return nil }
        var cf = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &cf),
              let rect = caretRect(focused, at: cf.location, textLength: Int.max)
        else { return nil }
        return (rect, app.bundleIdentifier ?? "")
    }

    /// Selects a range in the given element (used before replacing a paragraph).
    @discardableResult
    static func select(_ range: NSRange, in element: AXUIElement) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let v = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    /// Where a range of text sits on screen, in Cocoa coordinates. Used to point at the writer's words.
    static func screenRect(for range: NSRange, in element: AXUIElement) -> CGRect? {
        guard let ax = bounds(element, CFRange(location: range.location, length: range.length)) else { return nil }
        return cocoa(ax)
    }

    // MARK: Internals

    private static func copy<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &out) == .success, let out else { return nil }
        if T.self == AXUIElement.self || T.self == AXValue.self { return (out as! T) }
        return out as? T
    }

    private static func bounds(_ el: AXUIElement, _ range: CFRange) -> CGRect? {
        var r = range
        guard let v = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            el, kAXBoundsForRangeParameterizedAttribute as CFString, v, &out) == .success,
            let out, CFGetTypeID(out) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect), rect.height > 1, rect.height < 400 else { return nil }
        return rect
    }

    private static func caretRect(_ el: AXUIElement, at loc: Int, textLength: Int) -> CGRect? {
        var axRect: CGRect?
        if let r = bounds(el, CFRange(location: loc, length: 0)), r.origin != .zero {
            axRect = CGRect(x: r.minX, y: r.minY, width: 1, height: r.height)
        }
        if axRect == nil, loc > 0, let r = bounds(el, CFRange(location: loc - 1, length: 1)) {
            axRect = CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height)
        }
        guard let ax = axRect else { return nil }
        return cocoa(ax)
    }

    /// Accessibility uses top-left origin on the primary screen; Cocoa uses bottom-left.
    private static func cocoa(_ ax: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: ax.minX, y: primaryHeight - ax.maxY, width: ax.width, height: ax.height)
    }
}
