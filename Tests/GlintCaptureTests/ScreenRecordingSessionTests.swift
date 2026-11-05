import AppKit
import GlintCore
import Testing
@testable import GlintCapture

// The session flow runs entirely on fakes: no display is captured, no permission is needed and the only files
// are tiny synthetic videos in the temporary directory.

@MainActor
private final class FakePicker: RegionPicking {
    enum Behaviour {
        case returns(RecordingRegion)
        case waits
        case fails(CaptureError)
    }

    let behaviour: Behaviour
    private(set) var cancelCount = 0
    private var continuation: CheckedContinuation<RecordingRegion, Error>?

    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    func pick() async throws -> RecordingRegion {
        switch behaviour {
        case .returns(let region): return region
        case .fails(let error): throw error
        case .waits: return try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    func cancel() {
        cancelCount += 1
        continuation?.resume(throwing: CaptureError.cancelled)
        continuation = nil
    }
}

@MainActor
private final class FakePresenter: RecordingPresenting {
    enum Event: Equatable {
        case ready(CGRect)
        case countdown(Int)
        case recording
        case dismissed
    }

    private(set) var events: [Event] = []
    private(set) var actions: RecordingControlActions?
    private(set) var elapsedUpdates: [TimeInterval] = []

    func showReady(region: RecordingRegion, actions: RecordingControlActions) {
        events.append(.ready(region.rect))
        self.actions = actions
    }

    func showCountdown(_ remaining: Int) { events.append(.countdown(remaining)) }
    func showRecording(elapsed: TimeInterval) { events.append(.recording) }
    func updateElapsed(_ elapsed: TimeInterval) { elapsedUpdates.append(elapsed) }
    func dismiss() { events.append(.dismissed) }
}

/// Writes a real one-frame video so file handling is exercised, without ScreenCaptureKit.
private final class FakeEngine: RecordingEngine, @unchecked Sendable {
    let target: RecordingTarget
    private let lock = NSLock()
    private var handler: (@Sendable (RecordingEngineEvent) -> Void)?
    private var writer: FrameWriter?
    private var starts = 0
    private var finishes = 0
    private var discards = 0
    private var startError: Error?

    init(target: RecordingTarget, startError: Error?) {
        self.target = target
        self.startError = startError
    }

    var startCount: Int { lock.withLock { starts } }
    var finishCount: Int { lock.withLock { finishes } }
    var discardCount: Int { lock.withLock { discards } }

    func setEventHandler(_ handler: @escaping @Sendable (RecordingEngineEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func start() async throws {
        lock.withLock { starts += 1 }
        if let startError { throw startError }
        let writer = try FrameWriter(url: target.outputURL, width: target.geometry.outputWidth,
                                     height: target.geometry.outputHeight)
        let frame = SyntheticFrames.pixelBuffer(width: target.geometry.outputWidth, height: target.geometry.outputHeight)
        _ = await SyntheticFrames.append(frame, to: writer, at: .zero, arrival: .zero)
        lock.withLock { self.writer = writer }
    }

    func finish() async throws -> RecordedVideo {
        lock.withLock { finishes += 1 }
        guard let writer = lock.withLock({ self.writer }) else { throw FrameWriterError.noFrames }
        let summary = try await writer.finish(at: SyntheticFrames.time(2))
        return RecordedVideo(url: writer.url, duration: summary.duration, pixelSize: summary.pixelSize)
    }

    func discard() async {
        lock.withLock { discards += 1 }
        lock.withLock { writer }?.cancel()
    }

    func emit(_ event: RecordingEngineEvent) {
        lock.withLock { handler }?(event)
    }
}

@MainActor
private final class Harness {
    typealias Run = Task<RecordedVideo, Error>

    let display = DisplayInfo(id: 7, frame: CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 1,
                              name: "Synthetic", isMain: true)
    let picker: FakePicker
    let presenter = FakePresenter()
    private(set) var session: ScreenRecordingSession!
    private(set) var engine: FakeEngine?
    private(set) var phases: [RecordingPhase] = []
    private(set) var pickersCreated = 0
    private(set) var outputURLs: [URL] = []
    var clock: TimeInterval = 0
    var engineStartError: Error?

    nonisolated static let pickedRect = CGRect(x: 100, y: 100, width: 320, height: 200)

    init(picker behaviour: FakePicker.Behaviour? = nil, pickedRect: CGRect = Harness.pickedRect,
         permissionError: CaptureError? = nil, slowCountdown: Bool = false,
         maximumDuration: TimeInterval = RecordingLimits.maximumDuration, showsCursor: Bool = true) {
        let display = display
        picker = FakePicker(behaviour ?? .returns(RecordingRegion(rect: pickedRect, display: display)))
        let environment = RecordingEnvironment(
            requirePermission: { if let permissionError { throw permissionError } },
            makePicker: { [unowned self] _ in
                pickersCreated += 1
                return picker
            },
            makePresenter: { [unowned self] in presenter },
            makeEngine: { [unowned self] target in
                let engine = FakeEngine(target: target, startError: engineStartError)
                self.engine = engine
                return engine
            },
            makeOutputURL: { [unowned self] in
                let url = SyntheticFrames.tempURL("glint-session")
                outputURLs.append(url)
                return url
            },
            sleep: { seconds in
                let slow = slowCountdown && seconds >= 1
                try await Task.sleep(nanoseconds: slow ? 60_000_000_000 : 1_000_000)
            },
            now: { [unowned self] in clock },
            maximumDuration: maximumDuration)
        session = ScreenRecordingSession(snapToEdges: false, showsCursor: showsCursor, environment: environment)
        session.onPhaseChanged = { [unowned self] in phases.append($0) }
    }

    func cleanUp() {
        for url in outputURLs { try? FileManager.default.removeItem(at: url) }
    }

    func run() -> Run { Task { try await session.run() } }

    func waitFor(_ phase: RecordingPhase) async {
        await waitUntil("phase \(phase)") { session.phase == phase }
    }

    func waitUntil(_ description: String, _ condition: () -> Bool) async {
        // Generous: other main-actor suites in the same run can block the main thread for many seconds.
        let deadline = Date().addingTimeInterval(60)
        while !condition() {
            if Date() > deadline {
                Issue.record("Timed out waiting for \(description)")
                session.cancel()
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Presses Record in the on-screen controls.
    func pressRecord(_ choice: RecordingCountdownChoice = .none, region: CGRect = Harness.pickedRect) {
        presenter.actions?.record(choice, region)
    }

    /// Runs up to the point where the session is recording.
    func startRecording(_ choice: RecordingCountdownChoice = .none, region: CGRect = Harness.pickedRect) async -> Run {
        let task = run()
        await waitFor(.ready)
        pressRecord(choice, region: region)
        await waitFor(.recording)
        return task
    }
}

private func isCancelled(_ result: Result<RecordedVideo, Error>) -> Bool {
    if case .failure(let error) = result, case CaptureError.cancelled = error { return true }
    return false
}

private func captureError(_ result: Result<RecordedVideo, Error>) -> CaptureError? {
    if case .failure(let error) = result { return error as? CaptureError }
    return nil
}

@Suite("Screen recording session")
@MainActor
struct ScreenRecordingSessionTests {
    @Test func recordingWithACountdownWalksThroughEveryPhase() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let task = await harness.startRecording(.three)
        #expect(harness.session.stopReason == nil)

        harness.session.stop()
        let video = try await task.value

        #expect(harness.phases == [.selecting, .ready, .countdown(3), .countdown(2), .countdown(1), .recording,
                                   .finishing, .idle])
        #expect(harness.presenter.events == [.ready(Harness.pickedRect), .countdown(3), .countdown(2), .countdown(1),
                                             .countdown(0), .recording, .dismissed])
        #expect(harness.session.phase == .idle)
        #expect(harness.session.stopReason == .user)
        #expect(FileManager.default.fileExists(atPath: video.url.path))
        #expect(video.url == harness.engine?.target.outputURL)
        #expect(video.pixelSize == CGSize(width: 320, height: 200))
        #expect(abs(video.duration - 2) < 0.001)
        #expect(harness.engine?.startCount == 1 && harness.engine?.finishCount == 1 && harness.engine?.discardCount == 0)
    }

    @Test func recordingWithoutACountdownStartsRightAway() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let task = await harness.startRecording(.none)
        harness.session.stop()
        _ = try await task.value

        #expect(harness.phases == [.selecting, .ready, .recording, .finishing, .idle])
        #expect(harness.presenter.events == [.ready(Harness.pickedRect), .recording, .dismissed])
    }

    @Test func theFinishedVideoIsReallyPlayable() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let task = await harness.startRecording()
        harness.session.stop()
        let video = try await task.value

        let probe = try await SyntheticFrames.probe(video.url)
        #expect(probe.videoTrackCount == 1)
        #expect(probe.naturalSize == video.pixelSize)
        #expect(abs(probe.duration - video.duration) < 0.15)
    }

    @Test func theAdjustedFrameDecidesWhatIsCaptured() async throws {
        let harness = Harness(showsCursor: false)
        defer { harness.cleanUp() }
        let adjusted = CGRect(x: 150, y: 120, width: 401, height: 300)
        let task = await harness.startRecording(.none, region: adjusted)
        harness.session.stop()
        _ = try await task.value

        let target = try #require(harness.engine?.target)
        #expect(target.displayID == 7)
        #expect(!target.showsCursor)
        #expect(target.geometry.sourceRect == CGRect(x: 150, y: 120, width: 400, height: 300))
        #expect(target.geometry.outputSize == CGSize(width: 400, height: 300))
    }

    @Test func cursorIsCapturedByDefault() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let task = await harness.startRecording()
        harness.session.stop()
        _ = try await task.value
        #expect(harness.engine?.target.showsCursor == true)
    }

    @Test func aTinyPickedRegionIsGrownBeforeItIsShown() async throws {
        let harness = Harness(pickedRect: CGRect(x: 10, y: 10, width: 20, height: 20))
        defer { harness.cleanUp() }
        let task = harness.run()
        await harness.waitFor(.ready)
        #expect(harness.presenter.events.first == .ready(CGRect(x: 10, y: 10, width: 64, height: 64)))
        harness.session.cancel()
        _ = await task.result
    }

    @Test func aSecondRecordRequestIsIgnored() async throws {
        let harness = Harness(slowCountdown: true)
        defer { harness.cleanUp() }
        let task = harness.run()
        await harness.waitFor(.ready)
        harness.pressRecord(.five)
        harness.pressRecord(.none)
        await harness.waitFor(.countdown(5))
        #expect(harness.phases == [.selecting, .ready, .countdown(5)])
        harness.session.cancel()
        _ = await task.result
    }

    @Test func aRegionOutsideTheDisplayIsRejected() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let task = harness.run()
        await harness.waitFor(.ready)
        harness.pressRecord(.none, region: CGRect(x: 5000, y: 5000, width: 300, height: 200))

        let result = await task.result
        if case CaptureError.invalidRect? = captureError(result) {} else { Issue.record("Expected invalidRect, got \(result)") }
        #expect(harness.engine == nil)
        #expect(harness.session.phase == .idle)
    }

    // MARK: Cancelling

    @Test func cancellingBeforeRunThrowsWithoutShowingAnything() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.session.cancel()

        let result = await harness.run().result

        #expect(isCancelled(result))
        #expect(harness.phases.isEmpty)
        #expect(harness.pickersCreated == 0)
        #expect(harness.presenter.events.isEmpty)
        #expect(harness.outputURLs.isEmpty)
    }

    @Test func cancellingWhileSelectingStopsThePicker() async throws {
        let harness = Harness(picker: .waits)
        defer { harness.cleanUp() }
        let task = harness.run()
        await harness.waitFor(.selecting)

        harness.session.cancel()
        let result = await task.result

        #expect(isCancelled(result))
        #expect(harness.picker.cancelCount >= 1)
        #expect(harness.phases == [.selecting, .idle])
        #expect(harness.engine == nil)
    }

    @Test func theUserBackingOutOfTheSelectionCancels() async throws {
        let harness = Harness(picker: .fails(.cancelled))
        defer { harness.cleanUp() }

        let result = await harness.run().result

        #expect(isCancelled(result))
        #expect(harness.phases == [.selecting, .idle])
    }

    @Test func pickerFailuresPropagate() async throws {
        let harness = Harness(picker: .fails(.noDisplay))
        defer { harness.cleanUp() }

        let result = await harness.run().result

        if case CaptureError.noDisplay? = captureError(result) {} else { Issue.record("Expected noDisplay, got \(result)") }
        #expect(harness.phases == [.selecting, .idle])
    }

    @Test func cancellingWhileReadyRemovesTheControls() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let task = harness.run()
        await harness.waitFor(.ready)

        harness.presenter.actions?.cancel()
        let result = await task.result

        #expect(isCancelled(result))
        #expect(harness.phases == [.selecting, .ready, .idle])
        #expect(harness.presenter.events.last == .dismissed)
        #expect(harness.engine == nil)
        #expect(harness.outputURLs.isEmpty)
    }

    @Test func stoppingWhileReadyCancels() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let task = harness.run()
        await harness.waitFor(.ready)

        harness.session.stop()
        let result = await task.result

        #expect(isCancelled(result))
        #expect(harness.session.stopReason == nil)
    }

    @Test func cancellingDuringTheCountdownNeverStartsTheEngine() async throws {
        let harness = Harness(slowCountdown: true)
        defer { harness.cleanUp() }
        let task = harness.run()
        await harness.waitFor(.ready)
        harness.pressRecord(.five)
        await harness.waitFor(.countdown(5))

        harness.session.cancel()
        let result = await task.result

        #expect(isCancelled(result))
        #expect(harness.phases == [.selecting, .ready, .countdown(5), .idle])
        #expect(harness.engine?.startCount == 0)
        #expect(harness.engine?.discardCount == 1)
        #expect(harness.presenter.events.last == .dismissed)
        for url in harness.outputURLs { #expect(!FileManager.default.fileExists(atPath: url.path)) }
    }

    @Test func stoppingDuringTheCountdownCancels() async throws {
        let harness = Harness(slowCountdown: true)
        defer { harness.cleanUp() }
        let task = harness.run()
        await harness.waitFor(.ready)
        harness.pressRecord(.three)
        await harness.waitFor(.countdown(3))

        harness.session.stop()
        let result = await task.result

        #expect(isCancelled(result))
        #expect(harness.engine?.startCount == 0)
    }

    @Test func cancellingWhileRecordingDeletesThePartialFile() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let task = await harness.startRecording()
        let url = try #require(harness.engine?.target.outputURL)
        #expect(FileManager.default.fileExists(atPath: url.path))

        harness.session.cancel()
        let result = await task.result

        #expect(isCancelled(result))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(harness.engine?.finishCount == 0 && harness.engine?.discardCount == 1)
        #expect(harness.phases == [.selecting, .ready, .recording, .idle])
        #expect(harness.presenter.events.last == .dismissed)
    }

    @Test func cancellingTheTaskCancelsTheRecording() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let task = await harness.startRecording()
        let url = try #require(harness.engine?.target.outputURL)

        task.cancel()
        let result = await task.result

        #expect(isCancelled(result))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(harness.session.phase == .idle)
    }

    @Test func cancellingAfterTheRecordingWasReturnedChangesNothing() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let task = await harness.startRecording()
        harness.session.stop()
        let video = try await task.value

        harness.session.cancel()
        harness.session.stop()

        #expect(FileManager.default.fileExists(atPath: video.url.path))
        #expect(harness.session.phase == .idle)
    }

    // MARK: Limits, failures and the system

    @Test func reachingTheTimeLimitFinishesTheRecordingNormally() async throws {
        let harness = Harness(maximumDuration: 5)
        defer { harness.cleanUp() }
        let task = await harness.startRecording()

        harness.clock = 100
        let video = try await task.value

        #expect(harness.session.stopReason == .timeLimit)
        #expect(FileManager.default.fileExists(atPath: video.url.path))
        #expect(Array(harness.phases.suffix(3)) == [.recording, .finishing, .idle])
    }

    @Test func elapsedTimeKeepsTheRecordingPillCurrent() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let task = await harness.startRecording()

        harness.clock = 3
        await harness.waitUntil("an elapsed update") { harness.presenter.elapsedUpdates.contains(3) }
        harness.session.stop()
        _ = try await task.value

        #expect(harness.presenter.elapsedUpdates == harness.presenter.elapsedUpdates.sorted())
        #expect(harness.session.stopReason == .user)
    }

    @Test func anEngineFailureAbortsAndDeletesTheFile() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let task = await harness.startRecording()
        let url = try #require(harness.engine?.target.outputURL)

        harness.engine?.emit(.failed(CaptureError.failed("encoder died")))
        let result = await task.result

        if case CaptureError.failed("encoder died")? = captureError(result) {} else { Issue.record("Unexpected \(result)") }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(harness.engine?.discardCount == 1)
        #expect(harness.session.phase == .idle)
        #expect(harness.presenter.events.last == .dismissed)
    }

    @Test func otherEngineErrorsAreReportedAsCaptureFailures() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let task = await harness.startRecording()

        harness.engine?.emit(.failed(FrameWriterError.writerFailed("disk full")))
        let result = await task.result

        if case CaptureError.failed(let message)? = captureError(result) {
            #expect(message.contains("disk full"))
        } else {
            Issue.record("Expected a capture failure, got \(result)")
        }
    }

    @Test func theSystemEndingTheStreamKeepsTheFootage() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let task = await harness.startRecording()

        harness.engine?.emit(.stoppedBySystem)
        let video = try await task.value

        #expect(harness.session.stopReason == .system)
        #expect(FileManager.default.fileExists(atPath: video.url.path))
        #expect(harness.engine?.finishCount == 1)
    }

    @Test func aUserStopIsNotOverwrittenByALaterSystemStop() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let task = await harness.startRecording()

        harness.session.stop()
        harness.engine?.emit(.stoppedBySystem)
        _ = try await task.value

        #expect(harness.session.stopReason == .user)
    }

    @Test func anEngineThatCannotStartAbortsTheSession() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        harness.engineStartError = CaptureError.permissionDenied
        let task = harness.run()
        await harness.waitFor(.ready)
        harness.pressRecord()

        let result = await task.result

        if case CaptureError.permissionDenied? = captureError(result) {} else { Issue.record("Unexpected \(result)") }
        #expect(harness.phases == [.selecting, .ready, .idle])
        #expect(harness.engine?.discardCount == 1)
        #expect(harness.presenter.events.last == .dismissed)
    }

    @Test func missingPermissionFailsBeforeAnythingAppears() async throws {
        let harness = Harness(permissionError: .permissionDenied)
        defer { harness.cleanUp() }

        let result = await harness.run().result

        if case CaptureError.permissionDenied? = captureError(result) {} else { Issue.record("Unexpected \(result)") }
        #expect(harness.phases.isEmpty)
        #expect(harness.pickersCreated == 0)
        #expect(harness.presenter.events.isEmpty)
        #expect(harness.session.phase == .idle)
    }

    @Test func aSessionCanOnlyRunOnce() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let task = await harness.startRecording()
        harness.session.stop()
        _ = try await task.value

        let second = await harness.run().result

        if case CaptureError.failed? = captureError(second) {} else { Issue.record("Expected a failure, got \(second)") }
        #expect(harness.pickersCreated == 1)
    }
}
