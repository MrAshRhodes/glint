import AppKit
import Foundation
import GlintCapture
import GlintCore
import GlintEditor

/// Capture -> raw save -> auto-redact -> editor or direct export.
@MainActor
final class CapturePipeline {
    let prefs: AppPreferences
    let presetStore: PresetStore
    private var editors: [EditorWindowController] = []
    private var busy = false
    private let quickAccess = QuickAccessPanel()
    var onStatusTitle: ((String?) -> Void)?

    init(prefs: AppPreferences, presetStore: PresetStore) {
        self.prefs = prefs
        self.presetStore = presetStore
    }

    enum Mode { case area, window, fullscreen, repeatLast, text, areaToClipboard, timer(Int) }

    // MARK: capture entry

    func start(_ mode: Mode) {
        guard !busy else { return }
        busy = true
        let capturer = ScreenCapturer.shared
        let defaults = UserDefaults.standard
        capturer.options.hideCursor = defaults.object(forKey: ShellKey.hideCursor) as? Bool ?? true
        let remember = defaults.object(forKey: ShellKey.rememberArea) as? Bool ?? true
        if !remember { capturer.lastArea = nil }
        let hidden = prefs.hideWindowsDuringCapture ? hideOwnWindows() : []

        Task { @MainActor in
            defer {
                busy = false
                onStatusTitle?(nil)
                for w in hidden { w.orderFront(nil) }
            }
            do {
                switch mode {
                case .text:
                    let image = try await capturer.captureTextOnly()
                    await recognizeText(in: image)
                case .area, .window, .fullscreen, .repeatLast, .areaToClipboard, .timer:
                    let result: CaptureResult
                    switch mode {
                    case .area, .areaToClipboard: result = try await capturer.captureArea()
                    case .window: result = try await capturer.captureWindow()
                    case .fullscreen: result = try await capturer.captureFullscreen()
                    case .repeatLast: result = try await capturer.captureLastArea()
                    case .timer(let s):
                        result = try await capturer.captureWithTimer(seconds: s, mode: .area) { [weak self] remaining in
                            self?.onStatusTitle?(remaining > 0 ? " \(remaining)" : nil)
                        }
                    default: return
                    }
                    for w in hidden { w.orderFront(nil) }
                    var forceClipboard = false
                    if case .areaToClipboard = mode { forceClipboard = true }
                    await handle(result, source: String(describing: result.kind), clipboardOnly: forceClipboard)
                }
            } catch CaptureError.cancelled {
                // user pressed Esc
            } catch CaptureError.permissionDenied {
                PermissionsWindow.shared.show()
            } catch {
                Notifier.post(title: "Capture failed", body: error.localizedDescription)
            }
        }
    }

    private func hideOwnWindows() -> [NSWindow] {
        let visible = NSApp.windows.filter { $0.isVisible && $0.level == .normal && !($0 is NSPanel) }
        visible.forEach { $0.orderOut(nil) }
        return visible
    }

    private func recognizeText(in image: CGImage) async {
        do {
            let lines = try await TextRecognizer.recognize(in: image)
            let text = lines.map(\.text).joined(separator: "\n")
            guard !text.isEmpty else {
                Notifier.post(title: "No text found", body: "Nothing was recognised in the selected area.")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Notifier.playSound()
            Notifier.post(title: "Text copied", body: String(text.prefix(120)))
        } catch {
            Notifier.post(title: "Text recognition failed", body: error.localizedDescription)
        }
    }

    // MARK: handling

    /// Saves raw, optionally auto-redacts, then opens the editor or exports directly.
    func handle(_ result: CaptureResult, source: String, clipboardOnly: Bool = false) async {
        await handle(image: result.image, scale: result.scale, source: source, rawURL: nil,
                     saveRaw: true, clipboardOnly: clipboardOnly)
    }

    func handle(image: CGImage, scale: CGFloat, source: String?, rawURL existingRaw: URL?,
                saveRaw: Bool, clipboardOnly: Bool = false) async {
        Notifier.playSound()
        var rawURL = existingRaw
        if saveRaw, prefs.saveRaw, let url = prefs.outputPaths.rawURL() {
            if (try? Exporter.write(image, to: url, format: .plainPNG, scale: .original, backingScale: scale)) != nil {
                rawURL = url
            }
        }
        var working = image
        var redactions: [Annotation] = []
        if prefs.autoRedact {
            var opts = AutoRedactOptions(detector: prefs.autoRedactOptions, style: prefs.redactStyle, color: prefs.redactColor)
            opts.padding = 3
            redactions = await AutoRedact.run(image, options: opts)
            if !redactions.isEmpty { working = AnnotationRenderer.bake(source: image, annotations: redactions) ?? image }
        }
        if prefs.openEditorAfterCapture && !clipboardOnly {
            openEditor(image: working, scale: scale, rawURL: rawURL, source: source)
        } else {
            exportDirectly(image: working, scale: scale, rawURL: rawURL, source: source, clipboardOnly: clipboardOnly)
        }
    }

    func settings(presetName: String? = nil) -> RenderSettings {
        var s: RenderSettings
        if let name = presetName ?? prefs.defaultPresetName, let p = presetStore.preset(named: name) {
            s = p.settings
        } else {
            s = presetStore.defaultPreset?.settings ?? .default
        }
        s.autoBalance = prefs.autoBalance
        return s
    }

    private func exportDirectly(image: CGImage, scale: CGFloat, rawURL: URL?, source: String?, clipboardOnly: Bool) {
        let rendered = Compositor.render(image: image, settings: settings(), backingScale: scale)
        var saved: URL?
        if prefs.saveOutput && !clipboardOnly {
            let format = prefs.exportFormat
            let url = prefs.outputPaths.outputURL(format: format) ?? prefs.outputPaths.saveURL(format: format)
            saved = try? Exporter.write(rendered, to: url, format: format, scale: prefs.exportScale, backingScale: scale)
        }
        if prefs.copyToClipboardAfterCapture || clipboardOnly || prefs.openEditorAfterCapture == false && saved == nil {
            Exporter.copyToClipboard(rendered)
        }
        if let saved { RecentFiles.add(saved) }
        Notifier.post(title: clipboardOnly ? "Copied to clipboard" : "Screenshot saved",
                      body: saved?.lastPathComponent ?? "The beautified image is on the clipboard.", fileURL: saved)
        if UserDefaults.standard.object(forKey: ShellKey.quickAccess) as? Bool ?? true {
            quickAccess.show(image: rendered, fileURL: saved) { [weak self] in
                self?.openEditor(image: image, scale: scale, rawURL: rawURL, source: source)
            }
        }
    }

    // MARK: editor

    func openEditor(image: CGImage, scale: CGFloat, rawURL: URL?, source: String?) {
        let context = EditorContext(image: image, backingScale: scale, rawURL: rawURL, source: source)
        let controller = EditorWindowController(context: context, preferences: prefs, presetStore: presetStore)
        editors.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.editors.removeAll { $0 === controller }
        }
        controller.onExported = { (url: URL?) in
            if let url { RecentFiles.add(url) }
            Notifier.playSound()
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.showEditor()
    }

    func openFile(_ url: URL) {
        guard let image = GlintImageIO.load(url: url) else {
            Notifier.post(title: "Cannot open image", body: url.lastPathComponent)
            return
        }
        RecentFiles.add(url)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        openEditor(image: image, scale: scale, rawURL: nil, source: "file")
    }
}

/// Most-recently opened/exported files for the Open Recent submenu.
enum RecentFiles {
    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: ShellKey.recentFiles) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        var list = (UserDefaults.standard.stringArray(forKey: ShellKey.recentFiles) ?? []).filter { $0 != url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: ShellKey.recentFiles)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: ShellKey.recentFiles) }
}
