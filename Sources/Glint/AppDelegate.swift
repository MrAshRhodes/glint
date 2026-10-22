import AppKit
import GlintCapture
import GlintCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let prefs: AppPreferences
    let presetStore = PresetStore()
    lazy var pipeline = CapturePipeline(prefs: prefs, presetStore: presetStore)
    lazy var urlCaptureHandler: URLCaptureHandler = {
        let pipeline = pipeline
        return URLCaptureHandler(services: .init(
            isCaptureBusy: { pipeline.isBusy },
            startCapture: { pipeline.start($0) }
        ))
    }()
    private var statusItem: NSStatusItem?
    private let menu: NSMenu

    init(prefs: AppPreferences = .shared, menu: NSMenu = NSMenu()) {
        self.prefs = prefs
        self.menu = menu
        super.init()
    }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.applyActivationPolicy()
        Self.applyTheme()
        installMainMenu()
        PreferencesWindowController.shared = PreferencesWindowController(prefs: prefs, store: presetStore)
        pipeline.onStatusTitle = { [weak self] title in self?.statusItem?.button?.title = title ?? "" }
        menu.delegate = self
        updateStatusItem()
        registerHotkeys()
        NotificationCenter.default.addObserver(forName: .glintPreferencesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.registerHotkeys()
                self?.updateStatusItem()
                let cursor = UserDefaults.standard.object(forKey: ShellKey.hideCursor) as? Bool ?? true
                ScreenCapturer.shared.options.hideCursor = cursor
            }
        }
        if PermissionsWindow.shouldPresentAtLaunch(granted: ScreenRecordingPermission.refreshGrant()) {
            PermissionsWindow.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { PreferencesWindowController.shared.present() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL { pipeline.openFile(url) } else if url.scheme == GlintInfo.urlScheme { handle(url: url) }
        }
    }

    static func applyActivationPolicy() {
        NSApp.setActivationPolicy(AppPreferences.shared.hideDockIcon ? .accessory : .regular)
    }

    static func applyTheme() {
        switch AppPreferences.shared.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: URL scheme (glint://capture-area, open?file=, preset?name=)

    func handle(url: URL) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let action = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        if urlCaptureHandler.handle(action: action) { return }
        func param(_ name: String) -> String? { comps?.queryItems?.first { $0.name == name }?.value }
        switch action {
        case "open":
            if let file = param("file") { pipeline.openFile(URL(fileURLWithPath: (file as NSString).expandingTildeInPath)) }
        case "preset":
            if let name = param("name"), let p = presetStore.preset(named: name) {
                prefs.defaultPresetName = p.name
                presetStore.setDefault(id: p.id)
                try? presetStore.save()
            }
        case "preferences": PreferencesWindowController.shared.present()
        default: NSSound.beep()
        }
    }

    // MARK: hotkeys

    private func registerHotkeys() {
        let center = HotkeyCenter.shared
        for action in HotkeyAction.allCases {
            let combo = prefs.hotkey(for: action)
            let modifiers = HotkeyModifiers(rawValue: combo.carbonModifiers)
            try? center.register(id: action.rawValue, keyCode: combo.keyCode, modifiers: modifiers) { [weak self] in
                self?.perform(action)
            }
        }
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .captureArea: pipeline.start(.area)
        case .captureAreaToClipboard: pipeline.start(.areaToClipboard)
        case .captureWindow: pipeline.start(.window)
        case .captureFullscreen: pipeline.start(.fullscreen)
        case .captureText: pipeline.start(.text)
        case .repeatLast: pipeline.start(.repeatLast)
        }
    }

    // MARK: status item & menu

    private func updateStatusItem() {
        let show = UserDefaults.standard.object(forKey: ShellKey.showMenuBarIcon) as? Bool ?? true
        if show, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: GlintInfo.name)
            image?.isTemplate = true
            item.button?.image = image
            item.button?.imagePosition = .imageLeading
            item.menu = menu
            statusItem = item
        } else if !show, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()
        add(menu, "Capture Area", #selector(captureArea), hotkey: .captureArea)
        add(menu, "Capture Window", #selector(captureWindow), hotkey: .captureWindow)
        add(menu, "Capture Fullscreen", #selector(captureFullscreen), hotkey: .captureFullscreen)
        add(menu, "Capture Text (OCR)", #selector(captureText), hotkey: .captureText)
        add(menu, "Repeat Last Area", #selector(repeatLast), hotkey: .repeatLast)

        let timer = NSMenuItem(title: "Capture with Timer", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for s in [3, 5, 10] {
            let item = NSMenuItem(title: "\(s) seconds", action: #selector(timerCapture(_:)), keyEquivalent: "")
            item.tag = s
            item.target = self
            sub.addItem(item)
        }
        timer.submenu = sub
        menu.addItem(timer)
        add(menu, "Snap to Edges", #selector(toggleSnapToEdges)).state = prefs.snapToEdges ? .on : .off
        menu.addItem(.separator())

        add(menu, "Open Image…", #selector(openImage), key: "o")
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let urls = RecentFiles.urls
        if urls.isEmpty {
            recentMenu.addItem(withTitle: "No Recent Items", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            for url in urls {
                let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
                item.representedObject = url
                item.target = self
                recentMenu.addItem(item)
            }
            recentMenu.addItem(.separator())
            add(recentMenu, "Clear Menu", #selector(clearRecent))
        }
        recent.submenu = recentMenu
        menu.addItem(recent)
        add(menu, "Show Output Folder", #selector(showOutput))
        add(menu, "Show Raw Folder", #selector(showRaw))
        menu.addItem(.separator())
        add(menu, "Preferences…", #selector(showPreferences), key: ",")
        add(menu, "Check for Updates…", #selector(checkUpdates))
        add(menu, "About Glint", #selector(showAbout))
        menu.addItem(.separator())
        add(menu, "Quit Glint", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
                     hotkey: HotkeyAction? = nil, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        if let hotkey {
            let combo = prefs.hotkey(for: hotkey)
            let name = KeyCombo(keyCode: combo.keyCode, modifiers: []).displayString
            if name.count == 1 {
                item.keyEquivalent = name.lowercased()
                item.keyEquivalentModifierMask = combo.modifiers.cocoa
            }
        }
        menu.addItem(item)
        return item
    }

    @objc private func captureArea() { pipeline.start(.area) }
    @objc private func captureWindow() { pipeline.start(.window) }
    @objc private func captureFullscreen() { pipeline.start(.fullscreen) }
    @objc private func captureText() { pipeline.start(.text) }
    @objc private func repeatLast() { pipeline.start(.repeatLast) }
    @objc private func timerCapture(_ sender: NSMenuItem) { pipeline.start(.timer(sender.tag)) }
    @objc private func toggleSnapToEdges() {
        prefs.snapToEdges.toggle()
        NotificationCenter.default.post(name: .glintPreferencesChanged, object: nil)
    }
    @objc private func openRecent(_ sender: NSMenuItem) { if let u = sender.representedObject as? URL { pipeline.openFile(u) } }
    @objc private func clearRecent() { RecentFiles.clear() }
    @objc private func checkUpdates() { UpdateChecker.check() }

    @objc private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { panel.urls.forEach(pipeline.openFile) }
    }

    @objc private func showOutput() { reveal(prefs.outputPaths.outputDirectory ?? prefs.saveDirectory) }
    @objc private func showRaw() { reveal(prefs.outputPaths.rawDirectory ?? prefs.saveDirectory) }

    private func reveal(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func showPreferences() { PreferencesWindowController.shared.present() }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: GlintInfo.name,
            .applicationVersion: AppInfo.version,
            .credits: NSAttributedString(string: "Open-source screenshot beautifier (MIT).\n\(GlintInfo.repositoryURL.absoluteString)"),
        ])
    }

    // MARK: main menu (Edit/Window so ⌘ shortcuts work in the editor)

    private func installMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            item.submenu = m
            main.addItem(item)
            return m
        }
        let app = submenu(GlintInfo.name)
        app.addItem(withTitle: "About Glint", action: #selector(showAbout), keyEquivalent: "").target = self
        app.addItem(.separator())
        let prefsItem = app.addItem(withTitle: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Glint", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Glint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu("File")
        file.addItem(withTitle: "Open Image…", action: #selector(openImage), keyEquivalent: "o").target = self
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let window = submenu("Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}
