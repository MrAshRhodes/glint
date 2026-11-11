import AppKit
import Foundation
import GlintCapture
import GlintCore
import GlintEditor

/// Capture -> raw save -> auto-redact -> editor or direct export.
@MainActor
final class CapturePipeline {
    struct Services {
        /// Runs off the main thread, on the queue that writes screenshots. The name it is given was only checked to be
        /// unused, so it never replaces a file: it throws `ExportError.fileExists` instead.
        var write: @Sendable (CGImage, URL, ExportFormat, ExportScale, CGFloat) throws -> URL = {
            try Exporter.write($0, to: $1, format: $2, scale: $3, backingScale: $4, replacing: false)
        }
        /// Copies the finished image with the export scale and backing scale a saved copy would use.
        var copy: (CGImage, ExportScale, CGFloat) -> Bool = {
            Exporter.copyToClipboard($0, scale: $1, backingScale: $2)
        }
        var copyText: @MainActor (String) -> Void = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString($0, forType: .string)
        }
        /// Changes whenever anything puts something on the clipboard, in this app or another.
        var clipboardChangeCount: @MainActor () -> Int = { NSPasteboard.general.changeCount }
        var recognize: (CGImage, TextRecognizer.Options) async throws -> [RecognizedLine] = {
            try await TextRecognizer.recognize(in: $0, options: $1)
        }
        var bake: (CGImage, [Annotation]) -> CGImage? = { AnnotationRenderer.bake(source: $0, annotations: $1) }
        /// Runs off the main thread so a large render never stalls the interface.
        var render: @Sendable (CGImage, RenderSettings, CGFloat, CGImage?) throws -> CGImage = {
            try Compositor.render(image: $0, settings: $1, backingScale: $2, wallpaper: $3)
        }
        var notify: @MainActor (String, String, URL?) -> Void = { Notifier.post(title: $0, body: $1, fileURL: $2) }
        /// A failure the user must not miss, even with notifications off: see `FailureFeedback`.
        var fail: @MainActor (String, String, URL?) -> Void = { Notifier.postFailure(title: $0, body: $1, fileURL: $2) }
        /// A start request dropped because a capture or recording is already in progress.
        var reject: @MainActor () -> Void = { NSSound.beep() }
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
        var makeQuickAccess: @MainActor () -> any QuickAccessPresenting = { QuickAccessPanel() }
        var screenScale: @MainActor () -> CGFloat = { NSScreen.main?.backingScaleFactor ?? 2 }
        var captureWindows: @MainActor () -> [NSWindow] = { NSApp.orderedWindows }
        var capture: @MainActor (ScreenCapturer, Mode, @escaping (Int) -> Void) async throws -> CaptureResult = {
            capturer, mode, onTick in
            switch mode {
            case .area, .areaToClipboard: return try await capturer.captureArea()
            case .window: return try await capturer.captureWindow()
            case .fullscreen: return try await capturer.captureFullscreen()
            case .repeatLast: return try await capturer.captureLastArea()
            case .timer(let seconds):
                return try await capturer.captureWithTimer(seconds: seconds, mode: .area, onTick: onTick)
            case .text:
                throw CaptureError.failed("This capture mode requires its dedicated capture operation.")
            }
        }
        var captureText: @MainActor (ScreenCapturer) async throws -> CGImage = {
            try await $0.captureTextOnly()
        }
        var permissionDenied: @MainActor () -> Void = { PermissionsWindow.shared.show() }
        var readProject: @Sendable (URL) throws -> GlintProject = { try ProjectStore.read(from: $0) }
        var presentRecordingEditor: @MainActor (RecordingEditorWindowController) -> Void = {
            NSApp.activate(ignoringOtherApps: true)
            $0.showEditor()
        }
    }

    let prefs: AppPreferences
    let presetStore: PresetStore
    /// Tracks the screenshots that were copied, dragged or auto-saved, so they can be reopened and expire.
    let retention: OutputRetention
    let retentionQueue = RetentionQueue()
    /// Writes of the unstyled captures, apart from the outputs so neither waits for the other.
    let rawQueue = RetentionQueue()
    /// Writes of the finished outputs. They are what the user is waiting on, so they outrank the upkeep queues.
    let outputQueue = RetentionQueue(priority: .userInitiated)
    private let services: Services
    private var editors: [EditorWindowController] = []
    private var recordingEditors: [RecordingEditorWindowController] = []
    private var busy = false
    private var reportedCleanupFailures: Set<String> = []
    private lazy var quickAccess: any QuickAccessPresenting = services.makeQuickAccess()
    var onStatusTitle: ((String?) -> Void)?
    var onReopenAvailabilityChanged: ((Bool) -> Void)?
    private(set) var canReopenLastImage = false
    private var availabilityRequest = UUID()

    var isBusy: Bool { busy || isRecordingActive() }

    /// Set by the app shell so screenshots never start while a screen recording is in progress.
    var isRecordingActive: () -> Bool = { false }

    init(prefs: AppPreferences, presetStore: PresetStore, services: Services = Services()) {
        self.prefs = prefs
        self.presetStore = presetStore
        self.services = services
        retention = services.retention(prefs)
    }

    enum Mode: Equatable {
        case area, window, fullscreen, repeatLast, text, areaToClipboard, timer(Int)

        /// The signpost label: the mode alone, without a timer's delay.
        var signpostLabel: String {
            switch self {
            case .area: "area"
            case .window: "window"
            case .fullscreen: "fullscreen"
            case .repeatLast: "repeatLast"
            case .text: "text"
            case .areaToClipboard: "areaToClipboard"
            case .timer: "timer"
            }
        }
    }

    // MARK: capture entry

    /// Starts a capture.
    @discardableResult
    func start(_ mode: Mode, trigger: CaptureSignposts.Trigger = .menu) -> Task<Void, Never>? {
        guard !isBusy else {
            services.reject()
            return nil
        }
        busy = true
        let signpost = CaptureSignposts.beginCapture(trigger: trigger, mode: mode.signpostLabel)
        let capturer = ScreenCapturer.shared
        let defaults = UserDefaults.standard
        capturer.options.hideCursor = defaults.object(forKey: ShellKey.hideCursor) as? Bool ?? true
        capturer.options.snapToEdges = prefs.snapToEdges
        let windows = services.captureWindows()
        capturer.options.excludeOwnWindows = prefs.hideWindowsDuringCapture
        capturer.options.excludedWindowIDs = Set(windows.compactMap {
            $0.identifier == QuickAccessPanel.windowIdentifier ? CGWindowID(exactly: $0.windowNumber) : nil
        })
        let remember = defaults.object(forKey: ShellKey.rememberArea) as? Bool ?? true
        if !remember { capturer.lastArea = nil }
        var canHide = prefs.hideWindowsDuringCapture
        var hidden: [NSWindow] = []
        func hideWindows() {
            guard canHide else { return }
            canHide = false
            hidden = hideOwnWindows(windows)
        }
        func restoreWindows() {
            canHide = false
            for window in hidden.reversed() { window.orderFront(nil) }
            hidden.removeAll()
        }
        // Frozen selection hides windows only after covering them. Live timer selection still
        // needs them out of the way; noninteractive captures rely on the ScreenCaptureKit exclusion.
        capturer.onSelectionPresented = nil
        switch mode {
        case .area, .areaToClipboard, .window, .text:
            if canHide { capturer.onSelectionPresented = { hideWindows() } }
        case .timer:
            hideWindows()
        case .fullscreen, .repeatLast:
            break
        }

        return Task { @MainActor in
            var outcome = CaptureSignposts.Outcome.completed
            defer {
                capturer.onSelectionPresented = nil
                busy = false
                onStatusTitle?(nil)
                restoreWindows()
                CaptureSignposts.end(signpost, outcome == .completed && Task.isCancelled ? .cancelled : outcome)
            }
            do {
                try Task.checkCancellation()
                switch mode {
                case .text:
                    let image = try await services.captureText(capturer)
                    try Task.checkCancellation()
                    restoreWindows()
                    await recognizeText(in: image)
                case .area, .window, .fullscreen, .repeatLast, .areaToClipboard, .timer:
                    let result = try await services.capture(capturer, mode) { [weak self] remaining in
                        self?.onStatusTitle?(remaining > 0 ? " \(remaining)" : nil)
                    }
                    try Task.checkCancellation()
                    restoreWindows()
                    var forceClipboard = false
                    if case .areaToClipboard = mode { forceClipboard = true }
                    await handle(result, source: String(describing: result.kind), clipboardOnly: forceClipboard)
                }
            } catch CaptureError.cancelled {
                // user pressed Esc
                outcome = .cancelled
            } catch is CancellationError {
                // The capture task was cancelled before it produced an output.
                outcome = .cancelled
            } catch CaptureError.permissionDenied {
                outcome = .failed
                services.permissionDenied()
            } catch {
                outcome = .failed
                services.fail("Capture failed", error.localizedDescription, nil)
            }
        }
    }

    private func hideOwnWindows(_ windows: [NSWindow]) -> [NSWindow] {
        let visible = windows.filter { $0.isVisible && $0.level == .normal && !($0 is NSPanel) }
        visible.forEach { $0.orderOut(nil) }
        return visible
    }

    func recognizeText(in image: CGImage) async {
        do {
            let lines = try await services.recognize(image, TextRecognizer.Options())
            guard !Task.isCancelled else { return }
            let text = lines.map(\.text).joined(separator: "\n")
            guard !text.isEmpty else {
                services.notify("No text found", "Nothing was recognised in the selected area.", nil)
                return
            }
            services.copyText(text)
            services.sound()
            services.notify("Text copied", "Recognized text copied to clipboard", nil)
        } catch {
            guard !Task.isCancelled else { return }
            services.fail("Text recognition failed", error.localizedDescription, nil)
        }
    }

    // MARK: handling

    /// Starts saving the raw capture, optionally auto-redacts, then opens the editor or exports directly.
    func handle(_ result: CaptureResult, source: String, clipboardOnly: Bool = false) async {
        await handle(image: result.image, scale: result.scale, source: source, rawURL: nil,
                     saveRaw: true, clipboardOnly: clipboardOnly, displayID: result.displayID)
    }

    func handle(image: CGImage, scale: CGFloat, source: String?, rawURL existingRaw: URL?,
                saveRaw: Bool, clipboardOnly: Bool = false, displayID: CGDirectDisplayID? = nil) async {
        let redactionOptions = prefs.autoRedact
            ? AutoRedactOptions(detector: prefs.autoRedactOptions, color: prefs.redactColor, backingScale: scale)
            : nil
        services.sound()
        let raw = RawCapture(url: existingRaw)
        if saveRaw, prefs.saveRaw { saveRawCapture(image, backingScale: scale, as: raw) }
        var working = image
        // What the editor and a direct export's Edit action are told, so neither reads the same text again.
        var redaction = RedactionAnalysis.notRequested
        if let opts = redactionOptions {
            let redactions: [Annotation]
            while true {
                do {
                    let lines = try await services.recognize(image, opts.recognizer)
                    guard !Task.isCancelled else { return }
                    let outcome = AutoRedact.analyse(lines, options: opts, imageSize: image.pixelSize)
                    redactions = outcome.annotations
                    redaction = outcome.analysis
                    break
                } catch {
                    guard !Task.isCancelled else { return }
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
        // A cancelled capture task must not publish output that finished late.
        guard !Task.isCancelled else { return }
        if prefs.openEditorAfterCapture && !clipboardOnly {
            openEditor(image: working, scale: scale, raw: raw, source: source, redaction: redaction)
        } else {
            await exportDirectly(image: working, scale: scale, raw: raw, source: source, clipboardOnly: clipboardOnly,
                                 displayID: displayID, redaction: redaction)
        }
    }

    /// Queues the write of the unstyled capture. An editor that opened in the meantime gets the file once it exists;
    /// a failure is reported but changes nothing else.
    private func saveRawCapture(_ image: CGImage, backingScale: CGFloat, as raw: RawCapture) {
        let paths = prefs.outputPaths
        let write = services.write
        let image = SendableImage(image)
        rawQueue.enqueue({ () -> Result<URL, Error>? in
            guard let url = paths.rawURL() else { return nil }
            return Result { try CaptureSignposts.measure("RawWrite") { try write(image.value, url, .plainPNG, .original, backingScale) } }
        }, completion: { [weak self] result in
            switch result {
            case .success(let url): raw.saved(url)
            case .failure(let error): self?.services.fail("Raw screenshot not saved", error.localizedDescription, nil)
            case nil: break
            }
        })
    }

    /// The look a capture is exported with: the same resolution the editor starts from, so Remember settings and the
    /// default preset apply whether or not the editor opens. A preset requested by name takes precedence.
    func settings(presetName: String? = nil) -> RenderSettings {
        EditorHeadless.initialSettings(preferences: prefs, presetStore: presetStore, presetName: presetName)
    }

    /// What a direct export still needs once its file write ended.
    private struct DirectExport {
        let id: UUID
        /// The finished image.
        let image: CGImage
        let backingScale: CGFloat
        let exportScale: ExportScale
        let copied: Bool
        let copyFailed: Bool
        /// The user asked for a file but no copy, so a copy rescues the image when the file cannot be written.
        let copiesIfNotSaved: Bool
        /// The clipboard's change count when the export published, to tell whether anything else used it since.
        let clipboardMark: Int
        let showsQuickAccess: Bool
        let wallpaperProblem: String?
    }

    /// Renders off the main thread, then publishes the clipboard and the thumbnail. The file is written in the
    /// background: its URL, the Recent list and the notification follow once it exists, so nothing claims a save that
    /// has not happened. Everything the export depends on is read here, so later preference changes don't alter it.
    private func exportDirectly(image: CGImage, scale: CGFloat, raw: RawCapture, source: String?, clipboardOnly: Bool,
                                displayID: CGDirectDisplayID?, redaction: RedactionAnalysis = .notRequested) async {
        let release = outputQueue.hold()
        defer { release() }
        let settings = settings()
        let exportScale = prefs.exportScale
        let format = prefs.exportFormat
        let paths = prefs.outputPaths
        let wantsSave = prefs.saveOutput && !clipboardOnly
        let editorOff = prefs.openEditorAfterCapture == false
        let copiesNow = prefs.copyToClipboardAfterCapture || clipboardOnly || editorOff && !wantsSave
        let showsQuickAccess = prefs.defaults.object(forKey: ShellKey.quickAccess) as? Bool ?? true
        var wallpaper: CGImage?
        var wallpaperProblem: String?
        if settings.usesDesktopWallpaper {
            switch services.wallpaper() {
            case .success(let image): wallpaper = image
            case .failure(let error): wallpaperProblem = error.localizedDescription
            }
        }
        let render = services.render
        let rendered: CGImage
        while true {
            do {
                rendered = try await BlockingWork.run { [wallpaper] _ in
                    try CaptureSignposts.measure("Render") { try render(image, settings, scale, wallpaper) }
                }
                break
            } catch {
                // A cancelled capture task must not publish output that finished late.
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                services.notify("Screenshot not exported", error.localizedDescription, nil)
                guard services.requestRetry("Screenshot not exported", error.localizedDescription) else { return }
            }
        }
        guard !Task.isCancelled else { return }

        let id = UUID()
        var thumbnail: Task<SendableImage, Never>?
        if showsQuickAccess {
            let side = quickAccess.thumbnailPixelSide(for: displayID)
            let full = SendableImage(rendered)
            thumbnail = Task.detached(priority: .userInitiated) { SendableImage(full.value.glintThumbnail(maxPixelSide: side)) }
        }
        var copied = false
        var copyFailed = false
        if copiesNow {
            copied = services.copy(rendered, exportScale, scale)
            copyFailed = !copied
        }
        // The thumbnail is made while the copy runs. Once the clipboard has changed the export is finished; before that
        // a cancellation that arrives while waiting still stops it.
        let thumbnailImage = await thumbnail?.value.value
        guard copied || !Task.isCancelled else { return }
        if let thumbnailImage {
            quickAccess.show(QuickAccessItem(id: id, thumbnail: thumbnailImage, image: rendered, displayID: displayID, onEdit: { [weak self] in
                self?.openEditor(image: image, scale: scale, raw: raw, source: source, redaction: redaction)
            }, onDragOut: { [weak self] file in
                self?.quickAccessDragStarted(image: rendered, backingScale: scale, savedFile: file)
            }))
        }

        let export = DirectExport(id: id, image: rendered, backingScale: scale, exportScale: exportScale,
                                  copied: copied, copyFailed: copyFailed,
                                  copiesIfNotSaved: !copiesNow && editorOff,
                                  clipboardMark: services.clipboardChangeCount(),
                                  showsQuickAccess: showsQuickAccess, wallpaperProblem: wallpaperProblem)
        let write = services.write
        let date = Date()
        let output = SendableImage(rendered)
        // Every export finishes through this queue, in the order it was captured, even one with no file to write, so a
        // slow save never lets a newer screenshot be recorded ahead of an older one.
        outputQueue.enqueue({ () -> Result<URL, Error>? in
            guard wantsSave else { return nil }
            // A name is only checked to be unused: another writer can take it before this one is written, in which
            // case the next unused name is tried.
            for _ in 0..<5 {
                let url = paths.outputURL(date: date, format: format) ?? paths.saveURL(date: date, format: format)
                do {
                    return .success(try CaptureSignposts.measure("OutputWrite") {
                        try write(output.value, url, format, exportScale, scale)
                    })
                } catch ExportError.fileExists {
                    continue
                } catch {
                    return .failure(error)
                }
            }
            return .failure(ExportError.writeFailed("No unused file name was available."))
        }, completion: { [weak self] written in
            self?.finishExport(export, written: written)
        })
    }

    /// Records the outcome of a direct export, which is when its file (if any) exists: the Recent list, the
    /// thumbnail's drag file, the kept copy and the notification. A failed save falls back to the clipboard only when
    /// no copy was asked for and nothing else has been put on the clipboard since the export published.
    private func finishExport(_ export: DirectExport, written: Result<URL, Error>?) {
        var saved: URL?
        var failures: [String] = []
        var copied = export.copied
        var copyFailed = export.copyFailed
        switch written {
        case .success(let url): saved = url
        case .failure(let error): failures.append("Save failed: \(error.localizedDescription)")
        case nil: break
        }
        if saved == nil, export.copiesIfNotSaved, services.clipboardChangeCount() == export.clipboardMark {
            copied = services.copy(export.image, export.exportScale, export.backingScale)
            copyFailed = !copied
        }
        if copyFailed { failures.append("Copy to clipboard failed.") }
        if let saved {
            services.addRecent(saved)
            if export.showsQuickAccess { quickAccess.fileSaved(saved, for: export.id) }
        }
        keep(export.image, backingScale: export.backingScale, savedFile: saved, savedExportScale: export.exportScale,
             sharedAs: copied ? .copied : nil)
        let title: String
        let detail: String
        var failed = !failures.isEmpty
        if let saved {
            title = failures.isEmpty ? "Screenshot saved" : "Screenshot saved, but copy failed"
            detail = saved.lastPathComponent + (copied ? " — also copied to clipboard." : "")
        } else if copied {
            title = failures.isEmpty ? "Copied to clipboard" : "Copied to clipboard, but save failed"
            detail = "The beautified image is on the clipboard."
        } else {
            title = "Screenshot export failed"
            detail = "The beautified image was not saved or copied."
            failed = true
        }
        let message = ([detail] + failures + [export.wallpaperProblem].compactMap { $0 }).joined(separator: "\n")
        if failed {
            services.fail(title, message, saved)
        } else {
            services.notify(title, message, saved)
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

    /// True while screenshots are still being exported or kept: raw captures, outputs and kept copies being written.
    var isKeepingScreenshots: Bool { !(rawQueue.isIdle && outputQueue.isIdle && retentionQueue.isIdle) }

    /// Returns true when every queued write finished, false when `timeout` ran out first. A finished output queues its
    /// kept copy, so the queues are visited again until none has work left.
    func waitForRetention(timeout: Duration? = nil) async -> Bool {
        let clock = ContinuousClock()
        let deadline = timeout.map { clock.now.advanced(by: $0) }
        while isKeepingScreenshots {
            for queue in [rawQueue, outputQueue, retentionQueue] {
                let remaining = deadline.map { max(clock.now.duration(to: $0), .zero) }
                guard await queue.waitUntilIdle(timeout: remaining) else { return false }
            }
        }
        return true
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

    /// Opens the editor for a fresh capture. Its raw file may not be written yet; the editor is told when it is.
    private func openEditor(image: CGImage, scale: CGFloat, raw: RawCapture, source: String?,
                            redaction: RedactionAnalysis = .notRequested) {
        let controller = openEditor(image: image, scale: scale, rawURL: raw.url, source: source, redaction: redaction)
        raw.attach(controller)
    }

    @discardableResult
    func openEditor(image: CGImage, scale: CGFloat, rawURL: URL?, source: String?, isComposed: Bool = false,
                    restored: EditorRestoreState? = nil,
                    redaction: RedactionAnalysis = .notRequested) -> EditorWindowController {
        let context = EditorContext(image: image, backingScale: scale, rawURL: rawURL, source: source, isComposed: isComposed,
                                    restored: restored, redaction: redaction)
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
        controller.onProjectSaved = { [weak self] url in self?.services.addRecent(url) }
        controller.onProjectSaveFailed = { [weak self] url, error in self?.reportProjectSaveFailure(url, error) }
        services.presentEditor(controller)
        return controller
    }

    private func reportProjectSaveFailure(_ url: URL, _ error: Error) {
        services.notify("Project not saved", "\(url.lastPathComponent): \(error.localizedDescription)", nil)
    }

    /// Opens a saved `.glint` project with its look, annotations (and, for recordings, trim and export settings)
    /// exactly as they were saved. A project Glint can't read safely is reported and nothing is opened.
    func openProject(_ url: URL) async {
        let read = services.readProject
        let result = await Task.detached(priority: .userInitiated) { Result { try read(url) } }.value
        let project: GlintProject
        switch result {
        case .success(let value): project = value
        case .failure(let error):
            services.notify("Cannot open project", "\(url.lastPathComponent): \(error.localizedDescription)", nil)
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        switch (project.state, project.source) {
        case (.screenshot(let state), .image(let image)):
            services.addRecent(url)
            let controller = openEditor(image: image, scale: CGFloat(state.backingScale), rawURL: nil,
                                        source: state.source,
                                        restored: EditorRestoreState(settings: state.settings,
                                                                     annotations: state.annotations, projectName: name))
            let removeEditor = controller.onClose
            // The opened assets live in a private snapshot; it goes once no save can still be reading it.
            controller.onClose = { [weak controller] in
                removeEditor?()
                Task { @MainActor in
                    await controller?.waitForProjectSave()
                    project.discardSnapshot()
                }
            }
        case (.recording(let state), .video(let videoURL)):
            // The clip is Glint's private snapshot of the project's video, so it goes when the editor closes.
            let video = RecordedVideo(url: videoURL, duration: state.duration, pixelSize: state.pixelSize,
                                      deletesFileOnClose: true)
            let controller: RecordingEditorWindowController
            do {
                controller = try RecordingEditorWindowController(recording: video, project: state, projectName: name,
                                                                 preferences: prefs, presetStore: presetStore)
            } catch {
                project.discardSnapshot()
                services.notify("Cannot open project", "\(url.lastPathComponent): \(error.localizedDescription)", nil)
                return
            }
            services.addRecent(url)
            recordingEditors.append(controller)
            controller.onClose = { [weak self, weak controller] in
                project.discardSnapshot()
                guard let self, let controller else { return }
                self.recordingEditors.removeAll { $0 === controller }
            }
            controller.onProjectSaved = { [weak self] saved in self?.services.addRecent(saved) }
            controller.onProjectSaveFailed = { [weak self] saved, error in self?.reportProjectSaveFailure(saved, error) }
            services.presentRecordingEditor(controller)
        default:
            project.discardSnapshot()
            services.notify("Cannot open project", "\(url.lastPathComponent): \(ProjectFormatError.mismatchedSource.localizedDescription)", nil)
        }
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
        if ProjectStore.isProject(url) {
            Task { await openProject(url) }
            return
        }
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

/// The unstyled capture of one screenshot. Its file is written in the background, so it is only known once the write
/// succeeded, which can be after an editor for the capture opened.
@MainActor
private final class RawCapture {
    private(set) var url: URL?
    private let editors = NSHashTable<EditorWindowController>.weakObjects()

    init(url: URL? = nil) { self.url = url }

    func saved(_ url: URL) {
        self.url = url
        for editor in editors.allObjects { editor.rawFileSaved(url) }
    }

    /// Tells `editor` where the file is, now or as soon as it exists.
    func attach(_ editor: EditorWindowController) {
        if let url {
            editor.rawFileSaved(url)
        } else {
            editors.add(editor)
        }
    }
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
