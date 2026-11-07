import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import GlintCore

/// Screen captures deliver no frames while nothing changes. Time-based presentation effects must still play in MP4.
@Suite("Presentation sparse-frame export", .serialized)
struct PresentationSparseExportTests {
    /// A flat grey 160×90 clip with frames only at `times`, lasting `duration` seconds.
    private func sparseVideo(_ fixture: RecordingExportFixture, times: [Double], duration: Double) async throws -> URL {
        let url = fixture.directory.appendingPathComponent("sparse.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for time in times {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let pool = try #require(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private func decodedMP4(_ url: URL) async throws -> [CGImage] {
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
            let image = CIImage(cvPixelBuffer: try #require(CMSampleBufferGetImageBuffer(sample)))
            frames.append(try #require(context.createCGImage(image, from: image.extent,
                                                              format: .RGBA8, colorSpace: ColorSpaces.sRGB)))
        }
        return frames
    }

    private let settings = RenderSettings(padding: 0, inset: 0, cornerRadius: 0, shadow: .none,
                                          background: .solid(.white), autoBalance: false)

    private func export(_ source: URL, _ fixture: RecordingExportFixture, resamples: Bool,
                        annotations: [Annotation] = [], presentation: Presentation) async throws -> ([CGImage], [Double]) {
        let times = ProgressLog()
        let settings = settings
        let output = try await RecordingExporter.export(
            source: source, range: 0...3,
            options: RecordingExportOptions(format: .mp4, resamplesStyledFrames: resamples),
            outputDirectory: fixture.outputDirectory,
            frameRenderer: { frame, time in
                times.record(time)
                return try Compositor.render(image: frame, settings: settings, annotations: annotations,
                                             annotationTime: time, presentation: presentation)
            })
        let frames = try await decodedMP4(output)
        #expect(frames.count == times.all.count)
        return (frames, times.all)
    }

    /// Pixels in `rect` whose colour differs by more than 40 in any channel.
    private func changedPixels(_ a: CGImage, _ b: CGImage, in rect: CGRect) throws -> Int {
        let pa = try #require(PixelBuffer(a)), pb = try #require(PixelBuffer(b))
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let p = pa.pixel(x, y), q = pb.pixel(x, y)
                if abs(Int(p.0) - Int(q.0)) > 40 || abs(Int(p.1) - Int(q.1)) > 40 || abs(Int(p.2) - Int(q.2)) > 40 {
                    count += 1
                }
            }
        }
        return count
    }

    @Test func zoomPlaysThroughAGapWithNoSourceFrames() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await sparseVideo(fixture, times: [0, 0.05, 2.9], duration: 3)
        let annotations = [Annotation(kind: .redact(CGRect(x: 50, y: 25, width: 60, height: 40)),
                                      style: AnnotationStyle(color: .black))]
        let presentation = Presentation(settings: PresentationSettings(zooms: [
            ZoomSegment(start: 0.5, end: 2.5, rect: CGRect(x: 60, y: 30, width: 40, height: 22.5)),
        ]))

        let (plainFrames, plainTimes) = try await export(source, fixture, resamples: false,
                                                         annotations: annotations, presentation: presentation)
        #expect(plainTimes.count == 3 && plainFrames.count == 3, "Without resampling only source frames are rendered")
        #expect(!plainTimes.contains { (0.9...2.1).contains($0) }, "…so the zoom would be skipped entirely")

        let (frames, times) = try await export(source, fixture, resamples: true,
                                               annotations: annotations, presentation: presentation)
        #expect(times.count >= 85 && times.count <= 185, "A steady cadence over the whole 3 s range")
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
        let zoomed = zip(frames, times).filter { (1.0...2.0).contains($0.1) }
        #expect(zoomed.count >= 25)
        for (frame, time) in zoomed {
            let pixels = try #require(PixelBuffer(frame))
            func isBlack(_ x: Int, _ y: Int) -> Bool { let p = pixels.pixel(x, y); return p.0 < 35 && p.1 < 35 && p.2 < 35 }
            #expect(isBlack(3, 3) && isBlack(156, 86), "Full zoom on the held frame at \(time)")
        }
        let start = try #require(PixelBuffer(frames[0]))
        #expect(start.pixel(3, 3).0 > 100, "No zoom at the start")
    }

    @Test func clickRipplesAndADrawnPointerAnimateOverAHeldFrame() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await sparseVideo(fixture, times: [0, 2.9], duration: 3)
        let capture = PresentationCapture(
            pointer: PointerTrack(samples: [PointerSample(time: 0, position: CGPoint(x: 20, y: 70)),
                                            PointerSample(time: 2.9, position: CGPoint(x: 140, y: 70))]),
            clicks: [ClickEvent(time: 1.0, position: CGPoint(x: 80, y: 35))], pointerIsBaked: false)
        let presentation = Presentation(capture: capture, settings: PresentationSettings(
            clicks: ClickHighlightStyle(enabled: true, size: 40, duration: 0.6)))

        let (frames, times) = try await export(source, fixture, resamples: true, presentation: presentation)
        func frame(near time: Double) throws -> CGImage {
            let index = try #require(times.indices.min { abs(times[$0] - time) < abs(times[$1] - time) })
            #expect(abs(times[index] - time) < 0.05)
            return frames[index]
        }
        let clickArea = CGRect(x: 50, y: 5, width: 60, height: 50)
        #expect(try changedPixels(frame(near: 1.2), frame(near: 0.6), in: clickArea) > 20,
                "The ripple appears after the click although no source frame arrived")
        #expect(try changedPixels(frame(near: 1.2), frame(near: 1.4), in: clickArea) > 5, "The ripple keeps growing")
        #expect(try changedPixels(frame(near: 2.2), frame(near: 0.6), in: clickArea) <= 5, "The ripple has finished")
        let pointerBand = CGRect(x: 0, y: 60, width: 160, height: 30)
        #expect(try changedPixels(frame(near: 0.5), frame(near: 2.0), in: pointerBand) > 20, "The pointer moves")
    }

    @Test func resampledCadenceFollowsTheSourceWithinLimits() {
        #expect(RecordingExporter.resampledFrameInterval(nominalFrameRate: 3) == 1.0 / 30)
        #expect(RecordingExporter.resampledFrameInterval(nominalFrameRate: 45) == 1.0 / 45)
        #expect(RecordingExporter.resampledFrameInterval(nominalFrameRate: 120) == 1.0 / 60)
        #expect(RecordingExporter.resampledFrameInterval(nominalFrameRate: .nan) == 1.0 / 30)
    }
}
