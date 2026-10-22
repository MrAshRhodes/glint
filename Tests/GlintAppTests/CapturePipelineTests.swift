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
    var failRender = false
    var lines: [RecognizedLine] = []
    var recognizedImages: [CGImage] = []
    var bakedImages: [CGImage] = []
    var renderedImages: [CGImage] = []
    var retryRequests: [(title: String, message: String)] = []
    var retry: () -> Bool = { false }

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
        services.recognize = { [self] image, _ in
            recognizedImages.append(image)
            if failRecognition { throw TestFailure.recognition }
            return lines
        }
        services.bake = { [self] image, annotations in
            bakedImages.append(image)
            return failBake ? nil : AnnotationRenderer.bake(source: image, annotations: annotations)
        }
        services.render = { [self] image, settings, backingScale, wallpaper in
            renderedImages.append(image)
            if failRender { throw RenderError.annotationsNotApplied }
            return try Compositor.render(image: image, settings: settings, backingScale: backingScale, wallpaper: wallpaper)
        }
        services.notify = { [self] in notifications.append(($0, $1, $2)) }
        services.requestRetry = { [self] title, message in
            retryRequests.append((title, message))
            return retry()
        }
        services.addRecent = { [self] in recent.append($0) }
        services.sound = { [self] in sounds += 1 }
        return CapturePipeline(prefs: preferences, presetStore: presets, services: services)
    }

    func run(clipboardOnly: Bool = false, saveRaw: Bool = false) async {
        await pipeline().handle(image: image, scale: 2, source: "test", rawURL: nil,
                                saveRaw: saveRaw, clipboardOnly: clipboardOnly)
    }

    func cleanUp() {
        retry = { false }
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

    @Test func failedRenderNeverSavesOrCopies() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.copyToClipboardAfterCapture = true
        f.failRender = true
        await f.run()
        #expect(f.writes.isEmpty && f.copies == 0 && f.recent.isEmpty)
        #expect(f.notifications.map(\.title) == ["Screenshot not exported"])
        #expect(f.notifications.first?.body == RenderError.annotationsNotApplied.localizedDescription)
        #expect(f.notifications.first?.url == nil)
    }

    @Test func failedRenderInClipboardOnlyModeNeverCopies() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.failRender = true
        await f.run(clipboardOnly: true)
        #expect(f.writes.isEmpty && f.copies == 0 && f.copiedImage == nil)
        #expect(f.notifications.map(\.title) == ["Screenshot not exported"])
    }

    @Test(arguments: RedactionStyle.allCases)
    func successfulRedactionIsBakedIntoExportDespiteLegacyStyle(_ legacyStyle: RedactionStyle) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.defaults.set(legacyStyle.rawValue, forKey: AppPreferences.Key.redactStyle)
        f.preferences.autoRedact = true
        f.preferences.copyToClipboardAfterCapture = true
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        await f.run()
        let url = try #require(f.recent.first)
        let image = try #require(GlintImageIO.load(url: url))
        let copied = try #require(f.copiedImage)
        for output in [image, copied] {
            let pixels = try #require(PixelBuffer(output))
            for y in 7..<33 { for x in 7..<93 {
                #expect(pixels.pixel(x, y) == (0, 0, 0, 255))
            } }
            #expect(pixels.pixel(0, 0) == (255, 255, 255, 255))
        }
        #expect(f.copies == 1)
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

    @Test func retryAlertOffersRecoveryWithoutShowingCapturedPixels() throws {
        let alert = CaptureRecovery.alert(title: "Auto-redaction failed", message: "Redactions could not be applied.")
        #expect(alert.messageText == "Auto-redaction failed")
        #expect(alert.informativeText.contains("No safe output was saved or copied."))
        #expect(alert.informativeText.contains("stays in memory"))
        #expect(alert.informativeText.contains("No additional raw image is saved"))
        #expect(alert.buttons.map(\.title) == ["Retry", "Discard Capture"])
        #expect(alert.buttons.first?.keyEquivalent == "\r")
        #expect(alert.accessoryView == nil)
    }

    @Test func retriesOCRAndBakeWithoutLosingPixelsOrRequiredRedactions() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        f.failRecognition = true
        f.failBake = true
        f.retry = {
            #expect(f.writes.isEmpty && f.copies == 0 && f.renderedImages.isEmpty)
            f.preferences.autoRedact = false
            f.preferences.autoRedactOptions = SensitiveInfoOptions(categories: [])
            f.preferences.redactColor = .white
            if f.retryRequests.count == 2 { f.failRecognition = false }
            if f.retryRequests.count == 4 { f.failBake = false }
            return f.retryRequests.count <= 4
        }
        await f.run()
        #expect(f.retryRequests.count == 4)
        #expect(f.recognizedImages.count == 3 && f.bakedImages.count == 3)
        #expect(f.recognizedImages.allSatisfy { $0 === f.image })
        #expect(f.bakedImages.allSatisfy { $0 === f.image })
        #expect(f.sounds == 1 && f.writes.count == 1 && f.copies == 0)
        let savedURL = try #require(f.recent.first)
        let saved = try #require(GlintImageIO.load(url: savedURL))
        #expect(try #require(PixelBuffer(saved)).pixel(50, 20) == (0, 0, 0, 255))
    }

    @Test(arguments: [false, true])
    func discardingRepeatedRedactionFailuresNeverExports(bakeFailure: Bool) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        f.failRecognition = !bakeFailure
        f.failBake = bakeFailure
        f.retry = {
            #expect(f.writes.isEmpty && f.copies == 0 && f.renderedImages.isEmpty)
            return f.retryRequests.count < 100
        }
        await f.run()
        #expect(f.retryRequests.count == 100)
        #expect(f.recognizedImages.count == (bakeFailure ? 1 : 100))
        #expect(f.bakedImages.count == (bakeFailure ? 100 : 0))
        #expect(f.writes.isEmpty && f.copies == 0 && f.recent.isEmpty)
        #expect(f.renderedImages.isEmpty && f.sounds == 1)
    }

    @Test func retriesDoNotRepeatExplicitRawSaveOrCaptureSound() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.preferences.saveRaw = true
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        f.failBake = true
        f.failRender = true
        f.retry = {
            #expect(f.writes.count == 1 && f.copies == 0 && f.sounds == 1)
            if f.retryRequests.count == 2 { f.failBake = false }
            if f.retryRequests.count == 4 { f.failRender = false }
            return f.retryRequests.count <= 4
        }
        await f.run(saveRaw: true)
        #expect(f.retryRequests.count == 4 && f.sounds == 1)
        #expect(f.recognizedImages.count == 1 && f.bakedImages.count == 3 && f.renderedImages.count == 3)
        #expect(f.writes.count == 2 && f.recent.count == 1)
        #expect(f.writes.filter { $0.url.deletingLastPathComponent().lastPathComponent == "Raw" }.count == 1)
        let rawURL = try #require(f.writes.first?.url)
        let savedURL = try #require(f.recent.first)
        let raw = try #require(GlintImageIO.load(url: rawURL))
        let saved = try #require(GlintImageIO.load(url: savedURL))
        #expect(try #require(PixelBuffer(raw)).pixel(50, 20) == (255, 255, 255, 255))
        #expect(try #require(PixelBuffer(saved)).pixel(50, 20) == (0, 0, 0, 255))
    }

    @Test func renderRetryKeepsRedactedInputAndClipboardOnlyPolicy() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.preferences.openEditorAfterCapture = true
        f.lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 10, width: 80, height: 20))]
        f.failRender = true
        f.retry = {
            #expect(f.writes.isEmpty && f.copies == 0 && f.recent.isEmpty)
            f.preferences.autoRedact = false
            f.preferences.saveOutput = true
            if f.retryRequests.count == 2 { f.failRender = false }
            return f.retryRequests.count <= 2
        }
        await f.run(clipboardOnly: true)
        #expect(f.retryRequests.count == 2)
        #expect(f.recognizedImages.count == 1 && f.bakedImages.count == 1 && f.renderedImages.count == 3)
        let redacted = try #require(f.renderedImages.first)
        #expect(redacted !== f.image)
        #expect(f.renderedImages.allSatisfy { $0 === redacted })
        #expect(try #require(PixelBuffer(redacted)).pixel(50, 20) == (0, 0, 0, 255))
        let copied = try #require(f.copiedImage)
        #expect(try #require(PixelBuffer(copied)).pixel(50, 20) == (0, 0, 0, 255))
        #expect(f.writes.isEmpty && f.recent.isEmpty && f.copies == 1 && f.sounds == 1)
        #expect(f.notifications.last?.title == "Copied to clipboard")
    }

    @Test(arguments: [false, true])
    func discardingRepeatedRenderFailuresNeverExports(clipboardOnly: Bool) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.failRender = true
        f.retry = {
            #expect(f.writes.isEmpty && f.copies == 0 && f.recent.isEmpty)
            return f.retryRequests.count < 100
        }
        await f.run(clipboardOnly: clipboardOnly)
        #expect(f.retryRequests.count == 100 && f.renderedImages.count == 100)
        #expect(f.renderedImages.allSatisfy { $0 === f.image })
        #expect(f.writes.isEmpty && f.copies == 0 && f.recent.isEmpty && f.sounds == 1)
    }
}
