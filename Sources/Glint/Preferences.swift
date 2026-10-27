import AppKit
import Combine
import GlintCapture
import GlintCore
import GlintEditor
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PrefsModel: ObservableObject {
    static let rememberSettingsHelp = "Remember your last-used settings for your next screenshot. "
        + "To keep a look you can return to anytime, save these settings as a preset."

    let prefs: AppPreferences
    let store: PresetStore
    private var presetEditors: [UUID: EditorWindowController] = [:]
    init(prefs: AppPreferences, store: PresetStore) { self.prefs = prefs; self.store = store }

    func bind<T>(_ kp: ReferenceWritableKeyPath<AppPreferences, T>, then: (() -> Void)? = nil) -> Binding<T> {
        Binding(get: { self.prefs[keyPath: kp] },
                set: { self.prefs[keyPath: kp] = $0; self.objectWillChange.send(); self.changed(); then?() })
    }

    func changed() { NotificationCenter.default.post(name: .glintPreferencesChanged, object: nil) }

    func openPresetDesigner(_ design: PresetDesign, onSaved: @escaping (Preset) -> Void) {
        let id = UUID()
        let editor = EditorWindowController(design: design, preferences: prefs, presetStore: store)
        presetEditors[id] = editor
        editor.onClose = { [weak self] in self?.presetEditors[id] = nil }
        editor.onPresetSaved = { [weak self] preset in
            self?.objectWillChange.send()
            self?.changed()
            onSaved(preset)
        }
        editor.showEditor()
    }
}

// MARK: - Window

/// The Settings window: a native toolbar-style tab window (like Safari, Mail or Xcode settings) that
/// takes its title from the selected pane and resizes to fit each pane's content.
@MainActor
final class PreferencesWindowController: NSWindowController {
    static var shared: PreferencesWindowController!

    convenience init(prefs: AppPreferences, store: PresetStore) {
        let tabs = PreferencesTabViewController(model: PrefsModel(prefs: prefs, store: store))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenNone)
        self.init(window: window)
        tabs.restoreSelection()
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Settings panes, in toolbar order.
enum PreferencesPane: String, CaseIterable {
    case general, capture, output, editor, presets, about

    var title: String {
        switch self {
        case .general: return "General"
        case .capture: return "Capture"
        case .output: return "Output"
        case .editor: return "Editor"
        case .presets: return "Presets"
        case .about: return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .capture: return "viewfinder"
        case .output: return "square.and.arrow.down"
        case .editor: return "slider.horizontal.3"
        case .presets: return "square.stack"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class PreferencesTabViewController: NSTabViewController {
    static let contentWidth: CGFloat = 540
    static let selectedPaneKey = "prefs.selectedPane"
    private static let minimumContentHeight: CGFloat = 220

    init(model: PrefsModel) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        // No crossfade: it leaves the incoming pane under a stale toolbar blur on macOS 26.
        transitionOptions = [.allowUserInteraction]
        for pane in PreferencesPane.allCases {
            let item = NSTabViewItem(viewController: Self.host(pane, model: model))
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title)
            item.identifier = pane.rawValue
            addTabViewItem(item)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func host(_ pane: PreferencesPane, model: PrefsModel) -> NSViewController {
        let controller: NSViewController
        switch pane {
        case .general: controller = paneHost(GeneralTab(model: model))
        case .capture: controller = paneHost(CaptureTab(model: model))
        case .output: controller = paneHost(OutputTab(model: model))
        case .editor: controller = paneHost(EditorTab(model: model))
        case .presets: controller = paneHost(PresetsTab(model: model))
        case .about: controller = paneHost(AboutTab())
        }
        controller.title = pane.title
        return controller
    }

    private static func paneHost<Content: View>(_ content: Content) -> NSViewController {
        let host = NSHostingController(rootView: content.frame(width: contentWidth))
        host.sizingOptions = [.preferredContentSize]
        return host
    }

    var selectedPane: PreferencesPane? {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex) else { return nil }
        return (tabViewItems[selectedTabViewItemIndex].identifier as? String).flatMap(PreferencesPane.init(rawValue:))
    }

    func select(_ pane: PreferencesPane) {
        guard let index = tabViewItems.firstIndex(where: { ($0.identifier as? String) == pane.rawValue }) else { return }
        selectedTabViewItemIndex = index
    }

    func restoreSelection(defaults: UserDefaults = .standard) {
        if let stored = defaults.string(forKey: Self.selectedPaneKey), let pane = PreferencesPane(rawValue: stored) {
            select(pane)
        }
        fitWindowToSelectedPane(animated: false)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String { UserDefaults.standard.set(id, forKey: Self.selectedPaneKey) }
        view.window?.title = tabViewItem?.label ?? "Settings"
        fitWindowToSelectedPane(animated: view.window?.isVisible == true)
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard tabViewItems.indices.contains(selectedTabViewItemIndex),
              tabViewItems[selectedTabViewItemIndex].viewController === viewController else { return }
        fitWindowToSelectedPane(animated: view.window?.isVisible == true)
    }

    /// Resizes the window to the selected pane's ideal height, keeping its top edge in place.
    func fitWindowToSelectedPane(animated: Bool) {
        guard let window = view.window, let contentView = window.contentView,
              tabViewItems.indices.contains(selectedTabViewItemIndex),
              let pane = tabViewItems[selectedTabViewItemIndex].viewController else { return }
        window.title = tabViewItems[selectedTabViewItemIndex].label
        var height = pane.preferredContentSize.height
        if height <= 0 { height = pane.view.fittingSize.height }
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let chrome = window.frame.height - contentView.frame.height
        height = min(max(height.rounded(.up), Self.minimumContentHeight), screenHeight - chrome - 40)
        let delta = CGSize(width: Self.contentWidth - contentView.frame.width, height: height - contentView.frame.height)
        guard abs(delta.width) >= 1 || abs(delta.height) >= 1 else { return }
        var frame = window.frame
        frame.size.width += delta.width
        frame.size.height += delta.height
        frame.origin.y -= delta.height
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }
}

// MARK: - Shared building blocks

/// A grouped-form section the user can collapse. Its expanded state persists under
/// `prefs.section.<id>.expanded` so each pane opens the way it was left.
struct CollapsibleSection<Content: View>: View {
    static func storageKey(_ id: String) -> String { "prefs.section.\(id).expanded" }

    private let title: String
    private let summary: String?
    private let content: Content
    @AppStorage private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, id: String, expandedByDefault: Bool = true, summary: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self.content = content()
        _isExpanded = AppStorage(wrappedValue: expandedByDefault, Self.storageKey(id))
    }

    var body: some View {
        Section(isExpanded: $isExpanded.animation(reduceMotion ? nil : .snappy(duration: 0.22))) {
            content
        } header: {
            HStack(spacing: 6) {
                Text(title)
                if !isExpanded, let summary {
                    Text(summary).foregroundStyle(.tertiary).fontWeight(.regular)
                }
            }
        }
    }
}

extension View {
    /// Grouped settings form that only scrolls when its content outgrows the window.
    func preferencesPaneForm() -> some View {
        formStyle(.grouped).scrollBounceBehavior(.basedOnSize)
    }
}

final class Local<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}

extension Binding {
    func onChange(_ action: @escaping () -> Void) -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0; action() })
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var model: PrefsModel
    @AppStorage(ShellKey.showMenuBarIcon) private var showIcon = true
    @AppStorage(ShellKey.quickAccess) private var quickAccess = true
    @StateObject private var login = Local<String?>(nil)

    var body: some View {
        Form {
            Section {
                Toggle(isOn: model.bind(\.launchAtLogin) { applyLaunchAtLogin() }) {
                    Text("Launch at login")
                    Text("Open Glint automatically when you log in.")
                }
                if let loginError = login.value {
                    Label(loginError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Picker("Appearance", selection: model.bind(\.theme) { AppDelegate.applyTheme() }) {
                    Text("System").tag(AppTheme.system)
                    Text("Light").tag(AppTheme.light)
                    Text("Dark").tag(AppTheme.dark)
                }
            }
            Section("Menu bar & Dock") {
                Toggle("Show menu bar icon", isOn: $showIcon.onChange { model.changed() })
                Toggle(isOn: model.bind(\.hideDockIcon) { AppDelegate.applyActivationPolicy() }) {
                    Text("Hide Dock icon")
                    Text("Glint keeps running from the menu bar.")
                }
            }
            Section("Feedback") {
                Toggle("Play sounds", isOn: model.bind(\.soundsEnabled))
                Toggle("Show notifications", isOn: model.bind(\.notificationsEnabled))
                Toggle(isOn: $quickAccess) {
                    Text("Show quick-access thumbnail after capture")
                    Text("A floating preview lets you copy, drag or edit right away.")
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Reset All Preferences") {
                        model.prefs.resetToDefaults(); model.objectWillChange.send(); model.changed()
                        AppDelegate.applyTheme(); AppDelegate.applyActivationPolicy()
                    }
                    .help("Restore every setting to its default value")
                }
            }
        }
        .preferencesPaneForm()
    }

    private func applyLaunchAtLogin() {
        do {
            if model.prefs.launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            login.value = nil
        } catch {
            login.value = "Could not update the login item: \(error.localizedDescription)"
        }
    }
}

// MARK: - Capture

private struct CaptureTab: View {
    @ObservedObject var model: PrefsModel
    @AppStorage(ShellKey.timerSeconds) private var timer = 5
    @AppStorage(ShellKey.hideCursor) private var hideCursor = true
    @AppStorage(ShellKey.rememberArea) private var rememberArea = true
    @AppStorage private var snapToEdges: Bool

    init(model: PrefsModel) {
        self.model = model
        _snapToEdges = AppStorage(wrappedValue: false, AppPreferences.Key.snapToEdges, store: model.prefs.defaults)
    }

    var body: some View {
        Form {
            Section("Capture") {
                Picker("Default timer", selection: $timer) {
                    ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Toggle("Hide mouse cursor", isOn: $hideCursor.onChange { model.changed() })
                Toggle("Hide Glint windows while capturing", isOn: model.bind(\.hideWindowsDuringCapture))
            }
            CollapsibleSection("Selection", id: "selection") {
                Toggle("Remember last area", isOn: $rememberArea)
                Toggle(isOn: $snapToEdges.onChange { model.changed() }) {
                    Text("Snap selection to edges")
                    Text("Snap to window and display edges only. Hold Command to temporarily invert snapping. Shift still constrains the selection to a square.")
                }
            }
            CollapsibleSection("Global shortcuts", id: "shortcuts") {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    HotkeyRow(model: model, action: action)
                }
            }
        }
        .preferencesPaneForm()
    }
}

private struct HotkeyRow: View {
    @ObservedObject var model: PrefsModel
    let action: HotkeyAction

    var body: some View {
        let current = model.prefs.hotkey(for: action)
        LabeledContent(action.displayName) {
            HStack(spacing: 6) {
                ShortcutField(combo: Self.recorded(current), name: action.displayName) { new in
                    apply(KeyCombo(keyCode: new.keyCode, modifiers: KeyModifiers(rawValue: 0).union(Self.modifiers(new.modifiers))))
                }
                Button { apply(action.defaultCombo) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .disabled(current == action.defaultCombo)
                    .help("Restore default")
                    .accessibilityLabel("Restore default shortcut for \(action.displayName)")
            }
        }
    }

    private func apply(_ c: KeyCombo) {
        guard model.prefs.hotkey(for: action) != c else { return }
        model.prefs.setHotkey(c, for: action)
        model.objectWillChange.send()
        model.changed()
    }

    static func recorded(_ c: KeyCombo) -> RecordedKeyCombo {
        RecordedKeyCombo(keyCode: c.keyCode, modifiers: HotkeyModifiers(rawValue: c.carbonModifiers))
    }

    static func modifiers(_ m: HotkeyModifiers) -> KeyModifiers {
        var r: KeyModifiers = []
        if m.contains(.command) { r.insert(.command) }
        if m.contains(.shift) { r.insert(.shift) }
        if m.contains(.option) { r.insert(.option) }
        if m.contains(.control) { r.insert(.control) }
        return r
    }
}

/// Rounded shortcut field that shows the combo as key caps. Click it (or press Space when focused) and
/// type a shortcut; Esc cancels.
private struct ShortcutField: View {
    let combo: RecordedKeyCombo?
    let name: String
    let onRecord: (RecordedKeyCombo) -> Void
    @StateObject private var recording = Local<Bool>(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)

    var body: some View {
        HStack(spacing: 3) {
            if recording.value {
                Text("Type shortcut…").foregroundStyle(.secondary)
            } else if let combo {
                ForEach(Array(Self.caps(combo).enumerated()), id: \.offset) { _, cap in KeyCap(text: cap) }
            } else {
                Text("Click to record").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .frame(minWidth: 120, minHeight: 24)
        .background(shape.fill(.quaternary))
        .overlay(shape.strokeBorder(Color.accentColor, lineWidth: 2).opacity(recording.value ? 1 : 0))
        .overlay {
            ShortcutCapture(name: name, value: combo?.displayString ?? "None",
                            onRecordingChange: { recording.value = $0 }, onRecord: onRecord)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: recording.value)
        .help("Click and type a new shortcut. Esc cancels.")
    }

    static func caps(_ combo: RecordedKeyCombo) -> [String] {
        KeyGlyphs.modifierString(combo.modifiers).map(String.init) + [KeyGlyphs.keyName(combo.keyCode)]
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, text.count > 1 ? 4 : 0)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 0, y: 0.5)
    }
}

/// Transparent AppKit layer over `ShortcutField` that records key combos (it needs raw key codes).
private struct ShortcutCapture: NSViewRepresentable {
    let name: String
    let value: String
    let onRecordingChange: (Bool) -> Void
    let onRecord: (RecordedKeyCombo) -> Void

    func makeNSView(context: Context) -> ShortcutCaptureView { update(ShortcutCaptureView()) }
    func updateNSView(_ view: ShortcutCaptureView, context: Context) { _ = update(view) }

    private func update(_ view: ShortcutCaptureView) -> ShortcutCaptureView {
        view.setAccessibilityLabel("\(name) shortcut")
        view.setAccessibilityValue(value)
        view.onRecordingChange = { recording in DispatchQueue.main.async { onRecordingChange(recording) } }
        view.onRecord = { combo in DispatchQueue.main.async { onRecord(combo) } }
        return view
    }
}

final class ShortcutCaptureView: NSView {
    var onRecordingChange: ((Bool) -> Void)?
    var onRecord: ((RecordedKeyCombo) -> Void)?
    private var recording = false {
        didSet {
            guard oldValue != recording else { return }
            noteFocusRingMaskChanged()
            onRecordingChange?(recording)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Press to record a new shortcut")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    // Like buttons, only reachable with Tab when Full Keyboard Access is on; otherwise switching panes
    // would focus (and scroll to) the first shortcut field.
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    // While recording the field draws its own accent outline instead.
    override var focusRingMaskBounds: NSRect { recording ? .zero : bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }

    override func mouseDown(with event: NSEvent) { startRecording() }

    override func accessibilityPerformPress() -> Bool { startRecording(); return true }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            if event.keyCode == 49 || event.keyCode == 36 { startRecording() } else { super.keyDown(with: event) }
            return
        }
        let mods = HotkeyModifiers(event.modifierFlags)
        switch event.keyCode {
        case 53, 51, 117: recording = false // Esc and Delete leave the shortcut unchanged
        default:
            let isFunctionKey = (96...122).contains(Int(event.keyCode)) && event.keyCode != 114
            guard !mods.isEmpty || isFunctionKey else { NSSound.beep(); return }
            recording = false
            onRecord?(RecordedKeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods))
        }
    }

    private func startRecording() {
        recording = true
        window?.makeFirstResponder(self)
    }
}

// MARK: - Output

private enum FormatKind: String, CaseIterable { case png = "PNG", jpeg = "JPEG", heic = "HEIC" }

private struct OutputTab: View {
    @ObservedObject var model: PrefsModel

    private var kind: Binding<FormatKind> {
        Binding(get: {
            switch model.prefs.exportFormat { case .jpeg: return .jpeg; case .heic: return .heic; default: return .png }
        }, set: { k in
            let q = quality.wrappedValue
            switch k {
            case .png: model.prefs.exportFormat = .plainPNG
            case .jpeg: model.prefs.exportFormat = .jpeg(quality: q)
            case .heic: model.prefs.exportFormat = .heic(quality: q)
            }
            model.objectWillChange.send()
        })
    }

    private var quality: Binding<Double> {
        Binding(get: {
            switch model.prefs.exportFormat { case .jpeg(let q), .heic(let q): return q; default: return model.prefs.jpegQuality }
        }, set: { q in
            model.prefs.jpegQuality = q
            switch model.prefs.exportFormat {
            case .jpeg: model.prefs.exportFormat = .jpeg(quality: q)
            case .heic: model.prefs.exportFormat = .heic(quality: q)
            default: break
            }
            model.objectWillChange.send()
        })
    }

    private var exportSummary: String {
        var parts = [kind.wrappedValue.rawValue]
        if kind.wrappedValue != .png { parts.append("\(Int(quality.wrappedValue * 100))%") }
        switch model.prefs.exportScale {
        case .original: parts.append("Original size")
        case .x1: parts.append("1×")
        case .x2: parts.append("2×")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Form {
            Section("Folders") {
                FolderRow(title: "History folder (Raw/ + Output/)", url: model.bind(\.historyDirectory))
                FolderRow(title: "Save folder", url: model.bind(\.saveDirectory))
                Toggle("Keep history", isOn: model.bind(\.saveHistory))
                Toggle("Save untouched raw capture", isOn: model.bind(\.saveRaw))
                Toggle("Save styled output", isOn: model.bind(\.saveOutput))
            }
            CollapsibleSection("After capture", id: "afterCapture") {
                Toggle("Copy to clipboard", isOn: model.bind(\.copyToClipboardAfterCapture))
                Toggle(isOn: model.bind(\.openEditorAfterCapture)) {
                    Text("Open editor")
                    Text("When off, captures are saved directly.")
                }
                Toggle("Close editor after copying", isOn: model.bind(\.closeAfterCopy))
            }
            CollapsibleSection("Export", id: "export", expandedByDefault: false, summary: exportSummary) {
                Picker("Format", selection: kind) { ForEach(FormatKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                if kind.wrappedValue != .png {
                    LabeledContent("Quality") {
                        HStack(spacing: 8) {
                            Slider(value: quality, in: 0.1...1).labelsHidden()
                                .accessibilityLabel("Quality")
                            Text("\(Int(quality.wrappedValue * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 36, alignment: .trailing)
                        }
                    }
                }
                Picker("Scale", selection: model.bind(\.exportScale)) {
                    Text("Original").tag(ExportScale.original)
                    Text("1×").tag(ExportScale.x1)
                    Text("2×").tag(ExportScale.x2)
                }
                .pickerStyle(.segmented)
                TextField(text: model.bind(\.fileNameTemplate)) {
                    Text("File name")
                    Text("{datetime} and {uuid} are replaced.")
                }
                .help("{datetime} and {uuid} are replaced")
            }
            OutputRetentionSection(model: model)
        }
        .preferencesPaneForm()
    }
}

/// Keeping copied and dragged screenshots for Reopen Last Image, and how long Output keeps them.
/// Both settings need Keep history. While it is off they are dimmed and keep their stored choice, and nothing
/// here turns history back on.
struct OutputRetentionSection: View {
    static let title = "Reopen & cleanup"
    static let sectionID = "retention"
    static let keepTitle = "Keep copied and dragged screenshots for reopening"
    static let periodTitle = "Keep screenshots in Output for"
    /// Forever first, then the finite periods from shortest to longest.
    static let periods = OutputRetentionPeriod.allCases

    static let keepDetail = "Needs Keep history. Copied and dragged images are saved to Output/ "
        + "for Reopen Last Image, reusing the file Save styled output wrote. "
        + "Raw/ is never touched, whatever Save untouched raw capture is set to."
    static let periodDetail = "Forever never removes anything. A shorter period moves expired images to the Trash, "
        + "but only ones Glint saved to Output/ after you opted in. "
        + "Existing files, Raw/ and anything you save or export yourself are left alone."
    static let keepPausedDetail = "Needs Keep history, which is off. Nothing is kept for reopening until "
        + "you turn it on, and Glint never turns it on for you."
    static let periodPausedDetail = "Needs Keep history, which is off. Nothing is removed until you turn it on."

    static func isEnabled(_ prefs: AppPreferences) -> Bool { prefs.saveHistory }
    static func keepCaption(_ prefs: AppPreferences) -> String {
        isEnabled(prefs) ? keepDetail : keepPausedDetail
    }
    static func periodCaption(_ prefs: AppPreferences) -> String {
        isEnabled(prefs) ? periodDetail : periodPausedDetail
    }

    @ObservedObject var model: PrefsModel

    private var summary: String {
        guard Self.isEnabled(model.prefs) else { return "Needs Keep history" }
        return model.prefs.outputRetention.displayName
    }

    var body: some View {
        let enabled = Self.isEnabled(model.prefs)
        CollapsibleSection(Self.title, id: Self.sectionID, expandedByDefault: false, summary: summary) {
            Toggle(isOn: model.bind(\.keepCopiedImages)) {
                Text(Self.keepTitle)
                caption(Self.keepCaption(model.prefs))
            }
            .disabled(!enabled)
            Picker(selection: model.bind(\.outputRetention)) {
                ForEach(Self.periods) { Text($0.displayName).tag($0) }
            } label: {
                Text(Self.periodTitle)
                caption(Self.periodCaption(model.prefs))
            }
            .disabled(!enabled)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).fixedSize(horizontal: false, vertical: true)
    }
}

private struct FolderRow: View {
    let title: String
    @Binding var url: URL

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    p.canChooseFiles = false
                    p.canCreateDirectories = true
                    p.directoryURL = url
                    if p.runModal() == .OK, let u = p.url { url = u }
                }
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("Open in Finder")
                    .accessibilityLabel("Open \(title) in Finder")
            }
        } label: {
            Text(title)
            Text((url.path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.path)
        }
    }
}

// MARK: - Editor defaults

private struct EditorTab: View {
    @ObservedObject var model: PrefsModel

    private var presetName: Binding<String> {
        Binding(get: { model.prefs.defaultPresetName ?? model.store.defaultPreset?.name ?? "" },
                set: { name in
                    model.prefs.defaultPresetName = name
                    if let p = model.store.preset(named: name) { model.store.setDefault(id: p.id); try? model.store.save() }
                    model.objectWillChange.send()
                })
    }

    private var words: Binding<String> {
        Binding(get: { model.prefs.autoRedactOptions.customWords.joined(separator: ", ") },
                set: { text in
                    var o = model.prefs.autoRedactOptions
                    o.customWords = text.split(whereSeparator: { $0 == "," || $0 == "\n" })
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    model.prefs.autoRedactOptions = o
                    model.objectWillChange.send()
                })
    }

    private var redactSummary: String {
        let on = model.prefs.autoRedactOptions.categories.count
        return "\(on) of \(SensitiveCategory.allCases.count) types"
    }

    var body: some View {
        Form {
            Section {
                Picker("Default preset", selection: presetName) {
                    ForEach(model.store.presets, id: \.id) { Text($0.name).tag($0.name) }
                }
                Toggle(isOn: model.bind(\.rememberSettings)) {
                    Text("Remember settings")
                    Text(model.prefs.rememberSettings
                         ? "New screenshots start with your last-used settings."
                         : "New screenshots start with the default preset.")
                }
                .help(PrefsModel.rememberSettingsHelp)
            }
            Section("Automatic adjustments") {
                Toggle(isOn: model.bind(\.autoBalance)) {
                    Text("Auto-balance")
                    Text("Crop uniform borders around the screenshot.")
                }
                Toggle("Auto-redact sensitive info", isOn: model.bind(\.autoRedact))
            }
            if model.prefs.autoRedact {
                CollapsibleSection("Auto-redact", id: "autoRedact", expandedByDefault: false, summary: redactSummary) {
                    Label("Always uses solid fill. Review the image before sharing; detection can miss information.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(SensitiveCategory.allCases, id: \.self) { cat in
                        Toggle(cat.displayName, isOn: Binding(
                            get: { model.prefs.autoRedactOptions.categories.contains(cat) },
                            set: { on in
                                var o = model.prefs.autoRedactOptions
                                if on { o.categories.insert(cat) } else { o.categories.remove(cat) }
                                model.prefs.autoRedactOptions = o
                                model.objectWillChange.send()
                            }))
                    }
                    TextField(text: words, prompt: Text("e.g. Project Atlas, Jane Doe")) {
                        Text("Custom words (comma separated)")
                    }
                }
            }
        }
        .preferencesPaneForm()
    }
}
// MARK: - Presets

struct PresetStartingPoint: Identifiable {
    let id: String
    let name: String
    let detail: String
    let settings: RenderSettings

    static func choices(lastUsed: RenderSettings?, presets: [Preset]) -> [PresetStartingPoint] {
        var choices: [PresetStartingPoint] = []
        if let lastUsed {
            choices.append(PresetStartingPoint(id: "last-used", name: "Last used",
                                              detail: "Your latest editor settings", settings: lastUsed))
        }
        choices += presets.map {
            PresetStartingPoint(id: $0.id.uuidString, name: $0.name, detail: "Saved preset", settings: $0.settings)
        }
        choices += Preset.builtIn.filter { builtIn in !presets.contains { $0.id == builtIn.id } }.map {
            PresetStartingPoint(id: $0.id.uuidString, name: $0.name, detail: "Built-in", settings: $0.settings)
        }
        return choices
    }
}

@MainActor
final class NewPresetModel: ObservableObject {
    let choices: [PresetStartingPoint]
    let store: PresetStore
    @Published var selectedID: String
    @Published var name: String
    @Published var image: CGImage
    @Published var imageName = "Built-in sample image"
    @Published var imageRevision = 0
    @Published var errorMessage: String?
    private(set) var backingScale: CGFloat = 2

    init(prefs: AppPreferences, store: PresetStore) {
        self.store = store
        choices = PresetStartingPoint.choices(lastUsed: prefs.lastRenderSettings, presets: store.presets)
        selectedID = choices[0].id
        name = store.uniqueName("My preset")
        image = SampleImage.make()
    }

    var selected: PresetStartingPoint? { choices.first { $0.id == selectedID } }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var validationMessage: String? {
        if trimmedName.isEmpty { return "Enter a name for your preset." }
        if store.preset(named: trimmedName) != nil { return "A preset with this name already exists." }
        if selected == nil { return "Choose a starting point." }
        return nil
    }

    func design() throws -> PresetDesign {
        if let message = validationMessage { throw CreationError(message: message) }
        guard let selected else { throw CreationError(message: "Choose a starting point.") }
        return PresetDesign(image: image, backingScale: backingScale, settings: selected.settings, name: trimmedName)
    }

    func add() throws -> Preset {
        let design = try design()
        let previousDefault = store.defaultPresetID
        let preset = store.add(name: design.name, settings: design.settings)
        do {
            try store.save()
        } catch {
            store.delete(id: preset.id)
            store.defaultPresetID = previousDefault
            throw error
        }
        return preset
    }

    func useImage(at url: URL) throws {
        guard let loaded = NSImage(contentsOf: url),
              let pixels = loaded.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CreationError(message: "This file could not be opened as an image.")
        }
        image = pixels
        backingScale = loaded.size.width > 0 ? CGFloat(pixels.width) / loaded.size.width : 1
        imageName = url.lastPathComponent
        imageRevision += 1
        errorMessage = nil
    }

    private struct CreationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

private struct PresetsTab: View {
    @ObservedObject var model: PrefsModel
    @StateObject private var sel = Local<UUID?>(nil)
    @StateObject private var ticker = Local<Int>(0)
    @StateObject private var adding = Local<Bool>(false)
    @StateObject private var error = Local<String?>(nil)
    @StateObject private var sample = Local<CGImage>(SampleImage.make())

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Create a reusable look with a sample image, no screenshot needed.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.store.presets, id: \.id) { preset in
                        card(preset)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }
            .frame(minHeight: 220, idealHeight: 300)
            Divider()
            HStack(spacing: 8) {
                Button("Add Preset…") { adding.value = true }
                    .help("Choose a starting look and preview it on a sample image")
                Button("Edit…") { edit() }.disabled(sel.value == nil)
                Button("Rename…") { rename() }.disabled(sel.value == nil)
                Button("Delete") { delete() }
                    .disabled(sel.value == nil || model.store.presets.count <= 1)
                Spacer()
                Button("Set Default") { setDefault() }
                    .disabled(sel.value == nil || sel.value == model.store.defaultPreset?.id)
                Menu {
                    Button("Import…") { importPresets() }
                    Button("Export…") { exportPresets() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Import or export presets")
                .accessibilityLabel("Import or export presets")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            if let message = error.value {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $adding.value) {
            NewPresetSheet(model: model, onSaved: saved, onCustomize: openDesigner)
        }
        .onReceive(NotificationCenter.default.publisher(for: .glintPreferencesChanged)) { _ in
            ticker.value += 1
            model.objectWillChange.send()
        }
    }

    private func card(_ preset: Preset) -> some View {
        let selected = preset.id == sel.value
        let isDefault = preset.id == model.store.defaultPreset?.id
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            sel.value = preset.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                PresetThumbnail(settings: preset.settings, image: sample.value, backingScale: 2)
                    .padding(6)
                    .frame(height: 96)
                    .frame(maxWidth: .infinity)
                    .background(shape.fill(.quinary))
                    .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1),
                                                lineWidth: selected ? 2.5 : 0.5))
                HStack(spacing: 6) {
                    Text(preset.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
                    if isDefault {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule(style: .continuous).fill(.quaternary))
                    }
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { sel.value = preset.id; edit() })
        .contextMenu {
            Button("Edit…") { sel.value = preset.id; edit() }
            Button("Rename…") { sel.value = preset.id; rename() }
            Button("Set as Default") { sel.value = preset.id; setDefault() }.disabled(isDefault)
            Divider()
            Button("Delete") { sel.value = preset.id; delete() }.disabled(model.store.presets.count <= 1)
        }
        .accessibilityLabel(isDefault ? "\(preset.name), default" : preset.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Double-click to edit")
        .help(preset.name)
    }

    private func saved(_ preset: Preset) {
        sel.value = preset.id
        error.value = nil
        model.objectWillChange.send()
        model.changed()
    }

    private func openDesigner(_ design: PresetDesign) {
        model.openPresetDesigner(design, onSaved: saved)
    }

    private func edit() {
        guard let id = sel.value, let preset = model.store.presets.first(where: { $0.id == id }) else { return }
        openDesigner(PresetDesign(image: SampleImage.make(), backingScale: 2, settings: preset.settings,
                                  name: preset.name, editingID: preset.id))
    }

    private func setDefault() {
        guard let id = sel.value else { return }
        model.store.setDefault(id: id)
        model.prefs.defaultPresetName = model.store.presets.first { $0.id == id }?.name
        commit()
    }

    private func delete() {
        guard let id = sel.value, model.store.presets.count > 1 else { return }
        model.store.delete(id: id)
        sel.value = nil
        commit()
    }

    private func commit() {
        do {
            try model.store.save()
            error.value = nil
        } catch {
            self.error.value = "Could not save presets: \(error.localizedDescription)"
        }
        ticker.value += 1
        model.changed()
    }

    private func rename() {
        guard let id = sel.value, let p = model.store.presets.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename preset"
        let field = NSTextField(string: p.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            model.store.rename(id: id, to: field.stringValue)
            commit()
        }
    }

    private func importPresets() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let u = p.url { _ = try? model.store.importPresets(from: u); commit() }
    }

    private func exportPresets() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "glint-presets.json"
        if p.runModal() == .OK, let u = p.url { try? model.store.exportPresets(to: u) }
    }
}

private struct NewPresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: NewPresetModel
    let onSaved: (Preset) -> Void
    let onCustomize: (PresetDesign) -> Void

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    init(model: PrefsModel, onSaved: @escaping (Preset) -> Void, onCustomize: @escaping (PresetDesign) -> Void) {
        _draft = StateObject(wrappedValue: NewPresetModel(prefs: model.prefs, store: model.store))
        self.onSaved = onSaved
        self.onCustomize = onCustomize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Preset").font(.headline)
                Text("Choose a starting point. Add it as-is or customize the look in the editor.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(draft.choices) { choice in
                        startingPoint(choice)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            .frame(height: 290)
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name:").gridColumnAlignment(.trailing)
                    TextField("Preset name", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Preset name")
                }
                GridRow {
                    Text("Preview image:")
                    HStack {
                        Text(draft.imageName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button("Use My Image…") { chooseImage() }
                            .help("Use your own preview image; it is never stored in the preset")
                    }
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    footnote
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            HStack(spacing: 8) {
                Button("Customize in Editor…") {
                    do {
                        let design = try draft.design()
                        dismiss()
                        onCustomize(design)
                    } catch { draft.errorMessage = error.localizedDescription }
                }
                .disabled(draft.validationMessage != nil)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    do {
                        let preset = try draft.add()
                        onSaved(preset)
                        dismiss()
                    } catch { draft.errorMessage = "Could not save preset: \(error.localizedDescription)" }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.validationMessage != nil)
            }
            .padding(20)
        }
        .frame(width: 520)
    }

    @ViewBuilder
    private var footnote: some View {
        if let message = draft.errorMessage ?? draft.validationMessage {
            Text(message).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Only the look is saved. Your last-used editor settings stay unchanged.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func startingPoint(_ choice: PresetStartingPoint) -> some View {
        let selected = choice.id == draft.selectedID
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            draft.selectedID = choice.id
            draft.errorMessage = nil
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                PresetThumbnail(settings: choice.settings, image: draft.image, backingScale: draft.backingScale)
                    .id("\(choice.id)-\(draft.imageRevision)")
                    .padding(6)
                    .frame(height: 96)
                    .frame(maxWidth: .infinity)
                    .background(shape.fill(.quinary))
                    .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1),
                                                lineWidth: selected ? 2.5 : 0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(choice.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.name), \(choice.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(choice.name)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try draft.useImage(at: url) } catch { draft.errorMessage = error.localizedDescription }
    }
}

private struct PresetThumbnail: View {
    let settings: RenderSettings
    let image: CGImage
    let backingScale: CGFloat
    @StateObject private var rendered = Local<CGImage?>(nil)
    @StateObject private var finished = Local<Bool>(false)
    @StateObject private var error = Local<String?>(nil)

    var body: some View {
        Group {
            if let image = rendered.value {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else if finished.value {
                Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(error.value ?? "Customize in the editor to inspect this look.")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: settings) {
            let settings = settings, image = image, scale = backingScale
            let wallpaper: CGImage?
            if settings.usesDesktopWallpaper {
                switch DesktopWallpaper.current() {
                case .success(let image): wallpaper = image
                case .failure(let problem):
                    error.value = problem.localizedDescription
                    finished.value = true
                    return
                }
            } else {
                wallpaper = nil
            }
            let result = await Task.detached(priority: .userInitiated) {
                PresetPreview.render(settings: settings, image: image, backingScale: scale,
                                     fitting: CGSize(width: 420, height: 192), wallpaper: wallpaper)
            }.value
            guard !Task.isCancelled else { return }
            rendered.value = result
            finished.value = true
        }
    }
}

// MARK: - About / permissions

private struct AboutTab: View {
    private var copyright: String {
        (Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String) ?? "MIT License - Glint contributors"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                    .accessibilityHidden(true)
                    .padding(.bottom, 6)
                Text("Glint").font(.title2.bold())
                Text("Version \(AppInfo.version) · MIT licensed")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button("Check for Updates") { UpdateChecker.check() }
                Link(destination: GlintInfo.repositoryURL) {
                    Label("GitHub", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 16)
            VStack(spacing: 4) {
                Text("Updates are manual. Glint does not download or install them automatically.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Link("How to update with Homebrew or a download", destination: UpdateChecker.guideURL)
                    .font(.footnote)
            }
            .padding(.top, 10)
            GroupBox {
                PermissionsPane().padding(6)
            }
            .padding(.top, 20)
            Text(copyright)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 16)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
    }
}

struct PermissionsPane: View {
    static let reauthorizeTitle = "Re-authorize Screen Recording…"
    static let reauthorizeCaption = "Already switched on in System Settings but captures still fail? This can happen after an update. Glint will clear its old entry and request access again."
    static let accessHint = "Glint needs Screen Recording access to take screenshots. After switching it on, choose Quit & Reopen if macOS asks, or restart Glint yourself."

    @StateObject private var state = Local<Bool>(ScreenRecordingPermission.refreshGrant())
    @StateObject private var stale = Local<Bool>(ScreenRecordingPermission.needsReauthorization)
    @StateObject private var requestedHere = Local<Bool>(false)
    @StateObject private var working = Local<Bool>(false)
    @StateObject private var status = Local<String?>(nil)
    private var granted: Bool { state.value }
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                    .imageScale(.large)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(granted ? "Screen Recording is enabled" : "Screen Recording is required to capture")
                        .fontWeight(.medium)
                    if !granted {
                        Text(Self.accessHint)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if !granted {
                if stale.value {
                    VStack(alignment: .leading, spacing: 6) {
                        Button(Self.reauthorizeTitle) { reauthorize() }
                            .buttonStyle(.borderedProminent)
                            .disabled(working.value)
                        Text(Self.reauthorizeCaption)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Open System Settings") { ScreenRecordingPermission.openSystemSettings() }
                } else {
                    HStack {
                        Button("Request Access") {
                            requestedHere.value = true
                            ScreenRecordingPermission.request()
                            refresh()
                        }
                        Button("Open System Settings") { ScreenRecordingPermission.openSystemSettings() }
                    }
                }
                if let message = status.value {
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        state.value = ScreenRecordingPermission.refreshGrant()
        // A request made from this pane is still waiting on the user, not a stale entry.
        stale.value = !requestedHere.value && ScreenRecordingPermission.needsReauthorization(granted: state.value)
    }

    private func reauthorize() {
        working.value = true
        status.value = nil
        Task { @MainActor in
            let outcome = await ScreenRecordingPermission.reauthorize()
            if outcome == .requestedAgain { requestedHere.value = true }
            status.value = Self.message(for: outcome)
            working.value = false
            refresh()
        }
    }

    static func message(for outcome: ScreenRecordingPermission.ReauthorizationOutcome) -> String? {
        switch outcome {
        case .alreadyGranted:
            return nil
        case .requestedAgain:
            return "Glint’s old entry was cleared. Allow Screen Recording in System Settings, then choose Quit & Reopen if asked, or restart Glint yourself."
        case .missingBundleIdentifier:
            return "Glint is not running as an app, so it could not clear its old entry. In System Settings, remove Glint with “−”, add it again with “+”, then reopen Glint."
        case .resetFailed:
            return "Glint could not clear its old entry. In System Settings, remove Glint with “−”, add it again with “+”, then reopen Glint."
        }
    }
}

// MARK: - Permissions / onboarding window

@MainActor
final class PermissionsWindow {
    static let shared = PermissionsWindow()
    private var window: NSWindow?

    /// First launch always shows setup. Afterwards only a grant Glint saw before and has now lost
    /// brings it back; a request or denial alone never does (captures still surface the window).
    static func shouldPresentAtLaunch(granted: Bool, defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: ShellKey.onboarded)
            || ScreenRecordingPermission.lostRecordedGrant(granted: granted, defaults: defaults)
    }

    func show() {
        let content = NSHostingController(rootView: Self.content(
            needsReauthorization: ScreenRecordingPermission.needsReauthorization
        ))
        if let window {
            if !window.isVisible { window.contentViewController = content }
        } else {
            let w = NSWindow(contentViewController: content)
            w.title = "Glint Setup"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            window = w
        }
        UserDefaults.standard.set(true, forKey: ShellKey.onboarded)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private static let shortcuts: [(String, HotkeyAction)] = [
        ("Capture an area", .captureArea), ("Capture a window", .captureWindow), ("Capture the full screen", .captureFullscreen),
    ]

    private static func content(needsReauthorization: Bool) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 80, height: 80)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                    .accessibilityHidden(true)
                Text(needsReauthorization ? "Screen Recording needs attention" : "Welcome to Glint")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(needsReauthorization ? "Glint can’t capture until macOS allows Screen Recording again."
                                          : "Turn screenshots into polished images.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
            GroupBox {
                PermissionsPane().padding(6)
            }
            .padding(.top, 20)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shortcuts, id: \.1) { title, action in
                        HStack {
                            Text(title)
                            Spacer()
                            Text(HotkeyRow.recorded(AppPreferences.shared.hotkey(for: action)).displayString)
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text("Glint lives in the menu bar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .padding(.top, 12)
            Button {
                PermissionsWindow.shared.window?.close()
            } label: {
                Text("Done").frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 20)
        .frame(width: 440)
    }
}
