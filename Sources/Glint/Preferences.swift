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

@MainActor
final class PreferencesWindowController: NSWindowController {
    static var shared: PreferencesWindowController!

    convenience init(prefs: AppPreferences, store: PresetStore) {
        let host = NSHostingController(rootView: PreferencesView(model: PrefsModel(prefs: prefs, store: store)))
        let window = NSWindow(contentViewController: host)
        window.title = "Glint Preferences"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PreferencesView: View {
    @ObservedObject var model: PrefsModel

    var body: some View {
        TabView {
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
            CaptureTab(model: model).tabItem { Label("Capture", systemImage: "viewfinder") }
            OutputTab(model: model).tabItem { Label("Output", systemImage: "square.and.arrow.down") }
            EditorTab(model: model).tabItem { Label("Editor", systemImage: "slider.horizontal.3") }
            PresetsTab(model: model).tabItem { Label("Presets", systemImage: "square.stack") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 460)
        .padding(12)
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
            Toggle("Launch at login", isOn: model.bind(\.launchAtLogin) { applyLaunchAtLogin() })
            if let loginError = login.value { Text(loginError).font(.caption).foregroundStyle(.red) }
            Toggle("Hide Dock icon", isOn: model.bind(\.hideDockIcon) { AppDelegate.applyActivationPolicy() })
            Toggle("Show menu bar icon", isOn: $showIcon.onChange { model.changed() })
            Toggle("Play sounds", isOn: model.bind(\.soundsEnabled))
            Toggle("Show notifications", isOn: model.bind(\.notificationsEnabled))
            Toggle("Show quick-access thumbnail after capture", isOn: $quickAccess)
            Picker("Appearance", selection: model.bind(\.theme) { AppDelegate.applyTheme() }) {
                Text("System").tag(AppTheme.system)
                Text("Light").tag(AppTheme.light)
                Text("Dark").tag(AppTheme.dark)
            }
            Section {
                HStack {
                    Spacer()
                    Button("Reset all preferences") { model.prefs.resetToDefaults(); model.objectWillChange.send(); model.changed()
                        AppDelegate.applyTheme(); AppDelegate.applyActivationPolicy() }
                }
            }
        }
        .formStyle(.grouped)
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

final class Local<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}

extension Binding {
    func onChange(_ action: @escaping () -> Void) -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0; action() })
    }
}

// MARK: - Capture

private struct CaptureTab: View {
    @ObservedObject var model: PrefsModel
    @AppStorage(ShellKey.timerSeconds) private var timer = 5
    @AppStorage(ShellKey.hideCursor) private var hideCursor = true
    @AppStorage(ShellKey.rememberArea) private var rememberArea = true

    var body: some View {
        Form {
            Section("Global shortcuts") {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    HotkeyRow(model: model, action: action)
                }
            }
            Section("Capture") {
                Picker("Default timer", selection: $timer) {
                    ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Toggle("Hide mouse cursor", isOn: $hideCursor.onChange { model.changed() })
                Toggle("Remember last area", isOn: $rememberArea)
                Toggle("Hide Glint windows while capturing", isOn: model.bind(\.hideWindowsDuringCapture))
            }
        }
        .formStyle(.grouped)
    }
}

private struct HotkeyRow: View {
    @ObservedObject var model: PrefsModel
    let action: HotkeyAction
    @StateObject private var comboBox = Local<RecordedKeyCombo?>(nil)

    var body: some View {
        HStack {
            Text(action.displayName)
            Spacer()
            KeyComboRecorderView(combo: $comboBox.value)
                .frame(width: 130, height: 24)
            Button {
                apply(action.defaultCombo)
                comboBox.value = Self.recorded(action.defaultCombo)
            } label: { Image(systemName: "arrow.counterclockwise") }
            .buttonStyle(.borderless)
            .help("Restore default")
        }
        .onAppear { comboBox.value = Self.recorded(model.prefs.hotkey(for: action)) }
        .onChange(of: comboBox.value) { _, new in
            guard let new else { return }
            apply(KeyCombo(keyCode: new.keyCode, modifiers: KeyModifiers(rawValue: 0).union(Self.modifiers(new.modifiers))))
        }
    }

    private func apply(_ c: KeyCombo) {
        guard model.prefs.hotkey(for: action) != c else { return }
        model.prefs.setHotkey(c, for: action)
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

    var body: some View {
        Form {
            Section("Folders") {
                FolderRow(title: "History folder (Raw/ + Output/)", url: model.bind(\.historyDirectory))
                FolderRow(title: "Save folder", url: model.bind(\.saveDirectory))
                Toggle("Keep history", isOn: model.bind(\.saveHistory))
                Toggle("Save untouched raw capture", isOn: model.bind(\.saveRaw))
                Toggle("Save styled output", isOn: model.bind(\.saveOutput))
            }
            Section("Export") {
                Picker("Format", selection: kind) { ForEach(FormatKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                if kind.wrappedValue != .png {
                    HStack { Text("Quality"); Slider(value: quality, in: 0.1...1); Text("\(Int(quality.wrappedValue * 100))%").monospacedDigit() }
                }
                Picker("Scale", selection: model.bind(\.exportScale)) {
                    Text("Original").tag(ExportScale.original)
                    Text("1×").tag(ExportScale.x1)
                    Text("2×").tag(ExportScale.x2)
                }
                TextField("File name", text: model.bind(\.fileNameTemplate))
                    .help("{datetime} and {uuid} are replaced")
            }
            Section("After capture") {
                Toggle("Copy to clipboard", isOn: model.bind(\.copyToClipboardAfterCapture))
                Toggle("Open editor (otherwise save directly)", isOn: model.bind(\.openEditorAfterCapture))
                Toggle("Close editor after copying", isOn: model.bind(\.closeAfterCopy))
            }
        }
        .formStyle(.grouped)
    }
}

private struct FolderRow: View {
    let title: String
    @Binding var url: URL

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text((url.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
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

    var body: some View {
        Form {
            Picker("Default preset", selection: presetName) {
                ForEach(model.store.presets, id: \.id) { Text($0.name).tag($0.name) }
            }
            Toggle("Auto-balance (crop uniform borders)", isOn: model.bind(\.autoBalance))
            Toggle("Auto-redact sensitive info", isOn: model.bind(\.autoRedact))
            if model.prefs.autoRedact {
                Section("Auto-redact") {
                    Text("Always uses solid fill. Review the image before sharing; detection can miss information.")
                        .font(.caption).foregroundStyle(.secondary)
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
                    TextField("Custom words (comma separated)", text: words)
                }
            }
        }
        .formStyle(.grouped)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create a reusable look with a sample image, no screenshot needed.")
                .font(.callout).foregroundStyle(.secondary)
            List(selection: $sel.value) {
                ForEach(model.store.presets, id: \.id) { p in
                    HStack {
                        Text(p.name)
                        if p.id == model.store.defaultPreset?.id { Text("default").font(.caption).foregroundStyle(.secondary) }
                    }.tag(p.id)
                }
            }
            .id(ticker.value)
            HStack {
                Button("Add Preset…") { adding.value = true }
                    .help("Choose a starting look and preview it on a sample image")
                Button("Edit…") { edit() }.disabled(sel.value == nil)
                Spacer()
                Button("Set default") {
                    if let id = sel.value {
                        model.store.setDefault(id: id)
                        model.prefs.defaultPresetName = model.store.presets.first { $0.id == id }?.name
                        commit()
                    }
                }.disabled(sel.value == nil)
            }
            HStack {
                Button("Rename…") { rename() }.disabled(sel.value == nil)
                Button("Delete") { if let id = sel.value { model.store.delete(id: id); sel.value = nil; commit() } }
                    .disabled(sel.value == nil || model.store.presets.count <= 1)
                Spacer()
                Button("Import…") { importPresets() }
                Button("Export…") { exportPresets() }
            }
            if let message = error.value {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(8)
        .sheet(isPresented: $adding.value) {
            NewPresetSheet(model: model, onSaved: saved, onCustomize: openDesigner)
        }
        .onReceive(NotificationCenter.default.publisher(for: .glintPreferencesChanged)) { _ in
            ticker.value += 1
            model.objectWillChange.send()
        }
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

    init(model: PrefsModel, onSaved: @escaping (Preset) -> Void, onCustomize: @escaping (PresetDesign) -> Void) {
        _draft = StateObject(wrappedValue: NewPresetModel(prefs: model.prefs, store: model.store))
        self.onSaved = onSaved
        self.onCustomize = onCustomize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Preset").font(.title2.bold())
            Text("Choose a starting point. Add it as-is or customize the look in the editor.")
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(draft.choices) { choice in
                        startingPoint(choice)
                    }
                }
                .padding(2)
            }
            .frame(height: 280)
            HStack {
                Text(draft.imageName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Use My Image…") { chooseImage() }
                    .help("Use your own preview image; it is never stored in the preset")
            }
            HStack {
                Text("Name")
                TextField("Preset name", text: $draft.name).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Preset name")
            }
            if let message = draft.errorMessage ?? draft.validationMessage {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else {
                Text("Only the look is saved. Your last-used editor settings stay unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Customize in Editor…") {
                    do {
                        let design = try draft.design()
                        dismiss()
                        onCustomize(design)
                    } catch { draft.errorMessage = error.localizedDescription }
                }
                .disabled(draft.validationMessage != nil)
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
        }
        .padding(20)
        .frame(width: 480)
    }

    private func startingPoint(_ choice: PresetStartingPoint) -> some View {
        let selected = choice.id == draft.selectedID
        return Button {
            draft.selectedID = choice.id
            draft.errorMessage = nil
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                PresetThumbnail(settings: choice.settings, image: draft.image, backingScale: draft.backingScale)
                    .id("\(choice.id)-\(draft.imageRevision)")
                    .frame(height: 96)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.name).font(.callout.weight(.medium)).lineLimit(1)
                        Text(choice.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
            }
            .padding(10)
            .background(selected ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(
                selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
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
        .task {
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
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Glint").font(.title.bold())
            Text("Version \(AppInfo.version) · MIT licensed").foregroundStyle(.secondary)
            HStack {
                Button("Check for Updates") { UpdateChecker.check() }
                Button("GitHub") { NSWorkspace.shared.open(GlintInfo.repositoryURL) }
            }
            Text("Updates are manual. Glint does not download or install them automatically.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Link("How to update with Homebrew or a download", destination: UpdateChecker.guideURL)
                .font(.caption)
            Divider()
            PermissionsPane()
            Spacer()
        }
        .padding()
    }
}

struct PermissionsPane: View {
    @StateObject private var state = Local<Bool>(ScreenRecordingPermission.isGranted)
    private var granted: Bool { state.value }
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions").font(.headline)
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                Text(granted ? "Screen Recording is enabled" : "Screen Recording is required to capture")
                Spacer()
            }
            if !granted {
                Text("Glint needs Screen Recording access to take screenshots. After enabling it you may need to restart Glint.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Request Access") { ScreenRecordingPermission.request(); state.value = ScreenRecordingPermission.isGranted }
                    Button("Open System Settings") { ScreenRecordingPermission.openSystemSettings() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(timer) { _ in state.value = ScreenRecordingPermission.isGranted }
    }
}

// MARK: - Permissions / onboarding window

@MainActor
final class PermissionsWindow {
    static let shared = PermissionsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading) {
                        Text("Welcome to Glint").font(.title2.bold())
                        Text("Turn screenshots into polished images.").foregroundStyle(.secondary)
                    }
                }
                PermissionsPane()
                Divider()
                Text("Capture area with ⌃⌥⌘4, a window with ⌃⌥⌘6, or the full screen with ⌃⌥⌘3. Glint lives in the menu bar.")
                    .font(.callout)
                HStack { Spacer(); Button("Done") { PermissionsWindow.shared.window?.close() }.keyboardShortcut(.defaultAction) }
            }
            .padding(20)
            .frame(width: 420)
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Glint Setup"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
        }
        UserDefaults.standard.set(true, forKey: ShellKey.onboarded)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
