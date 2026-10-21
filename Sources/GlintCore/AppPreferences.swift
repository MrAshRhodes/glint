import AppKit
import Foundation

public struct KeyModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)

    /// Carbon `RegisterEventHotKey` modifier mask.
    public var carbon: UInt32 {
        var m: UInt32 = 0
        if contains(.command) { m |= 0x100 }
        if contains(.shift) { m |= 0x200 }
        if contains(.option) { m |= 0x800 }
        if contains(.control) { m |= 0x1000 }
        return m
    }

    public var cocoa: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if contains(.command) { f.insert(.command) }
        if contains(.shift) { f.insert(.shift) }
        if contains(.option) { f.insert(.option) }
        if contains(.control) { f.insert(.control) }
        return f
    }

    public init(cocoa: NSEvent.ModifierFlags) {
        var m: KeyModifiers = []
        if cocoa.contains(.command) { m.insert(.command) }
        if cocoa.contains(.shift) { m.insert(.shift) }
        if cocoa.contains(.option) { m.insert(.option) }
        if cocoa.contains(.control) { m.insert(.control) }
        self = m
    }
}

/// A global shortcut: macOS virtual key code + modifiers.
public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: KeyModifiers
    public init(keyCode: UInt32, modifiers: KeyModifiers) { self.keyCode = keyCode; self.modifiers = modifiers }

    public var carbonModifiers: UInt32 { modifiers.carbon }

    /// e.g. `⌃⌥⌘4`
    public var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (KeyCombo.keyNames[keyCode] ?? "key\(keyCode)")
    }

    static let keyNames: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
        46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

public enum HotkeyAction: String, Codable, CaseIterable, Sendable {
    case captureArea, captureAreaToClipboard, captureWindow, captureFullscreen, captureText, repeatLast

    public var displayName: String {
        switch self {
        case .captureArea: return "Capture area and open editor"
        case .captureAreaToClipboard: return "Capture area and copy to clipboard"
        case .captureWindow: return "Capture window"
        case .captureFullscreen: return "Capture full screen"
        case .captureText: return "Capture text (OCR)"
        case .repeatLast: return "Repeat last capture area"
        }
    }

    public var defaultCombo: KeyCombo {
        let m: KeyModifiers = [.control, .option, .command]
        switch self {
        case .captureArea: return KeyCombo(keyCode: 21, modifiers: m) // ⌃⌥⌘4
        case .captureAreaToClipboard: return KeyCombo(keyCode: 23, modifiers: m) // ⌃⌥⌘5
        case .captureWindow: return KeyCombo(keyCode: 22, modifiers: m) // ⌃⌥⌘6
        case .captureFullscreen: return KeyCombo(keyCode: 20, modifiers: m) // ⌃⌥⌘3
        case .captureText: return KeyCombo(keyCode: 26, modifiers: m) // ⌃⌥⌘7
        case .repeatLast: return KeyCombo(keyCode: 15, modifiers: m) // ⌃⌥⌘R
        }
    }
}

public enum AppTheme: String, Codable, CaseIterable, Sendable { case system, light, dark }

/// Typed wrapper around `UserDefaults`.
public final class AppPreferences {
    public static let shared = AppPreferences()

    public enum Key {
        public static let saveDirectory = "glint.saveDirectory"
        public static let historyDirectory = "glint.historyDirectory"
        public static let saveHistory = "glint.saveHistory"
        public static let saveRaw = "glint.saveRaw"
        public static let saveOutput = "glint.saveOutput"
        public static let copyToClipboardAfterCapture = "glint.copyToClipboardAfterCapture"
        public static let openEditorAfterCapture = "glint.openEditorAfterCapture"
        public static let autoBalance = "glint.autoBalance"
        public static let autoRedact = "glint.autoRedact"
        public static let autoRedactOptions = "glint.autoRedactOptions"
        public static let defaultPresetName = "glint.defaultPresetName"
        public static let hotkeys = "glint.hotkeys"
        public static let hideDockIcon = "glint.hideDockIcon"
        public static let launchAtLogin = "glint.launchAtLogin"
        public static let soundsEnabled = "glint.soundsEnabled"
        public static let notificationsEnabled = "glint.notificationsEnabled"
        public static let theme = "glint.theme"
        public static let closeAfterCopy = "glint.closeAfterCopy"
        public static let hideWindowsDuringCapture = "glint.hideWindowsDuringCapture"
        public static let fileNameTemplate = "glint.fileNameTemplate"
        public static let enableFileNameTemplate = "glint.enableFileNameTemplate"
        public static let exportFormat = "glint.exportFormat"
        public static let exportScale = "glint.exportScale"
        public static let compressToJPEG = "glint.compressToJPEG"
        public static let jpegQuality = "glint.jpegQuality"
        public static let lastRenderSettings = "glint.lastRenderSettings"
        public static let annotationColor = "glint.annotationColor"
        public static let redactColor = "glint.redactColor"
        public static let redactStyle = "glint.redactStyle"
        public static var all: [String] {
            [saveDirectory, historyDirectory, saveHistory, saveRaw, saveOutput, copyToClipboardAfterCapture,
             openEditorAfterCapture, autoBalance, autoRedact, autoRedactOptions, defaultPresetName, hotkeys,
             hideDockIcon, launchAtLogin, soundsEnabled, notificationsEnabled, theme, closeAfterCopy,
             hideWindowsDuringCapture, fileNameTemplate, enableFileNameTemplate, exportFormat, exportScale,
             compressToJPEG, jpegQuality, lastRenderSettings, annotationColor, redactColor, redactStyle]
        }
    }

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    // MARK: helpers
    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
    private func decode<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
    private func url(_ key: String, _ fallback: URL) -> URL {
        defaults.string(forKey: key).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? fallback
    }

    private static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    // MARK: folders & files
    /// Default Save / Save As folder (default `~/Desktop`).
    public var saveDirectory: URL {
        get { url(Key.saveDirectory, Self.home.appendingPathComponent("Desktop")) }
        set { defaults.set(newValue.path, forKey: Key.saveDirectory) }
    }
    /// Base of the `Raw/` + `Output/` history (default `~/Documents/Glint`).
    public var historyDirectory: URL {
        get { url(Key.historyDirectory, Self.home.appendingPathComponent("Documents/Glint")) }
        set { defaults.set(newValue.path, forKey: Key.historyDirectory) }
    }
    /// Master switch for keeping history.
    public var saveHistory: Bool {
        get { bool(Key.saveHistory, true) } set { defaults.set(newValue, forKey: Key.saveHistory) }
    }
    public var saveRaw: Bool { get { bool(Key.saveRaw, true) } set { defaults.set(newValue, forKey: Key.saveRaw) } }
    public var saveOutput: Bool { get { bool(Key.saveOutput, true) } set { defaults.set(newValue, forKey: Key.saveOutput) } }
    public var enableFileNameTemplate: Bool {
        get { bool(Key.enableFileNameTemplate, true) } set { defaults.set(newValue, forKey: Key.enableFileNameTemplate) }
    }
    public var fileNameTemplate: String {
        get { defaults.string(forKey: Key.fileNameTemplate) ?? FileNaming.defaultTemplate }
        set { defaults.set(newValue, forKey: Key.fileNameTemplate) }
    }
    public var exportFormat: ExportFormat {
        get { decode(Key.exportFormat, as: ExportFormat.self) ?? .plainPNG }
        set { encode(newValue, Key.exportFormat) }
    }
    public var exportScale: ExportScale {
        get { defaults.string(forKey: Key.exportScale).flatMap(ExportScale.init(rawValue:)) ?? .original }
        set { defaults.set(newValue.rawValue, forKey: Key.exportScale) }
    }
    public var compressToJPEG: Bool {
        get { bool(Key.compressToJPEG, false) } set { defaults.set(newValue, forKey: Key.compressToJPEG) }
    }
    public var jpegQuality: Double {
        get { defaults.object(forKey: Key.jpegQuality) == nil ? 0.8 : defaults.double(forKey: Key.jpegQuality) }
        set { defaults.set(newValue, forKey: Key.jpegQuality) }
    }

    /// History disabled → nil history directory.
    public var outputPaths: OutputPaths {
        OutputPaths(historyDirectory: saveHistory ? historyDirectory : nil, saveDirectory: saveDirectory,
                    fileNameTemplate: enableFileNameTemplate ? fileNameTemplate : FileNaming.defaultTemplate)
    }

    // MARK: behaviour
    public var copyToClipboardAfterCapture: Bool {
        get { bool(Key.copyToClipboardAfterCapture, false) } set { defaults.set(newValue, forKey: Key.copyToClipboardAfterCapture) }
    }
    public var openEditorAfterCapture: Bool {
        get { bool(Key.openEditorAfterCapture, true) } set { defaults.set(newValue, forKey: Key.openEditorAfterCapture) }
    }
    public var closeAfterCopy: Bool { get { bool(Key.closeAfterCopy, true) } set { defaults.set(newValue, forKey: Key.closeAfterCopy) } }
    public var hideWindowsDuringCapture: Bool {
        get { bool(Key.hideWindowsDuringCapture, true) } set { defaults.set(newValue, forKey: Key.hideWindowsDuringCapture) }
    }
    public var autoBalance: Bool { get { bool(Key.autoBalance, true) } set { defaults.set(newValue, forKey: Key.autoBalance) } }
    public var autoRedact: Bool { get { bool(Key.autoRedact, false) } set { defaults.set(newValue, forKey: Key.autoRedact) } }
    public var autoRedactOptions: SensitiveInfoOptions {
        get { decode(Key.autoRedactOptions, as: SensitiveInfoOptions.self) ?? .default }
        set { encode(newValue, Key.autoRedactOptions) }
    }
    public var redactStyle: RedactionStyle {
        get { defaults.string(forKey: Key.redactStyle).flatMap(RedactionStyle.init(rawValue:)) ?? .solid }
        set { defaults.set(newValue.rawValue, forKey: Key.redactStyle) }
    }
    public var redactColor: RGBAColor {
        get { defaults.string(forKey: Key.redactColor).flatMap(RGBAColor.init(hex:)) ?? .black }
        set { defaults.set(newValue.hexString, forKey: Key.redactColor) }
    }
    public var annotationColor: RGBAColor {
        get { defaults.string(forKey: Key.annotationColor).flatMap(RGBAColor.init(hex:)) ?? .red }
        set { defaults.set(newValue.hexString, forKey: Key.annotationColor) }
    }
    public var defaultPresetName: String? {
        get { defaults.string(forKey: Key.defaultPresetName) } set { defaults.set(newValue, forKey: Key.defaultPresetName) }
    }
    public var lastRenderSettings: RenderSettings? {
        get { decode(Key.lastRenderSettings, as: RenderSettings.self) } set { encode(newValue, Key.lastRenderSettings) }
    }

    // MARK: app
    public var hideDockIcon: Bool { get { bool(Key.hideDockIcon, true) } set { defaults.set(newValue, forKey: Key.hideDockIcon) } }
    /// Stored intent only; the app target registers the login item.
    public var launchAtLogin: Bool { get { bool(Key.launchAtLogin, false) } set { defaults.set(newValue, forKey: Key.launchAtLogin) } }
    public var soundsEnabled: Bool { get { bool(Key.soundsEnabled, true) } set { defaults.set(newValue, forKey: Key.soundsEnabled) } }
    public var notificationsEnabled: Bool {
        get { bool(Key.notificationsEnabled, true) } set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }
    public var theme: AppTheme {
        get { defaults.string(forKey: Key.theme).flatMap(AppTheme.init(rawValue:)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.theme) }
    }

    // MARK: hotkeys
    /// Stored overrides merged over the defaults.
    public var hotkeys: [HotkeyAction: KeyCombo] {
        get {
            var result = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0, $0.defaultCombo) })
            for (name, combo) in decode(Key.hotkeys, as: [String: KeyCombo].self) ?? [:] {
                if let a = HotkeyAction(rawValue: name) { result[a] = combo }
            }
            return result
        }
        set { encode(Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) }), Key.hotkeys) }
    }

    public func hotkey(for action: HotkeyAction) -> KeyCombo { hotkeys[action] ?? action.defaultCombo }

    public func setHotkey(_ combo: KeyCombo, for action: HotkeyAction) {
        var all = hotkeys
        all[action] = combo
        hotkeys = all
    }

    public func resetToDefaults() { Key.all.forEach { defaults.removeObject(forKey: $0) } }
}
