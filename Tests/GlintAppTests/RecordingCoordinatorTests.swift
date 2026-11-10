import AppKit
import GlintCapture
@testable import GlintCore
import Testing
@testable import Glint

@MainActor
private final class FakeSession: RecordingSessioning {
    var onPhaseChanged: ((RecordingPhase) -> Void)?
    var stopReason: RecordingStopReason?
    private(set) var stops = 0
    private(set) var cancels = 0
    private(set) var isRunning = false
    private var continuation: CheckedContinuation<RecordedVideo, Error>?

    func run() async throws -> RecordedVideo {
        try await withCheckedThrowingContinuation {
            continuation = $0
            isRunning = true
        }
    }

    func emit(_ phase: RecordingPhase) { onPhaseChanged?(phase) }
    func finish(_ video: RecordedVideo) { resume(.success(video)) }
    func fail(_ error: Error) { resume(.failure(error)) }
    func stop() { stops += 1 }
    func cancel() {
        cancels += 1
        fail(CaptureError.cancelled)
    }

    func waitUntilRunning() async {
        while !isRunning { await Task.yield() }
    }

    private func resume(_ result: Result<RecordedVideo, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor
private final class Harness {
    var sessions: [FakeSession] = []
    var snapRequests: [Bool] = []
    var closers: [@MainActor () -> Void] = []
    var presented: [RecordedVideo] = []
    var notifications: [(title: String, body: String)] = []
    var failures: [(title: String, body: String)] = []
    var permissionPrompts = 0
    var beeps = 0
    var busy = false
    var snapToEdges = false
    var titles: [String?] = []
    lazy var coordinator: RecordingCoordinator = {
        var services = RecordingCoordinator.Services()
        services.makeSession = { [self] snap in
            snapRequests.append(snap)
            let session = FakeSession()
            sessions.append(session)
            return session
        }
        services.presentEditor = { [self] video, onClose in
            presented.append(video)
            closers.append(onClose)
            return NSObject()
        }
        services.notify = { [self] in notifications.append(($0, $1)) }
        services.fail = { [self] in failures.append(($0, $1)) }
        services.showPermissions = { [self] in permissionPrompts += 1 }
        services.beep = { [self] in beeps += 1 }
        let coordinator = RecordingCoordinator(services: services, snapToEdges: { [self] in snapToEdges },
                                               isCaptureBusy: { [self] in busy })
        coordinator.onStatusTitle = { [self] in titles.append($0) }
        return coordinator
    }()

    static let video = RecordedVideo(url: URL(fileURLWithPath: "/tmp/glint-test.mp4"), duration: 2, pixelSize: CGSize(width: 160, height: 90))

    func startAndWaitUntilRunning() async throws -> FakeSession {
        coordinator.start()
        let session = try #require(sessions.last)
        await session.waitUntilRunning()
        return session
    }

    func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
@Suite struct RecordingCoordinatorTests {
    @Test func finishedRecordingOpensTheEditorAndReleasesItOnClose() async throws {
        let h = Harness()
        let session = try await h.startAndWaitUntilRunning()
        #expect(h.coordinator.isActive)

        session.finish(Harness.video)
        await h.settle()

        #expect(h.presented == [Harness.video])
        #expect(!h.coordinator.isActive && h.coordinator.phase == .idle)
        #expect(h.coordinator.openEditorCount == 1)
        h.closers.forEach { $0() }
        #expect(h.coordinator.openEditorCount == 0)
        #expect(h.notifications.isEmpty && h.permissionPrompts == 0)
    }

    @Test func timeLimitStopStillOpensTheEditorAndExplainsWhy() async throws {
        let h = Harness()
        let session = try await h.startAndWaitUntilRunning()
        session.stopReason = .timeLimit

        session.finish(Harness.video)
        await h.settle()

        #expect(h.presented == [Harness.video])
        #expect(h.notifications.map(\.title) == ["Recording stopped"])
        #expect(h.notifications.first?.body == RecordingCoordinator.timeLimitMessage)
        #expect(RecordingCoordinator.timeLimitMessage.contains("10-minute limit"))
        #expect(!h.coordinator.isActive)
    }

    @Test func userAndSystemStopsDoNotNotify() async throws {
        let h = Harness()
        for reason in [RecordingStopReason.user, .system] {
            let session = try await h.startAndWaitUntilRunning()
            session.stopReason = reason
            session.finish(Harness.video)
            await h.settle()
        }
        #expect(h.presented.count == 2)
        #expect(h.notifications.isEmpty)
    }

    @Test func sessionIsCreatedWithTheSnapPreference() async throws {
        let h = Harness()
        h.snapToEdges = true
        _ = try await h.startAndWaitUntilRunning()
        #expect(h.snapRequests == [true])
    }

    @Test func startingAgainWhileActiveIsIgnored() async throws {
        let h = Harness()
        _ = try await h.startAndWaitUntilRunning()
        h.coordinator.start()
        #expect(h.sessions.count == 1)
    }

    @Test func startIsRefusedWhileAScreenshotIsInProgress() {
        let h = Harness()
        h.busy = true
        h.coordinator.start()
        #expect(h.sessions.isEmpty && h.beeps == 1 && !h.coordinator.isActive)
    }

    @Test func toggleCancelsBeforeRecordingAndStopsWhileRecording() async throws {
        let h = Harness()
        let first = try await h.startAndWaitUntilRunning()
        first.emit(.ready)
        h.coordinator.toggle()
        #expect(first.cancels == 1 && first.stops == 0)
        await h.settle()
        #expect(!h.coordinator.isActive && h.presented.isEmpty && h.notifications.isEmpty)

        let second = try await h.startAndWaitUntilRunning()
        second.emit(.recording)
        h.coordinator.toggle()
        #expect(second.stops == 1 && second.cancels == 0)
        second.emit(.finishing)
        h.coordinator.toggle()
        #expect(second.stops == 1 && second.cancels == 0)
        second.finish(Harness.video)
        await h.settle()
        #expect(h.presented.count == 1)
    }

    @Test func toggleWhenIdleStartsARecording() {
        let h = Harness()
        h.coordinator.toggle()
        #expect(h.sessions.count == 1 && h.coordinator.isActive)
    }

    @Test func cancelledRecordingIsSilent() async throws {
        let h = Harness()
        let session = try await h.startAndWaitUntilRunning()
        session.fail(CaptureError.cancelled)
        await h.settle()
        #expect(!h.coordinator.isActive)
        #expect(h.notifications.isEmpty && h.permissionPrompts == 0 && h.presented.isEmpty)
    }

    @Test func missingPermissionShowsTheSetupWindow() async throws {
        let h = Harness()
        let session = try await h.startAndWaitUntilRunning()
        session.fail(CaptureError.permissionDenied)
        await h.settle()
        #expect(h.permissionPrompts == 1 && h.notifications.isEmpty && !h.coordinator.isActive)
    }

    @Test func failuresAreReportedAndAllowARetry() async throws {
        let h = Harness()
        let session = try await h.startAndWaitUntilRunning()
        session.fail(CaptureError.failed("Disk full"))
        await h.settle()
        #expect(h.failures.map(\.title) == ["Recording failed"])
        #expect(h.failures.first?.body == "Disk full")
        #expect(h.notifications.isEmpty)
        #expect(!h.coordinator.isActive)

        _ = try await h.startAndWaitUntilRunning()
        #expect(h.sessions.count == 2)
    }

    @Test func pressingTheShortcutWhileFinishingBeepsInsteadOfDroppingItSilently() async throws {
        let h = Harness()
        let session = try await h.startAndWaitUntilRunning()
        session.emit(.recording)
        h.coordinator.toggle()
        #expect(session.stops == 1 && h.beeps == 0)

        session.emit(.finishing)
        h.coordinator.toggle()
        h.coordinator.toggle()
        #expect(h.beeps == 2)
        #expect(session.stops == 1 && session.cancels == 0 && h.sessions.count == 1)
        session.finish(Harness.video)
        await h.settle()
        #expect(h.presented.count == 1 && h.failures.isEmpty)
    }

    @Test func statusTitleFollowsThePhaseAndClearsWhenDone() async throws {
        let h = Harness()
        let session = try await h.startAndWaitUntilRunning()
        session.emit(.selecting)
        session.emit(.countdown(3))
        session.emit(.recording)
        session.emit(.finishing)
        session.finish(Harness.video)
        await h.settle()
        #expect(h.titles == [nil, " 3", " ● REC", " …", nil])
    }

    @Test func capturingIsOnlyTrueOnceFootageMayExist() async throws {
        let h = Harness()
        let session = try await h.startAndWaitUntilRunning()
        for phase in [RecordingPhase.selecting, .ready, .countdown(5)] {
            session.emit(phase)
            #expect(!h.coordinator.isCapturing)
        }
        for phase in [RecordingPhase.recording, .finishing] {
            session.emit(phase)
            #expect(h.coordinator.isCapturing)
        }
    }

    @Test func menuTitleReflectsTheRecordingState() {
        #expect(AppDelegate.recordingMenuTitle(for: .idle, isActive: false) == "Record Screen…")
        #expect(AppDelegate.recordingMenuTitle(for: .recording, isActive: true) == "Stop Recording")
        #expect(AppDelegate.recordingMenuTitle(for: .ready, isActive: true) == "Cancel Recording")
        #expect(AppDelegate.recordingMenuTitle(for: .countdown(3), isActive: true) == "Cancel Recording")
        #expect(AppDelegate.recordingMenuTitle(for: .finishing, isActive: true) == "Finishing Recording…")
    }
}

@MainActor
@Suite struct RecordingAppShellTests {
    private func makeDelegate(recorder: RecordingCoordinator, menu: NSMenu = NSMenu()) throws -> (AppDelegate, () -> Void) {
        _ = NSApplication.shared
        let suite = "glint.recording.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glint-recording-\(UUID().uuidString)")
        let prefs = AppPreferences(defaults: defaults)
        prefs.saveDirectory = directory.appendingPathComponent("Manual")
        prefs.historyDirectory = directory.appendingPathComponent("History")
        let delegate = AppDelegate(prefs: prefs, menu: menu)
        delegate.pipeline = CapturePipeline(prefs: prefs, presetStore: PresetStore(url: directory.appendingPathComponent("presets.json")))
        delegate.recorder = recorder
        return (delegate, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    @Test func menuOffersRecordScreenWithItsShortcut() throws {
        let h = Harness()
        let menu = NSMenu()
        let (delegate, cleanUp) = try makeDelegate(recorder: h.coordinator, menu: menu)
        defer { cleanUp() }
        delegate.menuNeedsUpdate(menu)
        let item = try #require(menu.item(withTitle: "Record Screen…"))
        #expect(item.target === delegate && item.action != nil)
        #expect(item.keyEquivalent == "9")
        #expect(item.keyEquivalentModifierMask == [.control, .option, .command])
    }

    @Test func menuOffersStopWhileRecording() async throws {
        let h = Harness()
        let menu = NSMenu()
        let (delegate, cleanUp) = try makeDelegate(recorder: h.coordinator, menu: menu)
        defer { cleanUp() }
        let session = try await h.startAndWaitUntilRunning()
        session.emit(.recording)
        delegate.menuNeedsUpdate(menu)
        #expect(menu.item(withTitle: "Stop Recording") != nil)
        #expect(menu.item(withTitle: "Record Screen…") == nil)
        session.emit(.finishing)
        let finishing = try #require({ () -> NSMenuItem? in
            delegate.menuNeedsUpdate(menu)
            return menu.item(withTitle: "Finishing Recording…")
        }())
        #expect(!delegate.validateMenuItem(finishing))
        session.finish(Harness.video)
        await h.settle()
    }

    @Test func quittingWhileRecordingAsksBeforeDiscarding() async throws {
        let h = Harness()
        let (delegate, cleanUp) = try makeDelegate(recorder: h.coordinator)
        defer { cleanUp() }
        let session = try await h.startAndWaitUntilRunning()
        session.emit(.recording)
        let asked = Box(0)
        let allow = Box(false)
        delegate.confirmDiscardRecording = {
            asked.value += 1
            return allow.value
        }

        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(asked.value == 1 && session.cancels == 0 && h.coordinator.isActive)

        allow.value = true
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(asked.value == 2 && session.cancels == 1)
        await h.settle()
    }

    @Test func quittingBeforeRecordingStartsCancelsWithoutAsking() async throws {
        let h = Harness()
        let (delegate, cleanUp) = try makeDelegate(recorder: h.coordinator)
        defer { cleanUp() }
        let session = try await h.startAndWaitUntilRunning()
        session.emit(.ready)
        delegate.confirmDiscardRecording = {
            Issue.record("Quitting before any footage exists must not ask")
            return false
        }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(session.cancels == 1)
        await h.settle()
    }

    @Test func quittingWhenNotRecordingNeverAsks() throws {
        let h = Harness()
        let (delegate, cleanUp) = try makeDelegate(recorder: h.coordinator)
        defer { cleanUp() }
        delegate.confirmDiscardRecording = {
            Issue.record("Nothing is recording")
            return false
        }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    @Test func screenshotsAreBlockedWhileRecordingIsActive() throws {
        let h = Harness()
        let (delegate, cleanUp) = try makeDelegate(recorder: h.coordinator)
        defer { cleanUp() }
        let pipeline = delegate.pipeline
        #expect(!pipeline.isBusy)
        pipeline.isRecordingActive = { true }
        #expect(pipeline.isBusy)
    }

    @Test func recordScreenHasADistinctDefaultHotkey() {
        let combos = HotkeyAction.allCases.map(\.defaultCombo)
        #expect(Set(combos).count == combos.count)
        #expect(HotkeyAction.recordScreen.rawValue == "recordScreen")
        #expect(RecordingCoordinator.statusTitle(for: .idle) == nil)
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
