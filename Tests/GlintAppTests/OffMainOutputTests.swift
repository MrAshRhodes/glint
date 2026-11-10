import AppKit
import GlintCapture
@testable import GlintCore
@testable import GlintEditor
import Testing
@testable import Glint

/// Holds work on its background thread until a test lets it go.
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let arrivals = LockedValue(0)

    /// How many callers have reached the gate.
    var entered: Int { arrivals.value }

    func wait() {
        arrivals.withValue { $0 += 1 }
        _ = semaphore.wait(timeout: .now() + 120)
    }

    func open(_ count: Int = 1) {
        for _ in 0..<count { semaphore.signal() }
    }
}

@MainActor
private func eventually(timeout: Duration = .seconds(60), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func solidImage(width: Int, height: Int) throws -> CGImage {
    let context = try #require(GlintBitmap.makeContext(width: width, height: height))
    context.setFillColor(RGBAColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

/// Records what the pipeline puts in the quick-access panel instead of opening a window.
@MainActor
private final class FakeQuickAccess: QuickAccessPresenting {
    var side = 128
    private(set) var sideRequests: [CGDirectDisplayID?] = []
    private(set) var shown: [QuickAccessItem] = []
    private(set) var savedFiles: [(url: URL, id: UUID)] = []

    func thumbnailPixelSide(for displayID: CGDirectDisplayID?) -> Int {
        sideRequests.append(displayID)
        return side
    }

    func show(_ item: QuickAccessItem) { shown.append(item) }

    func fileSaved(_ url: URL, for id: UUID) { savedFiles.append((url, id)) }
}

private func isInFolder(_ name: String) -> @Sendable (URL) -> Bool {
    { $0.deletingLastPathComponent().lastPathComponent == name }
}

@Suite("Capture output off the main thread")
@MainActor
struct OffMainOutputTests {
    private func fixture(quickAccess: Bool = false) throws -> CaptureFixture {
        let f = try CaptureFixture()
        f.preferences.exportFormat = .plainPNG
        f.preferences.exportScale = .original
        f.preferences.defaults.set(quickAccess, forKey: ShellKey.quickAccess)
        return f
    }

    private func result(_ f: CaptureFixture, displayID: CGDirectDisplayID = 1) -> CaptureResult {
        CaptureResult(image: f.image, scale: 2, displayID: displayID, rect: CGRect(x: 0, y: 0, width: 100, height: 40),
                      kind: .area, windowInfo: nil)
    }

    private func capture(_ pipeline: CapturePipeline, _ image: CGImage, clipboardOnly: Bool = false,
                         saveRaw: Bool = false) async {
        await pipeline.handle(image: image, scale: 2, source: "test", rawURL: nil, saveRaw: saveRaw,
                              clipboardOnly: clipboardOnly)
    }

    // MARK: rendering

    @Test func renderRunsOffTheMainThreadAndLeavesItFree() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.preferences.copyToClipboardAfterCapture = true
        let gate = Gate(); defer { gate.open(8) }
        f.beforeRender.value = { gate.wait() }
        let pipeline = f.pipeline()

        let task = Task { await capture(pipeline, f.image) }
        let rendering = await eventually { gate.entered == 1 }
        #expect(rendering)
        // The render is held, yet the main actor is running this code, so the render is not on it.
        #expect(f.copies == 0 && f.notifications.isEmpty && pipeline.isKeepingScreenshots)
        gate.open()
        await task.value
        await f.settle(pipeline)

        #expect(f.renderedOnMain.value == [false])
        #expect(f.copies == 1 && f.recent.count == 1)
    }

    @Test func cancellingDuringTheRenderPublishesNothing() async throws {
        let f = try fixture(quickAccess: true); defer { f.cleanUp() }
        f.preferences.copyToClipboardAfterCapture = true
        let quickAccess = FakeQuickAccess()
        let gate = Gate(); defer { gate.open(8) }
        f.beforeRender.value = { gate.wait() }
        let captured = result(f)
        let pipeline = f.pipeline {
            $0.captureWindows = { [] }
            $0.capture = { _, _, _ in captured }
            $0.makeQuickAccess = { quickAccess }
        }

        let task = try #require(pipeline.start(.area))
        let rendering = await eventually { gate.entered == 1 }
        #expect(rendering)
        task.cancel()
        gate.open()
        await task.value

        #expect(f.copies == 0 && f.writes.isEmpty && f.notifications.isEmpty && quickAccess.shown.isEmpty)
        #expect(!pipeline.isBusy && !pipeline.isKeepingScreenshots)
    }

    // MARK: feedback before the file

    @Test func clipboardAndThumbnailAppearBeforeTheFileIsWritten() async throws {
        let f = try fixture(quickAccess: true); defer { f.cleanUp() }
        f.preferences.copyToClipboardAfterCapture = true
        let quickAccess = FakeQuickAccess()
        quickAccess.side = 50
        let gate = Gate(); defer { gate.open(8) }
        f.beforeWrite.value = { _ in gate.wait() }
        let pipeline = f.pipeline { $0.makeQuickAccess = { quickAccess } }

        await capture(pipeline, f.image)
        let writing = await eventually { gate.entered == 1 }
        #expect(writing)

        #expect(f.copies == 1)
        let item = try #require(quickAccess.shown.first)
        #expect(quickAccess.shown.count == 1)
        // The panel gets a thumbnail of the size it asked for and, separately, the full image a drag carries.
        #expect(max(item.thumbnail.width, item.thumbnail.height) == 50)
        #expect(item.image.width > 50)
        let thumbnailRatio = Double(item.thumbnail.width) / Double(item.thumbnail.height)
        let imageRatio = Double(item.image.width) / Double(item.image.height)
        #expect(abs(thumbnailRatio - imageRatio) < 0.1)
        // Nothing claims a save, or lists a file, before the write finished.
        #expect(f.recent.isEmpty && f.notifications.isEmpty && quickAccess.savedFiles.isEmpty)
        #expect(pipeline.isKeepingScreenshots)

        gate.open()
        await f.settle(pipeline)
        let saved = try #require(f.recent.first)
        #expect(f.recent.count == 1 && FileManager.default.fileExists(atPath: saved.path))
        #expect(quickAccess.savedFiles.map(\.url) == [saved] && quickAccess.savedFiles.map(\.id) == [item.id])
        #expect(f.notifications.map(\.title) == ["Screenshot saved"])
        #expect(f.notifications.first?.url == saved)
        #expect(!pipeline.isKeepingScreenshots)
    }

    @Test func aFailedWriteIsReportedOnceItsPreviewIsAlreadyUp() async throws {
        let f = try fixture(quickAccess: true); defer { f.cleanUp() }
        f.preferences.copyToClipboardAfterCapture = false
        f.failWrite = true
        let quickAccess = FakeQuickAccess()
        let gate = Gate(); defer { gate.open(8) }
        f.beforeWrite.value = { _ in gate.wait() }
        let pipeline = f.pipeline { $0.makeQuickAccess = { quickAccess } }

        await capture(pipeline, f.image)
        let writing = await eventually { gate.entered == 1 }
        #expect(writing)
        #expect(f.copies == 0 && quickAccess.shown.count == 1 && f.notifications.isEmpty)

        gate.open()
        await f.settle(pipeline)
        // The editor is off and nothing was saved, so the image is rescued on the clipboard.
        #expect(f.copies == 1 && f.recent.isEmpty && quickAccess.savedFiles.isEmpty)
        #expect(f.notifications.map(\.title) == ["Copied to clipboard, but save failed"])
    }

    @Test func aSaveThatFailsLateNeverCoversANewerClipboardImage() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.preferences.copyToClipboardAfterCapture = false
        f.failWrite = true
        let gate = Gate(); defer { gate.open(8) }
        f.beforeWrite.value = { _ in gate.wait() }
        let pipeline = f.pipeline()

        await capture(pipeline, f.image)
        let newer = try solidImage(width: 60, height: 30)
        await capture(pipeline, newer, clipboardOnly: true)
        #expect(f.copies == 1 && f.copiedImage?.width != f.image.width)

        gate.open()
        await f.settle(pipeline)
        // The first screenshot could not be saved, but its copy must not replace the newer one. Each is reported once
        // its turn in the queue comes, which is the order they were captured in.
        #expect(f.copies == 1 && f.copiedImage?.width != f.image.width)
        #expect(f.notifications.map(\.title) == ["Screenshot export failed", "Copied to clipboard"])
    }

    @Test func aSaveThatFailsLateNeverCoversWhatSomethingElseCopiedMeanwhile() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.preferences.copyToClipboardAfterCapture = false
        f.failWrite = true
        let gate = Gate(); defer { gate.open(8) }
        f.beforeWrite.value = { _ in gate.wait() }
        let pipeline = f.pipeline()

        await capture(pipeline, f.image)
        let writing = await eventually { gate.entered == 1 }
        #expect(writing)
        // Another app, or the editor, puts something on the clipboard while the file is still being written.
        f.clipboardChanges += 1

        gate.open()
        await f.settle(pipeline)
        #expect(f.copies == 0)
        #expect(f.notifications.map(\.title) == ["Screenshot export failed"])
    }

    @Test func aNameTakenWhileTheFileWasBeingWrittenIsNeverReplaced() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let taken = LockedValue<URL?>(nil)
        let someoneElses = Data("someone else's screenshot".utf8)
        f.beforeWrite.value = { url in
            // Another writer claims the name between its being picked and the file being written, once.
            guard taken.value == nil else { return }
            taken.value = url
            try? someoneElses.write(to: url)
        }
        let pipeline = f.pipeline()

        await capture(pipeline, f.image)
        await f.settle(pipeline)

        let first = try #require(taken.value)
        #expect(try Data(contentsOf: first) == someoneElses)
        #expect(f.writes.count == 2 && f.writes[0].url == first && f.writes[1].url != first)
        let second = f.writes[1].url
        #expect(f.recent == [second] && f.notifications.map(\.url) == [second])
        #expect(f.notifications.map(\.title) == ["Screenshot saved"])
        #expect(GlintImageIO.load(url: second) != nil)
    }

    @Test func aScreenshotWithoutAFileIsRecordedAfterTheEarlierOnesStillBeingSaved() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.preferences.copyToClipboardAfterCapture = false
        let gate = Gate(); defer { gate.open(8) }
        f.beforeWrite.value = { _ in gate.wait() }
        let pipeline = f.pipeline()

        await capture(pipeline, f.image)
        let newer = try solidImage(width: 60, height: 30)
        await capture(pipeline, newer, clipboardOnly: true)
        let writing = await eventually { gate.entered == 1 }
        #expect(writing)
        // The newer screenshot is already on the clipboard, but nothing records it ahead of the older one.
        #expect(f.copies == 1 && f.notifications.isEmpty && pipeline.isKeepingScreenshots)

        gate.open()
        await f.settle(pipeline)
        #expect(f.notifications.map(\.title) == ["Screenshot saved", "Copied to clipboard"])
    }

    @Test func laterPreferenceChangesNeverAlterAQueuedExport() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let gate = Gate(); defer { gate.open(8) }
        f.beforeWrite.value = { _ in gate.wait() }
        let pipeline = f.pipeline()
        let historyFolder = f.preferences.historyDirectory

        await capture(pipeline, f.image)
        f.preferences.exportFormat = .tiff
        f.preferences.exportScale = .x1
        f.preferences.saveHistory = false
        gate.open()
        await f.settle(pipeline)

        let saved = try #require(f.recent.first)
        #expect(saved.pathExtension == "png")
        #expect(saved.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                == historyFolder.standardizedFileURL.path)
        #expect(f.writes.first?.format == .plainPNG && f.writes.first?.scale == .original)
    }

    // MARK: the next capture

    @Test func theNextCaptureStartsWhileTheFileIsStillBeingWritten() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.preferences.copyToClipboardAfterCapture = true
        let gate = Gate(); defer { gate.open(8) }
        f.beforeWrite.value = { _ in gate.wait() }
        let captured = result(f)
        let pipeline = f.pipeline {
            $0.captureWindows = { [] }
            $0.capture = { _, _, _ in captured }
        }

        try await #require(pipeline.start(.area)).value
        #expect(!pipeline.isBusy && pipeline.isKeepingScreenshots)
        #expect(f.recent.isEmpty && f.copies == 1)
        try await #require(pipeline.start(.area)).value
        #expect(f.copies == 2 && f.recent.isEmpty)

        gate.open(2)
        await f.settle(pipeline)
        #expect(f.recent.count == 2 && f.notifications.map(\.title) == ["Screenshot saved", "Screenshot saved"])
    }

    @Test func eachScreenshotGetsItsOwnFileAndThumbnailEvenInTheSameSecond() async throws {
        let f = try fixture(quickAccess: true); defer { f.cleanUp() }
        f.preferences.copyToClipboardAfterCapture = true
        let quickAccess = FakeQuickAccess()
        let gate = Gate(); defer { gate.open(8) }
        f.beforeWrite.value = { _ in gate.wait() }
        let pipeline = f.pipeline { $0.makeQuickAccess = { quickAccess } }

        await capture(pipeline, f.image)
        let second = try solidImage(width: 60, height: 30)
        await capture(pipeline, second)
        #expect(quickAccess.shown.count == 2 && f.recent.isEmpty)

        gate.open(2)
        await f.settle(pipeline)
        #expect(f.recent.count == 2 && Set(f.recent).count == 2)
        #expect(quickAccess.savedFiles.map(\.id) == quickAccess.shown.map(\.id))
        #expect(quickAccess.savedFiles.map(\.url) == f.recent)
        #expect(f.notifications.map(\.url) == f.recent)
        // Each file holds the image of its own capture, and each thumbnail is told about that file.
        #expect(quickAccess.shown[0].image.width != quickAccess.shown[1].image.width)
        for (file, item) in zip(f.recent, quickAccess.shown) {
            let loaded = try #require(GlintImageIO.load(url: file))
            #expect(loaded.width == item.image.width && loaded.height == item.image.height)
        }
    }

    @Test func theThumbnailIsSizedForTheDisplayOfTheCapture() async throws {
        let f = try fixture(quickAccess: true); defer { f.cleanUp() }
        let quickAccess = FakeQuickAccess()
        let pipeline = f.pipeline { $0.makeQuickAccess = { quickAccess } }

        await pipeline.handle(result(f, displayID: 7), source: "test", clipboardOnly: true)
        await f.settle(pipeline)
        #expect(quickAccess.sideRequests == [7] && quickAccess.shown.map(\.displayID) == [7])

        await capture(pipeline, f.image, clipboardOnly: true)
        #expect(quickAccess.sideRequests == [7, nil] && quickAccess.shown.map(\.displayID) == [7, nil])
    }

    @Test func disabledQuickAccessNeverCreatesThePanel() async throws {
        let f = try fixture(quickAccess: false); defer { f.cleanUp() }
        var created = 0
        let pipeline = f.pipeline { $0.makeQuickAccess = { created += 1; return FakeQuickAccess() } }
        await capture(pipeline, f.image)
        await f.settle(pipeline)
        #expect(created == 0 && f.recent.count == 1)
    }

    // MARK: the raw capture and the editor

    @Test func theEditorOpensBeforeTheRawFileExistsAndLearnsItsLocationAfterwards() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.preferences.openEditorAfterCapture = true
        f.preferences.saveRaw = true
        let gate = Gate(); defer { gate.open(8) }
        let isRaw = isInFolder("Raw")
        f.beforeWrite.value = { if isRaw($0) { gate.wait() } }
        var presented: [EditorWindowController] = []
        let pipeline = f.pipeline { $0.presentEditor = { presented.append($0) } }
        defer { presented.forEach { $0.window?.close() } }

        await capture(pipeline, f.image, saveRaw: true)
        let editor = try #require(presented.first)
        #expect(presented.count == 1 && editor.model.rawURL == nil)
        let writing = await eventually { gate.entered == 1 }
        #expect(writing && pipeline.isKeepingScreenshots)
        #expect(editor.model.rawURL == nil && f.notifications.isEmpty)

        gate.open()
        await f.settle(pipeline)
        let raw = try #require(f.writes.first)
        #expect(f.writes.count == 1 && isRaw(raw.url))
        #expect(editor.model.rawURL == raw.url)
        #expect(FileManager.default.fileExists(atPath: raw.url.path))
        #expect(f.notifications.isEmpty)
    }

    @Test func aFailedRawWriteIsReportedAndTheEditorKeepsWorkingWithoutIt() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.preferences.openEditorAfterCapture = true
        f.preferences.saveRaw = true
        f.failRaw = true
        var presented: [EditorWindowController] = []
        let pipeline = f.pipeline { $0.presentEditor = { presented.append($0) } }
        defer { presented.forEach { $0.window?.close() } }

        await capture(pipeline, f.image, saveRaw: true)
        await f.settle(pipeline)

        let editor = try #require(presented.first)
        #expect(editor.model.rawURL == nil)
        #expect(f.notifications.map(\.title) == ["Raw screenshot not saved"])
    }

    @Test func everyEditorLinksToTheRawFileOfItsOwnCapture() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.preferences.openEditorAfterCapture = true
        f.preferences.saveRaw = true
        var presented: [EditorWindowController] = []
        let pipeline = f.pipeline { $0.presentEditor = { presented.append($0) } }
        defer { presented.forEach { $0.window?.close() } }

        await capture(pipeline, f.image, saveRaw: true)
        await capture(pipeline, try solidImage(width: 60, height: 30), saveRaw: true)
        await f.settle(pipeline)

        #expect(presented.count == 2 && f.writes.count == 2)
        let firstRaw = f.writes[0].url, secondRaw = f.writes[1].url
        #expect(firstRaw != secondRaw)
        #expect(presented.map(\.model.rawURL) == [firstRaw, secondRaw])
        let first = try #require(GlintImageIO.load(url: firstRaw))
        let second = try #require(GlintImageIO.load(url: secondRaw))
        #expect(first.width == f.image.width && second.width == 60)
    }

    @Test func editingFromTheThumbnailGetsTheRawFileOnceItIsWritten() async throws {
        let f = try fixture(quickAccess: true); defer { f.cleanUp() }
        f.preferences.saveRaw = true
        f.preferences.saveOutput = false
        let quickAccess = FakeQuickAccess()
        let gate = Gate(); defer { gate.open(8) }
        f.beforeWrite.value = { _ in gate.wait() }
        var presented: [EditorWindowController] = []
        let pipeline = f.pipeline {
            $0.makeQuickAccess = { quickAccess }
            $0.presentEditor = { presented.append($0) }
        }
        defer { presented.forEach { $0.window?.close() } }

        await capture(pipeline, f.image, saveRaw: true)
        let item = try #require(quickAccess.shown.first)
        item.onEdit()
        let editor = try #require(presented.first)
        #expect(editor.model.rawURL == nil)

        gate.open()
        await f.settle(pipeline)
        let raw = try #require(f.writes.first)
        #expect(editor.model.rawURL == raw.url)
    }

    // MARK: shutdown

    @Test(arguments: [true, false])
    func queuedFileWritesCountAsScreenshotsStillBeingKept(rawFile: Bool) async throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.preferences.openEditorAfterCapture = rawFile
        f.preferences.saveRaw = rawFile
        let gate = Gate(); defer { gate.open(8) }
        let isHeld = isInFolder(rawFile ? "Raw" : "Output")
        f.beforeWrite.value = { if isHeld($0) { gate.wait() } }
        var presented: [EditorWindowController] = []
        let pipeline = f.pipeline { $0.presentEditor = { presented.append($0) } }
        defer { presented.forEach { $0.window?.close() } }

        await capture(pipeline, f.image, saveRaw: rawFile)
        #expect(pipeline.isKeepingScreenshots)
        let writing = await eventually { gate.entered == 1 }
        #expect(writing)
        let drainedEarly = await pipeline.waitForRetention(timeout: .milliseconds(100))
        #expect(!drainedEarly && pipeline.isKeepingScreenshots)

        gate.open()
        let drained = await pipeline.waitForRetention(timeout: .seconds(60))
        #expect(drained && !pipeline.isKeepingScreenshots)
    }

    @Test func quittingWaitsForAnOutputFileThatIsStillBeingWritten() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let gate = Gate(); defer { gate.open(8) }
        f.beforeWrite.value = { _ in gate.wait() }
        let pipeline = f.pipeline()
        let delegate = AppDelegate(prefs: f.preferences, menu: NSMenu())
        delegate.pipeline = pipeline
        delegate.terminationGrace = .seconds(300)
        let replies = LockedValue<[Bool]>([])
        delegate.replyToTermination = { reply in replies.withValue { $0.append(reply) } }

        await capture(pipeline, f.image)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        for _ in 0..<3 { await Task.yield() }
        #expect(replies.value.isEmpty)

        gate.open()
        let replied = await eventually { replies.value == [true] }
        #expect(replied && f.recent.count == 1)
    }

    @Test func aRenderStillRunningCountsAsScreenshotsBeingKept() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let gate = Gate(); defer { gate.open(8) }
        f.beforeRender.value = { gate.wait() }
        let pipeline = f.pipeline()

        let task = Task { await capture(pipeline, f.image) }
        let rendering = await eventually { gate.entered == 1 }
        #expect(rendering && pipeline.isKeepingScreenshots)
        gate.open()
        await task.value
        await f.settle(pipeline)
        #expect(!pipeline.isKeepingScreenshots && f.recent.count == 1)
    }

    // MARK: the queues and the panel

    @Test func holdingAQueueCountsAsWorkUntilItIsReleased() async {
        let queue = RetentionQueue()
        let release = queue.hold()
        #expect(queue.pending == 1 && !queue.isIdle)
        let drainedEarly = await queue.waitUntilIdle(timeout: .milliseconds(50))
        #expect(!drainedEarly)
        release()
        release()
        #expect(queue.pending == 0 && queue.isIdle)
        let drained = await queue.waitUntilIdle(timeout: .milliseconds(50))
        #expect(drained)
    }

    @Test func aQueueIsIdleOnlyOnceItsHoldAndItsJobsAreDone() async {
        let queue = RetentionQueue()
        let release = queue.hold()
        queue.enqueue({ 1 }, completion: { _ in })
        let drainedEarly = await queue.waitUntilIdle(timeout: .milliseconds(200))
        #expect(!drainedEarly && queue.pending == 1)
        release()
        let drained = await queue.waitUntilIdle(timeout: .seconds(60))
        #expect(drained && queue.isIdle)
    }

    @Test func outputWritesNeverRunBelowUserInitiatedPriority() async throws {
        let f = try fixture(); defer { f.cleanUp() }
        let pipeline = f.pipeline()
        let priority = LockedValue<TaskPriority?>(nil)
        pipeline.outputQueue.enqueue({ priority.value = Task.currentPriority }, completion: { _ in })
        await f.settle(pipeline)
        let seen = try #require(priority.value)
        #expect(seen >= .userInitiated)
    }

    @Test func theQuickAccessPanelFindsTheScreenOfADisplay() throws {
        #expect(QuickAccessPanel.screen(for: nil) == nil)
        #expect(QuickAccessPanel.screen(for: 0xFFFF_FFF0) == nil)
        #expect(QuickAccessPanel.screen(for: 7, among: []) == nil)
        let panel = QuickAccessPanel()
        for screen in NSScreen.screens {
            let id = try #require(QuickAccessPanel.displayID(of: screen))
            #expect(QuickAccessPanel.screen(for: id) === screen)
            let expected = Int((QuickAccessPanel.maxSide * screen.backingScaleFactor).rounded(.up))
            #expect(panel.thumbnailPixelSide(for: id) == expected)
        }
        #expect(panel.thumbnailPixelSide(for: nil) >= Int(QuickAccessPanel.maxSide))
    }
}
