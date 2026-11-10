import AppKit
import GlintCapture
import GlintCore
import GlintEditor

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    let prefs: AppPreferences
    let presetStore = PresetStore()
    lazy var pipeline = CapturePipeline(prefs: prefs, presetStore: presetStore)
    lazy var recorder: RecordingCoordinator = {
        let pipeline = pipeline
        let prefs = prefs
        return RecordingCoordinator(
            services: .init(preferences: prefs, presetStore: presetStore),
            snapToEdges: { prefs.snapToEdges },
            isCaptureBusy: { pipeline.isBusy }
        )
    }()
    lazy var urlCaptureHandler: URLCaptureHandler = {
        let pipeline = pipeline
        return URLCaptureHandler(services: .init(
            isCaptureBusy: { pipeline.isBusy },
            startCapture: { pipeline.start($0, trigger: .url) }
        ))
    }()
    lazy var cleanupScheduler: OutputCleanupScheduler = {
        let pipeline = pipeline
        return OutputCleanupScheduler(run: { await pipeline.runOutputCleanup() })
    }()
    /// How long quitting waits for kept screenshots that are still being written.
    var terminationGrace: Duration = .seconds(3)
    var replyToTermination: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }
    /// Project saves quitting waits for.
    var projectSaves: ProjectSaveActivity = .shared
    /// Explains why quitting was cancelled while a project was still being saved.
    var notifyProjectSavePreventedQuit: () -> Void = {
        Notifier.post(title: "Glint didn't quit", body: "A project is still being saved. Try quitting again once it's done.")
    }
    /// Asked before quitting while footage is being recorded; returning false keeps Glint running.
    var confirmDiscardRecording: @MainActor () -> Bool = {
        let alert = NSAlert()
        alert.messageText = "Discard the recording in progress?"
        alert.informativeText = "Quitting now stops the recording and deletes it."
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "Discard and Quit")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
    private var cleanupObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    private let menu: NSMenu
    private let reopenMenuItems = NSHashTable<NSMenuItem>.weakObjects()

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
        // Snapshots of opened projects are only needed while their editor is open; a crash can leave some behind.
        Task.detached(priority: .utility) { ProjectStore.removeAllSnapshots() }
        // Starts a schedule the user chose; with the default (never) nothing is requested.
        _ = UpdateController.shared
        PreferencesWindowController.shared = PreferencesWindowController(prefs: prefs, store: presetStore)
        pipeline.onStatusTitle = { [weak self] title in self?.statusItem?.button?.title = title ?? "" }
        pipeline.isRecordingActive = { [weak self] in self?.recorder.isActive ?? false }
        recorder.onStatusTitle = { [weak self] title in self?.statusItem?.button?.title = title ?? "" }
        menu.delegate = self
        updateStatusItem()
        registerHotkeys()
        startOutputCleanup()
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

    /// Starts the scheduled Output cleanup; each preferences change also asks for a (debounced) pass.
    func startOutputCleanup() {
        cleanupScheduler.start()
        Task { await pipeline.refreshReopenAvailability() }
        guard cleanupObserver == nil else { return }
        cleanupObserver = NotificationCenter.default.addObserver(forName: .glintPreferencesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cleanupScheduler.preferencesChanged()
                Task { await self.pipeline.refreshReopenAvailability() }
            }
        }
    }

    func stopOutputCleanup() {
        cleanupScheduler.stop()
        if let cleanupObserver { NotificationCenter.default.removeObserver(cleanupObserver) }
        cleanupObserver = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { PreferencesWindowController.shared.present() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting right after a copy must not lose the kept screenshot that is still being written.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorder.isActive {
            if recorder.isCapturing, !confirmDiscardRecording() { return .terminateCancel }
            recorder.cancel()
        }
        let keeping = pipeline.isKeepingScreenshots
        guard keeping || projectSaves.isActive else { return .terminateNow }
        Task { @MainActor [pipeline, terminationGrace, replyToTermination, projectSaves, notifyProjectSavePreventedQuit] in
            let drained = keeping ? await pipeline.waitForRetention(timeout: terminationGrace) : true
            if !drained { pipeline.notifyRetentionPreventedQuit() }
            // A project being written would be left half-saved, so quitting waits for it too.
            let saved = await projectSaves.waitUntilIdle(timeout: terminationGrace)
            if !saved { notifyProjectSavePreventedQuit() }
            replyToTermination(drained && saved)
        }
        return .terminateLater
    }

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
        case .captureArea: pipeline.start(.area, trigger: .hotkey)
        case .captureAreaToClipboard: pipeline.start(.areaToClipboard, trigger: .hotkey)
        case .captureWindow: pipeline.start(.window, trigger: .hotkey)
        case .captureFullscreen: pipeline.start(.fullscreen, trigger: .hotkey)
        case .captureText: pipeline.start(.text, trigger: .hotkey)
        case .repeatLast: pipeline.start(.repeatLast, trigger: .hotkey)
        case .recordScreen: recorder.toggle()
        case .captureScrolling: pipeline.start(.scrolling, trigger: .hotkey)
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
        Task { await pipeline.refreshReopenAvailability() }
        guard menu === self.menu else { return }
        menu.removeAllItems()
        add(menu, "Capture Area", #selector(captureArea), hotkey: .captureArea)
        add(menu, "Capture Window", #selector(captureWindow), hotkey: .captureWindow)
        add(menu, "Capture Fullscreen", #selector(captureFullscreen), hotkey: .captureFullscreen)
        add(menu, "Capture Text (OCR)", #selector(captureText), hotkey: .captureText)
        add(menu, "Repeat Last Area", #selector(repeatLast), hotkey: .repeatLast)
        add(menu, pipeline.isScrollingCaptureActive ? "Finish Scrolling Capture" : "Scrolling Capture",
            #selector(captureScrolling), hotkey: .captureScrolling)
        add(menu, Self.recordingMenuTitle(for: recorder.phase, isActive: recorder.isActive),
            #selector(toggleRecording), hotkey: .recordScreen)

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
        let urls = RecentFiles.list(defaults: prefs.defaults)
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
        addReopenItem(to: menu)
        add(menu, "Show Output Folder", #selector(showOutput))
        add(menu, "Show Raw Folder", #selector(showRaw))
        menu.addItem(.separator())
        add(menu, "Preferences…", #selector(showPreferences), key: ",")
        add(menu, "Check for Updates…", #selector(UpdateController.checkForUpdates(_:)), target: UpdateController.shared)
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
    @objc private func captureScrolling() { pipeline.start(.scrolling) }
    @objc private func repeatLast() { pipeline.start(.repeatLast) }
    @objc private func toggleRecording() { recorder.toggle() }

    static func recordingMenuTitle(for phase: RecordingPhase, isActive: Bool) -> String {
        guard isActive else { return "Record Screen…" }
        switch phase {
        case .recording: return "Stop Recording"
        case .finishing: return "Finishing Recording…"
        case .idle, .selecting, .ready, .countdown: return "Cancel Recording"
        }
    }
    @objc private func timerCapture(_ sender: NSMenuItem) { pipeline.start(.timer(sender.tag), trigger: .timer) }
    @objc private func toggleSnapToEdges() {
        prefs.snapToEdges.toggle()
        NotificationCenter.default.post(name: .glintPreferencesChanged, object: nil)
    }
    @objc private func openRecent(_ sender: NSMenuItem) { if let u = sender.representedObject as? URL { pipeline.openFile(u) } }
    @objc private func clearRecent() { RecentFiles.clear() }
    @objc private func reopenLastImage() { Task { await pipeline.reopenLastImage() } }

    /// Menu validation must never wait for the index lock or disk; menu opening refreshes this cache asynchronously.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(reopenLastImage) { return pipeline.canReopenLastImage }
        if item.action == #selector(toggleRecording) { return recorder.phase != .finishing }
        return true
    }

    @objc private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, ProjectStore.contentType]
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

    func populateFileMenu(_ file: NSMenu) {
        file.delegate = self
        file.addItem(withTitle: "Open Image…", action: #selector(openImage), keyEquivalent: "o").target = self
        addReopenItem(to: file)
        let saveProject = file.addItem(withTitle: "Save as Project…",
                                       action: #selector(EditorWindowController.saveAsProject(_:)), keyEquivalent: "s")
        saveProject.keyEquivalentModifierMask = [.command, .option]
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    }

    private func addReopenItem(to menu: NSMenu) {
        let item = add(menu, "Reopen Last Image", #selector(reopenLastImage))
        item.isEnabled = pipeline.canReopenLastImage
        reopenMenuItems.add(item)
        pipeline.onReopenAvailabilityChanged = { [weak self] available in
            self?.reopenMenuItems.allObjects.forEach { $0.isEnabled = available }
        }
    }

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
        let updatesItem = app.addItem(
            withTitle: "Check for Updates…",
            action: #selector(UpdateController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updatesItem.target = UpdateController.shared
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
        populateFileMenu(file)

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
