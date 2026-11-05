import AVFoundation
import Foundation
import Testing
@testable import GlintCore

@Suite("Recording MP4 export")
struct RecordingExporterMP4Tests {
    private let mp4 = RecordingExportOptions(format: .mp4)

    private func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    @Test func trimmedExportHasTheRangeDuration() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 40, fps: 10)
        let progress = ProgressLog()

        let output = try await RecordingExporter.export(source: source, range: 1.0...2.5, options: mp4,
                                                        outputDirectory: fixture.outputDirectory) { progress.record($0) }

        #expect(output.pathExtension == "mp4" && output.deletingLastPathComponent() == fixture.outputDirectory)
        #expect(abs(try await duration(of: output) - 1.5) < 0.15)
        #expect(progress.all.last == 1)
        #expect(fixture.outputs() == [output.lastPathComponent])
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 160, height: 90))
    }

    @Test func trimmedExportStartsAtTheRequestedFrame() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 40, fps: 10)

        let output = try await RecordingExporter.export(source: source, range: 2.0...3.0, options: mp4,
                                                        outputDirectory: fixture.outputDirectory)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        // The default tolerance lets the generator hand back any nearby keyframe, not the first frame.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = try await generator.image(at: .zero).image
        // Red ramps 0→255 across the 4 s source, so a frame taken at 2.0 s is about half red.
        let red = Double(TestImages.pixel(first, 100, 60).r)
        #expect(abs(red - 255.0 * 2.0 / 3.9) < 30, "red was \(red)")
    }

    @Test func wholeFileExportKeepsTheDuration() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 30, fps: 10)
        let full = try await duration(of: source)

        let output = try await RecordingExporter.export(source: source, range: 0...full, options: mp4,
                                                        outputDirectory: fixture.outputDirectory)

        #expect(abs(try await duration(of: output) - full) < 0.15)
        #expect(output != source)
    }

    @Test func cancellingThrowsCancellationAndLeavesNoPartialFile() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 100, fps: 5)
        let outputDirectory = fixture.outputDirectory
        let options = mp4

        let task = Task {
            try await RecordingExporter.export(source: source, range: 1...15, options: options, outputDirectory: outputDirectory)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.outputs().isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func missingSourceIsReportedByName() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let missing = fixture.directory.appendingPathComponent("gone.mp4")

        await #expect(throws: RecordingExportError.sourceMissing("gone.mp4")) {
            try await RecordingExporter.export(source: missing, range: 0...1, options: mp4, outputDirectory: fixture.outputDirectory)
        }
        #expect(RecordingExportError.sourceMissing("gone.mp4").errorDescription?.contains("gone.mp4") == true)
    }

    @Test func unreadableSourceIsReported() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let bogus = fixture.directory.appendingPathComponent("bogus.mp4")
        try Data("definitely not a video".utf8).write(to: bogus)

        do {
            _ = try await RecordingExporter.export(source: bogus, range: 0...1, options: mp4, outputDirectory: fixture.outputDirectory)
            Issue.record("a text file must not export")
        } catch let error as RecordingExportError {
            guard case .sourceUnreadable = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(error.errorDescription?.isEmpty == false)
        }
        #expect(fixture.outputs().isEmpty)
    }

    @Test func invalidRangesAreRejectedBeforeAnyWork() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 20, fps: 10)   // 2 s

        for range in [3.0...4.0, 1.5...5.0] {
            do {
                _ = try await RecordingExporter.export(source: source, range: range, options: mp4, outputDirectory: fixture.outputDirectory)
                Issue.record("\(range) lies outside a 2 s recording")
            } catch let error as RecordingExportError {
                guard case .invalidRange = error else {
                    Issue.record("wrong error for \(range): \(error)")
                    continue
                }
            }
        }
        await #expect(throws: RecordingExportError.rangeTooShort(minimum: 0.2)) {
            try await RecordingExporter.export(source: source, range: 1.0...1.1, options: mp4, outputDirectory: fixture.outputDirectory)
        }
        #expect(fixture.outputs().isEmpty)
    }

    @Test func rangeEndingSlightlyPastTheFileIsClamped() throws {
        #expect(try RecordingExporter.validatedRange(0.5...2.05, sourceDuration: 2.0) == 0.5...2.0)
        #expect(try RecordingExporter.validatedRange(0...2.0, sourceDuration: 2.0) == 0...2.0)
        #expect(throws: RecordingExportError.self) { try RecordingExporter.validatedRange(0.5...2.5, sourceDuration: 2.0) }
        #expect(throws: RecordingExportError.self) { try RecordingExporter.validatedRange(-0.5...1, sourceDuration: 2.0) }
        #expect(throws: RecordingExportError.self) { try RecordingExporter.validatedRange(0...1, sourceDuration: 0) }
    }

    @Test func aRecordingShorterThanTheMinimumCanStillBeExportedWhole() throws {
        #expect(try RecordingExporter.validatedRange(0...0.1, sourceDuration: 0.1) == 0...0.1)
        #expect(throws: RecordingExportError.self) { try RecordingExporter.validatedRange(0...0.05, sourceDuration: 0.1) }
    }
}
