import AppKit
import Foundation
import GlintCapture
import GlintCore
import GlintEditor

/// Capture -> raw save -> auto-redact -> editor or direct export.
@MainActor
final class CapturePipeline {
    struct Services {
        var write: (CGImage, URL, ExportFormat, ExportScale, CGFloat) throws -> URL = {
            try Exporter.write($0, to: $1, format: $2, scale: $3, backingScale: $4)
        }
        var copy: (CGImage) -> Bool = { Exporter.copyToClipboard($0) }
        var copyText: @MainActor (String) -> Void = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString($0, forType: .string)
        }
        var recognize: (CGImage, TextRecognizer.Options) async throws -> [RecognizedLine] = {
            try await TextRecognizer.recognize(in: $0, options: $1)
        }
        var bake: (CGImage, [Annotation]) -> CGImage? = { AnnotationRenderer.bake(source: $0, annotations: $1) }
        var render: (CGImage, RenderSettings, CGFloat, CGImage?) throws -> CGImage = {
            try Compositor.render(image: $0, settings: $1, backingScale: $2, wallpaper: $3)
        }
        var notify: @MainActor (String, String, URL?) -> Void = { Notifier.post(title: $0, body: $1, fileURL: $2) }
        var requestRetry: @MainActor (String, String) -> Bool = { CaptureRecovery.requestRetry(title: $0, message: $1) }
        var sound: @MainActor () -> Void = { Notifier.playSound() }
        var addRecent: (URL) -> Void = { RecentFiles.add($0) }
        var removeRecent: (URL) -> Void = { RecentFiles.remove($0) }
        var wallpaper: @MainActor () -> Result<CGImage, DesktopWallpaperError> = { DesktopWallpaper.current() }
        var retention: (AppPreferences) -> OutputRetention = { OutputRetention(preferences: $0) }
        var latestRetainedOutput: @Sendable (OutputRetention) -> RetainedOutput? = { $0.latest() }
        var presentEditor: @MainActor (EditorWindowController) -> Void = {
            NSApp.activate(ignoringOtherApps: true)
            $0.showEditor()
        }
        var screenScale: @MainActor () -> CGFloat = { NSScreen.main?.backingScaleFactor ?? 2 }
    }

    let prefs: AppPreferences
    let presetStore: PresetStore
    /// Tracks the screenshots that were copied, dragged or auto-saved, so they can be reopened and expire.
    let retention: OutputRetention
    let retentionQueue = RetentionQueue()
    private let services: Services
    private var editors: [EditorWindowController] = []
    private var busy = false
    private var reportedCleanupFailures: Set<String> = []
    private lazy var quickAccess = QuickAccessPanel()
    var onStatusTitle: ((String?) -> Void)?
    var onReopenAvailabilityChanged: ((Bool) -> Void)?
    private(set) var canReopenLastImage = false
    private var availabilityRequest = UUID()

    var isBusy: Bool { busy }

    init(prefs: AppPreferences, presetStore: PresetStore, services: Services = Services()) {
        self.prefs = prefs
        self.presetStore = presetStore
        self.services = services
        retention = services.retention(prefs)
    }

    enum Mode: Equatable { case area, window, fullscreen, repeatLast, text, areaToClipboard, timer(Int) }

    // MARK: capture entry

    func start(_ mode: Mode) {
        guard !busy else { return }
        busy = true
        let capturer = ScreenCapturer.shared
        let defaults = UserDefaults.standard
        capturer.options.hideCursor = defaults.object(forKey: ShellKey.hideCursor) as? Bool ?? true
        capturer.options.snapToEdges = prefs.snapToEdges
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

    func recognizeText(in image: CGImage) async {
        do {
            let lines = try await services.recognize(image, TextRecognizer.Options())
            let text = lines.map(\.text).joined(separator: "\n")
            guard !text.isEmpty else {
                services.notify("No text found", "Nothing was recognised in the selected area.", nil)
                return
            }
            services.copyText(text)
            services.sound()
            services.notify("Text copied", "Recognized text copied to clipboard", nil)
        } catch {
            services.notify("Text recognition failed", error.localizedDescription, nil)
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
        let redactionOptions = prefs.autoRedact
            ? AutoRedactOptions(detector: prefs.autoRedactOptions, color: prefs.redactColor, padding: 3)
            : nil
        services.sound()
        var rawURL = existingRaw
        if saveRaw, prefs.saveRaw, let url = prefs.outputPaths.rawURL() {
            do {
                rawURL = try services.write(image, url, .plainPNG, .original, scale)
            } catch {
                services.notify("Raw screenshot not saved", error.localizedDescription, nil)
            }
        }
        var working = image
        if let opts = redactionOptions {
            let redactions: [Annotation]
            while true {
                do {
                    let lines = try await services.recognize(image, opts.recognizer)
                    redactions = AutoRedact.annotations(for: lines, options: opts, imageSize: image.pixelSize)
                    break
                } catch {
                    let message = "The image was not exported because text recognition failed: \(error.localizedDescription)"
                    services.notify("Auto-redaction failed", message, nil)
                    guard services.requestRetry("Auto-redaction failed", message) else { return }
                }
            }
            if !redactions.isEmpty {
                while true {
                    if let redacted = services.bake(image, redactions) {
                        working = redacted
                        break
                    }
                    let message = "The image was not exported because redactions could not be applied."
                    services.notify("Auto-redaction failed", message, nil)
                    guard services.requestRetry("Auto-redaction failed", message) else { return }
                }
            }
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
        let settings = settings()
        var wallpaper: CGImage?
        var wallpaperProblem: String?
        if settings.usesDesktopWallpaper {
            switch services.wallpaper() {
            case .success(let image): wallpaper = image
            case .failure(let error): wallpaperProblem = error.localizedDescription
            }
        }
        let rendered: CGImage
        while true {
            do {
                rendered = try services.render(image, settings, scale, wallpaper)
                break
            } catch {
                services.notify("Screenshot not exported", error.localizedDescription, nil)
                guard services.requestRetry("Screenshot not exported", error.localizedDescription) else { return }
            }
        }
        var saved: URL?
        var failures: [String] = []
        let exportScale = prefs.exportScale
        if prefs.saveOutput && !clipboardOnly {
            let format = prefs.exportFormat
            let url = prefs.outputPaths.outputURL(format: format) ?? prefs.outputPaths.saveURL(format: format)
            do {
                saved = try services.write(rendered, url, format, exportScale, scale)
            } catch {
                failures.append("Save failed: \(error.localizedDescription)")
            }
        }
        var copied = false
        if prefs.copyToClipboardAfterCapture || clipboardOnly || prefs.openEditorAfterCapture == false && saved == nil {
            copied = services.copy(rendered)
            if !copied { failures.append("Copy to clipboard failed.") }
        }
        if let saved { services.addRecent(saved) }
        keep(rendered, backingScale: scale, savedFile: saved, savedExportScale: exportScale,
             sharedAs: copied ? .copied : nil)
        let title: String
        let detail: String
        if let saved {
            title = failures.isEmpty ? "Screenshot saved" : "Screenshot saved, but copy failed"
            detail = saved.lastPathComponent + (copied ? " — also copied to clipboard." : "")
        } else if copied {
            title = failures.isEmpty ? "Copied to clipboard" : "Copied to clipboard, but save failed"
            detail = "The beautified image is on the clipboard."
        } else {
            title = "Screenshot export failed"
            detail = "The beautified image was not saved or copied."
        }
        services.notify(title, ([detail] + failures + [wallpaperProblem].compactMap { $0 }).joined(separator: "\n"), saved)
        if prefs.defaults.object(forKey: ShellKey.quickAccess) as? Bool ?? true {
            quickAccess.show(image: rendered, fileURL: saved, onEdit: { [weak self] in
                self?.openEditor(image: image, scale: scale, rawURL: rawURL, source: source)
            }, onDragOut: { [weak self] in
                self?.quickAccessDragStarted(image: rendered, backingScale: scale, savedFile: saved)
            })
        }
    }

    // MARK: kept screenshots

    /// Queues the retention work for a finished image: registers the file that was just auto-saved, and keeps a copy
    /// that was put on the clipboard or dragged out. Both run off the main thread, in this order, so a copy of the
    /// image that was just saved reuses the saved file. Failures are reported but never undo the copy or drag.
    private func keep(_ image: CGImage, backingScale: CGFloat, savedFile: URL? = nil,
                      savedExportScale: ExportScale = .original,
                      sharedAs source: OutputRetentionSource? = nil) {
        let retention = retention
        let registersSaved = savedFile != nil && retention.tracksSavedOutputs
        let retainsCopy = source != nil && retention.retainsCopies
        guard registersSaved || retainsCopy else { return }
        let image = SendableImage(image)
        retentionQueue.enqueue({ () -> Result<RetainedOutput, Error>? in
            if registersSaved, let savedFile {
                retention.register(savedFile: savedFile, image: image.value, backingScale: backingScale,
                                   exportScale: savedExportScale)
            }
            guard retainsCopy, let source else { return nil }
            return Result { try retention.retain(image.value, source: source, backingScale: backingScale) }
        }, completion: { [weak self] result in
            self?.finishKeeping(result)
        })
    }

    private func finishKeeping(_ result: Result<RetainedOutput, Error>?) {
        defer { Task { await refreshReopenAvailability() } }
        switch result {
        case .success(let output):
            services.addRecent(output.url)
        case .failure(let error):
            // Turned off while the job waited: nothing to report.
            if let error = error as? OutputRetentionError, error == .disabled { return }
            services.notify("Screenshot not kept for reopening",
                            "\(error.localizedDescription)\nThe copy or drag itself was not affected.", nil)
        case nil:
            break
        }
    }

    /// A quick-access thumbnail drag started. With a saved file that file is the payload and is already tracked;
    /// otherwise only image data leaves the app, so keep the image for reopening.
    func quickAccessDragStarted(image: CGImage, backingScale: CGFloat, savedFile: URL?) {
        guard savedFile == nil else { return }
        keep(image, backingScale: backingScale, sharedAs: .dragged)
    }

    /// True while kept screenshots are still being written.
    var isKeepingScreenshots: Bool { !retentionQueue.isIdle }

    /// Returns true when every queued retention job finished, false when `timeout` ran out first.
    func waitForRetention(timeout: Duration? = nil) async -> Bool {
        await retentionQueue.waitUntilIdle(timeout: timeout)
    }

    func notifyRetentionPreventedQuit() {
        services.notify("Screenshots are still being saved",
                        "Glint stayed open to finish keeping your screenshots. Please try quitting again when saving finishes.", nil)
    }

    /// One cleanup pass: moves expired kept screenshots to the Trash off the main thread, forgets them in Recent files
    /// and reports problems. Does nothing unless history is on and a retention period is set.
    func runOutputCleanup() async {
        guard retention.cleansUp else {
            await refreshReopenAvailability()
            return
        }
        let retention = retention
        let report = await Task.detached(priority: .utility) { retention.cleanUp() }.value
        for url in report.removed { services.removeRecent(url) }
        reportCleanupFailures(report.failures)
        await refreshReopenAvailability()
    }

    /// At most one notification per pass, and none while the same files keep failing.
    private func reportCleanupFailures(_ failures: [String]) {
        let current = Set(failures)
        guard !current.isEmpty else {
            reportedCleanupFailures = []
            return
        }
        guard current != reportedCleanupFailures else { return }
        reportedCleanupFailures = current
        let shown = failures.prefix(3).joined(separator: "\n")
        let more = failures.count > 3 ? "\n…and \(failures.count - 3) more." : ""
        services.notify("Old screenshots could not be removed",
                        "\(shown)\(more)\nThey stay in the Output folder and Glint will try again later.", nil)
    }

    // MARK: editor

    func openEditor(image: CGImage, scale: CGFloat, rawURL: URL?, source: String?, isComposed: Bool = false) {
        let context = EditorContext(image: image, backingScale: scale, rawURL: rawURL, source: source, isComposed: isComposed)
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
        controller.onImageShared = { [weak self] image, kind, backingScale in
            switch kind {
            case .copied: self?.keep(image, backingScale: backingScale, sharedAs: .copied)
            case .dragged: self?.keep(image, backingScale: backingScale, sharedAs: .dragged)
            }
        }
        services.presentEditor(controller)
    }

    /// Opens the newest kept screenshot as a finished image (nothing is styled again). A file that is missing or
    /// cannot be read is reported and forgotten.
    func reopenLastImage() async {
        guard let output = await refreshReopenAvailability() else {
            services.notify("No screenshot to reopen", "Glint has no kept screenshot left to reopen.", nil)
            return
        }
        let image = await Task.detached(priority: .userInitiated) {
            GlintImageIO.load(url: output.url).map(SendableImage.init)
        }.value
        guard let image else {
            let retention = retention
            await Task.detached(priority: .utility) { retention.discard(output.url) }.value
            reportForgotten(output.url)
            await refreshReopenAvailability()
            return
        }
        services.addRecent(output.url)
        openEditor(image: image.value, scale: output.backingScale, rawURL: nil, source: "last image", isComposed: true)
    }

    /// Refreshes the cached menu availability without waiting for the index or a Trash operation on the UI thread.
    @discardableResult
    func refreshReopenAvailability() async -> RetainedOutput? {
        let request = UUID()
        availabilityRequest = request
        let retention = retention
        let lookup = services.latestRetainedOutput
        let output = await Task.detached(priority: .utility) { lookup(retention) }.value
        if availabilityRequest == request {
            canReopenLastImage = output != nil
            onReopenAvailabilityChanged?(canReopenLastImage)
        }
        return output
    }

    func openFile(_ url: URL) {
        let kept = retention.isManaged(url)
        guard let image = GlintImageIO.load(url: url) else {
            if kept {
                forget(url)
            } else {
                services.notify("Cannot open image", url.lastPathComponent, nil)
            }
            return
        }
        services.addRecent(url)
        if kept {
            openEditor(image: image, scale: Self.pixelScale(ofFileAt: url) ?? services.screenScale(), rawURL: nil,
                       source: "file", isComposed: true)
        } else {
            openEditor(image: image, scale: services.screenScale(), rawURL: nil, source: "file")
        }
    }

    /// A kept screenshot that is gone or unreadable: say so, then drop it from the index and Recent files.
    private func forget(_ url: URL) {
        retention.discard(url)
        reportForgotten(url)
        Task { await refreshReopenAvailability() }
    }

    private func reportForgotten(_ url: URL) {
        services.removeRecent(url)
        services.notify("Cannot open image",
                        "\(url.lastPathComponent) is missing or could not be read, so Glint removed it from your kept screenshots.", nil)
    }

    /// Pixels per point of an image Glint wrote, from the density its exporter stored in the file.
    private static func pixelScale(ofFileAt url: URL) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi.isFinite, dpi >= 72 else { return nil }
        return CGFloat((dpi / 72 * 100).rounded() / 100)
    }
}

/// An immutable image that may cross to the retention thread.
private struct SendableImage: @unchecked Sendable {
    let value: CGImage

    init(_ value: CGImage) { self.value = value }
}

/// Most-recently opened/exported files for the Open Recent submenu.
enum RecentFiles {
    static let limit = 10

    static var urls: [URL] { list() }

    /// Recent files that still exist, newest first.
    static func list(defaults: UserDefaults = .standard) -> [URL] {
        storedPaths(defaults).filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func add(_ url: URL, defaults: UserDefaults = .standard, noteInSystemRecents: Bool = true) {
        var list = storedPaths(defaults).filter { $0 != url.path }
        list.insert(url.path, at: 0)
        defaults.set(Array(list.prefix(limit)), forKey: ShellKey.recentFiles)
        if noteInSystemRecents { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
    }

    /// Forgets `url`. The file itself is left alone.
    static func remove(_ url: URL, defaults: UserDefaults = .standard) {
        let list = storedPaths(defaults)
        let kept = list.filter { $0 != url.path }
        if kept.count != list.count { defaults.set(kept, forKey: ShellKey.recentFiles) }
    }

    /// Drops entries whose file no longer exists, so they stop using up the list. Returns what is left.
    @discardableResult
    static func prune(defaults: UserDefaults = .standard) -> [URL] {
        let list = storedPaths(defaults)
        let kept = list.filter { FileManager.default.fileExists(atPath: $0) }
        if kept.count != list.count { defaults.set(kept, forKey: ShellKey.recentFiles) }
        return kept.map { URL(fileURLWithPath: $0) }
    }

    static func clear(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: ShellKey.recentFiles) }

    private static func storedPaths(_ defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: ShellKey.recentFiles) ?? []
    }
}
