import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import GlintCore

/// A grey clip with a textured magenta square moving diagonally, so every frame has something to hide.
enum MovingSquareVideo {
    static let size = CGSize(width: 320, height: 180)
    static let fps: Int32 = 15
    static let frames = 45

    /// The square's position in frame `index`, in top-left source pixels.
    static func square(_ index: Int) -> CGRect {
        CGRect(x: 20 + 5 * index, y: 60 + 2 * index, width: 30, height: 30)
    }

    static func time(_ index: Int) -> TimeInterval { Double(index) / Double(fps) }

    /// The index of the frame on screen at `time`.
    static func index(at time: TimeInterval) -> Int {
        min(max(Int((time * Double(fps) + 1e-6).rounded(.down)), 0), frames - 1)
    }

    static func write(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = Int(size.width), height = Int(size.height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw SyntheticVideo.Failure(description: "startWriting failed") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw SyntheticVideo.Failure(description: "no pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw SyntheticVideo.Failure(description: "no pixel buffer") }
            fill(buffer, square: square(index))
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: fps)) else {
                throw SyntheticVideo.Failure(description: "append failed")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw SyntheticVideo.Failure(description: "finish failed") }
    }

    private static func fill(_ buffer: CVPixelBuffer, square: CGRect) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                let p = base + y * stride + x * 4
                let inside = square.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
                let light = ((x - Int(square.minX)) / 6 + (y - Int(square.minY)) / 6) % 2 == 0
                // BGRA: magenta with lighter checks inside the square, flat grey outside.
                let (r, g, b): (UInt8, UInt8, UInt8) = inside ? (light ? (255, 0, 255) : (200, 0, 200)) : (100, 100, 100)
                p[0] = b; p[1] = g; p[2] = r; p[3] = 255
            }
        }
    }

    static func isMagenta(_ p: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        Int(p.0) > 150 && Int(p.2) > 150 && Int(p.1) < 90
    }
}

/// Follows the known motion of `MovingSquareVideo` and fails where told to.
final class ScriptedFrameTracker: FrameTracker {
    let lostWhen: @Sendable (TimeInterval) -> Bool
    let offset: @Sendable (TimeInterval) -> CGFloat
    let onTrack: (@Sendable () -> Void)?
    private(set) var started: (time: TimeInterval, rect: CGRect)?

    init(lostWhen: @escaping @Sendable (TimeInterval) -> Bool = { _ in false },
         offset: @escaping @Sendable (TimeInterval) -> CGFloat = { _ in 0 }, onTrack: (@Sendable () -> Void)? = nil) {
        self.lostWhen = lostWhen; self.offset = offset; self.onTrack = onTrack
    }

    func start(on frame: TrackingFrame, rect: CGRect) throws { started = (frame.time, rect) }

    func track(_ frame: TrackingFrame) throws -> FrameTrackerObservation? {
        onTrack?()
        if lostWhen(frame.time) { return nil }
        let square = MovingSquareVideo.square(MovingSquareVideo.index(at: frame.time))
        return FrameTrackerObservation(rect: square.offsetBy(dx: offset(frame.time), dy: 0), confidence: 0.9)
    }
}

/// Holds a task so a tracker callback can cancel it.
final class TaskBox: @unchecked Sendable {
    var task: Task<RedactionTrack, Error>?
}

@Suite("Tracked redaction export and tracking", .serialized)
struct TrackedRedactionExportTests {
    private func decodedFrames(_ url: URL, format: RecordingFileFormat) async throws -> [CGImage] {
        if format == .gif {
            let gif = try #require(GIFInspection(url: url))
            return try (0..<gif.frameCount).map { try #require(gif.image(at: $0)) }
        }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        #expect(reader.startReading())
        let context = CIContext(options: [.cacheIntermediates: false])
        var frames: [CGImage] = []
        while let sample = output.copyNextSampleBuffer() {
            let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
            let image = CIImage(cvPixelBuffer: buffer)
            frames.append(try #require(context.createCGImage(image, from: image.extent,
                                                              format: .RGBA8, colorSpace: ColorSpaces.sRGB)))
        }
        #expect(reader.status == .completed)
        return frames
    }

    private var frameBounds: CGRect { CGRect(origin: .zero, size: MovingSquareVideo.size) }

    private func perFrameTrack() -> RedactionTrack {
        RedactionTrack(keyframes: (0..<MovingSquareVideo.frames).map {
            RedactionKeyframe(time: MovingSquareVideo.time($0), rect: MovingSquareVideo.square($0).insetBy(dx: -4, dy: -4),
                              source: .tracked)
        }, analyzedRange: AnnotationTiming(start: 0, end: 3), frameBounds: frameBounds)
    }

    private func sparseManualTrack() -> RedactionTrack {
        RedactionTrack(keyframes: [0, 15, 30, 44].map {
            RedactionKeyframe(time: MovingSquareVideo.time($0), rect: MovingSquareVideo.square($0).insetBy(dx: -4, dy: -4),
                              source: .manual)
        }, analyzedRange: AnnotationTiming(start: 0, end: 3), frameBounds: frameBounds)
    }

    @Test(arguments: [RecordingFileFormat.gif, .mp4], [false, true])
    func everyExportedFrameOfAMovingSquareIsCovered(format: RecordingFileFormat, sparse: Bool) async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = fixture.directory.appendingPathComponent("moving.mp4")
        try await MovingSquareVideo.write(to: source)
        let track = sparse ? sparseManualTrack() : perFrameTrack()
        let annotation = Annotation(kind: .redact(MovingSquareVideo.square(0)), style: AnnotationStyle(color: .black),
                                    track: track)
        #expect(RedactionGate.unresolvedIntervals(in: [annotation], sourceDuration: 3).isEmpty)
        let settings = RenderSettings(padding: 0, inset: 0, cornerRadius: 0, shadow: .none,
                                      background: .solid(.white), autoBalance: false)
        let times = ProgressLog()
        let output = try await RecordingExporter.export(
            source: source, range: 0.1...2.9,
            options: RecordingExportOptions(format: format, gif: GIFExportOptions(framesPerSecond: 10)),
            outputDirectory: fixture.outputDirectory,
            frameRenderer: { frame, time in
                times.record(time)
                return try Compositor.render(image: frame, settings: settings, annotations: [annotation],
                                             annotationTime: time)
            })
        let frames = try await decodedFrames(output, format: format)
        #expect(frames.count == times.all.count)
        #expect(frames.count > 20)
        for (index, frame) in frames.enumerated() {
            let pixels = try #require(PixelBuffer(frame))
            var exposed = 0, covered = 0
            for y in 0..<min(pixels.height, Int(MovingSquareVideo.size.height)) {
                for x in 0..<min(pixels.width, Int(MovingSquareVideo.size.width)) {
                    let p = pixels.pixel(x, y)
                    if MovingSquareVideo.isMagenta(p) { exposed += 1 }
                    if p.0 < 30 && p.1 < 30 && p.2 < 30 { covered += 1 }
                }
            }
            #expect(exposed == 0, "\(format) frame \(index) at \(times.all[index]) shows \(exposed) square pixels")
            #expect(covered >= 30 * 30, "\(format) frame \(index) has a redaction")
        }
    }

    // MARK: Tracker orchestration

    private func tracker(_ url: URL, lostWhen: @escaping @Sendable (TimeInterval) -> Bool = { _ in false },
                         offset: @escaping @Sendable (TimeInterval) -> CGFloat = { _ in 0 },
                         onTrack: (@Sendable () -> Void)? = nil) -> RedactionTracker {
        RedactionTracker(source: AssetTrackingFrameSource(url: url, maxDimension: 160)) {
            ScriptedFrameTracker(lostWhen: lostWhen, offset: offset, onTrack: onTrack)
        }
    }

    @Test func tracksForwardsAndBackwardsFromTheAnchorFrame() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = fixture.directory.appendingPathComponent("moving.mp4")
        try await MovingSquareVideo.write(to: source)
        let progress = ProgressLog()
        // 1.42 s falls between frames 21 and 22; frame 21 is on screen.
        let anchorRect = MovingSquareVideo.square(21)
        let result = try await tracker(source).track(
            RedactionTrackingRequest(anchorTime: 1.42, anchorRect: anchorRect, range: 0...3),
            progress: { progress.record($0) })
        #expect(result.isValid)
        #expect(result.keyframes.count == MovingSquareVideo.frames)
        #expect(result.uncertainIntervals.isEmpty)
        #expect(result.analyzedRange == AnnotationTiming(start: 0, end: 3))
        #expect(result.frameBounds == frameBounds)
        let anchor = try #require(result.keyframes.first { abs($0.time - MovingSquareVideo.time(21)) < 1e-6 })
        #expect(anchor.rect == anchorRect)
        for index in 0..<MovingSquareVideo.frames {
            #expect(result.coverRect(at: MovingSquareVideo.time(index)).contains(MovingSquareVideo.square(index)))
        }
        #expect(progress.all.last == 1)
        #expect(zip(progress.all, progress.all.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func lostFramesBecomeUnresolvedIntervalsInTheirDirection() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = fixture.directory.appendingPathComponent("moving.mp4")
        try await MovingSquareVideo.write(to: source)
        let lostAfter = MovingSquareVideo.time(30), lostBefore = MovingSquareVideo.time(5)
        let result = try await tracker(source, lostWhen: { $0 >= lostAfter - 1e-6 || $0 <= lostBefore + 1e-6 }).track(
            RedactionTrackingRequest(anchorTime: 1.0, anchorRect: MovingSquareVideo.square(15), range: 0...3))
        #expect(result.uncertainIntervals.count == 2)
        let before = try #require(result.uncertainIntervals.first)
        let after = try #require(result.uncertainIntervals.last)
        #expect(before.start == 0 && abs(before.end - MovingSquareVideo.time(6)) < 1e-6)
        #expect(abs(before.anchorTime - MovingSquareVideo.time(6)) < 1e-6)
        #expect(abs(after.start - lostAfter) < 1e-6 && after.end == 3)
        #expect(abs(after.anchorTime - MovingSquareVideo.time(29)) < 1e-6)

        let annotation = Annotation(kind: .redact(MovingSquareVideo.square(15)), track: result)
        let gate = RedactionGate.unresolvedIntervals(in: [annotation], sourceDuration: 3)
        #expect(gate.count == 2)
        #expect(RedactionGate.blocksExport(gate, range: 0...3))
        #expect(!RedactionGate.blocksExport(gate, range: MovingSquareVideo.time(6)...lostAfter), "trimmed out")
        // Even unresolved, the fail-safe cover hides the square on every frame.
        for index in 0..<MovingSquareVideo.frames {
            #expect(annotation.resolved(at: MovingSquareVideo.time(index)).redactionRect?
                .contains(MovingSquareVideo.square(index)) == true, "frame \(index)")
        }
    }

    @Test func suddenJumpsAreFlaggedRatherThanFollowed() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = fixture.directory.appendingPathComponent("moving.mp4")
        try await MovingSquareVideo.write(to: source)
        let jump = MovingSquareVideo.time(20)
        let result = try await tracker(source, offset: { $0 >= jump - 1e-6 ? 120 : 0 }).track(
            RedactionTrackingRequest(anchorTime: 0.5, anchorRect: MovingSquareVideo.square(7), range: 0...3))
        #expect(result.uncertainIntervals.count == 1)
        #expect(abs((result.uncertainIntervals.first?.start ?? 0) - jump) < 1e-6)
        #expect(!result.keyframes.contains { $0.time >= jump - 1e-6 })
    }

    @Test func trackingCanBeCancelled() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = fixture.directory.appendingPathComponent("moving.mp4")
        try await MovingSquareVideo.write(to: source)
        let box = TaskBox()
        let tracker = tracker(source, onTrack: { box.task?.cancel() })
        let task = Task.detached {
            try await tracker.track(RedactionTrackingRequest(anchorTime: 0, anchorRect: MovingSquareVideo.square(0),
                                                             range: 0...3))
        }
        box.task = task
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func invalidRequestsAreRefused() async throws {
        let tracker = RedactionTracker(source: AssetTrackingFrameSource(url: URL(fileURLWithPath: "/nonexistent.mp4"))) {
            ScriptedFrameTracker()
        }
        await #expect(throws: RedactionTrackingError.invalidRequest) {
            _ = try await tracker.track(RedactionTrackingRequest(anchorTime: 0, anchorRect: .zero, range: 0...1))
        }
    }

    /// Runs Apple's tracker on the synthetic clip. Wherever it is confident, the square is covered; anywhere else
    /// is flagged, so either way no frame is exposed without the user knowing.
    @Test func visionTrackingCoversOrFlagsEveryFrame() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = fixture.directory.appendingPathComponent("moving.mp4")
        try await MovingSquareVideo.write(to: source)
        let anchor = MovingSquareVideo.square(15).insetBy(dx: -3, dy: -3)
        let result = try await RedactionTracker(url: source).track(
            RedactionTrackingRequest(anchorTime: MovingSquareVideo.time(15), anchorRect: anchor, range: 0...3))
        #expect(result.isValid)
        #expect(result.keyframes.count > 5, "Vision follows a clearly textured square")
        for index in 0..<MovingSquareVideo.frames {
            let time = MovingSquareVideo.time(index)
            guard result.interval(containing: time)?.isResolved != false else { continue }
            #expect(result.coverRect(at: time).contains(MovingSquareVideo.square(index).insetBy(dx: 2, dy: 2)),
                    "frame \(index): \(result.coverRect(at: time)) vs \(MovingSquareVideo.square(index))")
        }
    }
}
