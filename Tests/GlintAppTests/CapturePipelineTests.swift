import AppKit
@testable import GlintCore
import Testing
@testable import Glint

private enum TestFailure: Error { case write, recognition }

@MainActor
private final class CaptureFixture {
    let suite = "glint.pipeline.tests.\(UUID().uuidString)"
    let directory: URL
    let preferences: AppPreferences
    let presets: PresetStore
    let image: CGImage
    var writes: [(url: URL, format: ExportFormat, scale: ExportScale, backingScale: CGFloat)] = []
    var notifications: [(title: String, body: String, url: URL?)] = []
    var recent: [URL] = []
    var copies = 0
    var copiedImage: CGImage?
    var copiedTexts: [String] = []
    var sounds = 0
    var wallpaper: Result<CGImage, DesktopWallpaperError> = .failure(.unavailable)
    var wallpaperReads = 0
    var failWrite = false
    var failRaw = false
    var copySucceeds = true
    var failRecognition = false
    var failBake = false
    var lines: [RecognizedLine] = []

    init() throws {
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/TestFixtures/\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: suite))
        preferences = AppPreferences(defaults: defaults)
        preferences.saveDirectory = directory.appendingPathComponent("Manual")
        preferences.historyDirectory = directory.appendingPathComponent("History")
        preferences.openEditorAfterCapture = false
        preferences.autoBalance = false
        preferences.autoRedact = false
        preferences.saveRaw = false
        defaults.set(false, forKey: ShellKey.quickAccess)
        presets = PresetStore(url: directory.appendingPathComponent("presets.json"))
        let preset = presets.add(name: "Test", settings: RenderSettings(
            padding: 0, cornerRadius: 0, shadow: .none, background: .transparent
        ))
        presets.setDefault(id: preset.id)
        let context = try #require(GlintBitmap.makeContext(width: 100, height: 40))
        context.setFillColor(RGBAColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 40))
        image = try #require(context.makeImage())
    }

    func pipeline() -> CapturePipeline {
        var services = CapturePipeline.Services()
        services.write = { [self] image, url, format, scale, backingScale in
            writes.append((url, format, scale, backingScale))
            if failWrite || failRaw && url.deletingLastPathComponent().lastPathComponent == "Raw" {
                throw TestFailure.write
            }
            return try Exporter.write(image, to: url, format: format, scale: scale, backingScale: backingScale)
        }
        services.copy = { [self] image in copies += 1; copiedImage = image; return copySucceeds }
        services.copyText = { [self] in copiedTexts.append($0) }
        services.wallpaper = { [self] in wallpaperReads += 1; return wallpaper }
        services.recognize = { [self] _, _ in
            if failRecognition { throw TestFailure.recognition }
            return lines
        }
        services.bake = { [self] image, annotations in
            failBake ? nil : AnnotationRenderer.bake(source: image, annotations: annotations)
        }
        services.notify = { [self] in notifications.append(($0, $1, $2)) }
        services.addRecent = { [self] in recent.append($0) }
        services.sound = { [self] in sounds += 1 }
        return CapturePipeline(prefs: preferences, presetStore: presets, services: services)
    }

    func run(clipboardOnly: Bool = false, saveRaw: Bool = false) async {
        await pipeline().handle(image: image, scale: 2, source: "test", rawURL: nil,
                                saveRaw: saveRaw, clipboardOnly: clipboardOnly)
    }

    func cleanUp() {
        preferences.defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Capture export outcomes")
@MainActor
struct CapturePipelineTests {
    @Test(arguments: [
        "demo-password-4826",
        "recovery-code-1234\n" + String(repeating: "token-", count: 30) + "\ncaf\u{00E9} \u{1F511}"
    ])
    func captureTextKeepsRecognizedContentOutOfNotifications(text: String) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.lines = text.components(separatedBy: "\n").map { RecognizedLine(text: $0, box: .zero) }
        await f.pipeline().recognizeText(in: f.image)
        #expect(f.copiedTexts == [text])
        #expect(f.sounds == 1)
        #expect(f.notifications.count == 1)
        let notification = try #require(f.notifications.first)
        #expect(notification.title == "Text copied")
        #expect(notification.body == "Recognized text copied to clipboard")
        #expect(notification.url == nil)
    }

    @Test func captureTextWithNoTextDoesNotCopyOrReportSuccess() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        await f.pipeline().recognizeText(in: f.image)
        #expect(f.copiedTexts.isEmpty && f.sounds == 0)
        #expect(f.notifications.count == 1)
        let notification = try #require(f.notifications.first)
        #expect(notification.title == "No text found")
        #expect(notification.body == "Nothing was recognised in the selected area.")
        #expect(notification.url == nil)
    }

    @Test func captureTextRecognitionFailureDoesNotCopyOrReportSuccess() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.failRecognition = true
        await f.pipeline().recognizeText(in: f.image)
        #expect(f.copiedTexts.isEmpty && f.sounds == 0)
        #expect(f.notifications.count == 1)
        let notification = try #require(f.notifications.first)
        #expect(notification.title == "Text recognition failed")
        #expect(notification.body == TestFailure.recognition.localizedDescription)
        #expect(notification.url == nil)
    }

    @Test func savesAutomaticOutputAndRecordsOnlySuccessfulFile() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.exportFormat = .jpeg(quality: 0.7)
        f.preferences.exportScale = .x1
        await f.run()
        let write = try #require(f.writes.first)
        #expect(write.url.deletingLastPathComponent() == f.preferences.historyDirectory.appendingPathComponent("Output"))
        #expect(write.format == .jpeg(quality: 0.7) && write.scale == .x1 && write.backingScale == 2)
        #expect(GlintImageIO.load(url: write.url)?.width == 50)
        #expect(f.recent == [write.url] && f.copies == 0)
        #expect(f.notifications.map(\.title) == ["Screenshot saved"])
        #expect(f.notifications.first?.url == write.url)
        #expect(f.wallpaperReads == 0)
    }

    @Test func wallpaperPresetUsesSameImageForAutomaticSaveAndCopy() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.presets.add(name: "Test", settings: RenderSettings(
            padding: 20, cornerRadius: 0, shadow: .none, background: .solid(.black), usesDesktopWallpaper: true
        ))
        f.wallpaper = .success(f.image)
        f.preferences.exportFormat = .plainPNG
        f.preferences.exportScale = .original
        f.preferences.copyToClipboardAfterCapture = true
        await f.run()
        let savedURL = try #require(f.recent.first)
        let saved = try #require(GlintImageIO.load(url: savedURL))
        let copied = try #require(f.copiedImage)
        #expect(try #require(PixelBuffer(saved)).pixel(1, 1) == (255, 255, 255, 255))
        #expect(PixelBuffer(saved)?.data == PixelBuffer(copied)?.data)
        #expect(f.wallpaperReads == 1 && f.copies == 1)
        #expect(f.notifications.map(\.title) == ["Screenshot saved"])
    }

    @Test func unreadableWallpaperReportsFallbackWithoutBlockingExport() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.presets.add(name: "Test", settings: RenderSettings(
            padding: 20, cornerRadius: 0, shadow: .none, background: .solid(.black), usesDesktopWallpaper: true
        ))
        f.preferences.exportFormat = .plainPNG
        await f.run()
        let savedURL = try #require(f.recent.first)
        let saved = try #require(GlintImageIO.load(url: savedURL))
        #expect(try #require(PixelBuffer(saved)).pixel(1, 1) == (0, 0, 0, 255))
        #expect(f.notifications.first?.body.contains(DesktopWallpaperError.unavailable.localizedDescription) == true)
        #expect(f.wallpaperReads == 1)
    }

    @Test func clipboardOnlyNeverSavesRenderedOutput() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.openEditorAfterCapture = true
        await f.run(clipboardOnly: true)
        #expect(f.writes.isEmpty && f.recent.isEmpty && f.copies == 1)
        #expect(f.notifications.map(\.title) == ["Copied to clipboard"])
        #expect(f.notifications.first?.url == nil)
    }

    @Test func saveFailureFallsBackToClipboardAndReportsPartialFailure() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.failWrite = true
        await f.run()
        #expect(f.writes.count == 1 && f.copies == 1 && f.recent.isEmpty)
        #expect(f.notifications.map(\.title) == ["Copied to clipboard, but save failed"])
        #expect(f.notifications.first?.body.contains("Save failed:") == true)
        #expect(f.notifications.first?.url == nil)
    }

    @Test func completeFailureNeverReportsSuccessOrAddsRecentFile() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.failWrite = true
        f.copySucceeds = false
        await f.run()
        #expect(f.recent.isEmpty && f.copies == 1)
        #expect(f.notifications.map(\.title) == ["Screenshot export failed"])
        #expect(f.notifications.first?.body.contains("not saved or copied") == true)
        #expect(f.notifications.first?.body.contains("Save failed:") == true)
        #expect(f.notifications.first?.body.contains("Copy to clipboard failed.") == true)
    }

    @Test func clipboardOnlyFailureIsNotReportedAsCopied() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.copySucceeds = false
        await f.run(clipboardOnly: true)
        #expect(f.writes.isEmpty && f.recent.isEmpty)
        #expect(f.notifications.map(\.title) == ["Screenshot export failed"])
    }

    @Test func savedFileSurvivesClipboardFailure() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.copyToClipboardAfterCapture = true
        f.copySucceeds = false
        await f.run()
        let url = try #require(f.recent.first)
        #expect(GlintImageIO.load(url: url) != nil && f.copies == 1)
        #expect(f.notifications.map(\.title) == ["Screenshot saved, but copy failed"])
        #expect(f.notifications.first?.url == url)
    }

    @Test func successfulSaveAndCopyReportsBoth() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.copyToClipboardAfterCapture = true
        await f.run()
        #expect(f.recent.count == 1 && f.copies == 1)
        #expect(f.notifications.map(\.title) == ["Screenshot saved"])
        #expect(f.notifications.first?.body.contains("also copied") == true)
    }

    @Test func disabledOutputSaveStillProducesClipboardOutput() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.saveOutput = false
        await f.run()
        #expect(f.writes.isEmpty && f.copies == 1)
        #expect(f.notifications.map(\.title) == ["Copied to clipboard"])
    }

    @Test func rawSaveFailureIsReportedWithoutDiscardingRenderedOutput() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.saveRaw = true
        f.failRaw = true
        await f.run(saveRaw: true)
        #expect(f.writes.count == 2 && f.recent.count == 1)
        #expect(f.notifications.map(\.title) == ["Raw screenshot not saved", "Screenshot saved"])
    }

    @Test func disabledHistoryUsesManualDirectoryAndSkipsRawSave() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.saveHistory = false
        f.preferences.saveRaw = true
        await f.run(saveRaw: true)
        #expect(f.writes.count == 1)
        #expect(f.writes.first?.url.deletingLastPathComponent() == f.preferences.saveDirectory)
    }

    @Test func failedOCRStopsAutomaticExport() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.failRecognition = true
        await f.run()
        #expect(f.writes.isEmpty && f.copies == 0 && f.recent.isEmpty)
        #expect(f.notifications.map(\.title) == ["Auto-redaction failed"])
    }

    @Test func failedRedactionBakeNeverExportsOriginalImage() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        f.failBake = true
        await f.run()
        #expect(f.writes.isEmpty && f.copies == 0 && f.recent.isEmpty)
        #expect(f.notifications.map(\.title) == ["Auto-redaction failed"])
        #expect(f.notifications.first?.body.contains("redactions could not be applied") == true)
    }

    @Test func successfulRedactionIsBakedIntoExport() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        await f.run()
        let url = try #require(f.recent.first)
        let image = try #require(GlintImageIO.load(url: url))
        let context = try #require(GlintBitmap.makeContext(width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let middle = 20 * context.bytesPerRow + 50 * 4
        #expect(bytes[middle] == 0 && bytes[middle + 1] == 0 && bytes[middle + 2] == 0)
        #expect(f.notifications.map(\.title) == ["Screenshot saved"])
    }

    @Test func successfulOCRWithNoFindingsStillExports() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.failBake = true
        await f.run()
        #expect(f.writes.count == 1 && f.recent.count == 1)
        #expect(f.notifications.map(\.title) == ["Screenshot saved"])
    }
}
