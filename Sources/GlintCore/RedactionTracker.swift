import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// One decoded recording frame prepared for tracking.
public struct TrackingFrame: @unchecked Sendable {
    /// Presentation time in source seconds.
    public var time: TimeInterval
    /// Downscaled 8-bit luma of the oriented frame. Small enough to keep a two-second backward window in memory.
    public var luma: CGImage
    /// Oriented source frame size. Rects passed to and from trackers use these pixels, origin top-left.
    public var sourceSize: CGSize

    public init(time: TimeInterval, luma: CGImage, sourceSize: CGSize) {
        self.time = time; self.luma = luma; self.sourceSize = sourceSize
    }
}

/// Where a tracked rect was found on one frame. `confidence` runs from 0 (lost) to 1.
public struct FrameTrackerObservation: Equatable, Sendable {
    public var rect: CGRect
    public var confidence: Double

    public init(rect: CGRect, confidence: Double) {
        self.rect = rect; self.confidence = confidence
    }
}

/// Follows one region from frame to frame in a single direction. A new tracker is made for each direction.
public protocol FrameTracker: AnyObject {
    func start(on frame: TrackingFrame, rect: CGRect) throws
    /// `nil` when the region is lost.
    func track(_ frame: TrackingFrame) throws -> FrameTrackerObservation?
}

/// Supplies decoded frames in presentation order.
public protocol TrackingFrameSource: Sendable {
    /// Calls `body` with every frame shown during `range`, starting with the frame already on screen at
    /// `range.lowerBound`. Returning false stops reading. Calls are serial and finish before this method returns.
    func readFrames(in range: ClosedRange<TimeInterval>, _ body: @escaping (TrackingFrame) throws -> Bool) async throws
}

/// Reads frames from a recording with `AVAssetReader`, oriented like the editor and exporters show them.
public struct AssetTrackingFrameSource: TrackingFrameSource {
    public let url: URL
    /// Longest side of the luma frames handed to trackers.
    public var maxDimension: CGFloat

    /// How far before a range to start reading so the frame on screen at its start is included.
    static let leadIn: TimeInterval = 1

    public init(url: URL, maxDimension: CGFloat = 1024) {
        self.url = url
        self.maxDimension = maxDimension
    }

    public func readFrames(in range: ClosedRange<TimeInterval>, _ body: @escaping (TrackingFrame) throws -> Bool) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingExportError.sourceUnreadable("it has no video track.")
        }
        let trackTransform = try await track.load(.preferredTransform)
        // Track transforms use top-left coordinates; Core Image uses bottom-left coordinates.
        let transform = CGAffineTransform(a: trackTransform.a, b: -trackTransform.b,
                                          c: -trackTransform.c, d: trackTransform.d,
                                          tx: trackTransform.tx, ty: -trackTransform.ty)
        let reader = try AVAssetReader(asset: asset)
        let start = max(0, range.lowerBound - Self.leadIn)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600_000),
                                       end: CMTime(seconds: range.upperBound + 0.001, preferredTimescale: 600_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecordingExportError.encodingFailed("couldn't create a video reader") }
        reader.add(output)
        let maxDimension = maxDimension
        try await BlockingWork.run { cancellation in
            try cancellation.check()
            guard reader.startReading() else {
                throw RecordingExportError.encodingFailed(reader.error?.localizedDescription ?? "couldn't start reading")
            }
            defer { reader.cancelReading() }
            cancellation.onCancel { reader.cancelReading() }
            let context = CIContext(options: [.cacheIntermediates: false])
            var held: TrackingFrame?
            var finished = false
            while !finished {
                try cancellation.check()
                let frame: TrackingFrame?? = try autoreleasepool {
                    guard let sample = output.copyNextSampleBuffer() else { return .none }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    guard time.isNumeric, let buffer = CMSampleBufferGetImageBuffer(sample) else { return .some(nil) }
                    return .some(try Self.lumaFrame(buffer, time: time.seconds, transform: transform,
                                                    maxDimension: maxDimension, context: context))
                }
                guard let next = frame else { break }
                guard let next else { continue }
                if next.time <= range.lowerBound {
                    held = next
                    continue
                }
                if let pending = held {
                    held = nil
                    if try !body(pending) { finished = true; break }
                }
                if next.time > range.upperBound { break }
                if try !body(next) { finished = true }
            }
            // Cancelling stops the reader early, which must not look like the end of the clip.
            try cancellation.check()
            if !finished, let pending = held { _ = try body(pending) }
            if reader.status == .failed {
                throw RecordingExportError.encodingFailed(reader.error?.localizedDescription ?? "the reader stopped")
            }
        }
    }

    static func lumaFrame(_ buffer: CVPixelBuffer, time: TimeInterval, transform: CGAffineTransform,
                          maxDimension: CGFloat, context: CIContext) throws -> TrackingFrame {
        let oriented = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
        let extent = oriented.extent.integral
        let normalized = oriented.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scale = min(1, maxDimension / max(extent.width, extent.height, 1))
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let size = CGSize(width: max(1, (extent.width * scale).rounded()), height: max(1, (extent.height * scale).rounded()))
        guard let luma = context.createCGImage(scaled, from: CGRect(origin: .zero, size: size), format: .L8,
                                               colorSpace: CGColorSpaceCreateDeviceGray()) else {
            throw RecordingExportError.encodingFailed("couldn't prepare a frame for tracking")
        }
        return TrackingFrame(time: time, luma: luma, sourceSize: extent.size)
    }
}

/// Limits beyond which a tracked position is not trusted and the frame is flagged instead.
public struct RedactionTrackingThresholds: Sendable {
    public var minimumConfidence: Double = 0.5
    /// Largest centre movement between consecutive frames, as a multiple of the rect's longer side.
    public var maximumJump: CGFloat = 0.75
    /// Movement always allowed, in pixels, so tiny rects can still move.
    public var minimumJumpAllowance: CGFloat = 6
    /// Largest change in width or height between consecutive frames.
    public var maximumScaleChange: CGFloat = 1.5

    public init() {}
}

/// What the user asked to track.
public struct RedactionTrackingRequest: Sendable {
    /// The time the user placed the redaction at; the frame on screen then is the anchor frame.
    public var anchorTime: TimeInterval
    public var anchorRect: CGRect
    /// The redaction's visible range within the source, which is all that is analysed.
    public var range: ClosedRange<TimeInterval>

    public init(anchorTime: TimeInterval, anchorRect: CGRect, range: ClosedRange<TimeInterval>) {
        self.anchorTime = anchorTime; self.anchorRect = anchorRect.standardized; self.range = range
    }
}

public enum RedactionTrackingError: LocalizedError, Equatable {
    case noFrames
    case invalidRequest

    public var errorDescription: String? {
        switch self {
        case .noFrames: return "The recording has no frames to track in this range."
        case .invalidRequest: return "Place the redaction inside the recording before tracking it."
        }
    }
}

/// Follows a redaction forwards and backwards from the frame it was placed on and records keyframes. Anything it
/// is unsure about becomes an unresolved interval rather than a guess, from that frame to the end of the range in
/// that direction, so export stays blocked until the user reviews it.
///
/// Runs entirely on the Mac; nothing leaves it. Reading forwards streams the clip; reading backwards decodes it in
/// windows of at most `backwardWindow` seconds so memory stays bounded.
public struct RedactionTracker: Sendable {
    public typealias Progress = @Sendable (Double) -> Void

    public static let backwardWindow: TimeInterval = 2

    let source: TrackingFrameSource
    let makeTracker: @Sendable () -> FrameTracker
    let thresholds: RedactionTrackingThresholds

    public init(source: TrackingFrameSource, thresholds: RedactionTrackingThresholds = RedactionTrackingThresholds(),
                makeTracker: @escaping @Sendable () -> FrameTracker) {
        self.source = source
        self.thresholds = thresholds
        self.makeTracker = makeTracker
    }

    /// Tracks with Apple's Vision framework.
    public init(url: URL) {
        self.init(source: AssetTrackingFrameSource(url: url)) { VisionFrameTracker() }
    }

    public func track(_ request: RedactionTrackingRequest, progress: Progress? = nil) async throws -> RedactionTrack {
        let range = request.range
        guard range.lowerBound.isFinite, range.upperBound.isFinite, range.upperBound > range.lowerBound,
              request.anchorTime.isFinite, request.anchorRect.isFiniteRect,
              request.anchorRect.width >= 1, request.anchorRect.height >= 1 else {
            throw RedactionTrackingError.invalidRequest
        }
        let anchorTime = min(max(request.anchorTime, range.lowerBound), range.upperBound)
        let total = range.upperBound - range.lowerBound
        let report = ProgressCounter(total: total, handler: progress)

        guard let anchor = try await anchorFrame(at: anchorTime, in: range) else { throw RedactionTrackingError.noFrames }
        let anchorKeyframe = RedactionKeyframe(time: anchor.time, rect: request.anchorRect, source: .tracked)
        var keyframes = [anchorKeyframe]
        var intervals: [RedactionUncertainInterval] = []

        // Forwards, streaming.
        let forward = makeTracker()
        try forward.start(on: anchor, rect: request.anchorRect)
        var previous = anchorKeyframe
        try await source.readFrames(in: anchor.time...max(anchor.time, range.upperBound)) { frame in
            try Task.checkCancellation()
            guard frame.time > anchor.time else { return true }
            guard frame.time < range.upperBound else { return false }
            report.advance(to: frame.time - anchor.time, part: .forward)
            if let rect = accepted(try forward.track(frame), after: previous, frameSize: frame.sourceSize) {
                previous = RedactionKeyframe(time: frame.time, rect: rect, source: .tracked)
                keyframes.append(previous)
                return true
            }
            intervals.append(RedactionUncertainInterval(start: frame.time, end: range.upperBound,
                                                        anchorTime: previous.time, anchorRect: previous.rect))
            return false
        }
        report.finish(.forward, span: range.upperBound - anchor.time)

        // Backwards, window by window.
        let backward = makeTracker()
        try backward.start(on: anchor, rect: request.anchorRect)
        previous = anchorKeyframe
        // `earliest` is the earliest frame examined so far. A window may hold no new frame (a gap in a
        // variable-frame-rate recording), so keep stepping back; the frame on screen at a window's start counts too.
        var earliest = anchor.time
        var windowEnd = anchor.time
        var lost = false
        while !lost, earliest > range.lowerBound, windowEnd > range.lowerBound {
            try Task.checkCancellation()
            let windowStart = max(range.lowerBound, windowEnd - Self.backwardWindow)
            var frames: [TrackingFrame] = []
            let before = earliest
            try await source.readFrames(in: windowStart...windowEnd) { frame in
                guard frame.time < before else { return false }
                frames.append(frame)
                return true
            }
            for frame in frames.reversed() {
                try Task.checkCancellation()
                report.advance(to: anchor.time - max(frame.time, range.lowerBound), part: .backward)
                if let rect = accepted(try backward.track(frame), after: previous, frameSize: frame.sourceSize) {
                    previous = RedactionKeyframe(time: frame.time, rect: rect, source: .tracked)
                    keyframes.append(previous)
                    earliest = frame.time
                } else {
                    // The flagged frame is shown until `previous` replaces it.
                    if previous.time > range.lowerBound {
                        intervals.append(RedactionUncertainInterval(start: range.lowerBound, end: previous.time,
                                                                    anchorTime: previous.time, anchorRect: previous.rect))
                    }
                    lost = true
                    break
                }
            }
            windowEnd = min(windowStart, earliest)
        }
        // Whatever was on screen before the earliest examined frame was never seen: flag it rather than assume it.
        if !lost, earliest - range.lowerBound > RedactionTrack.frameTolerance {
            intervals.append(RedactionUncertainInterval(start: range.lowerBound, end: earliest,
                                                        anchorTime: previous.time, anchorRect: previous.rect))
        }
        report.finish(.backward, span: anchor.time - range.lowerBound)

        return RedactionTrack(keyframes: keyframes, uncertainIntervals: intervals,
                              analyzedRange: AnnotationTiming(start: range.lowerBound, end: range.upperBound),
                              frameBounds: CGRect(origin: .zero, size: anchor.sourceSize))
    }

    /// The frame on screen at `time`: the last one starting at or before it, else the first one after it.
    private func anchorFrame(at time: TimeInterval, in range: ClosedRange<TimeInterval>) async throws -> TrackingFrame? {
        var candidate: TrackingFrame?
        try await source.readFrames(in: max(range.lowerBound, time - Self.backwardWindow)...range.upperBound) { frame in
            if frame.time <= time + RedactionTrack.keyframeMergeDistance || candidate == nil {
                candidate = frame
                return frame.time <= time
            }
            return false
        }
        return candidate
    }

    /// The rect to keep for an observation, or nil when it should be flagged.
    func accepted(_ observation: FrameTrackerObservation?, after previous: RedactionKeyframe,
                  frameSize: CGSize) -> CGRect? {
        guard let observation, observation.confidence.isFinite,
              observation.confidence >= thresholds.minimumConfidence else { return nil }
        let rect = observation.rect.standardized
        guard rect.isFiniteRect, rect.width >= 1, rect.height >= 1 else { return nil }
        // Content leaving the frame can't be followed reliably, and part of it may already be outside the rect.
        guard CGRect(origin: .zero, size: frameSize).insetBy(dx: -1, dy: -1).contains(rect) else { return nil }
        let last = previous.rect
        let allowance = max(thresholds.minimumJumpAllowance, thresholds.maximumJump * max(last.width, last.height))
        guard hypot(rect.midX - last.midX, rect.midY - last.midY) <= allowance else { return nil }
        let widthRatio = rect.width / max(last.width, 1), heightRatio = rect.height / max(last.height, 1)
        let limit = thresholds.maximumScaleChange
        guard widthRatio <= limit, widthRatio >= 1 / limit, heightRatio <= limit, heightRatio >= 1 / limit else {
            return nil
        }
        // Trackers tend to shrink boxes around content; never cover less than the previous size.
        let width = max(rect.width, last.width), height = max(rect.height, last.height)
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}

/// Reports combined forward and backward progress, monotonically.
private final class ProgressCounter: @unchecked Sendable {
    enum Part { case forward, backward }

    private let total: TimeInterval
    private let handler: RedactionTracker.Progress?
    private var done: [Part: TimeInterval] = [:]
    private var reported = 0.0

    init(total: TimeInterval, handler: RedactionTracker.Progress?) {
        self.total = max(total, 1e-6)
        self.handler = handler
    }

    func advance(to span: TimeInterval, part: Part) {
        done[part] = max(done[part] ?? 0, span)
        let fraction = min(1, ((done[.forward] ?? 0) + (done[.backward] ?? 0)) / total)
        guard fraction > reported + 0.005 || fraction >= 1 else { return }
        reported = fraction
        handler?(fraction)
    }

    func finish(_ part: Part, span: TimeInterval) {
        advance(to: max(span, 0), part: part)
    }
}
