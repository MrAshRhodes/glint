import AVFoundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import Testing
@testable import GlintCapture

/// Synthetic frames and files for the recording tests; nothing here touches the real display.
enum SyntheticFrames {
    static func tempURL(_ name: String = "glint-recording-test") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).mp4")
    }

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// A BGRA buffer whose colour depends on `index`, so consecutive frames differ.
    static func pixelBuffer(width: Int, height: Int, index: Int = 0) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                base[offset] = UInt8((x + index * 7) % 256)
                base[offset + 1] = UInt8((y + index * 3) % 256)
                base[offset + 2] = UInt8((index * 11) % 256)
                base[offset + 3] = 255
            }
        }
        return pixelBuffer
    }

    /// A sample buffer like ScreenCaptureKit delivers, carrying `status` as its frame-status attachment.
    static func sampleBuffer(width: Int, height: Int, at presentationTime: CMTime,
                             status: SCFrameStatus?) -> CMSampleBuffer {
        let image = pixelBuffer(width: width, height: height)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: format!,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        let buffer = sample!
        if let status {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true)! as NSArray
            let dictionary = attachments[0] as! NSMutableDictionary
            dictionary[SCStreamFrameInfo.status.rawValue as NSString] = NSNumber(value: status.rawValue)
        }
        return buffer
    }

    /// Appends a frame, waiting while the encoder is busy: the writer drops frames it cannot take (as it should
    /// when recording), which a busy machine running tests in parallel can trigger.
    static func append(_ frame: CVPixelBuffer, to writer: FrameWriter, at time: CMTime,
                       arrival: CMTime) async -> FrameWriter.AppendResult {
        var result = writer.append(pixelBuffer: frame, at: time, arrival: arrival)
        var attempts = 0
        while result == .notReady, attempts < 400 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            result = writer.append(pixelBuffer: frame, at: time, arrival: arrival)
            attempts += 1
        }
        return result
    }

    struct Probe {
        let duration: TimeInterval
        let videoTrackCount: Int
        let naturalSize: CGSize
    }

    static func probe(_ url: URL) async throws -> Probe {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let size = try await tracks.first?.load(.naturalSize) ?? .zero
        return Probe(duration: duration, videoTrackCount: tracks.count, naturalSize: size)
    }
}

@Suite("Frame writer")
struct FrameWriterTests {
    private let width = 320
    private let height = 180

    @Test func encodesFramesIntoAPlayableMP4() async throws {
        let url = SyntheticFrames.tempURL("glint-framewriter")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try FrameWriter(url: url, width: width, height: height, frameRate: 30)

        for index in 0..<30 {
            let time = CMTime(value: CMTimeValue(index), timescale: 30)
            let frame = SyntheticFrames.pixelBuffer(width: width, height: height, index: index)
            #expect(await SyntheticFrames.append(frame, to: writer, at: time, arrival: time) == .written)
        }
        let summary = try await writer.finish(at: CMTime(value: 30, timescale: 30))

        #expect(summary.frameCount == 30)
        #expect(summary.pixelSize == CGSize(width: width, height: height))
        #expect(abs(summary.duration - 1) < 0.001)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let probe = try await SyntheticFrames.probe(url)
        #expect(probe.videoTrackCount == 1)
        #expect(probe.naturalSize == CGSize(width: width, height: height))
        #expect(abs(probe.duration - 1) < 0.15)
    }

    @Test func stillScreenKeepsItsRealDuration() async throws {
        let url = SyntheticFrames.tempURL("glint-framewriter")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try FrameWriter(url: url, width: width, height: height)

        for (index, seconds) in [0.0, 0.5, 1.0].enumerated() {
            let time = SyntheticFrames.time(seconds)
            let frame = SyntheticFrames.pixelBuffer(width: width, height: height, index: index)
            #expect(await SyntheticFrames.append(frame, to: writer, at: time, arrival: time) == .written)
        }
        // ScreenCaptureKit sends nothing while the screen does not change; the last frame lasts until stop.
        let summary = try await writer.finish(at: SyntheticFrames.time(3))

        #expect(abs(summary.duration - 3) < 0.001)
        let probe = try await SyntheticFrames.probe(url)
        #expect(abs(probe.duration - 3) < 0.15)
    }

    @Test func aSingleFrameStillProducesAVideo() async throws {
        let url = SyntheticFrames.tempURL("glint-framewriter")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try FrameWriter(url: url, width: width, height: height)
        let time = SyntheticFrames.time(12)
        let frame = SyntheticFrames.pixelBuffer(width: width, height: height)
        #expect(await SyntheticFrames.append(frame, to: writer, at: time, arrival: time) == .written)

        let summary = try await writer.finish(at: SyntheticFrames.time(14))

        #expect(summary.frameCount == 1)
        #expect(abs(summary.duration - 2) < 0.001)
        let probe = try await SyntheticFrames.probe(url)
        #expect(abs(probe.duration - 2) < 0.15)
    }

    @Test func finishingImmediatelyStillHoldsAtLeastOneFrame() async throws {
        let url = SyntheticFrames.tempURL("glint-framewriter")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try FrameWriter(url: url, width: width, height: height, frameRate: 30)
        let time = SyntheticFrames.time(5)
        let frame = SyntheticFrames.pixelBuffer(width: width, height: height)
        _ = await SyntheticFrames.append(frame, to: writer, at: time, arrival: time)

        let summary = try await writer.finish(at: time)

        #expect(abs(summary.duration - 1.0 / 30) < 0.001)
    }

    @Test func rejectsFramesThatDoNotFit() async throws {
        let url = SyntheticFrames.tempURL("glint-framewriter")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try FrameWriter(url: url, width: width, height: height)
        let frame = SyntheticFrames.pixelBuffer(width: width, height: height)

        #expect(await SyntheticFrames.append(frame, to: writer, at: SyntheticFrames.time(1), arrival: SyntheticFrames.time(1)) == .written)
        #expect(writer.append(pixelBuffer: frame, at: SyntheticFrames.time(1), arrival: SyntheticFrames.time(1)) == .outOfOrder)
        #expect(writer.append(pixelBuffer: frame, at: SyntheticFrames.time(0.5), arrival: SyntheticFrames.time(1)) == .outOfOrder)
        #expect(writer.append(pixelBuffer: frame, at: .invalid, arrival: SyntheticFrames.time(1)) == .skipped)
        let wrongSize = SyntheticFrames.pixelBuffer(width: width + 2, height: height)
        #expect(writer.append(pixelBuffer: wrongSize, at: SyntheticFrames.time(2), arrival: SyntheticFrames.time(2)) == .skipped)
        #expect(await SyntheticFrames.append(frame, to: writer, at: SyntheticFrames.time(2), arrival: SyntheticFrames.time(2)) == .written)
        #expect(writer.framesWritten == 2)
        writer.cancel()
    }

    @Test func stopsAcceptingFramesAtTheMaximumDuration() async throws {
        let url = SyntheticFrames.tempURL("glint-framewriter")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try FrameWriter(url: url, width: width, height: height, maximumDuration: 2)
        let frame = SyntheticFrames.pixelBuffer(width: width, height: height)

        #expect(await SyntheticFrames.append(frame, to: writer, at: SyntheticFrames.time(10), arrival: SyntheticFrames.time(10)) == .written)
        #expect(await SyntheticFrames.append(frame, to: writer, at: SyntheticFrames.time(11.9), arrival: SyntheticFrames.time(11.9)) == .written)
        #expect(writer.append(pixelBuffer: frame, at: SyntheticFrames.time(12.5), arrival: SyntheticFrames.time(12.5)) == .limitReached)

        // A long wait before stopping cannot stretch the file past the limit.
        let summary = try await writer.finish(at: SyntheticFrames.time(60))
        #expect(abs(summary.duration - 2) < 0.001)
    }

    @Test func finishWithoutFramesThrowsAndLeavesNoFile() async throws {
        let url = SyntheticFrames.tempURL("glint-framewriter")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try FrameWriter(url: url, width: width, height: height)

        await #expect(throws: FrameWriterError.noFrames) { try await writer.finish() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func finishingTwiceIsRejected() async throws {
        let url = SyntheticFrames.tempURL("glint-framewriter")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try FrameWriter(url: url, width: width, height: height)
        let time = SyntheticFrames.time(0)
        let frame = SyntheticFrames.pixelBuffer(width: width, height: height)
        _ = await SyntheticFrames.append(frame, to: writer, at: time, arrival: time)
        _ = try await writer.finish(at: SyntheticFrames.time(1))

        await #expect(throws: FrameWriterError.alreadyFinished) { try await writer.finish() }
        #expect(writer.append(pixelBuffer: SyntheticFrames.pixelBuffer(width: width, height: height),
                              at: SyntheticFrames.time(2), arrival: SyntheticFrames.time(2)) == .closed)
        writer.cancel()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func cancelDeletesThePartialFile() async throws {
        let url = SyntheticFrames.tempURL("glint-framewriter")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try FrameWriter(url: url, width: width, height: height)
        let time = SyntheticFrames.time(0)
        let frame = SyntheticFrames.pixelBuffer(width: width, height: height)
        #expect(await SyntheticFrames.append(frame, to: writer, at: time, arrival: time) == .written)

        writer.cancel()

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(writer.append(pixelBuffer: SyntheticFrames.pixelBuffer(width: width, height: height),
                              at: SyntheticFrames.time(1), arrival: SyntheticFrames.time(1)) == .closed)
        writer.cancel()
    }

    @Test func invalidSizesAreRejectedUpFront() {
        let url = SyntheticFrames.tempURL("glint-framewriter")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: FrameWriterError.self) { try FrameWriter(url: url, width: 321, height: 180) }
        #expect(throws: FrameWriterError.self) { try FrameWriter(url: url, width: 320, height: 0) }
        #expect(throws: FrameWriterError.self) { try FrameWriter(url: url, width: -2, height: 180) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func onlyCompleteScreenCaptureKitFramesAreEncoded() async throws {
        let url = SyntheticFrames.tempURL("glint-framewriter")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try FrameWriter(url: url, width: width, height: height)

        let complete = SyntheticFrames.sampleBuffer(width: width, height: height, at: SyntheticFrames.time(0), status: .complete)
        let idle = SyntheticFrames.sampleBuffer(width: width, height: height, at: SyntheticFrames.time(0.1), status: .idle)
        let blank = SyntheticFrames.sampleBuffer(width: width, height: height, at: SyntheticFrames.time(0.2), status: .blank)
        let started = SyntheticFrames.sampleBuffer(width: width, height: height, at: SyntheticFrames.time(0.3), status: .started)
        let unmarked = SyntheticFrames.sampleBuffer(width: width, height: height, at: SyntheticFrames.time(0.4), status: nil)
        #expect(FrameWriter.isCompleteFrame(complete))
        for notFresh in [idle, blank, started, unmarked] { #expect(!FrameWriter.isCompleteFrame(notFresh)) }

        #expect(writer.append(idle, arrival: SyntheticFrames.time(0.1)) == .skipped)
        #expect(writer.append(blank, arrival: SyntheticFrames.time(0.2)) == .skipped)
        #expect(writer.append(unmarked, arrival: SyntheticFrames.time(0.4)) == .skipped)
        var result = writer.append(complete, arrival: SyntheticFrames.time(0))
        for _ in 0..<400 where result == .notReady {
            try await Task.sleep(nanoseconds: 5_000_000)
            result = writer.append(complete, arrival: SyntheticFrames.time(0))
        }
        #expect(result == .written)
        #expect(writer.framesWritten == 1)

        let summary = try await writer.finish(at: SyntheticFrames.time(1))
        #expect(summary.frameCount == 1)
        #expect(abs(summary.duration - 1) < 0.001)
    }

    @Test func bitRateScalesWithAreaWithinSaneBounds() {
        #expect(FrameWriter.bitRate(width: 1920, height: 1080, frameRate: 30) > 7_000_000)
        #expect(FrameWriter.bitRate(width: 1920, height: 1080, frameRate: 30) < 8_000_000)
        #expect(FrameWriter.bitRate(width: 64, height: 64, frameRate: 30) == 1_500_000)
        #expect(FrameWriter.bitRate(width: 8192, height: 4320, frameRate: 60) == 40_000_000)
    }
}
