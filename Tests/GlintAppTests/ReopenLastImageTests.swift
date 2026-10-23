import AppKit
@testable import GlintCore
@testable import GlintEditor
import Testing
@testable import Glint

// MARK: - Test doubles

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var snapshot: Value { lock.withLock { value } }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result { lock.withLock { body(&value) } }
}

/// The clock Output retention sees, moved by hand.
private final class StepClock: @unchecked Sendable {
    private let date = Box(Date(timeIntervalSince1970: 1_790_000_000))

    var now: Date { date.snapshot }

    func advance(hours: Double = 0, days: Double = 0) {
        date.withValue { $0 = $0.addingTimeInterval(hours * 3_600 + days * 86_400) }
    }
}

private struct TrashRefused: LocalizedError {
    var errorDescription: String? { "Trash refused" }
}

/// Stands in for the Trash: moves files into a fixture folder, or refuses on request. The real Trash is never touched.
private final class FakeTrash: @unchecked Sendable {
    private struct State {
        var refused: Set<String> = []
        var moved: [URL] = []
    }

    private let folder: URL
    private let state = Box(State())

    init(folder: URL) { self.folder = folder }

    var trashed: [URL] { state.snapshot.moved }
    func refuse(_ name: String) { state.withValue { _ = $0.refused.insert(name) } }
    func allow(_ name: String) { state.withValue { _ = $0.refused.remove(name) } }

    func move(_ url: URL) throws {
        let (refused, count) = state.withValue { ($0.refused.contains(url.lastPathComponent), $0.moved.count) }
        if refused { throw TrashRefused() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("\(count)-\(url.lastPathComponent)"))
        state.withValue { $0.moved.append(url) }
    }
}

/// Stands in for the real timers, so a test decides when a wait is over.
@MainActor
private final class ManualSchedule {
    final class Pending {
        let delay: Duration
        let fire: @MainActor () -> Void
        var cancelled = false
        var fired = false

        init(delay: Duration, fire: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.fire = fire
        }
    }

    private var timers: [Pending] = []

    var schedule: OutputCleanupScheduler.Schedule {
        { [self] delay, fire in
            let timer = Pending(delay: delay, fire: fire)
            timers.append(timer)
            return { timer.cancelled = true }
        }
    }

    func pending(_ delay: Duration? = nil) -> [Pending] {
        timers.filter { !$0.cancelled && !$0.fired && (delay == nil || $0.delay == delay) }
    }

    /// Lets the newest live timer armed for `delay` go off. Returns false when there is none.
    @discardableResult
    func fire(_ delay: Duration) -> Bool {
        guard let timer = pending(delay).last else { return false }
        timer.fired = true
        timer.fire()
        return true
    }
}

/// Counts cleanup passes, and can hold the first one open.
@MainActor
private final class RunLog {
    var runs = 0
    var holdFirstRun = false
    private var gate: CheckedContinuation<Void, Never>?

    var isHeld: Bool { gate != nil }

    func run() async {
        runs += 1
        guard holdFirstRun, runs == 1 else { return }
        await withCheckedContinuation { gate = $0 }
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

@MainActor
private func schedulerTiming() -> OutputCleanupScheduler.Timing {
    OutputCleanupScheduler.Timing(launchDelay: .seconds(1), interval: .seconds(2), debounce: .seconds(3))
}

@MainActor
private func eventually(timeout: Duration = .seconds(120), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func samePath(_ a: URL, _ b: URL) -> Bool {
    a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
}

/// Whether two images show the same colours, allowing for rounding in a colour conversion.
private func looksAlike(_ a: CGImage, _ b: CGImage, tolerance: Int = 2) -> Bool {
    guard a.width == b.width, a.height == b.height, let x = PixelBuffer(a), let y = PixelBuffer(b) else { return false }
    return zip(x.data, y.data).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
}

private final class BlockingGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let entered = Box(false)
    private let finished = Box(false)

    var hasEntered: Bool { entered.snapshot }
    var hasFinished: Bool { finished.snapshot }

    func wait() {
        entered.withValue { $0 = true }
        _ = semaphore.wait(timeout: .now() + 120)
        finished.withValue { $0 = true }
    }

    func signal() { semaphore.signal() }
}

@MainActor
private func holdRetentionQueue(_ pipeline: CapturePipeline) -> BlockingGate {
    let gate = BlockingGate()
    pipeline.retentionQueue.enqueue({ gate.wait() }, completion: { _ in })
    return gate
}

// MARK: - Fixture

@MainActor
private final class ReopenFixture {
    let suite = "glint.reopen.tests.\(UUID().uuidString)"
    let directory: URL
    let preferences: AppPreferences
    let presets: PresetStore
    let clock = StepClock()
    let trash: FakeTrash
    let activeFiles = OutputActiveFiles()
    var notifications: [(title: String, body: String, url: URL?)] = []
    var recent: [URL] = []
    var removedRecent: [URL] = []
    var copies: [CGImage] = []
    var copySucceeds = true
    var failRender = false
    var presented: [EditorWindowController] = []
    var screenScale: CGFloat = 1
    var latestRetainedOutput: (@Sendable (OutputRetention) -> RetainedOutput?)?
    lazy var pipeline: CapturePipeline = makePipeline()

    init() throws {
        _ = NSApplication.shared
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/TestFixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        trash = FakeTrash(folder: directory.appendingPathComponent("Trash"))
        let defaults = try #require(UserDefaults(suiteName: suite))
        preferences = AppPreferences(defaults: defaults)
        preferences.saveDirectory = directory.appendingPathComponent("Manual")
        preferences.historyDirectory = directory.appendingPathComponent("History")
        preferences.saveHistory = true
        preferences.openEditorAfterCapture = false
        preferences.autoBalance = false
        preferences.autoRedact = false
        preferences.saveRaw = false
        preferences.saveOutput = false
        preferences.copyToClipboardAfterCapture = false
        preferences.exportFormat = .plainPNG
        preferences.exportScale = .original
        defaults.set(false, forKey: ShellKey.quickAccess)
        presets = PresetStore(url: directory.appendingPathComponent("presets.json"))
        let preset = presets.add(name: "Test", settings: RenderSettings(
            padding: 0, cornerRadius: 0, shadow: .none, background: .transparent
        ))
        presets.setDefault(id: preset.id)
    }

    func makePipeline() -> CapturePipeline {
        var services = CapturePipeline.Services()
        services.copy = { [self] image in
            copies.append(image)
            return copySucceeds
        }
        services.notify = { [self] in notifications.append(($0, $1, $2)) }
        services.requestRetry = { _, _ in false }
        services.addRecent = { [self] in recent.append($0) }
        services.removeRecent = { [self] in removedRecent.append($0) }
        services.sound = {}
        services.render = { [self] image, settings, backingScale, wallpaper in
            if failRender { throw RenderError.annotationsNotApplied }
            return try Compositor.render(image: image, settings: settings, backingScale: backingScale, wallpaper: wallpaper)
        }
        services.presentEditor = { [self] in presented.append($0) }
        services.screenScale = { [self] in screenScale }
        if let latestRetainedOutput { services.latestRetainedOutput = latestRetainedOutput }
        services.retention = { [clock, trash, activeFiles] in
            OutputRetention(preferences: $0, now: { clock.now }, moveToTrash: { try trash.move($0) },
                            activeFiles: activeFiles)
        }
        return CapturePipeline(prefs: preferences, presetStore: presets, services: services)
    }

    var outputDirectory: URL { directory.appendingPathComponent("History/Output", isDirectory: true) }
    var indexURL: URL { outputDirectory.appendingPathComponent(".glint-output-index.json") }
    var latest: RetainedOutput? { pipeline.retention.latest() }

    /// A 100x40 image of one colour; different indexes (1...15) give different colours.
    func solid(_ index: Int, width: Int = 100, height: Int = 40) -> CGImage {
        guard let context = GlintBitmap.makeContext(width: width, height: height) else { fatalError("No bitmap context") }
        context.setFillColor(RGBAColor(r: Double(index % 4) / 3, g: Double(index / 4 % 4) / 3,
                                       b: Double(index / 16 % 4) / 3).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { fatalError("No test image") }
        return image
    }

    func capture(_ image: CGImage, scale: CGFloat = 2, clipboardOnly: Bool = false) async {
        await pipeline.handle(image: image, scale: scale, source: "test", rawURL: nil, saveRaw: false,
                              clipboardOnly: clipboardOnly)
        await settle()
    }

    func settle() async {
        let idle = await pipeline.waitForRetention(timeout: .seconds(120))
        #expect(idle, "Retention work did not finish")
        await pipeline.refreshReopenAvailability()
    }

    /// Keeps one image, then moves the clock past the retention period so that image has expired.
    func keepExpiredImage(_ index: Int = 1) async throws -> URL {
        preferences.keepCopiedImages = true
        preferences.outputRetention = .sevenDays
        await capture(solid(index), clipboardOnly: true)
        let url = try #require(latest).url
        clock.advance(days: 8)
        return url
    }

    func outputFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { outputDirectory.appendingPathComponent($0) }
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @discardableResult
    func touch(_ name: String, in folder: String = "Manual", contents: Data = Data("x".utf8)) throws -> URL {
        let folderURL = directory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let url = folderURL.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    func cleanUp() {
        preferences.defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Tests

@Suite("Reopen last image and kept screenshots")
@MainActor
struct ReopenLastImageTests {
    // MARK: keeping copies

    @Test func clipboardOnlyCopyIsKeptForReopening() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        await f.capture(f.solid(1), scale: 2, clipboardOnly: true)
        #expect(f.copies.count == 1)
        let kept = try #require(f.latest)
        #expect(kept.source == .copied && kept.backingScale == 2 && !kept.reused)
        #expect(samePath(kept.url.deletingLastPathComponent(), f.outputDirectory))
        #expect(f.outputFiles().map(\.lastPathComponent) == [kept.url.lastPathComponent])
        #expect(f.recent == [kept.url])
        #expect(GlintImageIO.load(url: kept.url)?.width == 100)
        #expect(f.notifications.map(\.title) == ["Copied to clipboard"])
        #expect(!f.pipeline.isKeepingScreenshots)
    }

    @Test func automaticCopyAfterCaptureIsKept() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        f.preferences.copyToClipboardAfterCapture = true
        await f.capture(f.solid(2), scale: 3)
        #expect(f.copies.count == 1)
        let kept = try #require(f.latest)
        #expect(kept.source == .copied && kept.backingScale == 3)
        #expect(f.outputFiles().count == 1)
    }

    @Test func nothingIsKeptByDefault() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.saveOutput = true
        await f.capture(f.solid(1), clipboardOnly: true)
        await f.capture(f.solid(2))
        #expect(f.copies.count == 1)
        let saved = try #require(f.recent.first)
        #expect(f.recent.count == 1 && f.exists(saved))
        #expect(!f.pipeline.retention.isManaged(saved))
        #expect(f.outputFiles().map(\.lastPathComponent) == [saved.lastPathComponent])
        #expect(!f.exists(f.indexURL))
        #expect(f.latest == nil && !f.pipeline.canReopenLastImage)
        #expect(!f.pipeline.isKeepingScreenshots)
    }

    @Test func nothingIsKeptWhileHistoryIsOff() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        f.preferences.outputRetention = .sevenDays
        f.preferences.saveHistory = false
        await f.capture(f.solid(1), clipboardOnly: true)
        #expect(f.copies.count == 1)
        #expect(!f.exists(f.directory.appendingPathComponent("History")))
        #expect(f.recent.isEmpty && f.latest == nil)
        #expect(f.notifications.map(\.title) == ["Copied to clipboard"])
    }

    @Test func copyOfTheAutoSavedStyledOutputReusesThatFile() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        f.preferences.saveOutput = true
        f.preferences.copyToClipboardAfterCapture = true
        await f.capture(f.solid(1), scale: 2)
        #expect(f.copies.count == 1)
        let saved = try #require(f.recent.first)
        let files = f.outputFiles()
        #expect(files.count == 1 && samePath(files[0], saved))
        #expect(f.pipeline.retention.isManaged(saved))
        #expect(samePath(try #require(f.latest).url, saved))
        #expect(f.recent.allSatisfy { samePath($0, saved) })
        #expect(f.notifications.map(\.title) == ["Screenshot saved"])
    }

    @Test func autoSavedOutputIsTrackedWhenOnlyARetentionPeriodIsSet() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.outputRetention = .thirtyDays
        f.preferences.saveOutput = true
        await f.capture(f.solid(1), scale: 2)
        let saved = try #require(f.recent.first)
        #expect(f.pipeline.retention.isManaged(saved))
        let kept = try #require(f.latest)
        #expect(kept.source == .saved && samePath(kept.url, saved) && kept.backingScale == 2)
        await f.capture(f.solid(2), clipboardOnly: true)
        #expect(f.copies.count == 1)
        #expect(f.outputFiles().count == 1)
    }

    @Test(arguments: ExportScale.allCases)
    func queuedAutosaveRegistrationUsesTheScaleAtSaveTime(_ exportScale: ExportScale) async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.outputRetention = .sevenDays
        f.preferences.saveOutput = true
        f.preferences.exportScale = exportScale
        let gate = holdRetentionQueue(f.pipeline)
        defer { gate.signal() }
        await f.pipeline.handle(image: f.solid(1, width: 300, height: 150), scale: 3, source: "test",
                                rawURL: nil, saveRaw: false)
        f.preferences.exportScale = exportScale == .x1 ? .x2 : .x1
        gate.signal()
        await f.settle()

        let kept = try #require(f.latest)
        let stored = try #require(GlintImageIO.load(url: kept.url))
        let expected: (width: Int, height: Int, scale: CGFloat)
        switch exportScale {
        case .original: expected = (300, 150, 3)
        case .x1: expected = (100, 50, 1)
        case .x2: expected = (200, 100, 2)
        }
        #expect(kept.source == .saved && kept.backingScale == expected.scale)
        #expect(stored.width == expected.width && stored.height == expected.height)
        await f.pipeline.reopenLastImage()
        #expect(f.presented.last?.model.backingScale == expected.scale)
    }

    @Test func keepFailureIsReportedWithoutUndoingTheCopy() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        try f.touch("Output", in: "History")
        await f.capture(f.solid(1), clipboardOnly: true)
        #expect(f.copies.count == 1)
        #expect(f.notifications.map(\.title) == ["Copied to clipboard", "Screenshot not kept for reopening"])
        #expect(f.notifications.last?.body.contains("The copy or drag itself was not affected.") == true)
        #expect(f.recent.isEmpty && f.latest == nil)
    }

    @Test func nothingIsKeptWhenTheExportOrTheCopyFailed() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        f.failRender = true
        await f.capture(f.solid(1), clipboardOnly: true)
        #expect(f.copies.isEmpty)
        f.failRender = false
        f.copySucceeds = false
        await f.capture(f.solid(2), clipboardOnly: true)
        #expect(f.copies.count == 1)
        #expect(f.outputFiles().isEmpty && f.latest == nil && !f.exists(f.indexURL))
        #expect(f.notifications.map(\.title) == ["Screenshot not exported", "Screenshot export failed"])
    }

    @Test func keepingTurnedOffWhileQueuedWritesNothingAndStaysSilent() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        let gate = holdRetentionQueue(f.pipeline)
        defer { gate.signal() }
        await f.pipeline.handle(image: f.solid(1), scale: 2, source: "test", rawURL: nil, saveRaw: false,
                                clipboardOnly: true)
        f.preferences.keepCopiedImages = false
        gate.signal()
        await f.settle()
        #expect(f.copies.count == 1)
        #expect(f.outputFiles().isEmpty && !f.exists(f.indexURL) && f.recent.isEmpty)
        #expect(f.notifications.map(\.title) == ["Copied to clipboard"])
    }

    @Test func copyDoesNotWaitForTheDisk() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        let gate = holdRetentionQueue(f.pipeline)
        defer { gate.signal() }
        #expect(await eventually { gate.hasEntered })
        await f.pipeline.handle(image: f.solid(1), scale: 2, source: "test", rawURL: nil, saveRaw: false,
                                clipboardOnly: true)
        #expect(!gate.hasFinished, "Copy must finish while the disk queue is still held")
        #expect(f.copies.count == 1)
        #expect(f.notifications.map(\.title) == ["Copied to clipboard"])
        #expect(f.pipeline.isKeepingScreenshots)
        #expect(f.outputFiles().isEmpty)
        gate.signal()
        await f.settle()
        #expect(!f.pipeline.isKeepingScreenshots)
        #expect(f.outputFiles().count == 1 && f.recent.count == 1)
    }

    @Test func defaultRetentionFollowsTheLivePreferences() throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        let pipeline = CapturePipeline(prefs: f.preferences, presetStore: f.presets)
        #expect(!pipeline.retention.retainsCopies && !pipeline.retention.tracksSavedOutputs && !pipeline.retention.cleansUp)
        f.preferences.keepCopiedImages = true
        #expect(pipeline.retention.retainsCopies && pipeline.retention.tracksSavedOutputs && !pipeline.retention.cleansUp)
        f.preferences.outputRetention = .thirtyDays
        #expect(pipeline.retention.cleansUp)
        f.preferences.saveHistory = false
        #expect(!pipeline.retention.retainsCopies && !pipeline.retention.cleansUp)
    }

    // MARK: editor and drag

    @Test func imageCopiedFromTheEditorIsKept() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        try await shareFromEditor(f, kind: .copied, expected: .copied)
    }

    @Test func imageDraggedFromTheEditorIsKept() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        try await shareFromEditor(f, kind: .dragged, expected: .dragged)
    }

    private func shareFromEditor(_ f: ReopenFixture, kind: EditorShareKind,
                                 expected: OutputRetentionSource) async throws {
        f.preferences.keepCopiedImages = true
        f.pipeline.openEditor(image: f.solid(1), scale: 3, rawURL: nil, source: "test")
        let controller = try #require(f.presented.last)
        controller.onImageShared?(f.solid(2), kind, 3)
        await f.settle()
        let kept = try #require(f.latest)
        #expect(kept.source == expected && kept.backingScale == 3)
        #expect(f.recent == [kept.url])
        #expect(f.copies.isEmpty)
    }

    @Test func editorSharesKeepNothingByDefault() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.pipeline.openEditor(image: f.solid(1), scale: 2, rawURL: nil, source: "test")
        let controller = try #require(f.presented.last)
        controller.onImageShared?(f.solid(2), .copied, 2)
        controller.onImageShared?(f.solid(3), .dragged, 2)
        await f.settle()
        #expect(f.latest == nil && !f.exists(f.indexURL) && f.recent.isEmpty)
    }

    @Test func draggingAThumbnailWithoutAFileKeepsTheImage() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        f.pipeline.quickAccessDragStarted(image: f.solid(1), backingScale: 2, savedFile: nil)
        await f.settle()
        let kept = try #require(f.latest)
        #expect(kept.source == .dragged && kept.backingScale == 2)
        #expect(f.recent == [kept.url])
    }

    @Test func draggingASavedFileDoesNotKeepAnotherCopy() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        let saved = f.outputDirectory.appendingPathComponent("saved.png")
        f.pipeline.quickAccessDragStarted(image: f.solid(1), backingScale: 2, savedFile: saved)
        #expect(!f.pipeline.isKeepingScreenshots)
        await f.settle()
        #expect(f.outputFiles().isEmpty && f.latest == nil)
    }

    @Test func draggingKeepsNothingWhenOff() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.pipeline.quickAccessDragStarted(image: f.solid(1), backingScale: 2, savedFile: nil)
        #expect(!f.pipeline.isKeepingScreenshots)
        #expect(!f.exists(f.directory.appendingPathComponent("History")))
    }

    // MARK: reopen last image

    @Test func reopenOpensTheNewestKeptImageAsFinishedOutput() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        f.screenScale = 1
        await f.capture(f.solid(1), scale: 2, clipboardOnly: true)
        f.clock.advance(hours: 1)
        await f.capture(f.solid(2), scale: 3, clipboardOnly: true)
        let newest = try #require(f.latest)
        await f.pipeline.reopenLastImage()
        #expect(f.presented.count == 1)
        let model = try #require(f.presented.last).model
        #expect(model.isComposed)
        #expect(model.backingScale == 3)
        #expect(looksAlike(model.image, f.copies[1]) && !looksAlike(model.image, f.copies[0]))
        #expect(f.recent.last == newest.url)
        #expect(f.notifications.map(\.title) == ["Copied to clipboard", "Copied to clipboard"])
    }

    @Test func reopenWithNothingKeptSaysSo() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        await f.pipeline.reopenLastImage()
        #expect(f.presented.isEmpty && f.removedRecent.isEmpty)
        #expect(f.notifications.map(\.title) == ["No screenshot to reopen"])
    }

    @Test func reopenForgetsAnImageThatCannotBeRead() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        await f.capture(f.solid(1), clipboardOnly: true)
        let kept = try #require(f.latest)
        try Data("not an image".utf8).write(to: kept.url)
        await f.pipeline.reopenLastImage()
        #expect(f.presented.isEmpty)
        #expect(f.notifications.map(\.title) == ["Copied to clipboard", "Cannot open image"])
        #expect(f.notifications.last?.body.contains(kept.url.lastPathComponent) == true)
        #expect(f.removedRecent == [kept.url])
        #expect(!f.pipeline.retention.isManaged(kept.url))
        #expect(f.exists(kept.url))
        await f.pipeline.reopenLastImage()
        #expect(f.notifications.last?.title == "No screenshot to reopen")
    }

    @Test func reopenFallsBackToAnOlderImageWhenTheNewestFileIsGone() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        await f.capture(f.solid(1), scale: 2, clipboardOnly: true)
        let older = try #require(f.latest)
        f.clock.advance(hours: 1)
        await f.capture(f.solid(2), scale: 3, clipboardOnly: true)
        try FileManager.default.removeItem(at: try #require(f.latest).url)
        #expect(f.pipeline.canReopenLastImage)
        await f.pipeline.reopenLastImage()
        let model = try #require(f.presented.last).model
        #expect(model.isComposed && model.backingScale == 2)
        #expect(looksAlike(model.image, f.copies[0]))
        try FileManager.default.removeItem(at: older.url)
        await f.pipeline.refreshReopenAvailability()
        #expect(!f.pipeline.canReopenLastImage)
        await f.pipeline.reopenLastImage()
        #expect(f.notifications.last?.title == "No screenshot to reopen")
        #expect(f.presented.count == 1)
    }

    @Test func reopenIsAvailableOnlyWhileAKeptImageExists() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        #expect(!f.pipeline.canReopenLastImage)
        f.preferences.keepCopiedImages = true
        await f.capture(f.solid(1), clipboardOnly: true)
        #expect(f.pipeline.canReopenLastImage)
        f.preferences.saveHistory = false
        await f.pipeline.refreshReopenAvailability()
        #expect(!f.pipeline.canReopenLastImage)
        f.preferences.saveHistory = true
        f.preferences.keepCopiedImages = false
        await f.pipeline.refreshReopenAvailability()
        #expect(f.pipeline.canReopenLastImage)
    }

    @Test func autoSavedOutputCanBeReopenedWithoutKeepingCopies() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.outputRetention = .sevenDays
        f.preferences.saveOutput = true
        await f.capture(f.solid(1), scale: 2)
        await f.pipeline.reopenLastImage()
        let model = try #require(f.presented.last).model
        #expect(model.isComposed && model.backingScale == 2)
    }

    // MARK: opening files

    @Test func openingAKeptFileShowsItFlattenedAtItsOwnScale() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        f.screenScale = 2
        await f.capture(f.solid(1), scale: 3, clipboardOnly: true)
        let kept = try #require(f.latest)
        f.pipeline.openFile(kept.url)
        let model = try #require(f.presented.last).model
        #expect(model.isComposed)
        #expect(model.backingScale == 3)
        #expect(f.recent.last == kept.url)
    }

    @Test func openingAnyOtherImageStaysAnOrdinaryCapture() throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.screenScale = 2
        let url = f.directory.appendingPathComponent("Manual/photo.png")
        try Exporter.write(f.solid(1), to: url, backingScale: 3)
        f.pipeline.openFile(url)
        let model = try #require(f.presented.last).model
        #expect(!model.isComposed)
        #expect(model.backingScale == 2)
        #expect(f.recent == [url])
    }

    @Test func aFileInOutputThatGlintDoesNotTrackOpensNormally() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        let url = f.outputDirectory.appendingPathComponent("earlier.png")
        try Exporter.write(f.solid(1), to: url, backingScale: 2)
        f.pipeline.openFile(url)
        #expect(f.presented.last?.model.isComposed == false)
        #expect(!f.pipeline.retention.isManaged(url))
    }

    @Test func openingAnUnreadableFileReportsItAndForgetsNothing() throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        let url = try f.touch("broken.png")
        f.pipeline.openFile(url)
        #expect(f.presented.isEmpty && f.removedRecent.isEmpty && f.recent.isEmpty)
        #expect(f.notifications.count == 1)
        #expect(f.notifications.first?.title == "Cannot open image")
        #expect(f.notifications.first?.body == "broken.png")
    }

    @Test func openingAnUnreadableKeptFileForgetsIt() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        await f.capture(f.solid(1), clipboardOnly: true)
        let kept = try #require(f.latest)
        try Data("not an image".utf8).write(to: kept.url)
        f.pipeline.openFile(kept.url)
        #expect(f.presented.isEmpty)
        #expect(f.removedRecent == [kept.url])
        #expect(!f.pipeline.retention.isManaged(kept.url))
        #expect(f.notifications.last?.title == "Cannot open image")
    }

    // MARK: recent files

    @Test func recentFilesAreNewestFirstWithoutDuplicatesAndCapped() throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        let defaults = f.preferences.defaults
        let files = try (1...12).map { try f.touch("recent-\($0).png") }
        for file in files.prefix(3) { RecentFiles.add(file, defaults: defaults, noteInSystemRecents: false) }
        #expect(RecentFiles.list(defaults: defaults).map(\.path) == [files[2], files[1], files[0]].map(\.path))
        RecentFiles.add(files[0], defaults: defaults, noteInSystemRecents: false)
        #expect(RecentFiles.list(defaults: defaults).map(\.path) == [files[0], files[2], files[1]].map(\.path))
        for file in files.dropFirst(3) { RecentFiles.add(file, defaults: defaults, noteInSystemRecents: false) }
        let list = RecentFiles.list(defaults: defaults)
        #expect(list.count == RecentFiles.limit)
        #expect(list.first?.path == files[11].path)
    }

    @Test func removingARecentFileLeavesTheFileAlone() throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        let defaults = f.preferences.defaults
        let a = try f.touch("a.png"), b = try f.touch("b.png")
        RecentFiles.add(a, defaults: defaults, noteInSystemRecents: false)
        RecentFiles.add(b, defaults: defaults, noteInSystemRecents: false)
        RecentFiles.remove(a, defaults: defaults)
        #expect(RecentFiles.list(defaults: defaults).map(\.path) == [b.path])
        #expect(f.exists(a))
        RecentFiles.remove(f.directory.appendingPathComponent("unknown.png"), defaults: defaults)
        #expect(RecentFiles.list(defaults: defaults).map(\.path) == [b.path])
    }

    @Test func pruningDropsMissingFilesFromTheStoredList() throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        let defaults = f.preferences.defaults
        let a = try f.touch("a.png"), b = try f.touch("b.png"), c = try f.touch("c.png")
        for file in [a, b, c] { RecentFiles.add(file, defaults: defaults, noteInSystemRecents: false) }
        try FileManager.default.removeItem(at: b)
        #expect(RecentFiles.list(defaults: defaults).map(\.path) == [c, a].map(\.path))
        #expect(defaults.stringArray(forKey: ShellKey.recentFiles)?.count == 3)
        #expect(RecentFiles.prune(defaults: defaults).map(\.path) == [c, a].map(\.path))
        #expect(defaults.stringArray(forKey: ShellKey.recentFiles) == [c.path, a.path])
        RecentFiles.clear(defaults: defaults)
        #expect(RecentFiles.list(defaults: defaults).isEmpty)
    }

    @Test func buildingRecentMenuHidesUnavailableFilesWithoutForgettingThem() throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        let available = try f.touch("available.png")
        let offline = f.directory.appendingPathComponent("Offline/unavailable.png")
        let defaults = f.preferences.defaults
        for file in [available, offline] { RecentFiles.add(file, defaults: defaults, noteInSystemRecents: false) }
        let stored = defaults.stringArray(forKey: ShellKey.recentFiles)
        let menu = NSMenu()
        let delegate = AppDelegate(prefs: f.preferences, menu: menu)
        delegate.pipeline = f.pipeline

        delegate.menuNeedsUpdate(menu)

        let recent = try #require(menu.item(withTitle: "Open Recent")?.submenu)
        #expect(recent.items.compactMap { ($0.representedObject as? URL)?.path } == [available.path])
        #expect(defaults.stringArray(forKey: ShellKey.recentFiles) == stored)
        try f.touch("unavailable.png", in: "Offline")
        delegate.menuNeedsUpdate(menu)
        let restored = try #require(menu.item(withTitle: "Open Recent")?.submenu)
        #expect(restored.items.compactMap { ($0.representedObject as? URL)?.path } == [offline.path, available.path])
    }

    // MARK: cleanup

    @Test func cleanupMovesExpiredImagesToTheTrashAndForgetsThemInRecentFiles() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        let expired = try await f.keepExpiredImage(1)
        await f.capture(f.solid(2), clipboardOnly: true)
        let fresh = try #require(f.latest).url
        #expect(!samePath(expired, fresh))
        await f.pipeline.runOutputCleanup()
        #expect(f.trash.trashed.map(\.lastPathComponent) == [expired.lastPathComponent])
        #expect(f.removedRecent == [expired])
        #expect(!f.exists(expired) && f.exists(fresh))
        #expect(samePath(try #require(f.latest).url, fresh))
        #expect(!f.notifications.contains { $0.title == "Old screenshots could not be removed" })
    }

    @Test func cleanupRemovesExpiredAutoSavedOutputs() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.outputRetention = .sevenDays
        f.preferences.saveOutput = true
        await f.capture(f.solid(1))
        let saved = try #require(f.recent.first)
        f.clock.advance(days: 8)
        await f.pipeline.runOutputCleanup()
        #expect(f.trash.trashed.count == 1 && !f.exists(saved))
        #expect(f.removedRecent.count == 1 && samePath(f.removedRecent[0], saved))
    }

    @Test func cleanupDoesNothingByDefault() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.saveOutput = true
        await f.capture(f.solid(1))
        f.clock.advance(days: 400)
        await f.pipeline.runOutputCleanup()
        #expect(f.trash.trashed.isEmpty && f.removedRecent.isEmpty)
        #expect(f.outputFiles().count == 1 && !f.exists(f.indexURL))
    }

    @Test func foreverNeverRemovesAnything() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        await f.capture(f.solid(1), clipboardOnly: true)
        f.clock.advance(days: 400)
        await f.pipeline.runOutputCleanup()
        #expect(f.trash.trashed.isEmpty && f.removedRecent.isEmpty)
        #expect(f.outputFiles().count == 1)
    }

    @Test func cleanupWaitsWhileHistoryIsOff() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        let expired = try await f.keepExpiredImage()
        f.preferences.saveHistory = false
        await f.pipeline.runOutputCleanup()
        #expect(f.trash.trashed.isEmpty && f.exists(expired))
        f.preferences.saveHistory = true
        await f.pipeline.runOutputCleanup()
        #expect(f.trash.trashed.count == 1 && !f.exists(expired))
    }

    @Test func cleanupSkipsAFileThatIsBeingDragged() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        let expired = try await f.keepExpiredImage()
        f.activeFiles.begin(expired)
        await f.pipeline.runOutputCleanup()
        #expect(f.trash.trashed.isEmpty && f.removedRecent.isEmpty && f.exists(expired))
        f.activeFiles.end(expired)
        await f.pipeline.runOutputCleanup()
        #expect(f.trash.trashed.count == 1 && f.removedRecent == [expired] && !f.exists(expired))
    }

    @Test func cleanupLeavesFilesGlintDidNotWriteAlone() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        let expired = try await f.keepExpiredImage()
        let earlier = try f.touch("earlier.png", in: "History/Output")
        let raw = try f.touch("raw.png", in: "History/Raw")
        let manual = try f.touch("manual.png")
        let longAgo = Date(timeIntervalSince1970: 1_000_000_000)
        for url in [earlier, raw, manual] {
            try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: url.path)
        }
        await f.pipeline.runOutputCleanup()
        #expect(f.trash.trashed.map(\.lastPathComponent) == [expired.lastPathComponent])
        #expect(f.exists(earlier) && f.exists(raw) && f.exists(manual))
    }

    @Test func cleanupFailuresAreReportedOncePerRunAndNotRepeated() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        let title = "Old screenshots could not be removed"
        func failureNotices() -> [(title: String, body: String, url: URL?)] { f.notifications.filter { $0.title == title } }
        let first = try await f.keepExpiredImage(1)
        f.clock.advance(hours: -192 + 1)
        await f.capture(f.solid(2), clipboardOnly: true)
        let second = try #require(f.latest).url
        f.clock.advance(days: 8)
        f.trash.refuse(first.lastPathComponent)
        f.trash.refuse(second.lastPathComponent)

        await f.pipeline.runOutputCleanup()
        #expect(failureNotices().count == 1)
        #expect(failureNotices().first?.body.contains(first.lastPathComponent) == true)
        #expect(failureNotices().first?.body.contains(second.lastPathComponent) == true)
        #expect(f.trash.trashed.isEmpty && f.removedRecent.isEmpty)

        await f.pipeline.runOutputCleanup()
        #expect(failureNotices().count == 1)

        f.trash.allow(first.lastPathComponent)
        await f.pipeline.runOutputCleanup()
        #expect(f.trash.trashed.count == 1 && f.removedRecent == [first])
        #expect(failureNotices().count == 2)

        f.trash.allow(second.lastPathComponent)
        await f.pipeline.runOutputCleanup()
        #expect(f.trash.trashed.count == 2 && f.removedRecent == [first, second])
        #expect(failureNotices().count == 2)

        await f.capture(f.solid(3), clipboardOnly: true)
        let third = try #require(f.latest).url
        f.clock.advance(days: 8)
        f.trash.refuse(third.lastPathComponent)
        await f.pipeline.runOutputCleanup()
        #expect(failureNotices().count == 3)
    }

    // MARK: cleanup scheduler

    @Test func schedulerRunsAfterTheLaunchDelayThenEveryInterval() async {
        let timing = schedulerTiming()
        let schedule = ManualSchedule()
        let log = RunLog()
        let scheduler = OutputCleanupScheduler(timing: timing, schedule: schedule.schedule) { await log.run() }
        scheduler.start()
        #expect(schedule.pending().map(\.delay) == [timing.launchDelay])
        #expect(log.runs == 0)
        #expect(schedule.fire(timing.launchDelay))
        await scheduler.waitUntilIdle()
        #expect(log.runs == 1)
        #expect(schedule.pending().map(\.delay) == [timing.interval])
        #expect(schedule.fire(timing.interval))
        await scheduler.waitUntilIdle()
        #expect(log.runs == 2)
        #expect(schedule.fire(timing.interval))
        await scheduler.waitUntilIdle()
        #expect(log.runs == 3)
        #expect(schedule.pending().map(\.delay) == [timing.interval])
        scheduler.stop()
    }

    @Test func schedulerRunsOnceAfterPreferencesHaveBeenQuiet() async {
        let timing = schedulerTiming()
        let schedule = ManualSchedule()
        let log = RunLog()
        let scheduler = OutputCleanupScheduler(timing: timing, schedule: schedule.schedule) { await log.run() }
        for _ in 0..<3 { scheduler.preferencesChanged() }
        #expect(schedule.pending(timing.debounce).count == 1)
        #expect(log.runs == 0)
        #expect(schedule.fire(timing.debounce))
        await scheduler.waitUntilIdle()
        #expect(log.runs == 1)
        #expect(!schedule.fire(timing.debounce))
    }

    @Test func schedulerAsksForOneMorePassWhenChangedDuringARun() async {
        let timing = schedulerTiming()
        let schedule = ManualSchedule()
        let log = RunLog()
        log.holdFirstRun = true
        defer { log.release() }
        let scheduler = OutputCleanupScheduler(timing: timing, schedule: schedule.schedule) { await log.run() }
        scheduler.preferencesChanged()
        schedule.fire(timing.debounce)
        let started = await eventually { log.isHeld }
        #expect(started && log.runs == 1)
        for _ in 0..<2 {
            scheduler.preferencesChanged()
            schedule.fire(timing.debounce)
        }
        #expect(log.runs == 1)
        log.release()
        await scheduler.waitUntilIdle()
        #expect(log.runs == 2)
    }

    @Test func stoppingTheSchedulerCancelsPendingWork() async {
        let timing = schedulerTiming()
        let schedule = ManualSchedule()
        let log = RunLog()
        let scheduler = OutputCleanupScheduler(timing: timing, schedule: schedule.schedule) { await log.run() }
        scheduler.start()
        scheduler.preferencesChanged()
        #expect(schedule.pending().count == 2)
        scheduler.stop()
        #expect(schedule.pending().isEmpty)
        #expect(!schedule.fire(timing.launchDelay) && !schedule.fire(timing.debounce))
        #expect(log.runs == 0)
    }

    @Test func schedulerDrivesThePipelineCleanup() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        let expired = try await f.keepExpiredImage()
        let timing = schedulerTiming()
        let schedule = ManualSchedule()
        let scheduler = OutputCleanupScheduler(timing: timing, schedule: schedule.schedule) { [pipeline = f.pipeline] in
            await pipeline.runOutputCleanup()
        }
        scheduler.start()
        #expect(f.exists(expired))
        schedule.fire(timing.launchDelay)
        await scheduler.waitUntilIdle()
        #expect(!f.exists(expired) && f.trash.trashed.count == 1)
        #expect(f.removedRecent == [expired])
        scheduler.stop()
    }

    @Test func preferenceChangesReachTheCleanupSchedulerUntilItIsStopped() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        let expired = try await f.keepExpiredImage()
        let timing = schedulerTiming()
        let schedule = ManualSchedule()
        let delegate = AppDelegate(prefs: f.preferences, menu: NSMenu())
        delegate.pipeline = f.pipeline
        delegate.cleanupScheduler = OutputCleanupScheduler(timing: timing, schedule: schedule.schedule) { [pipeline = f.pipeline] in
            await pipeline.runOutputCleanup()
        }
        delegate.startOutputCleanup()
        defer { delegate.stopOutputCleanup() }
        #expect(schedule.pending(timing.launchDelay).count == 1)

        NotificationCenter.default.post(name: .glintPreferencesChanged, object: nil)
        let armed = await eventually { !schedule.pending(timing.debounce).isEmpty }
        #expect(armed)
        schedule.fire(timing.debounce)
        await delegate.cleanupScheduler.waitUntilIdle()
        #expect(f.trash.trashed.count == 1 && !f.exists(expired))

        delegate.stopOutputCleanup()
        #expect(schedule.pending().isEmpty)
        NotificationCenter.default.post(name: .glintPreferencesChanged, object: nil)
        for _ in 0..<3 { await Task.yield() }
        #expect(schedule.pending().isEmpty)
    }

    // MARK: retention queue

    @Test func retentionQueueRunsJobsInOrderOffTheMainThread() async {
        let queue = RetentionQueue()
        let ran = Box<[Int]>([])
        let onMain = Box<[Bool]>([])
        let completed = Box<[Int]>([])
        for number in 1...5 {
            queue.enqueue({ () -> Int in
                onMain.withValue { $0.append(Thread.isMainThread) }
                ran.withValue { $0.append(number) }
                return number
            }, completion: { result in
                completed.withValue { $0.append(result) }
            })
        }
        #expect(queue.pending == 5 && !queue.isIdle)
        let idle = await queue.waitUntilIdle(timeout: .seconds(120))
        #expect(idle && queue.isIdle && queue.pending == 0)
        #expect(ran.snapshot == [1, 2, 3, 4, 5] && completed.snapshot == [1, 2, 3, 4, 5])
        #expect(onMain.snapshot.count == 5 && onMain.snapshot.allSatisfy { !$0 })
    }

    @Test func retentionQueueWaitReportsATimeout() async {
        let queue = RetentionQueue()
        let alreadyIdle = await queue.waitUntilIdle(timeout: .milliseconds(10))
        #expect(alreadyIdle)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        queue.enqueue({ _ = gate.wait(timeout: .now() + 120) }, completion: { _ in })
        let timedOut = await queue.waitUntilIdle(timeout: .milliseconds(100))
        #expect(!timedOut && !queue.isIdle)
        gate.signal()
        let finished = await queue.waitUntilIdle(timeout: .seconds(120))
        #expect(finished && queue.isIdle)
    }

    // MARK: quitting

    @Test func quitIsImmediateWhenNothingIsBeingKept() throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        let delegate = AppDelegate(prefs: f.preferences, menu: NSMenu())
        delegate.pipeline = f.pipeline
        let replies = Box<[Bool]>([])
        delegate.replyToTermination = { reply in replies.withValue { $0.append(reply) } }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(replies.snapshot.isEmpty)
    }

    @Test func quitWaitsForAKeptScreenshotThatIsStillBeingWritten() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        let delegate = AppDelegate(prefs: f.preferences, menu: NSMenu())
        delegate.pipeline = f.pipeline
        delegate.terminationGrace = .seconds(300)
        let replies = Box<[Bool]>([])
        delegate.replyToTermination = { reply in replies.withValue { $0.append(reply) } }
        let gate = holdRetentionQueue(f.pipeline)
        defer { gate.signal() }
        await f.pipeline.handle(image: f.solid(1), scale: 2, source: "test", rawURL: nil, saveRaw: false,
                                clipboardOnly: true)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        for _ in 0..<3 { await Task.yield() }
        #expect(replies.snapshot.isEmpty)
        gate.signal()
        let replied = await eventually { replies.snapshot == [true] }
        #expect(replied)
        await f.settle()
        #expect(replies.snapshot == [true])
        #expect(f.outputFiles().count == 1 && f.latest != nil)
    }

    @Test func quitIsCancelledAfterTheGraceTimeWithoutLosingTheScreenshot() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        let delegate = AppDelegate(prefs: f.preferences, menu: NSMenu())
        delegate.pipeline = f.pipeline
        delegate.terminationGrace = .milliseconds(100)
        let replies = Box<[Bool]>([])
        delegate.replyToTermination = { reply in replies.withValue { $0.append(reply) } }
        let gate = holdRetentionQueue(f.pipeline)
        defer { gate.signal() }
        await f.pipeline.handle(image: f.solid(1), scale: 2, source: "test", rawURL: nil, saveRaw: false,
                                clipboardOnly: true)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        let replied = await eventually { replies.snapshot == [false] }
        #expect(replied)
        #expect(f.pipeline.isKeepingScreenshots)
        #expect(f.notifications.last?.title == "Screenshots are still being saved")
        gate.signal()
        await f.settle()
        #expect(replies.snapshot == [false])
        #expect(f.outputFiles().count == 1 && f.latest != nil)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(replies.snapshot == [false])
    }

    // MARK: menus

    @Test func statusMenuListsReopenLastImageRightAfterOpenRecent() throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        let menu = NSMenu()
        let delegate = AppDelegate(prefs: f.preferences, menu: menu)
        delegate.pipeline = f.pipeline
        delegate.menuNeedsUpdate(menu)
        let recent = menu.indexOfItem(withTitle: "Open Recent")
        let reopen = try #require(menu.item(withTitle: "Reopen Last Image"))
        #expect(recent > 0 && menu.index(of: reopen) == recent + 1)
        #expect(menu.item(at: recent - 1)?.title == "Open Image…")
        #expect(reopen.target === delegate && reopen.action != nil)
        #expect(reopen.keyEquivalent.isEmpty)
    }

    @Test func fileMenuListsReopenLastImageBetweenOpenAndClose() throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        let delegate = AppDelegate(prefs: f.preferences, menu: NSMenu())
        delegate.pipeline = f.pipeline
        let file = NSMenu(title: "File")
        delegate.populateFileMenu(file)
        #expect(file.items.map(\.title) == ["Open Image…", "Reopen Last Image", "Close"])
        let reopen = file.items[1]
        #expect(reopen.target === delegate && reopen.action != nil && reopen.keyEquivalent.isEmpty)
        let keys = file.items.map(\.keyEquivalent).filter { !$0.isEmpty }
        #expect(Set(keys).count == keys.count)
    }

    @Test func reopenMenuItemIsEnabledOnlyWhileAnImageIsKept() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        let menu = NSMenu()
        let delegate = AppDelegate(prefs: f.preferences, menu: menu)
        delegate.pipeline = f.pipeline
        let file = NSMenu(title: "File")
        delegate.populateFileMenu(file)

        delegate.menuNeedsUpdate(menu)
        menu.update()
        file.update()
        let statusItem = try #require(menu.item(withTitle: "Reopen Last Image"))
        let fileItem = try #require(file.item(withTitle: "Reopen Last Image"))
        #expect(!delegate.validateMenuItem(statusItem) && !statusItem.isEnabled && !fileItem.isEnabled)
        #expect(delegate.validateMenuItem(try #require(menu.item(withTitle: "Show Output Folder"))))

        await f.pipeline.handle(image: f.solid(1), scale: 2, source: "test", rawURL: nil,
                                saveRaw: false, clipboardOnly: true)
        #expect(await eventually { statusItem.isEnabled && fileItem.isEnabled })
        #expect(delegate.validateMenuItem(statusItem))
        await f.settle()
        f.preferences.outputRetention = .oneDay
        f.clock.advance(days: 2)
        await f.pipeline.runOutputCleanup()
        #expect(!delegate.validateMenuItem(statusItem) && !statusItem.isEnabled && !fileItem.isEnabled)
    }

    @Test func menuValidationUsesTheCacheWhileLookupIsBlockedAndUpdatesTheOpenMenus() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        await f.capture(f.solid(1), clipboardOnly: true)
        let kept = try #require(f.latest)
        let gate = BlockingGate()
        defer { gate.signal() }
        let lookups = Box(0)
        let onMain = Box<[Bool]>([])
        f.latestRetainedOutput = { retention in
            onMain.withValue { $0.append(Thread.isMainThread) }
            let count = lookups.withValue { $0 += 1; return $0 }
            if count == 1 { gate.wait() }
            return retention.latest()
        }
        f.pipeline = f.makePipeline()
        let menu = NSMenu(), file = NSMenu(title: "File")
        let delegate = AppDelegate(prefs: f.preferences, menu: menu)
        delegate.pipeline = f.pipeline
        delegate.populateFileMenu(file)
        delegate.menuNeedsUpdate(menu)
        let statusItem = try #require(menu.item(withTitle: "Reopen Last Image"))
        let fileItem = try #require(file.item(withTitle: "Reopen Last Image"))
        #expect(await eventually { gate.hasEntered })

        #expect(!delegate.validateMenuItem(statusItem) && !delegate.validateMenuItem(fileItem))
        #expect(lookups.snapshot == 1 && !gate.hasFinished)
        #expect(!statusItem.isEnabled && !fileItem.isEnabled)
        gate.signal()
        #expect(await eventually { statusItem.isEnabled && fileItem.isEnabled })
        #expect(delegate.validateMenuItem(statusItem))
        #expect(onMain.snapshot.allSatisfy { !$0 })

        try FileManager.default.removeItem(at: kept.url)
        delegate.menuNeedsUpdate(file)
        #expect(await eventually { !statusItem.isEnabled && !fileItem.isEnabled })
        #expect(!delegate.validateMenuItem(fileItem))
    }

    @Test func reopeningRevalidatesOffTheMainThreadWithoutBlockingTheUI() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        await f.capture(f.solid(1), scale: 3, clipboardOnly: true)
        let gate = BlockingGate()
        defer { gate.signal() }
        let onMain = Box<[Bool]>([])
        f.latestRetainedOutput = { retention in
            onMain.withValue { $0.append(Thread.isMainThread) }
            gate.wait()
            return retention.latest()
        }
        f.pipeline = f.makePipeline()

        let reopening = Task { await f.pipeline.reopenLastImage() }
        #expect(await eventually { gate.hasEntered })
        #expect(!gate.hasFinished && f.presented.isEmpty)
        gate.signal()
        await reopening.value

        #expect(onMain.snapshot == [false])
        #expect(f.presented.count == 1 && f.presented.last?.model.backingScale == 3)
        #expect(f.pipeline.canReopenLastImage)
    }

    @Test func preferenceChangesRefreshTheOpenMenus() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        await f.capture(f.solid(1), clipboardOnly: true)
        let menu = NSMenu(), file = NSMenu(title: "File")
        let delegate = AppDelegate(prefs: f.preferences, menu: menu)
        delegate.pipeline = f.pipeline
        let schedule = ManualSchedule()
        delegate.cleanupScheduler = OutputCleanupScheduler(timing: schedulerTiming(), schedule: schedule.schedule) {}
        delegate.populateFileMenu(file)
        delegate.menuNeedsUpdate(menu)
        delegate.startOutputCleanup()
        defer { delegate.stopOutputCleanup() }
        let statusItem = try #require(menu.item(withTitle: "Reopen Last Image"))
        let fileItem = try #require(file.item(withTitle: "Reopen Last Image"))
        #expect(statusItem.isEnabled && fileItem.isEnabled)

        f.preferences.saveHistory = false
        NotificationCenter.default.post(name: .glintPreferencesChanged, object: nil)
        #expect(await eventually { !statusItem.isEnabled && !fileItem.isEnabled })
        f.preferences.saveHistory = true
        NotificationCenter.default.post(name: .glintPreferencesChanged, object: nil)
        #expect(await eventually { statusItem.isEnabled && fileItem.isEnabled })
    }

    @Test func choosingReopenLastImageOpensTheEditor() async throws {
        let f = try ReopenFixture(); defer { f.cleanUp() }
        f.preferences.keepCopiedImages = true
        let menu = NSMenu()
        let delegate = AppDelegate(prefs: f.preferences, menu: menu)
        delegate.pipeline = f.pipeline
        await f.capture(f.solid(1), scale: 3, clipboardOnly: true)
        delegate.menuNeedsUpdate(menu)
        let item = try #require(menu.item(withTitle: "Reopen Last Image"))
        _ = delegate.perform(item.action)
        #expect(await eventually { f.presented.count == 1 })
        #expect(f.presented.count == 1)
        #expect(f.presented.first?.model.isComposed == true && f.presented.first?.model.backingScale == 3)
    }

    // MARK: dragged files

    @Test func activeDragFileHoldsTheFileOnlyForTheDrag() {
        let files = OutputActiveFiles()
        let a = URL(fileURLWithPath: "/glint-test-folder/a.png")
        let b = URL(fileURLWithPath: "/glint-test-folder/b.png")
        let drag = ActiveDragFile(files: files)
        drag.begin(a)
        #expect(files.contains(a))
        drag.begin(b)
        #expect(!files.contains(a) && files.contains(b))
        drag.end()
        #expect(!files.contains(b))
        drag.end()
        drag.begin(a)
        drag.begin(nil)
        #expect(!files.contains(a))
    }

    @Test func activeDragFileLetsGoWhenItIsDropped() {
        let files = OutputActiveFiles()
        let a = URL(fileURLWithPath: "/glint-test-folder/a.png")
        var drag: ActiveDragFile? = ActiveDragFile(files: files)
        drag?.begin(a)
        #expect(files.contains(a))
        drag = nil
        #expect(!files.contains(a))
    }
}
