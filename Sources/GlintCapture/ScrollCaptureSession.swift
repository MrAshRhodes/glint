import AppKit
import GlintCore

/// A capture that keeps going until it is finished; the app shell holds on to it so a second press of the
/// shortcut can finish it.
@MainActor
public protocol ScrollingCapture: AnyObject {
    /// Runs the whole capture and returns the stitched image. Throws `CaptureError.cancelled` on Esc or `cancel()`.
    func run() async throws -> CaptureResult
    /// Finishes with what has been stitched so far. Before anything was captured it cancels instead.
    func finish()
    func cancel()
}

public enum ScrollCapturePhase: Equatable, Sendable {
    case idle, selecting, capturing, paused, finishing
}

/// One scrolling capture: pick a region, scroll through it, get one tall image.
///
/// Automatic scrolling advances in small steps, waiting for a settled, stitched frame before moving again.
/// In manual mode the session looks about ten times a second and grabs after settling or half a frame of travel.
/// A frame that can't be joined cleanly pauses with a warning until the user resumes, undoes, retries or finishes. Nothing is
/// written to disk. A session is single-use.
@MainActor
public final class ScrollCaptureSession: ScrollingCapture {
    public private(set) var phase: ScrollCapturePhase = .idle
    public var onPhaseChanged: ((ScrollCapturePhase) -> Void)?

    private let snapToEdges: Bool
    private let showsCursor: Bool
    private let autoScroll: Bool
    private let environment: ScrollCaptureEnvironment

    private var picker: (any RegionPicking)?
    private var presenter: (any ScrollCapturePresenting)?
    private var stitcher: ScrollStitcher
    private var policy = ScrollGrabPolicy()
    private var reference: ScrollSignature?
    private var warning: ScrollStitchWarning?
    private var scroller: (any ScrollDriving)?
    private var automaticStop: String?
    private var manualFallback: String?
    private var automaticStarted: TimeInterval = 0
    private var automaticSteps = 0
    private var unchangedSteps = 0
    private var pacePolicy = ScrollPacePolicy()
    private var pace: ScrollCapturePace = .ready
    private var skipFinalGrab = false
    private var preview: CGImage?

    private var hasStarted = false
    private var isFinished = false
    private var cancelRequested = false
    private var finishRequested = false
    private var pendingCommands: [Command] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var signaled = false
    private var tickFired = false

    private enum Command { case undo, resume, retry }

    public convenience init(snapToEdges: Bool = false, showsCursor: Bool = false, autoScroll: Bool = true) {
        self.init(snapToEdges: snapToEdges, showsCursor: showsCursor, autoScroll: autoScroll, environment: .live)
    }

    init(snapToEdges: Bool, showsCursor: Bool, autoScroll: Bool = true, environment: ScrollCaptureEnvironment) {
        self.snapToEdges = snapToEdges
        self.showsCursor = showsCursor
        self.autoScroll = autoScroll
        self.environment = environment
        stitcher = ScrollStitcher(limits: environment.limits)
    }

    public func run() async throws -> CaptureResult {
        guard !hasStarted else { throw CaptureError.failed("This scrolling capture session was already used.") }
        hasStarted = true
        defer { isFinished = true }
        return try await withTaskCancellationHandler {
            do {
                let result = try await capture()
                finishRun()
                return result
            } catch {
                picker?.cancel()
                finishRun()
                throw error
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
    }

    public func finish() {
        guard !isFinished else { return }
        switch phase {
        case .capturing, .paused:
            stopAutomaticScrolling()
            finishRequested = true
            signal()
        case .finishing:
            break
        case .idle, .selecting:
            cancel()
        }
    }

    public func cancel() {
        guard !isFinished else { return }
        cancelRequested = true
        stopAutomaticScrolling()
        picker?.cancel()
        signal()
    }

    // MARK: Flow

    private func capture() async throws -> CaptureResult {
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
        let region = RecordingRegion(rect: RegionAdjustment.clamped(picked.rect, to: picked.display.frame),
                                     display: picked.display)

        let presenter = environment.makePresenter()
        self.presenter = presenter
        presenter.show(region: region, actions: controlActions)
        setPhase(.capturing)
        let source = try await environment.makeSource(region, showsCursor)
        try throwIfCancelled()
        try await grab(source)
        if autoScroll, !isInterrupted, !isPaused {
            do {
                scroller = try environment.makeScroller(region)
                automaticStarted = environment.now()
                publish()
            } catch {
                fallBackToManual("Automatic scrolling is unavailable. \(error.localizedDescription) "
                    + "Manual capture is active. Scroll slowly, then choose Done.")
            }
        }

        while true {
            try throwIfCancelled()
            try await applyCommands(source)
            if finishRequested {
                // A short final scroll may still be below the polling/settling threshold. Do not lose it.
                // An explicit Done on a warning keeps the preview the user has already been asked to review.
                if skipFinalGrab, !isPaused {
                    let signature = try await source.signature()
                    try throwIfCancelled()
                    skipFinalGrab = reference.map { signature.difference(from: $0) <= policy.changeThreshold } ?? false
                }
                if !isPaused, !skipFinalGrab {
                    try await grab(source)
                    if isPaused { continue }
                }
                break
            }
            if scroller != nil, !isPaused {
                try await advanceAutomatically(source, region: region)
            } else if !isPaused {
                try await look(at: source)
            }
            if isInterrupted { continue }
            if !isPaused {
                await waitForTick(environment.pollInterval)
            } else {
                await waitForSignal()
            }
        }

        setPhase(.finishing)
        try throwIfCancelled()
        guard let image = stitcher.makeImage() else { throw CaptureError.failed("The scrolling capture is empty.") }
        presenter.dismiss()
        self.presenter = nil
        return CaptureResult(image: image, scale: region.display.scale, displayID: region.display.id,
                             rect: region.rect, kind: .scrolling, windowInfo: nil)
    }

    /// Takes a look at the region and grabs a frame when the policy says the content has moved enough.
    private func look(at source: any ScrollFrameSource) async throws {
        let signature = try await source.signature()
        try throwIfCancelled()
        if let reference, signature.difference(from: reference) > policy.changeThreshold { skipFinalGrab = false }
        let nextPace = pacePolicy.observe(signature, at: environment.now())
        if pace != nextPace {
            pace = nextPace
            publish()
        }
        guard policy.shouldGrab(signature, at: environment.now(), reference: reference) else { return }
        try await grab(source)
    }

    @discardableResult
    private func grab(_ source: any ScrollFrameSource) async throws -> ScrollStitchStep {
        let frame = try await source.frame()
        try throwIfCancelled()
        let step = stitcher.add(frame)
        scrollCaptureLog.info(
            "Frame \(self.stitcher.frameCount, privacy: .public): +\(step.addedRows, privacy: .public) rows, height \(self.stitcher.height, privacy: .public), warning \(String(describing: step.warning), privacy: .public), automatic \(self.scroller != nil, privacy: .public)")
        // The reference must describe the accepted snapshot itself: a second look could already show content
        // scrolled past the stitched image, and holding still there would then never grab the rest.
        if step.addedRows > 0 {
            guard let accepted = source.signature(of: frame) else {
                throw CaptureError.failed("Could not read the screen.")
            }
            reference = accepted
            skipFinalGrab = false
            preview = stitcher.thumbnail(maxWidth: 360, maxHeight: 480)
        }
        if let warning = step.warning, warning.pausesCapture {
            pause(warning)
        } else if stitcher.isAtLimit {
            pause(.heightLimit)
        } else if step.addedRows > 0 || stitcher.frameCount == 1 {
            publish()
        }
        return step
    }

    /// No next wheel event can be posted until the previous step has been captured and accepted.
    private func advanceAutomatically(_ source: any ScrollFrameSource, region: RecordingRegion) async throws {
        let timing = environment.automaticTiming
        guard automaticSteps < timing.maxSteps, environment.now() - automaticStarted < timing.maxDuration else {
            pauseAutomatic("Automatic scrolling reached its safety limit. Check the preview; choose Done, "
                + "or scroll manually and Resume to continue.")
            return
        }
        let fixedRows = (stitcher.sticky?.top ?? 0) + (stitcher.sticky?.bottom ?? 0)
        let scrollingFraction = Double(max(stitcher.frameHeight - fixedRows, 1))
            / Double(max(stitcher.frameHeight, 1))
        let points = min(max(region.rect.height * scrollingFraction * 0.2, 1), 120)
        do {
            try scroller?.scroll(by: points)
        } catch {
            pauseAutomatic("Automatic scrolling stopped. \(error.localizedDescription) "
                + "Scroll manually, then choose Resume.")
            return
        }
        automaticSteps += 1
        let started = environment.now()
        var last: ScrollSignature?
        var stableSince = started
        // Done stops future events immediately, but lets this already-posted step settle before the final grab.
        while !cancelRequested, pendingCommands.isEmpty {
            await waitForTick(environment.pollInterval, finishingStep: true)
            try throwIfCancelled()
            guard pendingCommands.isEmpty else { return }
            let signature = try await source.signature()
            try throwIfCancelled()
            guard pendingCommands.isEmpty else { return }
            let now = environment.now()
            if last.map({ signature.difference(from: $0) > policy.changeThreshold }) ?? true { stableSince = now }
            last = signature
            let changed = reference.map { signature.difference(from: $0) > policy.changeThreshold } ?? true
            let timedOut = now - started >= timing.responseTimeout
            if now - stableSince >= timing.settleInterval, changed || timedOut {
                scrollCaptureLog.debug(
                    "Automatic step \(self.automaticSteps, privacy: .public) settled after \(now - started, privacy: .public)s, changed \(changed, privacy: .public)")
                let step = try await grab(source)
                guard !isPaused, !isInterrupted else { return }
                unchangedSteps = step.addedRows > 0 ? 0 : unchangedSteps + 1
                if unchangedSteps >= timing.noMovementLimit {
                    fallBackToManual("No further automatic scrolling was detected. Check that the bottom was reached, "
                        + "then choose Done. Manual capture is still active; scroll slowly to capture more.")
                }
                return
            }
            if timedOut {
                pauseAutomatic("The content did not settle. Wait for it to stop moving, then scroll manually "
                    + "and choose Resume, or choose Done to keep the preview.")
                return
            }
        }
    }

    private func applyCommands(_ source: any ScrollFrameSource) async throws {
        while !pendingCommands.isEmpty {
            let command = pendingCommands.removeFirst()
            switch command {
            case .undo:
                guard stitcher.undoLast() else { continue }
                stopAutomaticScrolling()
                skipFinalGrab = true
                preview = stitcher.thumbnail(maxWidth: 360, maxHeight: 480)
                // Wait for the content to move again: the screen still shows the frame that was just removed.
                reference = try await source.signature()
                policy.reset()
                resumeCapturing()
            case .retry:
                guard stitcher.undoLast() else { continue }
                stopAutomaticScrolling()
                preview = stitcher.thumbnail(maxWidth: 360, maxHeight: 480)
                policy.reset()
                resumeCapturing()
                try await grab(source)
            case .resume:
                // Continues from what is on screen now, which the user may have scrolled back to.
                guard isPaused, warning != .heightLimit else { continue }
                policy.reset()
                resumeCapturing()
                try await grab(source)
            }
        }
    }

    private func pause(_ warning: ScrollStitchWarning) {
        stopAutomaticScrolling()
        finishRequested = false
        self.warning = warning
        if warning == .tooFast { pace = .tooFast }
        setPhase(.paused)
        publish()
    }

    private func pauseAutomatic(_ message: String) {
        scrollCaptureLog.notice("Automatic scrolling paused: \(message, privacy: .public)")
        stopAutomaticScrolling()
        finishRequested = false
        automaticStop = message
        setPhase(.paused)
        publish()
    }

    private func fallBackToManual(_ message: String) {
        scrollCaptureLog.notice("Manual fallback: \(message, privacy: .public)")
        stopAutomaticScrolling()
        manualFallback = message
        policy.reset()
        pacePolicy.reset()
        pace = .ready
        publish()
    }

    private func stopAutomaticScrolling() {
        scroller?.stop()
        scroller = nil
    }

    private var isPaused: Bool { warning != nil || automaticStop != nil }

    private func resumeCapturing() {
        automaticStop = nil
        pacePolicy.reset()
        pace = .ready
        warning = stitcher.isAtLimit ? .heightLimit : nil
        setPhase(warning == nil ? .capturing : .paused)
        publish()
    }

    private func publish() {
        let status = ScrollCaptureStatus(frames: stitcher.frameCount, height: stitcher.height,
                                         progress: stitcher.progress, isNearLimit: stitcher.isNearLimit,
                                         canUndo: stitcher.canUndo, warning: warning,
                                         isAutomatic: scroller != nil, pace: pace, automaticStop: automaticStop,
                                         manualFallback: manualFallback)
        presenter?.update(status, preview: preview)
    }

    private func finishRun() {
        stopAutomaticScrolling()
        presenter?.dismiss()
        presenter = nil
        picker = nil
        setPhase(.idle)
    }

    // MARK: Events

    private var controlActions: ScrollCaptureControlActions {
        ScrollCaptureControlActions(
            done: { [weak self] in self?.finish() },
            undo: { [weak self] in self?.enqueue(.undo) },
            cancel: { [weak self] in self?.cancel() },
            resume: { [weak self] in self?.enqueue(.resume) },
            retry: { [weak self] in self?.enqueue(.retry) })
    }

    private func enqueue(_ command: Command) {
        guard phase == .capturing || phase == .paused else { return }
        pendingCommands.append(command)
        signal()
    }

    private func setPhase(_ newPhase: ScrollCapturePhase) {
        guard phase != newPhase else { return }
        phase = newPhase
        onPhaseChanged?(newPhase)
    }

    private func throwIfCancelled() throws {
        if cancelRequested || Task.isCancelled { throw CaptureError.cancelled }
    }

    // MARK: Waiting

    private var isInterrupted: Bool { cancelRequested || finishRequested || !pendingCommands.isEmpty }

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

    /// Returns after `seconds`, or earlier once something asks for attention.
    private func waitForTick(_ seconds: TimeInterval, finishingStep: Bool = false) async {
        tickFired = false
        let sleep = environment.sleep
        let sleeper = Task { [weak self] in
            do { try await sleep(seconds) } catch { return }
            self?.tickFired = true
            self?.signal()
        }
        while !tickFired, !cancelRequested, pendingCommands.isEmpty, finishingStep || !finishRequested {
            await waitForSignal()
        }
        sleeper.cancel()
    }
}
