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
/// After the region is picked the session looks at it about ten times a second. When the content has scrolled and
/// settled (or moved half a frame) it grabs a frame and hands it to `ScrollStitcher`. A frame that can't be joined
/// cleanly pauses the capture with a warning until the user resumes, undoes, retries or finishes. Nothing is
/// written to disk. A session is single-use.
@MainActor
public final class ScrollCaptureSession: ScrollingCapture {
    public private(set) var phase: ScrollCapturePhase = .idle
    public var onPhaseChanged: ((ScrollCapturePhase) -> Void)?

    private let snapToEdges: Bool
    private let showsCursor: Bool
    private let environment: ScrollCaptureEnvironment

    private var picker: (any RegionPicking)?
    private var presenter: (any ScrollCapturePresenting)?
    private var stitcher: ScrollStitcher
    private var policy = ScrollGrabPolicy()
    private var reference: ScrollSignature?
    private var warning: ScrollStitchWarning?

    private var hasStarted = false
    private var isFinished = false
    private var cancelRequested = false
    private var finishRequested = false
    private var pendingCommands: [Command] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var signaled = false
    private var tickFired = false

    private enum Command { case undo, resume, retry }

    public convenience init(snapToEdges: Bool = false, showsCursor: Bool = false) {
        self.init(snapToEdges: snapToEdges, showsCursor: showsCursor, environment: .live)
    }

    init(snapToEdges: Bool, showsCursor: Bool, environment: ScrollCaptureEnvironment) {
        self.snapToEdges = snapToEdges
        self.showsCursor = showsCursor
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

        while true {
            try throwIfCancelled()
            try await applyCommands(source)
            if finishRequested { break }
            if warning == nil {
                try await look(at: source)
                if finishRequested { break }
            }
            if warning == nil {
                await waitForTick(environment.pollInterval)
            } else {
                await waitForSignal()
            }
        }

        setPhase(.finishing)
        if stitcher.isEmpty { _ = stitcher.add(try await source.frame()) }
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
        guard policy.shouldGrab(signature, at: environment.now(), reference: reference) else { return }
        try await grab(source)
    }

    private func grab(_ source: any ScrollFrameSource) async throws {
        let frame = try await source.frame()
        try throwIfCancelled()
        let step = stitcher.add(frame)
        reference = try await source.signature()
        if let warning = step.warning, warning.pausesCapture {
            pause(warning)
        } else if step.addedRows > 0 || stitcher.frameCount == 1 {
            publish()
        }
    }

    private func applyCommands(_ source: any ScrollFrameSource) async throws {
        while !pendingCommands.isEmpty {
            let command = pendingCommands.removeFirst()
            switch command {
            case .undo:
                guard stitcher.undoLast() else { continue }
                // Wait for the content to move again: the screen still shows the frame that was just removed.
                reference = try await source.signature()
                policy.reset()
                resumeCapturing()
            case .retry:
                guard stitcher.undoLast() else { continue }
                policy.reset()
                resumeCapturing()
                try await grab(source)
            case .resume:
                // Continues from what is on screen now, which the user may have scrolled back to.
                guard warning != nil, warning != .heightLimit else { continue }
                policy.reset()
                resumeCapturing()
                try await grab(source)
            }
        }
    }

    private func pause(_ warning: ScrollStitchWarning) {
        self.warning = warning
        setPhase(.paused)
        publish()
    }

    private func resumeCapturing() {
        warning = stitcher.isAtLimit ? .heightLimit : nil
        setPhase(warning == nil ? .capturing : .paused)
        publish()
    }

    private func publish() {
        let status = ScrollCaptureStatus(frames: stitcher.frameCount, height: stitcher.height,
                                         progress: stitcher.progress, isNearLimit: stitcher.isNearLimit,
                                         canUndo: stitcher.canUndo, warning: warning)
        presenter?.update(status, preview: stitcher.thumbnail(maxWidth: 360, maxHeight: 480))
    }

    private func finishRun() {
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
        if cancelRequested { throw CaptureError.cancelled }
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
