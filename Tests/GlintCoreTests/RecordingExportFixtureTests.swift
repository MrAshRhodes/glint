import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import GlintCore

/// Writes small synthetic videos for the export tests. Never touches the screen or needs any permission.
enum SyntheticVideo {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Writes `frames` BGRA frames, one every `1 / fps` seconds. The red channel ramps from 0 to 255 over the clip,
    /// so a frame's colour says where in the recording it came from.
    static func write(to url: URL, frames: Int, fps: Int32 = 10, size: CGSize = CGSize(width: 160, height: 90),
                      transform: CGAffineTransform = .identity) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = Int(size.width), height = Int(size.height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw Failure(description: "startWriting: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw Failure(description: "no pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw Failure(description: "no pixel buffer") }
            let ramp = frames > 1 ? Double(index) / Double(frames - 1) : 0
            fill(buffer, red: UInt8(ramp * 255), step: index)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: fps)) else {
                throw Failure(description: "append failed: \(String(describing: writer.error))")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure(description: "finish: \(String(describing: writer.error))") }
    }

    private static func fill(_ buffer: CVPixelBuffer, red: UInt8, step: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * stride + x * 4
                // A bar sweeps across the top so consecutive frames always differ, leaving the rest a flat colour.
                let onBar = y < 12 && (x + step * 3) % width < 40
                p[0] = onBar ? 255 : 80
                p[1] = onBar ? 255 : 255 - red
                p[2] = onBar ? 255 : red
                p[3] = 255
            }
        }
    }
}

/// What a GIF file says about itself, read back through ImageIO.
struct GIFInspection {
    let frameCount: Int
    let loopCount: Int?
    let delays: [Double]
    let width: Int
    let height: Int
    let source: CGImageSource

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == "com.compuserve.gif" else { return nil }
        self.source = source
        frameCount = CGImageSourceGetCount(source)
        let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        loopCount = (container?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        var delays: [Double] = []
        for index in 0..<frameCount {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            delays.append((gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0)
        }
        self.delays = delays
        let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        width = first?[kCGImagePropertyPixelWidth] as? Int ?? 0
        height = first?[kCGImagePropertyPixelHeight] as? Int ?? 0
    }

    var totalDuration: Double { delays.reduce(0, +) }

    func image(at index: Int) -> CGImage? {
        CGImageSourceCreateImageAtIndex(source, index, nil)
    }
}

/// A scratch folder inside the repository's ignored `.build` folder, plus synthetic clips made in it.
final class RecordingExportFixture {
    let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/TestFixtures/recording-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var outputDirectory: URL { directory.appendingPathComponent("out", isDirectory: true) }

    func video(name: String = "source.mp4", frames: Int, fps: Int32 = 10,
               size: CGSize = CGSize(width: 160, height: 90), transform: CGAffineTransform = .identity) async throws -> URL {
        let url = directory.appendingPathComponent(name)
        try await SyntheticVideo.write(to: url, frames: frames, fps: fps, size: size, transform: transform)
        return url
    }

    /// Files left in `outputDirectory`; empty when nothing (such as a partial export) was left behind.
    func outputs() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []).sorted()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Thread-safe progress log for the `@Sendable` progress callback.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
    }

    var all: [Double] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

@Suite("Recording export fixture")
struct RecordingExportFixtureTests {
    @Test func syntheticVideoHasTheRequestedDurationAndSize() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let url = try await fixture.video(frames: 30, fps: 10)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(abs(duration - 3.0) < 0.15)
        #expect(size == CGSize(width: 160, height: 90))
    }
}
