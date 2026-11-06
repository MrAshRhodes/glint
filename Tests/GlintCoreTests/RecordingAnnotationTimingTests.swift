import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import GlintCore

@Suite("Recording annotation timing", .serialized)
struct RecordingAnnotationTimingTests {
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
        // Decoding blocks, so keep it off the few threads every other test needs.
        let (frames, status) = try await BlockingWork.run { _ in
            let context = CIContext(options: [.cacheIntermediates: false])
            var frames: [CGImage] = []
            while let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                    throw RecordingExportError.encodingFailed("a decoded sample has no image buffer")
                }
                let image = CIImage(cvPixelBuffer: buffer)
                guard let frame = context.createCGImage(image, from: image.extent,
                                                        format: .RGBA8, colorSpace: ColorSpaces.sRGB) else {
                    throw RecordingExportError.encodingFailed("couldn't convert a decoded frame")
                }
                frames.append(frame)
            }
            return (frames, reader.status)
        }
        #expect(status == .completed)
        return frames
    }

    @Test(arguments: [RecordingFileFormat.gif, .mp4])
    func trimmedExportRendersEachVisibleRangeAndKeepsHiddenMagnifierSpace(format: RecordingFileFormat) async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 90, fps: 30)
        let black = AnnotationStyle(color: .black)
        let activeRange = AnnotationTiming(start: 1.2, end: 1.4)
        let annotations = [
            Annotation(kind: .redact(CGRect(x: 20, y: 20, width: 30, height: 30)), style: black,
                       visibleRange: activeRange),
            Annotation(kind: .redact(CGRect(x: 85, y: 20, width: 30, height: 30)), style: black,
                       visibleRange: AnnotationTiming(start: 1.01, end: 1.15)),
            Annotation(kind: .redact(CGRect(x: 60, y: 20, width: 20, height: 30)), style: black),
            Annotation(kind: .redact(CGRect(x: 130, y: 20, width: 20, height: 30)), style: black,
                       visibleRange: AnnotationTiming(start: 0, end: 0.5)),
            Annotation(kind: .redact(CGRect(x: 130, y: 60, width: 20, height: 20)), style: black,
                       visibleRange: AnnotationTiming(start: 2, end: 3)),
            Annotation(z: 1, kind: .magnify(Magnifier(source: CGRect(x: 20, y: 20, width: 30, height: 30),
                                                     inset: CGRect(x: 185, y: 15, width: 60, height: 60),
                                                     shape: .rectangle, showsSourceOutline: false, showsConnector: false)),
                       visibleRange: activeRange),
        ]
        let settings = RenderSettings(padding: 0, inset: 0, cornerRadius: 0, shadow: .none,
                                      background: .solid(.white), autoBalance: false)
        let reference = try Compositor.renderDetailed(image: TestImages.solid(160, 90, .white),
                                                      settings: settings, annotations: annotations)
        let times = ProgressLog()
        let output = try await RecordingExporter.export(
            source: source, range: 1.01...1.61,
            options: RecordingExportOptions(format: format, gif: GIFExportOptions(framesPerSecond: 10)),
            outputDirectory: fixture.outputDirectory,
            frameRenderer: { frame, time in
                times.record(time)
                return try Compositor.render(image: frame, settings: settings, annotations: annotations, annotationTime: time)
            })
        let frames = try await decodedFrames(output, format: format)
        #expect(frames.count == times.all.count)
        #expect(times.all.first == 1.01)
        #expect(times.all.contains { $0 >= 1.2 && $0 < 1.4 })
        #expect(times.all.contains { $0 >= 1.4 })
        let width = reference.image.width + (format == .mp4 ? reference.image.width % 2 : 0)
        let height = reference.image.height + (format == .mp4 ? reference.image.height % 2 : 0)
        for (frame, time) in zip(frames, times.all) {
            #expect(frame.width == width && frame.height == height)
            let pixels = try #require(PixelBuffer(frame))
            func isBlack(_ x: Int, _ y: Int) -> Bool {
                let p = pixels.pixel(Int(reference.layout.contentRect.minX) + x, Int(reference.layout.contentRect.minY) + y)
                return p.0 < 35 && p.1 < 35 && p.2 < 35
            }
            #expect(isBlack(35, 35) == (time >= 1.2 && time < 1.4), "\(format) main redaction at \(time)")
            #expect(isBlack(100, 35) == (time < 1.15), "\(format) trim-start redaction at \(time)")
            #expect(isBlack(70, 35), "\(format) whole-clip redaction at \(time)")
            #expect(!isBlack(140, 35), "\(format) annotation before trim must stay hidden")
            #expect(!isBlack(140, 70), "\(format) annotation after trim must stay hidden")
            #expect(isBlack(215, 45) == (time >= 1.2 && time < 1.4), "\(format) timed magnifier at \(time)")
        }
    }
    @Test(arguments: [RecordingFileFormat.gif, .mp4])
    func trimmedExportFollowsZoomOnTheSourceClock(format: RecordingFileFormat) async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 90, fps: 30)
        let annotations = [Annotation(kind: .redact(CGRect(x: 50, y: 25, width: 60, height: 40)),
                                      style: AnnotationStyle(color: .black))]
        let presentation = Presentation(settings: PresentationSettings(zooms: [
            ZoomSegment(start: 1, end: 3, rect: CGRect(x: 60, y: 30, width: 40, height: 22.5)),
        ]))
        let settings = RenderSettings(padding: 0, inset: 0, cornerRadius: 0, shadow: .none,
                                      background: .solid(.white), autoBalance: false)
        let times = ProgressLog()
        let output = try await RecordingExporter.export(
            source: source, range: 1.01...1.61,
            options: RecordingExportOptions(format: format, gif: GIFExportOptions(framesPerSecond: 10)),
            outputDirectory: fixture.outputDirectory,
            frameRenderer: { frame, time in
                times.record(time)
                return try Compositor.render(image: frame, settings: settings, annotations: annotations,
                                             annotationTime: time, presentation: presentation)
            })
        let frames = try await decodedFrames(output, format: format)
        #expect(frames.count == times.all.count)
        #expect(times.all.contains { $0 >= 1.4 })
        for (frame, time) in zip(frames, times.all) {
            #expect(frame.width >= 160 && frame.height >= 90, "Zoom never changes the output size")
            let pixels = try #require(PixelBuffer(frame))
            func isBlack(_ x: Int, _ y: Int) -> Bool {
                let p = pixels.pixel(x, y)
                return p.0 < 35 && p.1 < 35 && p.2 < 35
            }
            #expect(isBlack(80, 45), "\(format) redaction at the centre at \(time)")
            if time < 1.05 {
                #expect(!isBlack(3, 3), "\(format) zoom has barely started at \(time)")
            } else if time >= 1.4 {
                #expect(isBlack(3, 3) && isBlack(156, 86), "\(format) full zoom fills the frame with the redaction at \(time)")
            }
        }
    }
}
