import AppKit
import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import GlintCore
@testable import GlintEditor

@Suite("Recording editor window")
@MainActor
struct RecordingEditorWindowTests {
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func theEditorOwnsTheSourceUntilTheWindowCloses() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording()
        let controller = RecordingEditorWindowController(recording: recording)
        var closes = 0
        controller.onClose = { closes += 1 }
        let window = try #require(controller.window)

        #expect(exists(recording.url) && closes == 0)
        #expect(window.title == "Glint — Recording")
        #expect(!window.isReleasedWhenClosed)
        #expect(window.delegate === controller)

        window.close()

        #expect(!exists(recording.url), "the temporary recording goes away with the window")
        #expect(closes == 1)
    }

    @Test func closingTwiceReportsOnceAndSurvivesAMissingFile() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording()
        let controller = RecordingEditorWindowController(recording: recording, services: fixture.services())
        var closes = 0
        controller.onClose = { closes += 1 }
        let window = try #require(controller.window)
        try FileManager.default.removeItem(at: recording.url)

        window.close()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        window.close()

        #expect(closes == 1)
    }

    @Test func aFailedExportDoesNotDeleteTheSourceSoRetryWorks() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording()
        var services = fixture.services()
        let attempts = AttemptCounter()
        services.export = { source, range, options, directory, progress, renderer in
            if attempts.next() == 1 { throw RecordingExportError.encodingFailed("boom") }
            return try await RecordingExporter.export(source: source, range: range, options: options,
                                                      outputDirectory: directory, progress: progress, frameRenderer: renderer)
        }
        let controller = RecordingEditorWindowController(recording: recording, services: services)
        var closes = 0
        controller.onClose = { closes += 1 }

        controller.save()
        await controller.model.waitForExport()
        guard case .failed = controller.model.exportState else {
            Issue.record("expected a failure, got \(controller.model.exportState)")
            return
        }
        #expect(exists(recording.url) && closes == 0)

        controller.model.retry()
        await controller.model.waitForExport()
        #expect(controller.model.exportState == .done("Saved Export.gif"))
        #expect(exists(try #require(fixture.chosenDestination)))
        #expect(exists(recording.url) && closes == 0, "even a finished export leaves the file until the window closes")

        controller.window?.close()
        #expect(!exists(recording.url) && closes == 1)
    }

    @Test func saveGoesThroughThePanelAndExportsTheTrim() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording(frames: 30, fps: 10)
        let controller = RecordingEditorWindowController(recording: recording, services: fixture.services())
        controller.model.setTrimEnd(1)
        controller.model.options.gif.framesPerSecond = 10

        controller.save()
        await controller.model.waitForExport()

        let destination = try #require(fixture.chosenDestination)
        #expect(fixture.panelRequests == 1)
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 10)
        controller.window?.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func closingDuringAnExportCancelsItThenDeletesTheSourceAndReportsOnce() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try fixture.paperRecording(duration: 5)
        let log = EventLog()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (closed, didClose) = AsyncStream<Void>.makeStream()
        let sourceURL = recording.url
        var services = fixture.services()
        services.export = { _, _, _, _, _, _ in
            log.add("started")
            didStart.yield()
            didStart.finish()
            do {
                while true { try await Task.sleep(nanoseconds: 5_000_000) }
            } catch {
                // Cleanup after cancelling takes a moment; the source must still be there while it runs.
                try? await Task.sleep(nanoseconds: 150_000_000)
                log.add("export finished cleaning up, source exists: \(FileManager.default.fileExists(atPath: sourceURL.path))")
                throw error
            }
        }
        let controller = RecordingEditorWindowController(recording: recording, services: services)
        var closes = 0
        controller.onClose = {
            closes += 1
            log.add("onClose, source exists: \(FileManager.default.fileExists(atPath: sourceURL.path))")
            didClose.yield()
            didClose.finish()
        }

        controller.model.copy()
        for await _ in started {}
        controller.window?.close()

        #expect(closes == 0, "onClose waits for the cancelled export")
        #expect(exists(recording.url), "the file stays while the export is still cleaning up")

        for await _ in closed {}
        #expect(closes == 1)
        #expect(!exists(recording.url))
        #expect(log.events == ["started",
                               "export finished cleaning up, source exists: true",
                               "onClose, source exists: false"])
        #expect(controller.model.exportState == .cancelled)
        #expect(fixture.stagingLeftovers.isEmpty)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(closes == 1)
    }

    @Test(.timeLimit(.minutes(1))) func closingDuringARealExportLeavesNoExportFilesBehind() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording(frames: 200, fps: 20, size: CGSize(width: 960, height: 540))
        let controller = RecordingEditorWindowController(recording: recording, services: fixture.services())
        var closes = 0
        let (closed, didClose) = AsyncStream<Void>.makeStream()
        controller.onClose = {
            closes += 1
            didClose.yield()
            didClose.finish()
        }
        controller.model.options.gif = GIFExportOptions(framesPerSecond: 20, maxWidth: .original)

        controller.save()
        await waitUntil { controller.model.isExporting }
        controller.window?.close()
        for await _ in closed {}

        #expect(closes == 1 && !exists(recording.url))
        #expect(fixture.stagingLeftovers.isEmpty)
        if controller.model.exportState == .cancelled {
            #expect(!exists(try #require(fixture.chosenDestination)), "a cancelled save leaves no file at the destination")
        }
    }

    @Test func nothingStartsAfterTheWindowIsClosed() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording()
        let controller = RecordingEditorWindowController(recording: recording, services: fixture.services())

        controller.window?.close()
        controller.save()
        controller.model.copy()

        #expect(fixture.panelRequests == 0)
        #expect(controller.model.exportState == .idle && !controller.model.canExport)
    }

    @Test func aSavePanelAnsweredAfterCloseStartsNothing() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording()
        var services = fixture.services()
        var answer: ((URL?) -> Void)?
        services.chooseDestination = { _, _, completion in answer = completion }
        let controller = RecordingEditorWindowController(recording: recording, services: services)
        let chosen = try #require(fixture.chosenDestination)

        controller.save()
        controller.window?.close()
        answer?(chosen)

        #expect(controller.model.exportState == .idle && !controller.model.hasRunningTask)
        #expect(!exists(chosen))
    }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
