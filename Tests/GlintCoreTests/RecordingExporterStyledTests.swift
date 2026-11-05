import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

@Suite("Styled recording export", .serialized)
struct RecordingExporterStyledTests {
    private let formats: [RecordingFileFormat] = [.gif, .mp4]

    private func firstImage(_ url: URL, format: RecordingFileFormat) async throws -> CGImage {
        if format == .gif {
            return try #require(GIFInspection(url: url)?.image(at: 0))
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: .zero).image
    }

    private func settings(_ kind: WindowFrameKind = .browser) -> RenderSettings {
        RenderSettings(padding: 12, inset: 0, cornerRadius: 0, shadow: .none, background: .solid(.white),
                       windowFrame: WindowFrameSettings(style: kind, title: "Glint", screenEffects: false), autoBalance: false)
    }

    @Test func everyScreenshotFrameAndRedactionIsBakedIntoBothFormats() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 30, fps: 30)
        let original = try await firstImage(source, format: .mp4)
        let annotations = [Annotation(kind: .redact(CGRect(x: 20, y: 20, width: 60, height: 40)),
                                      style: AnnotationStyle(color: .black))]
        for kind in WindowFrameKind.allCases {
            let settings = settings(kind)
            let reference = try Compositor.renderDetailed(image: original, settings: settings, annotations: annotations)
            for format in formats {
                let count = ProgressLog()
                let output = try await RecordingExporter.export(
                    source: source, range: 0...0.2, options: RecordingExportOptions(format: format),
                    outputDirectory: fixture.outputDirectory,
                    frameRenderer: { frame, _ in
                        count.record(1)
                        return try Compositor.render(image: frame, settings: settings, annotations: annotations)
                    })
                let image = try await firstImage(output, format: format)
                let expectedWidth = reference.image.width + (format == .mp4 ? reference.image.width % 2 : 0)
                let expectedHeight = reference.image.height + (format == .mp4 ? reference.image.height % 2 : 0)
                #expect(image.width == expectedWidth && image.height == expectedHeight, "\(kind), \(format)")
                #expect(count.all.count == (format == .mp4 ? 6 : 3))
                let x = Int(reference.layout.contentRect.minX) + 40
                let y = Int(reference.layout.contentRect.minY) + 40
                let pixel = TestImages.pixel(image, x, y)
                #expect(pixel.r < 35 && pixel.g < 35 && pixel.b < 35, "\(kind), \(format) redaction")
                // Compare chrome, background and content against the screenshot compositor, allowing lossy encoding.
                var difference = 0, samples = 0
                let actualPixels = try #require(PixelBuffer(image))
                let referencePixels = try #require(PixelBuffer(reference.image))
                for y in stride(from: 4, to: reference.image.height, by: 9) {
                    for x in stride(from: 4, to: reference.image.width, by: 9) {
                        let a = actualPixels.pixel(x, y), b = referencePixels.pixel(x, y)
                        difference += abs(Int(a.0) - Int(b.0)) + abs(Int(a.1) - Int(b.1)) + abs(Int(a.2) - Int(b.2))
                        samples += 3
                    }
                }
                #expect(Double(difference) / Double(samples) < 20, "\(kind), \(format) differs from screenshot style")
            }
        }
    }

    @Test func styledTrimKeepsSourceTimingAndEveryMP4Frame() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 90, fps: 30)
        let sourceGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        sourceGenerator.requestedTimeToleranceBefore = .zero
        sourceGenerator.requestedTimeToleranceAfter = .zero
        let sourceFrame = try await sourceGenerator.image(at: CMTime(seconds: 1, preferredTimescale: 30)).image
        let expectedRed = Double(TestImages.pixel(sourceFrame, 100, 60).r)
        for format in formats {
            let count = ProgressLog(), progress = ProgressLog()
            let output = try await RecordingExporter.export(
                source: source, range: 1.01...1.52, options: RecordingExportOptions(format: format),
                outputDirectory: fixture.outputDirectory, progress: { progress.record($0) },
                frameRenderer: { frame, time in count.record(time); return frame })
            let image = try await firstImage(output, format: format)
            let red = Double(TestImages.pixel(image, 100, 60).r)
            #expect(abs(red - expectedRed) < 15, "\(format) wrong trim start: \(red), expected \(expectedRed)")
            #expect(progress.all.last == 1)
            #expect(zip(progress.all, progress.all.dropFirst()).allSatisfy { $0 <= $1 })
            #expect(count.all.first == 1.01, "the first renderer timestamp must be the source trim start")
            #expect(count.all.allSatisfy { $0 >= 1.01 && $0 < 1.52 })
            #expect(zip(count.all, count.all.dropFirst()).allSatisfy { $0 < $1 })
            if format == .mp4 {
                let asset = AVURLAsset(url: output)
                #expect(abs(try await asset.load(.duration).seconds - 0.51) < 0.005)
                #expect(count.all.count == 16)
                for (index, time) in count.all.enumerated().dropFirst() {
                    #expect(abs(time - Double(30 + index) / 30) < 1e-6)
                }
                #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
            } else {
                #expect(count.all.count == GIFLimits.frameCount(duration: 0.51, framesPerSecond: 15))
                for (index, time) in count.all.enumerated() {
                    #expect(abs(time - (1.01 + Double(index) / 15)) < 1e-6)
                }
            }
        }
    }

    @Test func preferredOrientationIsAppliedBeforeRendering() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 15, fps: 30,
                                             transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 90, ty: 0))
        let reference = try await firstImage(source, format: .mp4)
        for format in formats {
            let sizes = ProgressLog()
            let output = try await RecordingExporter.export(
                source: source, range: 0...0.2, options: RecordingExportOptions(format: format),
                outputDirectory: fixture.outputDirectory, frameRenderer: { image, _ in
                    sizes.record(Double(image.width))
                    return image
                })
            let actual = try await firstImage(output, format: format)
            #expect(actual.width == 90 && actual.height == 160)
            #expect(sizes.all.allSatisfy { $0 == 90 })
            for point in [(5, 5), (85, 5), (5, 150), (85, 150), (45, 80)] {
                let a = TestImages.pixel(actual, point.0, point.1)
                let b = TestImages.pixel(reference, point.0, point.1)
                #expect(abs(Int(a.r) - Int(b.r)) < 30, "\(format), \(point)")
                #expect(abs(Int(a.g) - Int(b.g)) < 30, "\(format), \(point)")
                #expect(abs(Int(a.b) - Int(b.b)) < 30, "\(format), \(point)")
            }
        }
    }

    @Test func transparencyIsWhiteAndOddMP4DimensionsArePaddedNotCropped() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 10, fps: 30)
        for format in formats {
            let output = try await RecordingExporter.export(
                source: source, range: 0...0.2, options: RecordingExportOptions(format: format),
                outputDirectory: fixture.outputDirectory, frameRenderer: { _, _ in
                    let context = try #require(GlintBitmap.makeContext(width: 161, height: 91))
                    context.setFillColor(CGColor(gray: 0, alpha: 1))
                    context.fill(CGRect(x: 130, y: 0, width: 31, height: 91))
                    return try #require(context.makeImage())
                })
            let image = try await firstImage(output, format: format)
            #expect(image.width == (format == .mp4 ? 162 : 161))
            #expect(image.height == (format == .mp4 ? 92 : 91))
            let clear = TestImages.pixel(image, 20, 45)
            #expect(clear.r > 240 && clear.g > 240 && clear.b > 240)
            #expect(TestImages.pixel(image, 159, 45).r < 40, "right edge of rendered image was lost")
        }
    }

    @Test func rendererRunsBeforeGIFDownscaling() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 6, fps: 30, size: CGSize(width: 960, height: 540))
        let sizes = ProgressLog()
        let output = try await RecordingExporter.export(
            source: source, range: 0...0.2,
            options: RecordingExportOptions(format: .gif, gif: GIFExportOptions(framesPerSecond: 10, maxWidth: .w480)),
            outputDirectory: fixture.outputDirectory, frameRenderer: { image, _ in
                sizes.record(Double(image.width))
                return try Compositor.render(image: image,
                                             settings: RenderSettings(padding: 20, shadow: .none, autoBalance: false))
            })
        let gif = try #require(GIFInspection(url: output))
        #expect(gif.width == 480)
        #expect(gif.height == 278)
        #expect(sizes.all == [960, 960])
    }

    @Test func errorsAfterTheFirstFrameDeleteThePartialFileWithoutRawFallback() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 30, fps: 30)
        for format in formats {
            let count = ProgressLog()
            await #expect(throws: RenderError.annotationsNotApplied) {
                try await RecordingExporter.export(
                    source: source, range: 0...0.5, options: RecordingExportOptions(format: format),
                    outputDirectory: fixture.outputDirectory, frameRenderer: { image, _ in
                        count.record(1)
                        if count.all.count > 1 { throw RenderError.annotationsNotApplied }
                        return image
                    })
            }
            #expect(count.all.count == 2)
            #expect(fixture.outputs().isEmpty)
        }
    }

    @Test func changingRenderedDimensionsFailsClosed() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 30, fps: 30)
        for format in formats {
            let count = ProgressLog()
            await #expect(throws: RecordingExportError.encodingFailed("the rendered frame dimensions changed")) {
                try await RecordingExporter.export(
                    source: source, range: 0...0.5, options: RecordingExportOptions(format: format),
                    outputDirectory: fixture.outputDirectory, frameRenderer: { image, _ in
                        count.record(1)
                        return count.all.count == 1 ? image : try #require(image.cropping(to: CGRect(x: 0, y: 0, width: 80, height: 80)))
                    })
            }
            #expect(fixture.outputs().isEmpty)
        }
    }

    @Test func cancellingAfterRenderingBeginsDeletesThePartialFile() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 90, fps: 30)
        for format in formats {
            let count = ProgressLog()
            let task = Task {
                try await RecordingExporter.export(
                    source: source, range: 0...3, options: RecordingExportOptions(format: format),
                    outputDirectory: fixture.outputDirectory, frameRenderer: { image, _ in
                        count.record(1)
                        Thread.sleep(forTimeInterval: 0.02)
                        return image
                    })
            }
            for _ in 0..<400 where count.all.count < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
            #expect(count.all.count >= 2)
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(fixture.outputs().isEmpty)
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLINT_RECORDING_EXPORT_BENCHMARK"] == "1"))
    func realisticStyledExportBenchmark() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 60, fps: 30, size: CGSize(width: 1280, height: 720))
        let settings = settings()
        let annotations = [Annotation(kind: .redact(CGRect(x: 30, y: 30, width: 250, height: 100)))]
        for format in formats {
            let start = ContinuousClock.now
            let output = try await RecordingExporter.export(
                source: source, range: 0...2, options: RecordingExportOptions(format: format),
                outputDirectory: fixture.outputDirectory, frameRenderer: { frame, _ in
                    try Compositor.render(image: frame, settings: settings, annotations: annotations)
                })
            print("Styled \(format) benchmark: 2s 1280×720 @30fps source, \(start.duration(to: .now)), \(output.lastPathComponent)")
            #expect(FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLINT_RECORDING_EXPORT_BENCHMARK"] == "1"))
    func maximumCaptureSizeWithChromeExportsToMP4() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 6, fps: 30, size: CGSize(width: 4096, height: 2304))
        let settings = settings()
        let start = ContinuousClock.now
        let output = try await RecordingExporter.export(
            source: source, range: 0...0.2, options: RecordingExportOptions(format: .mp4),
            outputDirectory: fixture.outputDirectory,
            frameRenderer: { frame, _ in try Compositor.render(image: frame, settings: settings) })
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 4120, height: 2368))
        print("Styled MP4 maximum-size smoke: 0.2s 4096×2304 source, \(start.duration(to: .now))")
    }
}
