import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Modifier mask using Carbon values (usable directly with RegisterEventHotKey).
public struct HotkeyModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let command = HotkeyModifiers(rawValue: UInt32(cmdKey))
    public static let shift = HotkeyModifiers(rawValue: UInt32(shiftKey))
    public static let option = HotkeyModifiers(rawValue: UInt32(optionKey))
    public static let control = HotkeyModifiers(rawValue: UInt32(controlKey))

    public init(_ flags: NSEvent.ModifierFlags) {
        var m: HotkeyModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        self = m
    }
}

/// A recorded shortcut (key code + modifiers).
public struct RecordedKeyCombo: Hashable, Codable, Sendable {
    public var keyCode: UInt32
    public var modifiers: HotkeyModifiers
    public init(keyCode: UInt32, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
    public var displayString: String { KeyGlyphs.string(keyCode: keyCode, modifiers: modifiers) }
}

public enum KeyGlyphs {
    /// e.g. keyCode 21 (4) with ⌃⌥⌘ -> "⌃⌥⌘4". Modifier order follows macOS: ⌃ ⌥ ⇧ ⌘.
    public static func string(keyCode: UInt32, modifiers: HotkeyModifiers) -> String {
        modifierString(modifiers) + keyName(keyCode)
    }

    public static func modifierString(_ m: HotkeyModifiers) -> String {
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s
    }

    public static func keyName(_ code: UInt32) -> String {
        names[code] ?? "Key\(code)"
    }

    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 115: "↖", 119: "↘",
        116: "⇞", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        82: "Num0", 83: "Num1", 84: "Num2", 85: "Num3", 86: "Num4", 87: "Num5", 88: "Num6",
        89: "Num7", 91: "Num8", 92: "Num9", 76: "⌤",
    ]
}

public enum HotkeyError: Error, LocalizedError {
    case registrationFailed(OSStatus)
    public var errorDescription: String? {
        switch self { case .registrationFailed(let s): return "Hotkey registration failed (OSStatus \(s)); it may be in use." }
    }
}

/// Global hotkeys via Carbon RegisterEventHotKey (no Accessibility permission required).
@MainActor
public final class HotkeyCenter {
    public static let shared = HotkeyCenter()

    private struct Entry { let ref: EventHotKeyRef; let handler: () -> Void; let numericID: UInt32 }
    private var entries: [String: Entry] = [:]
    private var byNumeric: [UInt32: String] = [:]
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x474C4E54 // 'GLNT'

    private init() {}

    /// Registers (replacing any existing hotkey with the same id).
    public func register(id: String, keyCode: UInt32, modifiers: HotkeyModifiers,
                         handler: @escaping () -> Void) throws {
        unregister(id: id)
        installHandlerIfNeeded()
        let numeric = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: Self.signature, id: numeric)
        let status = RegisterEventHotKey(keyCode, modifiers.rawValue, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { throw HotkeyError.registrationFailed(status) }
        entries[id] = Entry(ref: ref, handler: handler, numericID: numeric)
        byNumeric[numeric] = id
    }

    public func register(id: String, combo: RecordedKeyCombo, handler: @escaping () -> Void) throws {
        try register(id: id, keyCode: combo.keyCode, modifiers: combo.modifiers, handler: handler)
    }

    public func unregister(id: String) {
        guard let e = entries.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(e.ref)
        byNumeric[e.numericID] = nil
    }

    public func unregisterAll() {
        for id in Array(entries.keys) { unregister(id: id) }
    }

    public var registeredIDs: [String] { Array(entries.keys) }

    fileprivate func fire(numeric: UInt32) {
        guard let id = byNumeric[numeric], let e = entries[id] else { return }
        e.handler()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if st == noErr, hk.signature == HotkeyCenter.signature {
                let n = hk.id
                DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyCenter.shared.fire(numeric: n) } }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}

// MARK: - Recorder UI

public final class KeyComboRecorderNSView: NSView {
    public var combo: RecordedKeyCombo? { didSet { needsDisplay = true } }
    public var onChange: ((RecordedKeyCombo?) -> Void)?
    private var recording = false { didSet { needsDisplay = true } }

    public override var acceptsFirstResponder: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 24) }

    public override func mouseDown(with event: NSEvent) {
        recording = true
        window?.makeFirstResponder(self)
    }

    public override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        keyDown(with: event)
        return true
    }

    public override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        let mods = HotkeyModifiers(event.modifierFlags)
        switch event.keyCode {
        case 53: recording = false // Esc cancels
        case 51, 117: // delete clears
            combo = nil; recording = false; onChange?(nil)
        default:
            let isFunctionKey = (96...122).contains(Int(event.keyCode)) && event.keyCode != 114
            guard !mods.isEmpty || isFunctionKey else { NSSound.beep(); return }
            let c = RecordedKeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods)
            combo = c; recording = false; onChange?(c)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill(); path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1; path.stroke()
        let text = recording ? "Type shortcut…" : (combo?.displayString ?? "Click to record")
        let color: NSColor = (recording || combo == nil) ? .secondaryLabelColor : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                withAttributes: attrs)
    }
}

public struct KeyComboRecorderView: NSViewRepresentable {
    @Binding public var combo: RecordedKeyCombo?
    public init(combo: Binding<RecordedKeyCombo?>) { self._combo = combo }

    public func makeNSView(context: Context) -> KeyComboRecorderNSView {
        let v = KeyComboRecorderNSView()
        v.combo = combo
        v.onChange = { c in DispatchQueue.main.async { self.combo = c } }
        return v
    }

    public func updateNSView(_ v: KeyComboRecorderNSView, context: Context) {
        if v.combo != combo { v.combo = combo }
        v.onChange = { c in DispatchQueue.main.async { self.combo = c } }
    }
}
