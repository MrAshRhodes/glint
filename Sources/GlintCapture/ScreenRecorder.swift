import AVFoundation
import CoreMedia
import GlintCore
import ScreenCaptureKit

/// Records one display region with ScreenCaptureKit and encodes it through `FrameWriter`.
///
/// Frames arrive on a private serial queue and go straight into the encoder; the writer is only touched
/// from that queue, or after it has been drained, so no lock is held while encoding.
final class ScreenRecorder: NSObject, RecordingEngine, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private enum State { case idle, running, stopping, closed }

    private let target: RecordingTarget
    private let queue = DispatchQueue(label: "io.github.mrashrhodes.glint.recording", qos: .userInitiated)
    private let lock = NSLock()
    private var state = State.idle
    private var writer: FrameWriter?
    private var stream: SCStream?
    private var handler: (@Sendable (RecordingEngineEvent) -> Void)?
    private var systemStopTime: CMTime?
    private var firstFrameTime: TimeInterval?

    var firstFrameHostTime: TimeInterval? { lock.withLock { firstFrameTime } }

    init(target: RecordingTarget) {
        self.target = target
    }

    func setEventHandler(_ handler: @escaping @Sendable (RecordingEngineEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func start() async throws {
        let writer: FrameWriter
        do {
            writer = try FrameWriter(url: target.outputURL, width: target.geometry.outputWidth,
                                     height: target.geometry.outputHeight)
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }
        let isFirstStart = lock.withLock { () -> Bool in
            guard state == .idle else { return false }
            self.writer = writer
            return true
        }
        guard isFirstStart else {
            writer.cancel()
            throw CaptureError.failed("The recording was already started.")
        }
        do {
            let content = try await WindowEnumerator.shareableContent()
            guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
                throw CaptureError.noDisplay
            }
            let stream = SCStream(filter: Self.filter(for: display, in: content),
                                  configuration: Self.configuration(for: target), delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            lock.withLock {
                self.stream = stream
                state = .running
            }
            try await stream.startCapture()
        } catch {
            await discard()
            throw Self.captureError(from: error)
        }
    }

    func finish() async throws -> RecordedVideo {
        let stopTime = FrameWriter.hostTime()
        let running = lock.withLock { () -> (SCStream, FrameWriter, CMTime)? in
            guard state == .running, let stream, let writer else { return nil }
            state = .stopping
            return (stream, writer, systemStopTime ?? stopTime)
        }
        guard let (stream, writer, endTime) = running else {
            throw CaptureError.failed("The recording is not running.")
        }
        await halt(stream)
        do {
            let summary = try await writer.finish(at: endTime)
            let start = writer.startTime.map(\.seconds)
            lock.withLock {
                state = .closed
                firstFrameTime = start
            }
            let duration = await Self.fileDuration(of: target.outputURL) ?? summary.duration
            return RecordedVideo(url: target.outputURL, duration: duration, pixelSize: summary.pixelSize)
        } catch {
            lock.withLock { state = .closed }
            throw CaptureError.failed(error.localizedDescription)
        }
    }

    func discard() async {
        let previous = lock.withLock { () -> (State, SCStream?, FrameWriter?) in
            let snapshot = (state, stream, writer)
            if state != .closed { state = .closed }
            return snapshot
        }
        if let stream = previous.1, previous.0 == .running { await halt(stream) }
        // Wait for a frame that is still being encoded before the file goes away.
        await drainQueue()
        previous.2?.cancel()
    }

    // MARK: SCStreamOutput, SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let writer = lock.withLock({ state == .running ? self.writer : nil }) else { return }
        if writer.append(sampleBuffer) == .failed {
            report(.failed(CaptureError.failed((writer.failure ?? FrameWriterError.writerFailed("Unknown error"))
                .localizedDescription)))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let now = FrameWriter.hostTime()
        let isRunning = lock.withLock { () -> Bool in
            guard state == .running else { return false }
            systemStopTime = now
            return true
        }
        // A stop we requested ourselves also lands here; only unexpected ones are reported.
        guard isRunning else { return }
        let code = (error as NSError).code
        let byUser = (error as NSError).domain == SCStreamErrorDomain
            && (code == Self.userStoppedCode || code == Self.systemStoppedCode)
        report(byUser ? .stoppedBySystem : .failed(Self.captureError(from: error)))
    }

    // MARK: Helpers

    private static let userStoppedCode = -3817
    private static let systemStoppedCode = -3821

    private func report(_ event: RecordingEngineEvent) {
        lock.withLock { handler }?(event)
    }

    private func halt(_ stream: SCStream) async {
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .screen)
        await drainQueue()
    }

    private func drainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    private static func fileDuration(of url: URL) async -> TimeInterval? {
        guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric, time.seconds > 0 else {
            return nil
        }
        return time.seconds
    }

    /// Everything of this app is left out: the frame, control bar and countdown never reach the video.
    static func filter(for display: SCDisplay, in content: SCShareableContent) -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        let own = content.applications.filter { $0.processID == pid || (bundleID != nil && $0.bundleIdentifier == bundleID) }
        guard own.isEmpty else { return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []) }
        return SCContentFilter(display: display,
                               excludingWindows: content.windows.filter { $0.owningApplication?.processID == pid })
    }

    static func configuration(for target: RecordingTarget) -> SCStreamConfiguration {
        let geometry = target.geometry
        let config = SCStreamConfiguration()
        config.sourceRect = geometry.sourceRect
        config.width = geometry.outputWidth
        config.height = geometry.outputHeight
        // Only a region beyond the encoder limits is scaled; otherwise source and output pixels match one to one.
        config.scalesToFit = geometry.isDownscaled
        config.preservesAspectRatio = !geometry.isDownscaled
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(RecordingLimits.frameRate))
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = target.showsCursor
        config.capturesAudio = false
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    static func captureError(from error: Error) -> CaptureError {
        if let error = error as? CaptureError { return error }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return .permissionDenied
        }
        return .failed(error.localizedDescription)
    }
}
