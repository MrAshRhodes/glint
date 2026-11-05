import AppKit
import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import GlintCore
@testable import GlintEditor

/// Counts calls from an export that runs off the main actor.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

@Suite("Recording editor model")
@MainActor
struct RecordingEditorModelTests {
    // MARK: Options and limits

    @Test func startsWithTheWholeRecordingAndSensibleGIFDefaults() throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let model = RecordingEditorModel(recording: try fixture.paperRecording(duration: 12), services: fixture.services())

        #expect(model.trim.range == 0...12 && model.trim.isFullRange)
        #expect(model.options.format == .gif)
        #expect(model.options.gif == GIFExportOptions(framesPerSecond: 15, maxWidth: .w640))
        #expect(model.exportState == .idle && model.canExport && model.gifLimitIssue == nil)
    }

    @Test func outputSizeAndEstimateFollowTheOptions() throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let model = RecordingEditorModel(recording: try fixture.paperRecording(duration: 10, size: CGSize(width: 1920, height: 1080)),
                                         services: fixture.services())

        #expect(model.outputSizeText == "640 × 360 px")
        #expect(model.estimatedSizeText?.hasPrefix("about ") == true)
        model.options.gif.maxWidth = .w480
        #expect(model.outputSizeText == "480 × 270 px")
        model.options.gif.maxWidth = .original
        #expect(model.outputSizeText == "1280 × 720 px")

        model.options.format = .mp4
        #expect(model.outputSizeText == "1920 × 1080 px")
        #expect(model.estimatedSizeText == nil)
    }

    @Test func handlesClampAndAreLockedWhileExporting() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        var services = fixture.services()
        services.export = { _, _, _, _, _, _ in
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let model = RecordingEditorModel(recording: try fixture.paperRecording(duration: 10), services: services)

        model.setTrimStart(-3)
        model.setTrimEnd(99)
        #expect(model.trim.range == 0...10)
        model.setTrimStart(9.95)
        #expect(model.trim.start == 10 - RecordingTrim.minimumDuration)
        model.setTrimStart(2)
        model.setTrimEnd(6)

        model.copy()
        #expect(model.isExporting)
        model.setTrimStart(4)
        model.setTrimEnd(5)
        #expect(model.trim.range == 2...6, "the range can't change under a running export")

        model.cancelExport()
        await model.waitForExport()
    }

    @Test func gifOverTheLimitIsFlaggedAndRefusedUntilItFits() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let model = RecordingEditorModel(recording: try fixture.paperRecording(duration: 40), services: fixture.services())

        let issue = try #require(model.gifLimitIssue)
        #expect(issue.maxDuration == 30 && !model.canExport)
        model.save(in: nil)
        model.copy()
        #expect(model.exportState == .idle && fixture.panelRequests == 0, "an over-limit GIF is never started")

        model.fitToGIFLimit()
        #expect(model.trim.start == 0 && model.trim.end == 30)
        #expect(model.gifLimitIssue == nil && model.canExport)
    }

    @Test func fitToLimitFollowsTheFrameRateAndKeepsTheStartHandle() throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let model = RecordingEditorModel(recording: try fixture.paperRecording(duration: 40), services: fixture.services())
        model.setTrimStart(5)
        model.options.gif.framesPerSecond = 20

        #expect(model.gifLimitIssue?.maxDuration == 22.5)
        model.fitToGIFLimit()
        #expect(model.trim.start == 5 && model.trim.end == 27.5)
        #expect(model.gifLimitIssue == nil)
    }

    @Test func mp4HasNoGIFLimit() throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let model = RecordingEditorModel(recording: try fixture.paperRecording(duration: 120), services: fixture.services())

        #expect(model.gifLimitIssue != nil && !model.canExport)
        model.options.format = .mp4
        #expect(model.gifLimitIssue == nil && model.canExport)
    }

    @Test func shortRecordingsAreExportableWhole() throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let model = RecordingEditorModel(recording: try fixture.paperRecording(duration: 0.1), services: fixture.services())

        model.setTrimStart(0.05)
        #expect(model.trim.start == 0 && model.trim.end == 0.1 && model.canExport)
    }

    // MARK: Source file

    @Test func realDurationReplacesTheReportedOne() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let real = try await fixture.recording(frames: 20, fps: 10)
        let reported = RecordedVideo(url: real.url, duration: 5, pixelSize: real.pixelSize)
        let model = RecordingEditorModel(recording: reported, services: fixture.services())

        await model.refreshDuration()
        #expect(abs(model.trim.sourceDuration - 2) < 0.15)
        #expect(model.trim.isFullRange && model.sourceProblem == nil)
    }

    @Test func anUnreadableFileBlocksExports() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let model = RecordingEditorModel(recording: try fixture.paperRecording(duration: 3), services: fixture.services())

        await model.refreshDuration()
        #expect(model.sourceProblem?.contains("can't be read") == true)
        #expect(!model.canExport)
        model.copy()
        #expect(model.exportState == .idle)
    }

    // MARK: Saving

    @Test func savingTrimmedGIFWritesTheChosenFileAndLeavesTheSource() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording(frames: 30, fps: 10)
        let model = RecordingEditorModel(recording: recording, services: fixture.services())
        model.setTrimStart(0.5)
        model.setTrimEnd(2.0)
        model.options.gif = GIFExportOptions(framesPerSecond: 10, maxWidth: .w480)
        let destination = try #require(fixture.chosenDestination)

        model.save(in: nil)
        #expect(fixture.panelRequests == 1)
        await model.waitForExport()

        #expect(model.exportState == .done("Saved Export.gif"))
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 15)
        #expect(FileManager.default.fileExists(atPath: recording.url.path))
        #expect(fixture.stagingLeftovers.isEmpty)
    }

    @Test func savingMP4WritesPlayableVideoOfTheTrimmedLength() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording(frames: 30, fps: 10)
        let model = RecordingEditorModel(recording: recording, services: fixture.services())
        model.options.format = .mp4
        model.setTrimStart(1)
        model.setTrimEnd(2)
        let destination = fixture.directory.appendingPathComponent("saved/Clip.mp4")
        fixture.chosenDestination = destination

        model.save(in: nil)
        await model.waitForExport()

        #expect(model.exportState == .done("Saved Clip.mp4"))
        let duration = try await RecordingExporter.readableDuration(of: AVURLAsset(url: destination))
        #expect(abs(duration - 1) < 0.2)
        #expect(FileManager.default.fileExists(atPath: recording.url.path))
        #expect(fixture.stagingLeftovers.isEmpty)
    }

    @Test func cancellingTheSavePanelDoesNothing() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let model = RecordingEditorModel(recording: try await fixture.recording(), services: fixture.services())
        fixture.chosenDestination = nil

        model.save(in: nil)

        #expect(fixture.panelRequests == 1)
        #expect(model.exportState == .idle && !model.hasRunningTask && model.lastAction == nil)
        #expect(fixture.stagingLeftovers.isEmpty)
    }

    @Test func savingOverAnExistingFileReplacesIt() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let model = RecordingEditorModel(recording: try await fixture.recording(frames: 20, fps: 10), services: fixture.services())
        let destination = try #require(fixture.chosenDestination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination)

        model.save(in: nil)
        await model.waitForExport()

        #expect(model.exportState == .done("Saved Export.gif"))
        #expect(CGImageSourceCreateWithURL(destination as CFURL, nil).map(CGImageSourceGetCount) ?? 0 > 1)
    }

    // MARK: Failures

    @Test func aFailedExportKeepsTheSourceAndRetryRepeatsTheSameSave() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording(frames: 20, fps: 10)
        let attempts = Counter()
        var services = fixture.services()
        services.export = { source, range, options, directory, progress, renderer in
            if attempts.next() == 1 { throw RecordingExportError.encodingFailed("the disk is on fire") }
            return try await RecordingExporter.export(source: source, range: range, options: options,
                                                      outputDirectory: directory, progress: progress, frameRenderer: renderer)
        }
        let model = RecordingEditorModel(recording: recording, services: services)
        let destination = try #require(fixture.chosenDestination)

        model.save(in: nil)
        await model.waitForExport()
        #expect(model.exportState == .failed(RecordingExportError.encodingFailed("the disk is on fire").localizedDescription))
        #expect(model.canRetry && model.canExport)
        #expect(FileManager.default.fileExists(atPath: recording.url.path), "a failed export must not delete the recording")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(fixture.stagingLeftovers.isEmpty)

        model.retry()
        #expect(model.isExporting)
        await model.waitForExport()
        #expect(model.exportState == .done("Saved Export.gif"))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: recording.url.path))
        #expect(fixture.panelRequests == 1, "Retry reuses the chosen destination instead of asking again")
        #expect(!model.canRetry)
    }

    @Test func aFailedFinalMoveKeepsTheSourceAndCleansUpStaging() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording(frames: 20, fps: 10)
        var services = fixture.services()
        services.commit = { _, _ in throw RecordingExportError.writeFailed("the volume is read-only") }
        let model = RecordingEditorModel(recording: recording, services: services)

        model.save(in: nil)
        await model.waitForExport()

        #expect(model.exportState == .failed("Couldn't write the file: the volume is read-only"))
        #expect(FileManager.default.fileExists(atPath: recording.url.path))
        #expect(fixture.stagingLeftovers.isEmpty)
        #expect(model.canRetry)
    }

    @Test func aMissingStagingFolderIsReportedAndRetryable() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording()
        var services = fixture.services()
        services.makeStagingDirectory = { _ in throw RecordingExportError.writeFailed("no space left") }
        let model = RecordingEditorModel(recording: recording, services: services)

        model.copy()
        await model.waitForExport()

        #expect(model.exportState == .failed("Couldn't write the file: no space left"))
        #expect(FileManager.default.fileExists(atPath: recording.url.path))
        #expect(model.canRetry)
    }

    @Test func aFailedClipboardWriteIsReportedAndKeepsTheSource() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording()
        var services = fixture.services()
        services.copyToPasteboard = { _, _ in throw RecordingExportError.pasteboardWriteFailed }
        let model = RecordingEditorModel(recording: recording, services: services)

        model.copy()
        await model.waitForExport()

        #expect(model.exportState == .failed(RecordingExportError.pasteboardWriteFailed.localizedDescription))
        #expect(FileManager.default.fileExists(atPath: recording.url.path))
        #expect(fixture.stagingLeftovers.isEmpty)
    }

    // MARK: Copying

    @Test func copyPutsTheAnimatedGIFAndAFileOnTheClipboard() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording(frames: 20, fps: 10)
        let model = RecordingEditorModel(recording: recording, services: fixture.services())

        model.copy()
        await model.waitForExport()

        #expect(model.exportState == .done("Copied to the clipboard"))
        let item = try #require(fixture.board.pasteboardItems?.first)
        let gifType = NSPasteboard.PasteboardType("com.compuserve.gif")
        let data = try #require(item.data(forType: gifType))
        let pasted = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(pasted) > 1)
        let path = try #require(item.string(forType: .fileURL).flatMap(URL.init(string:)))
        #expect(FileManager.default.fileExists(atPath: path.path) && path.pathExtension == "gif")
        #expect(FileManager.default.fileExists(atPath: recording.url.path))
        #expect(fixture.stagingLeftovers.isEmpty)
    }

    @Test func copyingMP4PutsOnlyAFileOnTheClipboard() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let model = RecordingEditorModel(recording: try await fixture.recording(frames: 20, fps: 10), services: fixture.services())
        model.options.format = .mp4

        model.copy()
        await model.waitForExport()

        #expect(model.exportState == .done("Copied to the clipboard"))
        let item = try #require(fixture.board.pasteboardItems?.first)
        #expect(Set(item.types) == [.fileURL])
        let path = try #require(item.string(forType: .fileURL).flatMap(URL.init(string:)))
        #expect(path.pathExtension == "mp4" && FileManager.default.fileExists(atPath: path.path))
    }

    // MARK: Progress and cancelling

    @Test func progressIsReportedAndNeverGoesBackwards() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        var services = fixture.services()
        services.export = { _, _, _, _, progress, _ in
            progress(0.5)
            progress(0.2)
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let model = RecordingEditorModel(recording: try fixture.paperRecording(duration: 5), services: services)

        model.copy()
        await waitUntil { model.exportState == .running(0.5) }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(model.exportState == .running(0.5))
        #expect(model.statusText == "Exporting… 50%")
        model.cancelExport()
        await model.waitForExport()
    }

    @Test func cancellingStopsTheExportAndLeavesNothingBehind() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try fixture.paperRecording(duration: 5)
        let log = EventLog()
        var services = fixture.services()
        services.export = { _, _, _, directory, _, _ in
            try Data("partial".utf8).write(to: directory.appendingPathComponent("partial.gif"))
            log.add("started")
            do {
                while true { try await Task.sleep(nanoseconds: 5_000_000) }
            } catch {
                log.add("cancelled")
                throw error
            }
        }
        let model = RecordingEditorModel(recording: recording, services: services)
        let destination = try #require(fixture.chosenDestination)

        model.save(in: nil)
        await waitUntil { log.events.contains("started") }
        #expect(model.isExporting && !fixture.stagingLeftovers.isEmpty)

        model.cancelExport()
        await model.waitForExport()

        #expect(log.events == ["started", "cancelled"])
        #expect(model.exportState == .cancelled && model.statusText == "Export cancelled.")
        #expect(fixture.stagingLeftovers.isEmpty, "the partial file's staging folder is removed")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: recording.url.path))
        #expect(model.canExport, "after cancelling, the editor is usable again")
    }

    @Test func onlyOneExportRunsAtATime() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let started = Counter()
        var services = fixture.services()
        services.export = { _, _, _, _, _, _ in
            _ = started.next()
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let model = RecordingEditorModel(recording: try fixture.paperRecording(duration: 5), services: services)

        model.copy()
        model.copy()
        model.save(in: nil)
        await waitUntil { model.isExporting }
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(started.next() == 2, "only the first request reached the exporter")
        #expect(fixture.panelRequests == 0)
        model.cancelExport()
        await model.waitForExport()
    }

    @Test func exportsUseTheTrimAndOptionsFromTheMomentTheyStart() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let seen = EventLog()
        var services = fixture.services()
        services.export = { _, range, options, _, _, _ in
            seen.add("\(range.lowerBound)-\(range.upperBound) \(options.format.rawValue) \(options.gif.framesPerSecond)")
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let model = RecordingEditorModel(recording: try fixture.paperRecording(duration: 10), services: services)
        model.setTrimStart(1.5)
        model.setTrimEnd(4.5)
        model.options.gif.framesPerSecond = 10

        model.copy()
        await waitUntil { !seen.events.isEmpty }
        model.cancelExport()
        await model.waitForExport()

        #expect(seen.events == ["1.5-4.5 gif 10"])
    }
}
