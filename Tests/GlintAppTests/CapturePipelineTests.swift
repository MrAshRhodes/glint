import AppKit
import GlintCapture
@testable import GlintCore
@testable import GlintEditor
import ImageIO
import Testing
@testable import Glint

private enum TestFailure: Error { case write, recognition }

/// Pixel size and horizontal density (dpi) ImageIO recorded for the first image in `data`.
private func pixelSizeAndDensity(of data: Data) throws -> (width: Int, height: Int, dpi: Double) {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    return (try #require(properties[kCGImagePropertyPixelWidth] as? Int),
            try #require(properties[kCGImagePropertyPixelHeight] as? Int),
            try #require(properties[kCGImagePropertyDPIWidth] as? Double))
}

/// A value guarded by a lock, for test doubles the pipeline calls from background threads.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result { lock.withLock { body(&stored) } }
}

typealias RecordedWrite = (url: URL, format: ExportFormat, scale: ExportScale, backingScale: CGFloat)

/// Keeps the Edit action of the thumbnail the pipeline offers, which a test presses instead of clicking.
@MainActor
private final class EditActionQuickAccess: QuickAccessPresenting {
    private(set) var edit: (() -> Void)?

    func thumbnailPixelSide(for displayID: CGDirectDisplayID?) -> Int { 128 }

    func show(_ item: QuickAccessItem) { edit = item.onEdit }

    func fileSaved(_ url: URL, for id: UUID) {}
}

@MainActor
final class CaptureFixture {
    private struct Failures { var write = false, raw = false, render = false }

    let suite = "glint.pipeline.tests.\(UUID().uuidString)"
    let directory: URL
    let preferences: AppPreferences
    let presets: PresetStore
    let image: CGImage
    /// Written and rendered on background threads, so they sit behind locks.
    private let writeLog = LockedValue<[RecordedWrite]>([])
    private let renderLog = LockedValue<[CGImage]>([])
    private let failures = LockedValue(Failures())
    /// Whether each render ran on the main thread.
    let renderedOnMain = LockedValue<[Bool]>([])
    /// Runs on the writing thread before each file is written, so a test can hold the disk.
    let beforeWrite = LockedValue<(@Sendable (URL) -> Void)?>(nil)
    /// Runs on the rendering thread before each render.
    let beforeRender = LockedValue<(@Sendable () -> Void)?>(nil)
    var writes: [RecordedWrite] { writeLog.value }
    var renderedImages: [CGImage] { renderLog.value }
    var failWrite: Bool {
        get { failures.value.write }
        set { failures.withValue { $0.write = newValue } }
    }
    var failRaw: Bool {
        get { failures.value.raw }
        set { failures.withValue { $0.raw = newValue } }
    }
    var failRender: Bool {
        get { failures.value.render }
        set { failures.withValue { $0.render = newValue } }
    }
    var notifications: [(title: String, body: String, url: URL?)] = []
    var rejections = 0
    var recent: [URL] = []
    var copies = 0
    /// Counts every change of the clipboard, so a test can also stand in for another app using it.
    var clipboardChanges = 0
    var copiedImage: CGImage?
    var copiedScales: (scale: ExportScale, backingScale: CGFloat)?
    var copiedTexts: [String] = []
    var sounds = 0
    var wallpaper: Result<CGImage, DesktopWallpaperError> = .failure(.unavailable)
    var wallpaperReads = 0
    var copySucceeds = true
    var failRecognition = false
    var failBake = false
    var lines: [RecognizedLine] = []
    var recognizedImages: [CGImage] = []
    var bakedImages: [CGImage] = []
    var retryRequests: [(title: String, message: String)] = []
    var retry: () -> Bool = { false }
    var scrolling: (any ScrollingCapture)?

    init() throws {
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/TestFixtures/\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: suite))
        preferences = AppPreferences(defaults: defaults)
        preferences.saveDirectory = directory.appendingPathComponent("Manual")
        preferences.historyDirectory = directory.appendingPathComponent("History")
        preferences.openEditorAfterCapture = false
        preferences.autoBalance = false
        preferences.autoRedact = false
        preferences.saveRaw = false
        defaults.set(false, forKey: ShellKey.quickAccess)
        presets = PresetStore(url: directory.appendingPathComponent("presets.json"))
        let preset = presets.add(name: "Test", settings: RenderSettings(
            padding: 0, cornerRadius: 0, shadow: .none, background: .transparent
        ))
        presets.setDefault(id: preset.id)
        let context = try #require(GlintBitmap.makeContext(width: 100, height: 40))
        context.setFillColor(RGBAColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 40))
        image = try #require(context.makeImage())
    }

    func pipeline(configure: (inout CapturePipeline.Services) -> Void = { _ in }) -> CapturePipeline {
        var services = CapturePipeline.Services()
        let writeLog = writeLog, renderLog = renderLog, failures = failures
        let renderedOnMain = renderedOnMain, beforeWrite = beforeWrite, beforeRender = beforeRender
        services.write = { image, url, format, scale, backingScale in
            writeLog.withValue { $0.append((url, format, scale, backingScale)) }
            beforeWrite.value?(url)
            let flags = failures.value
            if flags.write || flags.raw && url.deletingLastPathComponent().lastPathComponent == "Raw" {
                throw TestFailure.write
            }
            return try Exporter.write(image, to: url, format: format, scale: scale, backingScale: backingScale,
                                      replacing: false)
        }
        services.copy = { [self] image, scale, backingScale in
            copies += 1
            clipboardChanges += 1
            copiedImage = image
            copiedScales = (scale, backingScale)
            return copySucceeds
        }
        services.copyText = { [self] in copiedTexts.append($0); clipboardChanges += 1 }
        services.clipboardChangeCount = { [self] in clipboardChanges }
        services.wallpaper = { [self] in wallpaperReads += 1; return wallpaper }
        services.recognize = { [self] image, _ in
            recognizedImages.append(image)
            if failRecognition { throw TestFailure.recognition }
            return lines
        }
        services.bake = { [self] image, annotations in
            bakedImages.append(image)
            return failBake ? nil : AnnotationRenderer.bake(source: image, annotations: annotations)
        }
        services.render = { image, settings, backingScale, wallpaper in
            renderLog.withValue { $0.append(image) }
            renderedOnMain.withValue { $0.append(Thread.isMainThread) }
            beforeRender.value?()
            if failures.value.render { throw RenderError.annotationsNotApplied }
            return try Compositor.render(image: image, settings: settings, backingScale: backingScale, wallpaper: wallpaper)
        }
        services.notify = { [self] in notifications.append(($0, $1, $2)) }
        services.fail = { [self] in notifications.append(($0, $1, $2)) }
        services.reject = { [self] in rejections += 1 }
        services.requestRetry = { [self] title, message in
            retryRequests.append((title, message))
            return retry()
        }
        services.addRecent = { [self] in recent.append($0) }
        services.sound = { [self] in sounds += 1 }
        services.captureWindows = { [] }
        if let scrolling { services.makeScrollingCapture = { scrolling } }
        configure(&services)
        return CapturePipeline(prefs: preferences, presetStore: presets, services: services)
    }

    func run(clipboardOnly: Bool = false, saveRaw: Bool = false) async {
        let pipeline = pipeline()
        await pipeline.handle(image: image, scale: 2, source: "test", rawURL: nil,
                              saveRaw: saveRaw, clipboardOnly: clipboardOnly)
        await settle(pipeline)
    }

    /// Waits for the writes a capture queued in the background.
    func settle(_ pipeline: CapturePipeline) async {
        let idle = await pipeline.waitForRetention(timeout: .seconds(60))
        #expect(idle, "Queued writes did not finish")
    }

    func cleanUp() {
        retry = { false }
        preferences.defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class CaptureTestWindow: NSWindow {
    var restorationCount = 0
    var hideCount = 0

    override func orderFront(_ sender: Any?) {
        restorationCount += 1
        super.orderFront(sender)
    }

    override func orderOut(_ sender: Any?) {
        hideCount += 1
        super.orderOut(sender)
    }
}

@Suite("Capture window lifecycle")
@MainActor
struct CaptureWindowLifecycleTests {
    private func window() -> CaptureTestWindow {
        _ = NSApplication.shared
        let window = CaptureTestWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        window.restorationCount = 0
        return window
    }

    @Test(arguments: [true, false])
    func hidePreferenceControlsCaptureAndCancellationPreservesEditor(hide: Bool) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        #expect(f.preferences.hideWindowsDuringCapture)
        f.preferences.hideWindowsDuringCapture = hide
        let editor = window(); defer { editor.close() }
        let content = NSView()
        editor.contentView = content
        var observed: CaptureOptions?
        var hook: (@MainActor () -> Void)?
        let pipeline = f.pipeline {
            $0.captureWindows = { [editor] }
            $0.capture = { capturer, mode, _ in
                observed = capturer.options
                hook = capturer.onSelectionPresented
                #expect(mode == .area)
                // Glint's windows stay up until the selection overlay covers them.
                #expect(editor.isVisible)
                capturer.onSelectionPresented?()
                #expect(editor.isVisible == !hide)
                throw CaptureError.cancelled
            }
        }
        try await #require(pipeline.start(.area)).value
        #expect(observed?.excludeOwnWindows == hide)
        #expect((hook != nil) == hide)
        #expect(ScreenCapturer.shared.onSelectionPresented == nil)
        #expect(editor.isVisible)
        #expect(editor.contentView === content)
        #expect(editor.restorationCount == (hide ? 1 : 0))
        #expect(!pipeline.isBusy)
        #expect(f.copies == 0 && f.writes.isEmpty && f.notifications.isEmpty)
    }

    @Test(arguments: [CapturePipeline.Mode.area, .areaToClipboard, .window, .fullscreen, .repeatLast, .timer(3), .text])
    func allScreenshotModesUseTheInclusionPolicy(mode: CapturePipeline.Mode) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.hideWindowsDuringCapture = false
        let editor = window(); defer { editor.close() }
        let utility = window(); defer { utility.close() }
        utility.identifier = QuickAccessPanel.windowIdentifier
        var options: CaptureOptions?
        var hooks: [Bool] = []
        var stalePresentations = 0
        ScreenCapturer.shared.onSelectionPresented = { stalePresentations += 1 }
        let pipeline = f.pipeline {
            $0.captureWindows = { [editor, utility] }
            $0.capture = { capturer, selectedMode, _ in
                #expect(selectedMode == mode)
                options = capturer.options
                hooks.append(capturer.onSelectionPresented != nil)
                throw CaptureError.cancelled
            }
            $0.captureText = { capturer in
                options = capturer.options
                hooks.append(capturer.onSelectionPresented != nil)
                throw CaptureError.cancelled
            }
        }
        try await #require(pipeline.start(mode)).value
        let received = try #require(options)
        #expect(!received.excludeOwnWindows)
        #expect(received.excludedWindowIDs == [CGWindowID(utility.windowNumber)])
        #expect(editor.isVisible && editor.restorationCount == 0)
        // The preference is off, so no hook is installed and a stale one is dropped.
        #expect(hooks == [false] && stalePresentations == 0)
        #expect(ScreenCapturer.shared.onSelectionPresented == nil)
    }

    @Test(arguments: [0, 1, 2, 3])
    func successAndFailuresRestoreTheExistingWindowExactlyOnce(outcome: Int) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let editor = window(); defer { editor.close() }
        var permissionPrompts = 0
        let pipeline = f.pipeline {
            $0.captureWindows = { [editor] }
            $0.permissionDenied = { permissionPrompts += 1 }
            $0.capture = { capturer, _, _ in
                #expect(editor.isVisible)
                capturer.onSelectionPresented?()
                #expect(!editor.isVisible)
                switch outcome {
                case 1: throw CaptureError.failed("Synthetic acquisition failure")
                case 2: throw CaptureError.permissionDenied
                case 3: throw CancellationError()
                default:
                    return CaptureResult(image: f.image, scale: 1, displayID: 1,
                                         rect: CGRect(x: 0, y: 0, width: 100, height: 40),
                                         kind: .area, windowInfo: nil)
                }
            }
        }
        try await #require(pipeline.start(.areaToClipboard)).value
        #expect(editor.isVisible && editor.restorationCount == 1)
        #expect(ScreenCapturer.shared.onSelectionPresented == nil)
        #expect(!pipeline.isBusy)
        #expect(permissionPrompts == (outcome == 2 ? 1 : 0))
        #expect(f.copies == (outcome == 0 ? 1 : 0))
        #expect(f.notifications.filter { $0.title == "Capture failed" }.count == (outcome == 1 ? 1 : 0))
    }

    @Test func cancelledTaskNeverExportsALateCaptureResult() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let editor = window(); defer { editor.close() }
        var continuation: CheckedContinuation<CaptureResult, Never>?
        let pipeline = f.pipeline {
            $0.captureWindows = { [editor] }
            $0.capture = { capturer, _, _ in
                capturer.onSelectionPresented?()
                return await withCheckedContinuation { continuation = $0 }
            }
        }
        let task = try #require(pipeline.start(.areaToClipboard))
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        #expect(!editor.isVisible)
        task.cancel()
        pending.resume(returning: CaptureResult(image: f.image, scale: 1, displayID: 1,
                                               rect: CGRect(x: 0, y: 0, width: 100, height: 40),
                                               kind: .area, windowInfo: nil))
        await task.value
        #expect(editor.isVisible && editor.restorationCount == 1)
        #expect(!pipeline.isBusy)
        #expect(f.copies == 0 && f.writes.isEmpty && f.notifications.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func cancellingDuringRecognitionNeverPublishesLateOutput(textMode: Bool, recognitionFails: Bool) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = !textMode
        var continuation: CheckedContinuation<Void, Never>?
        let pipeline = f.pipeline {
            $0.captureText = { _ in f.image }
            $0.capture = { _, _, _ in
                CaptureResult(image: f.image, scale: 1, displayID: 1,
                              rect: CGRect(x: 0, y: 0, width: 100, height: 40), kind: .area, windowInfo: nil)
            }
            $0.recognize = { _, _ in
                await withCheckedContinuation { continuation = $0 }
                if recognitionFails { throw CaptureError.invalidRect }
                return []
            }
            $0.requestRetry = { _, _ in Issue.record("Cancelled recognition offered a retry"); return false }
        }
        let task = try #require(pipeline.start(textMode ? .text : .areaToClipboard))
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        task.cancel()
        pending.resume()
        await task.value
        #expect(f.copies == 0 && f.copiedTexts.isEmpty && f.notifications.isEmpty)
        #expect(!pipeline.isBusy)
    }

    @Test(arguments: [true, false])
    func cancellingKeepsTheActualEditorAnnotationsAndUndoHistory(hide: Bool) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.hideWindowsDuringCapture = hide
        var windows: [NSWindow] = []
        let pipeline = f.pipeline {
            $0.captureWindows = { windows }
            $0.presentEditor = { $0.window?.orderFront(nil) }
            $0.capture = { capturer, _, _ in
                #expect(windows.allSatisfy { $0.isVisible })
                capturer.onSelectionPresented?()
                #expect(windows.allSatisfy { $0.isVisible == !hide })
                throw CaptureError.cancelled
            }
        }
        let editor = pipeline.openEditor(image: f.image, scale: 1, rawURL: nil, source: "Capture test")
        let window = try #require(editor.window)
        defer { window.close() }
        windows = [window]
        let annotation = Annotation(z: 0, kind: .redact(CGRect(x: 2, y: 2, width: 20, height: 10)))
        editor.model.undoManager.groupsByEvent = false
        editor.model.undoManager.beginUndoGrouping()
        editor.model.setAnnotations([annotation], actionName: "Redact")
        editor.model.undoManager.endUndoGrouping()

        try await #require(pipeline.start(.area)).value

        #expect(window.isVisible && editor.window === window)
        #expect(editor.model.annotations == [annotation])
        #expect(editor.model.undoManager.canUndo)
        editor.model.undoManager.undo()
        #expect(editor.model.annotations.isEmpty)
        editor.model.undoManager.redo()
        #expect(editor.model.annotations == [annotation])
    }

    @Test(arguments: [CapturePipeline.Mode.area, .areaToClipboard, .window, .text])
    func selectionOverlayHidesTheEditorOnlyOnceItIsPresented(mode: CapturePipeline.Mode) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.saveOutput = false
        let editor = window(); defer { editor.close() }
        var visibleAfterCapture: [Bool] = []
        func present(_ capturer: ScreenCapturer) {
            #expect(editor.isVisible)
            let presented = capturer.onSelectionPresented
            #expect(presented != nil)
            capturer.onSelectionPresented = nil
            presented?()
            // A repeated callback must not lose track of the hidden editor.
            presented?()
            #expect(!editor.isVisible)
        }
        let pipeline = f.pipeline {
            $0.captureWindows = { [editor] }
            $0.capture = { capturer, _, _ in
                present(capturer)
                return CaptureResult(image: f.image, scale: 1, displayID: 1,
                                     rect: CGRect(x: 0, y: 0, width: 100, height: 40), kind: .area, windowInfo: nil)
            }
            $0.captureText = { capturer in
                present(capturer)
                return f.image
            }
            $0.copy = { _, _, _ in visibleAfterCapture.append(editor.isVisible); return true }
            $0.recognize = { _, _ in visibleAfterCapture.append(editor.isVisible); return [] }
        }
        try await #require(pipeline.start(mode)).value
        #expect(visibleAfterCapture == [true])
        #expect(editor.isVisible && editor.restorationCount == 1)
        #expect(ScreenCapturer.shared.onSelectionPresented == nil)
        #expect(!pipeline.isBusy)
    }

    @Test(arguments: [CapturePipeline.Mode.area, .areaToClipboard, .window, .text], [0, 1, 2, 3])
    func selectionEndingBeforeItIsPresentedNeverHidesTheEditor(mode: CapturePipeline.Mode, outcome: Int) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let editor = window(); defer { editor.close() }
        var permissionPrompts = 0
        var hooks: [Bool] = []
        func failure(_ capturer: ScreenCapturer) -> Error {
            hooks.append(capturer.onSelectionPresented != nil)
            #expect(editor.isVisible)
            switch outcome {
            case 1: return CaptureError.failed("Synthetic freeze failure")
            case 2: return CaptureError.permissionDenied
            case 3: return CancellationError()
            default: return CaptureError.cancelled
            }
        }
        let pipeline = f.pipeline {
            $0.captureWindows = { [editor] }
            $0.permissionDenied = { permissionPrompts += 1 }
            $0.capture = { capturer, _, _ in throw failure(capturer) }
            $0.captureText = { capturer in throw failure(capturer) }
        }
        try await #require(pipeline.start(mode)).value
        #expect(hooks == [true])
        #expect(editor.isVisible && editor.restorationCount == 0)
        #expect(ScreenCapturer.shared.onSelectionPresented == nil)
        #expect(permissionPrompts == (outcome == 2 ? 1 : 0))
        #expect(!pipeline.isBusy)
    }

    @Test(arguments: [CapturePipeline.Mode.areaToClipboard, .text], [false, true])
    func presentationAfterRestorationNeverHidesTheEditorAgain(mode: CapturePipeline.Mode,
                                                               presentedDuringSelection: Bool) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let editor = window(); defer { editor.close() }
        var late: (@MainActor () -> Void)?
        func select(_ capturer: ScreenCapturer) {
            late = capturer.onSelectionPresented
            if presentedDuringSelection { late?() }
        }
        func presentLate() {
            late?()
            #expect(editor.isVisible)
        }
        let pipeline = f.pipeline {
            $0.captureWindows = { [editor] }
            $0.capture = { capturer, _, _ in
                select(capturer)
                return CaptureResult(image: f.image, scale: 1, displayID: 1,
                                     rect: CGRect(x: 0, y: 0, width: 100, height: 40), kind: .area, windowInfo: nil)
            }
            $0.captureText = { capturer in
                select(capturer)
                return f.image
            }
            $0.copy = { _, _, _ in presentLate(); return true }
            $0.recognize = { _, _ in presentLate(); return [] }
        }
        try await #require(pipeline.start(mode)).value
        #expect(late != nil)
        presentLate()
        #expect(editor.restorationCount == (presentedDuringSelection ? 1 : 0))
    }

    @Test(arguments: [CapturePipeline.Mode.fullscreen, .repeatLast], [0, 1, 2, 3, 4, 5])
    func noninteractiveCapturesNeverReorderExistingWindows(mode: CapturePipeline.Mode, outcome: Int) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.saveOutput = false
        let editor = window(); defer { editor.close() }
        let settings = window(); defer { settings.close() }
        let hidden = window(); defer { hidden.close() }
        hidden.orderOut(nil)
        hidden.hideCount = 0
        let visible: [NSWindow] = [settings, editor]
        let initialOrder = NSApp.orderedWindows.filter { visible.contains($0) }
        let initialKeyWindow = NSApp.keyWindow
        var permissionPrompts = 0
        var stalePresentations = 0
        ScreenCapturer.shared.onSelectionPresented = { stalePresentations += 1 }
        func checkWindows() {
            #expect(visible.allSatisfy { $0.isVisible })
            #expect(!hidden.isVisible)
            #expect(NSApp.orderedWindows.filter { visible.contains($0) } == initialOrder)
            #expect(NSApp.keyWindow === initialKeyWindow)
            #expect([editor, settings, hidden].allSatisfy { $0.hideCount == 0 && $0.restorationCount == 0 })
        }
        let pipeline = f.pipeline {
            $0.captureWindows = { [settings, editor, hidden] }
            $0.permissionDenied = { permissionPrompts += 1 }
            $0.capture = { capturer, selectedMode, _ in
                #expect(selectedMode == mode)
                #expect(capturer.options.excludeOwnWindows)
                #expect(capturer.onSelectionPresented == nil)
                checkWindows()
                switch outcome {
                case 1: throw CaptureError.failed("Synthetic acquisition failure")
                case 2: throw CaptureError.permissionDenied
                case 3: throw CancellationError()
                case 4: throw CaptureError.cancelled
                case 5: throw CaptureError.noLastArea
                default:
                    return CaptureResult(image: f.image, scale: 1, displayID: 1,
                                         rect: CGRect(x: 0, y: 0, width: 100, height: 40),
                                         kind: mode == .fullscreen ? .fullscreen : .lastArea, windowInfo: nil)
                }
            }
        }
        let task = try #require(pipeline.start(mode))
        checkWindows()
        await task.value
        checkWindows()
        #expect(stalePresentations == 0 && ScreenCapturer.shared.onSelectionPresented == nil)
        #expect(!pipeline.isBusy)
        #expect(permissionPrompts == (outcome == 2 ? 1 : 0))
        #expect(f.notifications.filter { $0.title == "Capture failed" }.count == ([1, 5].contains(outcome) ? 1 : 0))
    }

    @Test(arguments: [CapturePipeline.Mode.fullscreen, .repeatLast])
    func cancellingNoninteractiveCaptureDiscardsLatePixelsWithoutReorderingWindows(mode: CapturePipeline.Mode) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let editor = window(); defer { editor.close() }
        var continuation: CheckedContinuation<CaptureResult, Never>?
        let pipeline = f.pipeline {
            $0.captureWindows = { [editor] }
            $0.capture = { _, _, _ in
                return await withCheckedContinuation { continuation = $0 }
            }
        }
        let task = try #require(pipeline.start(mode))
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        #expect(editor.isVisible && editor.hideCount == 0)
        task.cancel()
        pending.resume(returning: CaptureResult(image: f.image, scale: 1, displayID: 1,
                                               rect: CGRect(x: 0, y: 0, width: 100, height: 40),
                                               kind: .fullscreen, windowInfo: nil))
        await task.value
        #expect(editor.isVisible && editor.hideCount == 0 && editor.restorationCount == 0)
        #expect(!pipeline.isBusy)
        #expect(f.copies == 0 && f.writes.isEmpty && f.notifications.isEmpty)
    }

    @Test func timedCaptureStillHidesWindowsUpFront() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let editor = window(); defer { editor.close() }
        var stalePresentations = 0
        ScreenCapturer.shared.onSelectionPresented = { stalePresentations += 1 }
        var hooks: [Bool] = []
        let pipeline = f.pipeline {
            $0.captureWindows = { [editor] }
            $0.capture = { capturer, _, _ in
                hooks.append(capturer.onSelectionPresented != nil)
                #expect(!editor.isVisible)
                throw CaptureError.cancelled
            }
        }
        try await #require(pipeline.start(.timer(3))).value
        #expect(hooks == [false] && stalePresentations == 0)
        #expect(editor.isVisible && editor.restorationCount == 1)
        #expect(ScreenCapturer.shared.onSelectionPresented == nil)
    }

    @Test func scrollingCaptureHidesUpFrontWithoutAPresentationHook() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let editor = window(); defer { editor.close() }
        let capture = FakeScrollingCapture(image: f.image)
        f.scrolling = capture
        var stalePresentations = 0
        ScreenCapturer.shared.onSelectionPresented = { stalePresentations += 1 }
        let pipeline = f.pipeline { $0.captureWindows = { [editor] } }

        let task = try #require(pipeline.start(.scrolling))
        #expect(!editor.isVisible)
        #expect(ScreenCapturer.shared.onSelectionPresented == nil)
        for _ in 0..<100 where !capture.isRunning { await Task.yield() }
        capture.cancel()
        await task.value
        #expect(stalePresentations == 0)
        #expect(editor.isVisible && editor.restorationCount == 1)
    }
}

/// Stands in for a scrolling capture: it runs until it is finished or cancelled.
@MainActor
private final class FakeScrollingCapture: ScrollingCapture {
    let result: CaptureResult
    private(set) var finishes = 0
    private(set) var isRunning = false
    private var continuation: CheckedContinuation<CaptureResult, Error>?

    init(image: CGImage) {
        result = CaptureResult(image: image, scale: 2, displayID: 1, rect: CGRect(x: 0, y: 0, width: 50, height: 400),
                               kind: .scrolling, windowInfo: nil)
    }

    func run() async throws -> CaptureResult {
        isRunning = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish() {
        finishes += 1
        continuation?.resume(returning: result)
        continuation = nil
    }

    func cancel() {
        continuation?.resume(throwing: CaptureError.cancelled)
        continuation = nil
    }
}

@Suite("Capture export outcomes")
@MainActor
struct CapturePipelineTests {
    @Test(arguments: [
        "demo-password-4826",
        "recovery-code-1234\n" + String(repeating: "token-", count: 30) + "\ncaf\u{00E9} \u{1F511}"
    ])
    func captureTextKeepsRecognizedContentOutOfNotifications(text: String) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.lines = text.components(separatedBy: "\n").map { RecognizedLine(text: $0, box: .zero) }
        await f.pipeline().recognizeText(in: f.image)
        #expect(f.copiedTexts == [text])
        #expect(f.sounds == 1)
        #expect(f.notifications.count == 1)
        let notification = try #require(f.notifications.first)
        #expect(notification.title == "Text copied")
        #expect(notification.body == "Recognized text copied to clipboard")
        #expect(notification.url == nil)
    }

    @Test func captureTextWithNoTextDoesNotCopyOrReportSuccess() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        await f.pipeline().recognizeText(in: f.image)
        #expect(f.copiedTexts.isEmpty && f.sounds == 0)
        #expect(f.notifications.count == 1)
        let notification = try #require(f.notifications.first)
        #expect(notification.title == "No text found")
        #expect(notification.body == "Nothing was recognised in the selected area.")
        #expect(notification.url == nil)
    }

    @Test func captureTextRecognitionFailureDoesNotCopyOrReportSuccess() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.failRecognition = true
        await f.pipeline().recognizeText(in: f.image)
        #expect(f.copiedTexts.isEmpty && f.sounds == 0)
        #expect(f.notifications.count == 1)
        let notification = try #require(f.notifications.first)
        #expect(notification.title == "Text recognition failed")
        #expect(notification.body == TestFailure.recognition.localizedDescription)
        #expect(notification.url == nil)
    }

    @Test func savesAutomaticOutputAndRecordsOnlySuccessfulFile() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.exportFormat = .jpeg(quality: 0.7)
        f.preferences.exportScale = .x1
        await f.run()
        let write = try #require(f.writes.first)
        #expect(write.url.deletingLastPathComponent() == f.preferences.historyDirectory.appendingPathComponent("Output"))
        #expect(write.format == .jpeg(quality: 0.7) && write.scale == .x1 && write.backingScale == 2)
        #expect(GlintImageIO.load(url: write.url)?.width == 50)
        #expect(f.recent == [write.url] && f.copies == 0)
        #expect(f.notifications.map(\.title) == ["Screenshot saved"])
        #expect(f.notifications.first?.url == write.url)
        #expect(f.wallpaperReads == 0)
    }

    @Test func wallpaperPresetUsesSameImageForAutomaticSaveAndCopy() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.presets.add(name: "Test", settings: RenderSettings(
            padding: 20, cornerRadius: 0, shadow: .none, background: .solid(.black), usesDesktopWallpaper: true
        ))
        f.wallpaper = .success(f.image)
        f.preferences.exportFormat = .plainPNG
        f.preferences.exportScale = .original
        f.preferences.copyToClipboardAfterCapture = true
        await f.run()
        let savedURL = try #require(f.recent.first)
        let saved = try #require(GlintImageIO.load(url: savedURL))
        let copied = try #require(f.copiedImage)
        #expect(try #require(PixelBuffer(saved)).pixel(1, 1) == (255, 255, 255, 255))
        #expect(PixelBuffer(saved)?.data == PixelBuffer(copied)?.data)
        #expect(f.wallpaperReads == 1 && f.copies == 1)
        #expect(f.notifications.map(\.title) == ["Screenshot saved"])
    }

    @Test(arguments: ExportScale.allCases, [false, true])
    func copyReceivesTheScalesOfTheSavedFile(scale: ExportScale, clipboardOnly: Bool) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.exportScale = scale
        f.preferences.copyToClipboardAfterCapture = true
        await f.run(clipboardOnly: clipboardOnly)
        let copied = try #require(f.copiedScales)
        #expect(f.copies == 1 && copied.scale == scale && copied.backingScale == 2)
        if clipboardOnly {
            #expect(f.writes.isEmpty)
        } else {
            let write = try #require(f.writes.first)
            #expect(write.scale == copied.scale && write.backingScale == copied.backingScale)
        }
    }

    @Test(arguments: ExportScale.allCases)
    func pastedCaptureHasTheSizeAndDensityOfTheSavedFile(scale: ExportScale) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.exportScale = scale
        f.preferences.copyToClipboardAfterCapture = true
        let pasteboard = NSPasteboard(name: .init("glint.pipeline.density.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let pipeline = f.pipeline {
            $0.copy = { Exporter.copyToClipboard($0, scale: $1, backingScale: $2, pasteboard: pasteboard) }
        }
        await pipeline.handle(image: f.image, scale: 2, source: "test", rawURL: nil, saveRaw: false, clipboardOnly: false)
        await f.settle(pipeline)

        let savedURL = try #require(f.recent.first)
        let file = try pixelSizeAndDensity(of: Data(contentsOf: savedURL))
        let png = try pixelSizeAndDensity(of: try #require(pasteboard.data(forType: .png)))
        let tiff = try pixelSizeAndDensity(of: try #require(pasteboard.data(forType: .tiff)))
        // The 100×40 capture came from a 2× display: Original and 2× keep that size at 144 dpi, 1× halves it at 72.
        let expected = scale == .x1 ? (width: 50, height: 20, dpi: 72.0) : (width: 100, height: 40, dpi: 144.0)
        for output in [file, png, tiff] {
            #expect(output.width == expected.width && output.height == expected.height)
            #expect(abs(output.dpi - expected.dpi) < 0.1)
        }
    }

    @Test func unreadableWallpaperReportsFallbackWithoutBlockingExport() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.presets.add(name: "Test", settings: RenderSettings(
            padding: 20, cornerRadius: 0, shadow: .none, background: .solid(.black), usesDesktopWallpaper: true
        ))
        f.preferences.exportFormat = .plainPNG
        await f.run()
        let savedURL = try #require(f.recent.first)
        let saved = try #require(GlintImageIO.load(url: savedURL))
        #expect(try #require(PixelBuffer(saved)).pixel(1, 1) == (0, 0, 0, 255))
        #expect(f.notifications.first?.body.contains(DesktopWallpaperError.unavailable.localizedDescription) == true)
        #expect(f.wallpaperReads == 1)
    }

    @Test func clipboardOnlyNeverSavesRenderedOutput() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.openEditorAfterCapture = true
        await f.run(clipboardOnly: true)
        #expect(f.writes.isEmpty && f.recent.isEmpty && f.copies == 1)
        #expect(f.notifications.map(\.title) == ["Copied to clipboard"])
        #expect(f.notifications.first?.url == nil)
    }

    @Test func saveFailureFallsBackToClipboardAndReportsPartialFailure() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.failWrite = true
        await f.run()
        #expect(f.writes.count == 1 && f.copies == 1 && f.recent.isEmpty)
        #expect(f.notifications.map(\.title) == ["Copied to clipboard, but save failed"])
        #expect(f.notifications.first?.body.contains("Save failed:") == true)
        #expect(f.notifications.first?.url == nil)
    }

    @Test func completeFailureNeverReportsSuccessOrAddsRecentFile() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.failWrite = true
        f.copySucceeds = false
        await f.run()
        #expect(f.recent.isEmpty && f.copies == 1)
        #expect(f.notifications.map(\.title) == ["Screenshot export failed"])
        #expect(f.notifications.first?.body.contains("not saved or copied") == true)
        #expect(f.notifications.first?.body.contains("Save failed:") == true)
        #expect(f.notifications.first?.body.contains("Copy to clipboard failed.") == true)
    }

    @Test func clipboardOnlyFailureIsNotReportedAsCopied() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.copySucceeds = false
        await f.run(clipboardOnly: true)
        #expect(f.writes.isEmpty && f.recent.isEmpty)
        #expect(f.notifications.map(\.title) == ["Screenshot export failed"])
    }

    @Test func savedFileSurvivesClipboardFailure() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.copyToClipboardAfterCapture = true
        f.copySucceeds = false
        await f.run()
        let url = try #require(f.recent.first)
        #expect(GlintImageIO.load(url: url) != nil && f.copies == 1)
        #expect(f.notifications.map(\.title) == ["Screenshot saved, but copy failed"])
        #expect(f.notifications.first?.url == url)
    }

    @Test func successfulSaveAndCopyReportsBoth() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.copyToClipboardAfterCapture = true
        await f.run()
        #expect(f.recent.count == 1 && f.copies == 1)
        #expect(f.notifications.map(\.title) == ["Screenshot saved"])
        #expect(f.notifications.first?.body.contains("also copied") == true)
    }

    @Test func disabledOutputSaveStillProducesClipboardOutput() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.saveOutput = false
        await f.run()
        #expect(f.writes.isEmpty && f.copies == 1)
        #expect(f.notifications.map(\.title) == ["Copied to clipboard"])
    }

    @Test func rawSaveFailureIsReportedWithoutDiscardingRenderedOutput() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.saveRaw = true
        f.failRaw = true
        await f.run(saveRaw: true)
        #expect(f.writes.count == 2 && f.recent.count == 1)
        // The raw file and the output are written on separate queues, so their reports can arrive in either order.
        #expect(f.notifications.map(\.title).sorted() == ["Raw screenshot not saved", "Screenshot saved"])
    }

    @Test func disabledHistoryUsesManualDirectoryAndSkipsRawSave() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.saveHistory = false
        f.preferences.saveRaw = true
        await f.run(saveRaw: true)
        #expect(f.writes.count == 1)
        #expect(f.writes.first?.url.deletingLastPathComponent() == f.preferences.saveDirectory)
    }

    @Test func failedOCRStopsAutomaticExport() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.failRecognition = true
        await f.run()
        #expect(f.writes.isEmpty && f.copies == 0 && f.recent.isEmpty)
        #expect(f.notifications.map(\.title) == ["Auto-redaction failed"])
    }

    @Test func failedRedactionBakeNeverExportsOriginalImage() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        f.failBake = true
        await f.run()
        #expect(f.writes.isEmpty && f.copies == 0 && f.recent.isEmpty)
        #expect(f.notifications.map(\.title) == ["Auto-redaction failed"])
        #expect(f.notifications.first?.body.contains("redactions could not be applied") == true)
    }

    @Test func failedRenderNeverSavesOrCopies() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.copyToClipboardAfterCapture = true
        f.failRender = true
        await f.run()
        #expect(f.writes.isEmpty && f.copies == 0 && f.recent.isEmpty)
        #expect(f.notifications.map(\.title) == ["Screenshot not exported"])
        #expect(f.notifications.first?.body == RenderError.annotationsNotApplied.localizedDescription)
        #expect(f.notifications.first?.url == nil)
    }

    @Test func failedRenderInClipboardOnlyModeNeverCopies() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.failRender = true
        await f.run(clipboardOnly: true)
        #expect(f.writes.isEmpty && f.copies == 0 && f.copiedImage == nil)
        #expect(f.notifications.map(\.title) == ["Screenshot not exported"])
    }

    @Test(arguments: RedactionStyle.allCases)
    func successfulRedactionIsBakedIntoExportDespiteLegacyStyle(_ legacyStyle: RedactionStyle) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.defaults.set(legacyStyle.rawValue, forKey: AppPreferences.Key.redactStyle)
        f.preferences.autoRedact = true
        f.preferences.copyToClipboardAfterCapture = true
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        await f.run()
        let url = try #require(f.recent.first)
        let image = try #require(GlintImageIO.load(url: url))
        let copied = try #require(f.copiedImage)
        for output in [image, copied] {
            let pixels = try #require(PixelBuffer(output))
            for y in 7..<33 { for x in 7..<93 {
                #expect(pixels.pixel(x, y) == (0, 0, 0, 255))
            } }
            #expect(pixels.pixel(0, 0) == (255, 255, 255, 255))
        }
        #expect(f.copies == 1)
        #expect(f.notifications.map(\.title) == ["Screenshot saved"])
    }

    @Test func successfulOCRWithNoFindingsStillExports() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.failBake = true
        await f.run()
        #expect(f.writes.count == 1 && f.recent.count == 1)
        #expect(f.notifications.map(\.title) == ["Screenshot saved"])
    }

    @Test func retryAlertOffersRecoveryWithoutShowingCapturedPixels() throws {
        let alert = CaptureRecovery.alert(title: "Auto-redaction failed", message: "Redactions could not be applied.")
        #expect(alert.messageText == "Auto-redaction failed")
        #expect(alert.informativeText.contains("No safe output was saved or copied."))
        #expect(alert.informativeText.contains("stays in memory"))
        #expect(alert.informativeText.contains("No additional raw image is saved"))
        #expect(alert.buttons.map(\.title) == ["Retry", "Discard Capture"])
        #expect(alert.buttons.first?.keyEquivalent == "\r")
        #expect(alert.accessoryView == nil)
    }

    @Test func retriesOCRAndBakeWithoutLosingPixelsOrRequiredRedactions() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        f.failRecognition = true
        f.failBake = true
        f.retry = {
            #expect(f.writes.isEmpty && f.copies == 0 && f.renderedImages.isEmpty)
            f.preferences.autoRedact = false
            f.preferences.autoRedactOptions = SensitiveInfoOptions(categories: [])
            f.preferences.redactColor = .white
            if f.retryRequests.count == 2 { f.failRecognition = false }
            if f.retryRequests.count == 4 { f.failBake = false }
            return f.retryRequests.count <= 4
        }
        await f.run()
        #expect(f.retryRequests.count == 4)
        #expect(f.recognizedImages.count == 3 && f.bakedImages.count == 3)
        #expect(f.recognizedImages.allSatisfy { $0 === f.image })
        #expect(f.bakedImages.allSatisfy { $0 === f.image })
        #expect(f.sounds == 1 && f.writes.count == 1 && f.copies == 0)
        let savedURL = try #require(f.recent.first)
        let saved = try #require(GlintImageIO.load(url: savedURL))
        #expect(try #require(PixelBuffer(saved)).pixel(50, 20) == (0, 0, 0, 255))
    }

    @Test(arguments: [false, true])
    func discardingRepeatedRedactionFailuresNeverExports(bakeFailure: Bool) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        f.failRecognition = !bakeFailure
        f.failBake = bakeFailure
        f.retry = {
            #expect(f.writes.isEmpty && f.copies == 0 && f.renderedImages.isEmpty)
            return f.retryRequests.count < 100
        }
        await f.run()
        #expect(f.retryRequests.count == 100)
        #expect(f.recognizedImages.count == (bakeFailure ? 1 : 100))
        #expect(f.bakedImages.count == (bakeFailure ? 100 : 0))
        #expect(f.writes.isEmpty && f.copies == 0 && f.recent.isEmpty)
        #expect(f.renderedImages.isEmpty && f.sounds == 1)
    }

    @Test func retriesDoNotRepeatExplicitRawSaveOrCaptureSound() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.preferences.saveRaw = true
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        f.failBake = true
        f.failRender = true
        f.retry = {
            // The raw file is written in the background, so it may not have been recorded yet; it is never repeated.
            #expect(f.writes.count <= 1 && f.copies == 0 && f.sounds == 1)
            if f.retryRequests.count == 2 { f.failBake = false }
            if f.retryRequests.count == 4 { f.failRender = false }
            return f.retryRequests.count <= 4
        }
        await f.run(saveRaw: true)
        #expect(f.retryRequests.count == 4 && f.sounds == 1)
        #expect(f.recognizedImages.count == 1 && f.bakedImages.count == 3 && f.renderedImages.count == 3)
        #expect(f.writes.count == 2 && f.recent.count == 1)
        let rawWrites = f.writes.filter { $0.url.deletingLastPathComponent().lastPathComponent == "Raw" }
        #expect(rawWrites.count == 1)
        let rawURL = try #require(rawWrites.first?.url)
        let savedURL = try #require(f.recent.first)
        let raw = try #require(GlintImageIO.load(url: rawURL))
        let saved = try #require(GlintImageIO.load(url: savedURL))
        #expect(try #require(PixelBuffer(raw)).pixel(50, 20) == (255, 255, 255, 255))
        #expect(try #require(PixelBuffer(saved)).pixel(50, 20) == (0, 0, 0, 255))
    }

    @Test func renderRetryKeepsRedactedInputAndClipboardOnlyPolicy() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.preferences.openEditorAfterCapture = true
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        f.failRender = true
        f.retry = {
            #expect(f.writes.isEmpty && f.copies == 0 && f.recent.isEmpty)
            f.preferences.autoRedact = false
            f.preferences.saveOutput = true
            if f.retryRequests.count == 2 { f.failRender = false }
            return f.retryRequests.count <= 2
        }
        await f.run(clipboardOnly: true)
        #expect(f.retryRequests.count == 2)
        #expect(f.recognizedImages.count == 1 && f.bakedImages.count == 1 && f.renderedImages.count == 3)
        let redacted = try #require(f.renderedImages.first)
        #expect(redacted !== f.image)
        #expect(f.renderedImages.allSatisfy { $0 === redacted })
        #expect(try #require(PixelBuffer(redacted)).pixel(50, 20) == (0, 0, 0, 255))
        let copied = try #require(f.copiedImage)
        #expect(try #require(PixelBuffer(copied)).pixel(50, 20) == (0, 0, 0, 255))
        #expect(f.writes.isEmpty && f.recent.isEmpty && f.copies == 1 && f.sounds == 1)
        #expect(f.notifications.last?.title == "Copied to clipboard")
    }

    @Test(arguments: [false, true])
    func discardingRepeatedRenderFailuresNeverExports(clipboardOnly: Bool) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.failRender = true
        f.retry = {
            #expect(f.writes.isEmpty && f.copies == 0 && f.recent.isEmpty)
            return f.retryRequests.count < 100
        }
        await f.run(clipboardOnly: clipboardOnly)
        #expect(f.retryRequests.count == 100 && f.renderedImages.count == 100)
        #expect(f.renderedImages.allSatisfy { $0 === f.image })
        #expect(f.writes.isEmpty && f.copies == 0 && f.recent.isEmpty && f.sounds == 1)
    }

    @Test(arguments: [true, false])
    func theEditorIsToldWhetherTheCaptureWasAlreadyRedacted(autoRedact: Bool) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = autoRedact
        f.preferences.openEditorAfterCapture = true
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        var opened: [(editor: EditorWindowController, holdsBack: Bool, showsCapture: Bool, analysis: RedactionAnalysis)] = []
        // Looks at the editor as it is presented, before anything it starts asynchronously has run.
        let pipeline = f.pipeline {
            $0.presentEditor = {
                opened.append(($0, $0.model.awaitsRedaction, $0.model.provisional != nil, $0.model.redactionAnalysis))
            }
        }
        await pipeline.handle(image: f.image, scale: 2, source: "test", rawURL: nil, saveRaw: false)

        let first = try #require(opened.first)
        defer { first.editor.window?.close() }
        #expect(opened.count == 1)
        #expect(!first.holdsBack, "The pipeline already redacted the capture, so the editor has nothing to wait for")
        #expect(first.showsCapture)
        let pixels = try #require(PixelBuffer(first.editor.model.image))
        let expected: UInt8 = autoRedact ? 0 : 255
        #expect(pixels.pixel(50, 20) == (expected, expected, expected, 255))
        #expect(f.recognizedImages.count == (autoRedact ? 1 : 0))

        let analysis: RedactionAnalysis = autoRedact ? foundEmail(f) : .notRequested
        #expect(first.analysis == analysis, "The editor starts from what the pipeline found")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(first.editor.model.redactionAnalysis == analysis, "It never started a pass of its own")
        #expect(!first.editor.model.isBusy)
    }

    @Test func editingADirectExportDoesNotReadItsCaptureAgain() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.preferences.defaults.set(true, forKey: ShellKey.quickAccess)
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        var editors: [EditorWindowController] = []
        let quickAccess = EditActionQuickAccess()
        let pipeline = f.pipeline {
            $0.makeQuickAccess = { quickAccess }
            $0.presentEditor = { editors.append($0) }
        }
        await pipeline.handle(image: f.image, scale: 2, source: "test", rawURL: nil, saveRaw: false)
        await f.settle(pipeline)
        #expect(f.writes.count == 1 && editors.isEmpty)
        #expect(f.recognizedImages.count == 1)

        let pressEdit = try #require(quickAccess.edit)
        pressEdit()
        let editor = try #require(editors.first)
        defer { editor.window?.close() }
        #expect(!editor.model.awaitsRedaction, "The exported capture was redacted, so the editor shows it at once")
        #expect(editor.model.redactionAnalysis == foundEmail(f))
        #expect(try #require(PixelBuffer(editor.model.image)).pixel(50, 20) == (0, 0, 0, 255))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(editor.model.redactionAnalysis == foundEmail(f) && !editor.model.isBusy)
        #expect(f.recognizedImages.count == 1, "Neither the pipeline nor the editor read the capture a second time")
    }

    @Test func anEditorWithOtherSettingsThanTheExportReadsTheCaptureItself() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.preferences.defaults.set(true, forKey: ShellKey.quickAccess)
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        var opened: [(editor: EditorWindowController, holdsBack: Bool, analysis: RedactionAnalysis)] = []
        let quickAccess = EditActionQuickAccess()
        let pipeline = f.pipeline {
            $0.makeQuickAccess = { quickAccess }
            $0.presentEditor = { opened.append(($0, $0.model.awaitsRedaction, $0.model.redactionAnalysis)) }
        }
        await pipeline.handle(image: f.image, scale: 2, source: "test", rawURL: nil, saveRaw: false)
        await f.settle(pipeline)

        f.preferences.autoRedactOptions = .all
        let pressEdit = try #require(quickAccess.edit)
        pressEdit()
        let first = try #require(opened.first)
        defer { first.editor.window?.close() }
        #expect(first.holdsBack && first.analysis == .pending, "What was found with other categories is not an answer")
    }

    @Test(arguments: [false, true])
    func theRawFileIsTheCaptureAsTakenBeforeAnyRedaction(opensEditor: Bool) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.preferences.saveRaw = true
        f.preferences.openEditorAfterCapture = opensEditor
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        var editors: [EditorWindowController] = []
        let pipeline = f.pipeline { $0.presentEditor = { editors.append($0) } }
        await pipeline.handle(image: f.image, scale: 2, source: "test", rawURL: nil, saveRaw: true)
        // The raw file is written off the main thread, alongside the redaction, so wait for it.
        await f.settle(pipeline)

        let rawWrite = try #require(f.writes.first { $0.url.deletingLastPathComponent().lastPathComponent == "Raw" })
        let raw = try #require(GlintImageIO.load(url: rawWrite.url))
        #expect(try #require(PixelBuffer(raw)).pixel(50, 20) == (255, 255, 255, 255), "It holds the original pixels")

        if opensEditor {
            let editor = try #require(editors.first)
            defer { editor.window?.close() }
            #expect(editor.model.rawURL == rawWrite.url, "The editor is told where the unredacted original is")
            #expect(try #require(PixelBuffer(editor.model.image)).pixel(50, 20) == (0, 0, 0, 255))
        } else {
            let exportedURL = try #require(f.recent.first)
            let exported = try #require(GlintImageIO.load(url: exportedURL))
            #expect(try #require(PixelBuffer(exported)).pixel(50, 20) == (0, 0, 0, 255), "The export is redacted")
        }
        #expect(f.writes.filter { $0.url.deletingLastPathComponent().lastPathComponent == "Raw" }.count == 1)
    }

    // MARK: One policy at every scale

    /// What a pass finds in the fixture's one address with the fixture's settings.
    private func foundEmail(_ f: CaptureFixture) -> RedactionAnalysis {
        .matches(.init(count: 1, byCategory: [.email: 1]), .init(detector: f.preferences.autoRedactOptions))
    }

    /// A white capture of 100 × 40 points taken at `scale`.
    private func capture(scale: CGFloat) throws -> CGImage {
        let context = try #require(GlintBitmap.makeContext(width: Int(100 * scale), height: Int(40 * scale)))
        context.setFillColor(RGBAColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 100 * scale, height: 40 * scale))
        return try #require(context.makeImage())
    }

    private func covers(_ annotations: [Annotation]) -> [CGRect] {
        annotations.compactMap { annotation in
            guard case .redact(let rect) = annotation.kind else { return nil }
            return rect
        }
    }

    @Test(arguments: [CGFloat(1), 2])
    func theEditorAndThePipelineCoverTheSameRegionAtEveryScale(scale: CGFloat) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.preferences.openEditorAfterCapture = true
        let image = try capture(scale: scale)
        // Text laid out in points: one match in the top-left corner and one running past the right edge, so
        // both covers are clipped by the image.
        let lines = [
            RecognizedLine(text: "test@example.com",
                           box: CGRect(x: 0, y: 1 * scale, width: 60 * scale, height: 10 * scale)),
            RecognizedLine(text: "123-45-6789",
                           box: CGRect(x: 70 * scale, y: 20 * scale, width: 40 * scale, height: 10 * scale)),
        ]
        f.lines = lines
        var baked: [Annotation] = []
        var editors: [EditorWindowController] = []
        let pipeline = f.pipeline {
            $0.bake = { image, annotations in
                baked = annotations
                return AnnotationRenderer.bake(source: image, annotations: annotations)
            }
            $0.presentEditor = { editors.append($0) }
        }
        await pipeline.handle(image: image, scale: scale, source: "test", rawURL: nil, saveRaw: false)
        let piped = try #require(editors.first)
        defer { piped.window?.close() }

        let context = EditorContext(image: image, backingScale: scale, rawURL: nil, source: "test")
        let own = EditorModel(context: context, preferences: f.preferences, presetStore: f.presets,
                              recognizeText: { _ in lines })
        defer { own.close() }
        for _ in 0..<500 where own.awaitsRedaction { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(!own.awaitsRedaction)

        let expected = [CGRect(x: 0, y: 0, width: 63, height: 14), CGRect(x: 67, y: 17, width: 33, height: 16)]
        let inPoints = covers(baked).map {
            CGRect(x: $0.minX / scale, y: $0.minY / scale, width: $0.width / scale, height: $0.height / scale)
        }
        #expect(inPoints == expected, "The pipeline covers the same logical region at 1× and 2×, up to the edges")
        #expect(covers(own.annotations) == covers(baked), "The editor's own pass covers exactly what the pipeline did")
        #expect(own.redactionAnalysis == piped.model.redactionAnalysis, "And finds exactly what the pipeline found")
    }
}

@Suite("Scrolling capture in the pipeline")
@MainActor
struct ScrollingCapturePipelineTests {
    private func tallImage(height: Int) throws -> CGImage {
        let context = try #require(GlintBitmap.makeContext(width: 50, height: height))
        context.setFillColor(RGBAColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 50, height: height))
        return try #require(context.makeImage())
    }

    @Test(arguments: [nil, false, true] as [Bool?])
    func automaticScrollingPreferenceReachesSessionFactory(autoScroll: Bool?) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        if let autoScroll { f.preferences.scrollCaptureAutoScroll = autoScroll }
        let expected = autoScroll ?? true
        let capturer = ScreenCapturer.shared
        let previousOptions = capturer.options
        defer { capturer.options = previousOptions }
        capturer.options.scrollCaptureAutoScroll = !expected
        let capture = FakeScrollingCapture(image: f.image)
        var observed: [Bool] = []
        let pipeline = f.pipeline {
            $0.makeScrollingCapture = {
                observed.append(capturer.options.scrollCaptureAutoScroll)
                return capture
            }
        }

        let task = try #require(pipeline.start(.scrolling))
        for _ in 0..<100 where !capture.isRunning { await Task.yield() }
        capture.cancel()
        await task.value

        #expect(observed == [expected])
        #expect(!pipeline.isBusy)
        #expect(f.copies == 0 && f.writes.isEmpty && f.notifications.isEmpty)
    }

    @Test func secondPressFinishesAndTheWholeImageIsRedacted() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.hideWindowsDuringCapture = false
        f.preferences.autoRedact = true
        let capture = FakeScrollingCapture(image: try tallImage(height: 9000))
        f.scrolling = capture
        let pipeline = f.pipeline()

        let task = try #require(pipeline.start(.scrolling))
        for _ in 0..<100 where !capture.isRunning { await Task.yield() }
        #expect(pipeline.isScrollingCaptureActive)
        #expect(pipeline.isBusy)
        // Another capture can't start meanwhile; the scrolling shortcut finishes instead.
        #expect(pipeline.start(.area) == nil)
        #expect(pipeline.start(.scrolling) == nil)
        #expect(capture.finishes == 1)
        await task.value
        await f.settle(pipeline)

        #expect(!pipeline.isScrollingCaptureActive && !pipeline.isBusy)
        // Recognition sees the full height, so redaction covers text far below the first screen.
        #expect(f.recognizedImages.map(\.height) == [9000])
        #expect(f.renderedImages.map(\.height) == [9000])
        #expect(f.copies + f.writes.count > 0)
    }

    @Test func cancellingLeavesNothingBehind() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.hideWindowsDuringCapture = false
        let capture = FakeScrollingCapture(image: f.image)
        f.scrolling = capture
        let pipeline = f.pipeline()

        let task = try #require(pipeline.start(.scrolling))
        for _ in 0..<100 where !capture.isRunning { await Task.yield() }
        capture.cancel()
        await task.value
        #expect(!pipeline.isBusy)
        #expect(f.copies == 0 && f.writes.isEmpty && f.notifications.isEmpty)
    }
}
