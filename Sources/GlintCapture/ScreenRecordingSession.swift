import AppKit
import GlintCore

/// Why a recording ended; see `ScreenRecordingSession.stopReason`.
public enum RecordingStopReason: Sendable, Equatable {
    /// `stop()` was called, from the Stop button or the global hotkey.
    case user
    /// The recording reached `ScreenRecordingSession.maximumDuration` and was finalised automatically.
    case timeLimit
    /// macOS ended the capture, for example from the menu bar's screen-recording indicator.
    case system
}

/// One screen recording from region selection to the finished `.mp4`.
///
/// `run()` walks through `idle → selecting → ready → [countdown(n)…] → recording → finishing → idle`.
/// A session is single-use; create a new one for the next recording.
@MainActor
public final class ScreenRecordingSession {
    /// Longest recording (10 minutes). `run()` then returns the finished file and `stopReason` is `.timeLimit`.
    public static let maximumDuration: TimeInterval = RecordingLimits.maximumDuration

    public private(set) var phase: RecordingPhase = .idle
    /// Called on the main actor after every change of `phase`.
    public var onPhaseChanged: ((RecordingPhase) -> Void)?
    /// Why the recording ended; nil until it has.
    public private(set) var stopReason: RecordingStopReason?

    private let snapToEdges: Bool
    private let showsCursor: Bool
    private let environment: RecordingEnvironment

    private var picker: (any RegionPicking)?
    private var presenter: (any RecordingPresenting)?
    private var engine: (any RecordingEngine)?

    private var hasStarted = false
    private var isFinished = false
    private var cancelRequested = false
    private var stopRequested = false
    private var recordRequest: (choice: RecordingCountdownChoice, region: CGRect)?
    private var failure: CaptureError?
    private var waiter: CheckedContinuation<Void, Never>?
    private var signaled = false
    private var tickFired = false

    public convenience init(snapToEdges: Bool = false, showsCursor: Bool = true) {
        self.init(snapToEdges: snapToEdges, showsCursor: showsCursor, environment: .live)
    }

    init(snapToEdges: Bool, showsCursor: Bool, environment: RecordingEnvironment) {
        self.snapToEdges = snapToEdges
        self.showsCursor = showsCursor
        self.environment = environment
    }

    /// Runs the whole flow and returns the recording. Throws `CaptureError.cancelled` on Esc, `cancel()` or
    /// task cancellation, and `.permissionDenied` without Screen Recording access. Nothing is left on disk
    /// unless a video is returned.
    public func run() async throws -> RecordedVideo {
        guard !hasStarted else { throw CaptureError.failed("This screen recording session was already used.") }
        hasStarted = true
        defer { isFinished = true }
        return try await withTaskCancellationHandler {
            do {
                let video = try await record()
                finishRun()
                return video
            } catch {
                await abort()
                finishRun()
                throw error
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
    }

    /// While recording: stops, finalises the file and lets `run()` return it. In every earlier phase (selecting,
    /// ready, countdown) there is nothing to keep, so it cancels instead. Does nothing while finishing.
    public func stop() {
        switch phase {
        case .recording:
            stopRequested = true
            stopReason = stopReason ?? .user
            signal()
        case .finishing:
            break
        case .idle, .selecting, .ready, .countdown:
            cancel()
        }
    }

    /// Aborts from any phase and deletes the partial file; `run()` throws `CaptureError.cancelled`.
    /// Called before `run()`, it makes `run()` throw right away.
    public func cancel() {
        guard !isFinished else { return }
        cancelRequested = true
        picker?.cancel()
        signal()
    }

    // MARK: Flow

    private func record() async throws -> RecordedVideo {
        try throwIfCancelled()
        try environment.requirePermission()

        setPhase(.selecting)
        let picker = environment.makePicker(snapToEdges)
        self.picker = picker
        let picked: RecordingRegion
        do {
            picked = try await picker.pick()
        } catch {
            self.picker = nil
            throw error
        }
        self.picker = nil
        try throwIfCancelled()

        let initial = RegionAdjustment.clamped(picked.rect, to: picked.display.frame)
        let presenter = environment.makePresenter()
        self.presenter = presenter
        presenter.showReady(region: RecordingRegion(rect: initial, display: picked.display), actions: controlActions)
        setPhase(.ready)

        let request = try await waitForRecordRequest()
        guard let geometry = RecordingGeometry(region: request.region, display: picked.display.frame,
                                               scale: picked.display.scale) else {
            throw CaptureError.invalidRect
        }
        let target = RecordingTarget(displayID: picked.display.id, geometry: geometry, showsCursor: showsCursor,
                                     outputURL: environment.makeOutputURL())
        let engine = environment.makeEngine(target)
        self.engine = engine
        engine.setEventHandler { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }

        try await runCountdown(request.choice, presenter: presenter)
        try await engine.start()
        try throwIfCancelled()
        presenter.showRecording(elapsed: 0)
        setPhase(.recording)

        try await waitUntilStopped(presenter: presenter)

        setPhase(.finishing)
        presenter.dismiss()
        self.presenter = nil
        let video = try await engine.finish()
        if cancelRequested {
            try? FileManager.default.removeItem(at: video.url)
            throw CaptureError.cancelled
        }
        return video
    }

    private func waitForRecordRequest() async throws -> (choice: RecordingCountdownChoice, region: CGRect) {
        while true {
            try throwIfCancelled()
            if let request = recordRequest { return request }
            await waitForSignal()
        }
    }

    private func runCountdown(_ choice: RecordingCountdownChoice, presenter: any RecordingPresenting) async throws {
        var countdown = RecordingCountdown(seconds: choice.seconds)
        guard !countdown.isFinished else { return }
        while !countdown.isFinished {
            setPhase(.countdown(countdown.remaining))
            presenter.showCountdown(countdown.remaining)
            await waitForTick(1)
            try throwIfCancelled()
            countdown.tick()
        }
        presenter.showCountdown(0)
    }

    private func waitUntilStopped(presenter: any RecordingPresenting) async throws {
        let startedAt = environment.now()
        while true {
            try throwIfCancelled()
            if let failure { throw failure }
            if stopRequested { return }
            let elapsed = environment.now() - startedAt
            presenter.updateElapsed(elapsed)
            if elapsed >= environment.maximumDuration {
                stopReason = .timeLimit
                return
            }
            await waitForTick(0.25)
        }
    }

    private func abort() async {
        picker?.cancel()
        picker = nil
        presenter?.dismiss()
        presenter = nil
        if let engine {
            self.engine = nil
            await engine.discard()
        }
    }

    private func finishRun() {
        presenter = nil
        engine = nil
        picker = nil
        setPhase(.idle)
    }

    // MARK: Events

    private var controlActions: RecordingControlActions {
        RecordingControlActions(
            record: { [weak self] choice, region in self?.requestRecord(choice, region) },
            stop: { [weak self] in self?.stop() },
            cancel: { [weak self] in self?.cancel() })
    }

    private func requestRecord(_ choice: RecordingCountdownChoice, _ region: CGRect) {
        guard phase == .ready, recordRequest == nil, !cancelRequested else { return }
        recordRequest = (choice, region)
        signal()
    }

    private func handle(_ event: RecordingEngineEvent) {
        switch event {
        case .failed(let error):
            failure = failure ?? (error as? CaptureError) ?? .failed(error.localizedDescription)
        case .stoppedBySystem:
            stopRequested = true
            stopReason = stopReason ?? .system
        }
        signal()
    }

    private func setPhase(_ newPhase: RecordingPhase) {
        guard phase != newPhase else { return }
        phase = newPhase
        onPhaseChanged?(newPhase)
    }

    private func throwIfCancelled() throws {
        if cancelRequested { throw CaptureError.cancelled }
    }

    // MARK: Waiting

    private var isInterrupted: Bool { cancelRequested || stopRequested || failure != nil }

    /// Suspends until `signal()` was called since the last wait. Only one task waits at a time.
    private func waitForSignal() async {
        if signaled {
            signaled = false
            return
        }
        await withCheckedContinuation { waiter = $0 }
    }

    private func signal() {
        if let waiter {
            self.waiter = nil
            waiter.resume()
        } else {
            signaled = true
        }
    }

    /// Returns after `seconds`, or earlier once the session is cancelled, stopped or has failed.
    private func waitForTick(_ seconds: TimeInterval) async {
        tickFired = false
        let sleep = environment.sleep
        let sleeper = Task { [weak self] in
            do { try await sleep(seconds) } catch { return }
            self?.tickFired = true
            self?.signal()
        }
        while !tickFired, !isInterrupted { await waitForSignal() }
        sleeper.cancel()
    }
}
