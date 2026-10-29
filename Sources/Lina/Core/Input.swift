import AppKit
import Carbon.HIToolbox

/// Marks events Lina synthesizes so its own event tap ignores them.
let linaEventMarker: Int64 = 0x4C_49_4E_41 // "LINA"

/// Writes text into whatever app has focus.
enum TextInserter {
    /// Types text as keyboard events — works in nearly every app and lands in its undo stack.
    static func type(_ text: String) {
        let src = CGEventSource(stateID: .privateState)
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let units = Array(line.utf16)
            var idx = 0
            while idx < units.count {
                let chunk = Array(units[idx..<min(idx + 18, units.count)])
                post(keyCode: 0, unicode: chunk, source: src)
                idx += 18
            }
            if i < lines.count - 1 { post(keyCode: CGKeyCode(kVK_Return), unicode: nil, source: src) }
        }
    }

    /// Pastes text via the clipboard (atomic, keeps formatting simple), then restores the clipboard.
    static func paste(_ text: String) {
        pasteRestoring { pb in pb.setString(text, forType: .string) }
    }

    /// Pastes a picture, for `/lina image`, then restores the clipboard.
    static func pasteImage(_ png: Data) {
        pasteRestoring { pb in
            pb.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        }
    }

    /// Deletes whatever is selected in the app in front.
    static func deleteSelection() {
        post(keyCode: CGKeyCode(kVK_Delete), unicode: nil, source: CGEventSource(stateID: .privateState))
    }

    /// Presses Delete `count` times, to take back characters the writer just typed (the "/lin" of "/lina").
    static func backspace(_ count: Int) {
        let src = CGEventSource(stateID: .privateState)
        for _ in 0..<max(0, count) { post(keyCode: CGKeyCode(kVK_Delete), unicode: nil, source: src) }
    }

    static func copyImage(_ png: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    private static func pasteRestoring(_ fill: (NSPasteboard) -> Void) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        pb.clearContents()
        fill(pb)
        // Tell clipboard managers this is transient.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            e?.flags = .maskCommand
            e?.setIntegerValueField(.eventSourceUserData, value: linaEventMarker)
            e?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func post(keyCode: CGKeyCode, unicode: [UniChar]?, source: CGEventSource?) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            e.flags = []
            if var u = unicode { e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u) }
            e.setIntegerValueField(.eventSourceUserData, value: linaEventMarker)
            e.post(tap: .cghidEventTap)
        }
    }
}

/// Global keyboard/mouse observer. Swallows keys only while a Lina card is waiting for a choice.
final class KeyMonitor {
    /// Return true to consume the event.
    var onKeyDown: ((CGEvent) -> Bool)?
    var onMouseDown: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func start() -> Bool {
        if let tap {
            if CGEvent.tapIsEnabled(tap: tap) { return true }
            // macOS disables a tap when access is revoked, and it stays dead after access comes back.
            CGEvent.tapEnable(tap: tap, enable: true)
            if CGEvent.tapIsEnabled(tap: tap) { return true }
            stop()
        }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon)
        else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == linaEventMarker { break }
            if onKeyDown?(event) == true { return nil }
        case .leftMouseDown, .rightMouseDown:
            onMouseDown?()
        default: break
        }
        return Unmanaged.passUnretained(event)
    }
}

extension CGEvent {
    var typedString: String {
        var len = 0
        var buf = [UniChar](repeating: 0, count: 8)
        keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
        return String(utf16CodeUnits: buf, count: len)
    }

    var keyCode: Int { Int(getIntegerValueField(.keyboardEventKeycode)) }
}

/// System-wide hotkey through Carbon — needs no extra permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    var handler: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var installed = false

    func register(_ key: LinaHotKey) {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if key == .off { return }
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKeyCenter.shared.handler?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        let (code, mods): (Int, Int) = switch key {
        case .optionSpace: (kVK_Space, optionKey)
        case .controlSpace: (kVK_Space, controlKey)
        case .commandShiftL: (kVK_ANSI_L, cmdKey | shiftKey)
        case .off: (0, 0)
        }
        let id = EventHotKeyID(signature: OSType(0x4C494E41), id: 1)
        RegisterEventHotKey(UInt32(code), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref)
    }
}
