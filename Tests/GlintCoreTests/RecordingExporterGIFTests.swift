import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import GlintCore

@Suite("Recording GIF export")
struct RecordingExporterGIFTests {
    private func gifOptions(fps: Int = 10, width: GIFMaxWidth = .w640) -> RecordingExportOptions {
        RecordingExportOptions(format: .gif, gif: GIFExportOptions(framesPerSecond: fps, maxWidth: width))
    }

    @Test func producesAnAnimatedLoopingGIFOfTheTrimmedRange() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 40, fps: 10)
        let progress = ProgressLog()

        let output = try await RecordingExporter.export(source: source, range: 1.0...3.0, options: gifOptions(fps: 10),
                                                        outputDirectory: fixture.outputDirectory) { progress.record($0) }

        let gif = try #require(GIFInspection(url: output))
        #expect(output.pathExtension == "gif" && output.deletingLastPathComponent() == fixture.outputDirectory)
        #expect(abs(gif.frameCount - 20) <= 1)
        #expect(gif.loopCount == 0)
        #expect(gif.delays.allSatisfy { abs($0 - 0.1) < 0.011 })
        #expect(abs(gif.totalDuration - 2.0) < 0.15)
        #expect((gif.width, gif.height) == (160, 90))
        #expect(progress.all.last == 1)
        #expect(zip(progress.all, progress.all.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(fixture.outputs() == [output.lastPathComponent])
    }

    @Test func framesComeFromTheTrimmedPartOfTheRecording() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        // Red ramps 0→255 over 4 s, so the red channel reads out the source time of each frame.
        let source = try await fixture.video(frames: 40, fps: 10)

        let output = try await RecordingExporter.export(source: source, range: 2.0...3.0, options: gifOptions(),
                                                        outputDirectory: fixture.outputDirectory)

        let gif = try #require(GIFInspection(url: output))
        let first = TestImages.pixel(try #require(gif.image(at: 0)), 100, 60).r
        let last = TestImages.pixel(try #require(gif.image(at: gif.frameCount - 1)), 100, 60).r
        let expectedFirst = 255.0 * 2.0 / 3.9, expectedLast = 255.0 * 2.9 / 3.9
        #expect(abs(Double(first) - expectedFirst) < 30)
        #expect(abs(Double(last) - expectedLast) < 30)
        #expect(last > first)
    }

    @Test func frameRateSetsFrameCountAndDelay() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 30, fps: 10)

        for fps in [10, 15, 20] {
            let output = try await RecordingExporter.export(source: source, range: 0...2.0, options: gifOptions(fps: fps),
                                                            outputDirectory: fixture.outputDirectory)
            let gif = try #require(GIFInspection(url: output))
            #expect(abs(gif.frameCount - 2 * fps) <= 1, "fps \(fps): \(gif.frameCount) frames")
            // Delays are whole centiseconds, so 15 fps alternates 7 and 6; the total must still match.
            #expect(gif.delays.allSatisfy { abs($0 - 1.0 / Double(fps)) < 0.011 }, "fps \(fps): \(gif.delays)")
            #expect(abs(gif.totalDuration - 2.0) < 0.05, "fps \(fps): \(gif.totalDuration)")
        }
    }

    @Test func scalesDownToMaxWidthButNeverUp() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let wide = try await fixture.video(name: "wide.mp4", frames: 10, fps: 10, size: CGSize(width: 960, height: 540))
        let small = try await fixture.video(name: "small.mp4", frames: 10, fps: 10, size: CGSize(width: 160, height: 90))

        let scaledDown = try await RecordingExporter.export(source: wide, range: 0...0.8, options: gifOptions(width: .w480),
                                                            outputDirectory: fixture.outputDirectory)
        let atOriginal = try await RecordingExporter.export(source: wide, range: 0...0.8, options: gifOptions(width: .original),
                                                            outputDirectory: fixture.outputDirectory)
        let notUpscaled = try await RecordingExporter.export(source: small, range: 0...0.8, options: gifOptions(width: .w720),
                                                             outputDirectory: fixture.outputDirectory)

        let a = try #require(GIFInspection(url: scaledDown))
        let b = try #require(GIFInspection(url: atOriginal))
        let c = try #require(GIFInspection(url: notUpscaled))
        #expect((a.width, a.height) == (480, 270))
        #expect((b.width, b.height) == (960, 540))
        #expect((c.width, c.height) == (160, 90))
    }

    @Test func cancellingMidExportThrowsCancellationAndLeavesNoPartialFile() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        // 20 s at 20 fps is 400 frames: far more work than the moment it takes to cancel.
        let source = try await fixture.video(frames: 100, fps: 5)
        let progress = ProgressLog()
        let outputDirectory = fixture.outputDirectory

        let task = Task {
            try await RecordingExporter.export(source: source, range: 0...19.5, options: gifOptions(fps: 20),
                                               outputDirectory: outputDirectory) { progress.record($0) }
        }
        var waited = 0
        while progress.all.isEmpty, waited < 2000 {
            try await Task.sleep(nanoseconds: 5_000_000)
            waited += 5
        }
        #expect(!progress.all.isEmpty, "the export never reported progress")
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.outputs().isEmpty)
        #expect((progress.all.last ?? 0) < 1)
    }

    @Test func refusesRangesOverTheGIFLimitInsteadOfTruncating() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 70, fps: 2)   // 35 s

        await #expect(throws: RecordingExportError.self) {
            try await RecordingExporter.export(source: source, range: 0...31, options: gifOptions(fps: 10),
                                               outputDirectory: fixture.outputDirectory)
        }
        do {
            _ = try await RecordingExporter.export(source: source, range: 0...25, options: gifOptions(fps: 20),
                                                   outputDirectory: fixture.outputDirectory)
            Issue.record("25 s at 20 fps is 500 frames and must be refused")
        } catch let error as RecordingExportError {
            guard case .gifLimitExceeded(let issue) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(issue.frameCount == 500 && issue.maxDuration == 22.5)
            #expect(error.errorDescription?.contains("22.5 s") == true)
        }
        #expect(fixture.outputs().isEmpty)
    }

    @Test func exportsExactlyTheLimitWithoutDroppingFrames() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 120, fps: 4)   // 30 s

        let output = try await RecordingExporter.export(source: source, range: 0...22.5, options: gifOptions(fps: 20, width: .w480),
                                                        outputDirectory: fixture.outputDirectory)

        let gif = try #require(GIFInspection(url: output))
        #expect(gif.frameCount == GIFLimits.maxFrameCount)
        #expect(abs(gif.totalDuration - 22.5) < 0.1)
    }

    @Test func rejectsUnsupportedFrameRates() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 10, fps: 10)

        await #expect(throws: RecordingExportError.unsupportedFrameRate(12)) {
            try await RecordingExporter.export(source: source, range: 0...0.9, options: gifOptions(fps: 12),
                                               outputDirectory: fixture.outputDirectory)
        }
    }
}
