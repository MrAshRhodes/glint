import AppKit
import ImageIO
import Testing
@testable import GlintCore
@testable import GlintEditor

private enum ExportTestFailure: Error { case refused }

/// Runs the real compositor but with an annotation baker that always fails (e.g. bitmap allocation failure).
private let failingBakeRenderer: EditorModel.Renderer = { image, settings, annotations, scale, background, wallpaper in
    try Compositor.renderDetailed(image: image, settings: settings, annotations: annotations, backingScale: scale,
                                  backgroundImage: background, wallpaper: wallpaper, bake: { _, _, _, _ in nil })
}

private let redaction = Annotation(kind: .redact(CGRect(x: 0, y: 0, width: 50, height: 40)),
                                   style: AnnotationStyle(color: .black))

private let notAppliedMessage = RenderError.annotationsNotApplied.localizedDescription

private func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
    )!
}

@Suite("Editor export actions")
@MainActor
struct EditorExportTests {
    @Test func commandCShortcutCopiesImageAndIsConsumed() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.closeAfterCopy = false
        var services = EditorExportServices()
        var copies = 0
        services.copy = { _ in copies += 1; return true }
        let controller = f.controller(services: services)
        defer { controller.window?.close() }

        #expect(controller.handleShortcut(keyEvent("c", modifiers: .command)))
        #expect(copies == 1)
        #expect(controller.model.statusMessage == "Copied to clipboard")
    }

    @Test func modifiedCommandCShortcutIsNotConsumed() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        var copies = 0
        services.copy = { _ in copies += 1; return true }
        let controller = f.controller(services: services)
        defer { controller.window?.close() }

        #expect(!controller.handleShortcut(keyEvent("c", modifiers: [.command, .option])))
        #expect(copies == 0)
    }

    @Test func textFirstResponderBypassesImageCopyShortcut() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        var copies = 0
        services.copy = { _ in copies += 1; return true }
        let controller = f.controller(services: services)
        defer { controller.window?.close() }
        let window = try #require(controller.window as? EditorWindow)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        window.contentView?.addSubview(textView)
        #expect(window.makeFirstResponder(textView))

        _ = window.performKeyEquivalent(with: keyEvent("c", modifiers: .command))
        #expect(copies == 0)
    }

    @Test func failedCopyKeepsWindowOpenAndDoesNotCallExportCallback() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        var canCopy = false
        services.copy = { _ in canCopy }
        var beeps = 0
        services.beep = { beeps += 1 }
        let controller = f.controller(services: services)
        defer { controller.window?.close() }
        var exports = 0, closes = 0
        controller.onExported = { _ in exports += 1 }
        controller.onClose = { closes += 1 }

        #expect(controller.window?.isVisible == false)
        controller.copyAndMaybeClose()
        #expect(exports == 0 && closes == 0 && beeps == 1)
        #expect(controller.model.statusMessage == "Copy failed")
        #expect(!controller.copyToClipboard())
        #expect(exports == 0 && closes == 0)
        let retry = try #require(controller.actions.retryExport)
        canCopy = true
        retry()
        #expect(exports == 1 && closes == 0)
        #expect(controller.actions.retryExport == nil)
        retry()
        #expect(exports == 1)
    }

    @Test func successfulCopyClosesOnlyWhenConfigured() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let pasteboard = NSPasteboard(name: .init("glint.editor.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var services = EditorExportServices()
        services.copy = { Exporter.copyToClipboard($0, pasteboard: pasteboard) }
        let controller = f.controller(services: services)
        var exports: [URL?] = [], closes = 0
        controller.onExported = { exports.append($0) }
        controller.onClose = { closes += 1 }

        f.preferences.closeAfterCopy = false
        controller.copyAndMaybeClose()
        #expect(exports.count == 1 && exports[0] == nil && closes == 0)
        #expect(controller.model.statusMessage == "Copied to clipboard")
        let data = try #require(pasteboard.data(forType: .png))
        let image = try #require(GlintImageIO.load(data: data))
        #expect(image.width == 100 && image.height == 80)
        f.preferences.closeAfterCopy = true
        controller.copyAndMaybeClose()
        #expect(exports.count == 2 && closes == 1)
    }

    @Test func manualSaveUsesManualDirectoryAndCallsBackAfterFileExists() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.compressToJPEG = true
        f.preferences.exportScale = .x1
        let controller = f.controller(services: EditorExportServices())
        defer { controller.window?.close() }
        var urls: [URL] = []
        controller.onExported = { url in
            if let url {
                #expect(GlintImageIO.load(url: url)?.width == 50)
                urls.append(url)
            }
        }
        controller.saveOutput()
        let url = try #require(urls.first)
        #expect(url.deletingLastPathComponent() == f.preferences.saveDirectory)
        #expect(url.pathExtension == "jpg" && urls.count == 1)
        #expect(controller.model.statusMessage == "Saved \(url.lastPathComponent)")
    }

    @Test func failedSaveReportsErrorWithoutExportCallback() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        services.write = { _, _, _, _, _ in throw ExportTestFailure.refused }
        var beeps = 0
        services.beep = { beeps += 1 }
        let controller = f.controller(services: services)
        defer { controller.window?.close() }
        var exports = 0
        controller.onExported = { _ in exports += 1 }
        controller.saveOutput()
        #expect(exports == 0 && beeps == 1)
        #expect(controller.model.statusMessage?.hasPrefix("Save failed:") == true)
        #expect(controller.actions.retryExport != nil)
    }

    @Test func closingEditorRemovesEveryDragPayloadButNotOtherFiles() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        services.dragDirectory = f.directory.appendingPathComponent("Drag")
        let controller = f.controller(services: services)
        let first = try #require(controller.prepareDragFile())
        let second = try #require(controller.prepareDragFile())
        #expect(first != second)
        #expect(GlintImageIO.load(url: first) != nil && GlintImageIO.load(url: second) != nil)
        let unrelated = services.dragDirectory.appendingPathComponent("keep.png")
        try Data([1, 2, 3]).write(to: unrelated)
        controller.window?.close()
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func dragWriteFailureIsVisibleAndReturnsNoPayload() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        services.dragDirectory = f.directory.appendingPathComponent("Drag")
        services.write = { _, _, _, _, _ in throw ExportTestFailure.refused }
        var beeps = 0
        services.beep = { beeps += 1 }
        let controller = f.controller(services: services)
        defer { controller.window?.close() }
        var exports = 0
        controller.onExported = { _ in exports += 1 }
        #expect(controller.prepareDragFile() == nil)
        #expect(controller.model.statusMessage?.hasPrefix("Drag export failed:") == true)
        #expect(beeps == 1 && exports == 0)
        #expect(controller.actions.retryExport != nil)
    }

    // MARK: Fail closed when annotations cannot be burned in

    private func failingController(_ f: EditorFixture, services: EditorExportServices) -> EditorWindowController {
        let controller = f.controller(services: services)
        controller.model.updateLive([redaction])
        controller.model.renderer = failingBakeRenderer
        return controller
    }

    @Test func renderFinalThrowsWhenAnnotationsCannotBeBaked() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        model.renderer = failingBakeRenderer
        model.updateLive([redaction])
        #expect(throws: RenderError.annotationsNotApplied) { try model.renderFinal() }
        model.updateLive([])
        #expect(try model.renderFinal().width == 100)
    }

    @Test func copyRefusesWhenAnnotationsCannotBeBaked() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.closeAfterCopy = true
        var services = EditorExportServices()
        var copies = 0, beeps = 0
        services.copy = { _ in copies += 1; return true }
        services.beep = { beeps += 1 }
        let controller = failingController(f, services: services)
        defer { controller.window?.close() }
        var exports = 0, closes = 0
        controller.onExported = { _ in exports += 1 }
        controller.onClose = { closes += 1 }

        #expect(!controller.copyToClipboard())
        #expect(copies == 0 && exports == 0 && beeps == 1)
        #expect(controller.model.statusMessage == "Copy failed: \(notAppliedMessage)")
        controller.copyAndMaybeClose()
        #expect(copies == 0 && exports == 0 && closes == 0 && beeps == 2)
    }

    @Test func saveRefusesWhenAnnotationsCannotBeBaked() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        var writes = 0, beeps = 0
        services.write = { image, url, format, scale, backing in
            writes += 1
            return try Exporter.write(image, to: url, format: format, scale: scale, backingScale: backing)
        }
        services.beep = { beeps += 1 }
        let controller = failingController(f, services: services)
        defer { controller.window?.close() }
        var exports = 0
        controller.onExported = { _ in exports += 1 }

        controller.saveOutput()
        #expect(writes == 0 && exports == 0 && beeps == 1)
        #expect(controller.model.statusMessage == "Save failed: \(notAppliedMessage)")
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: f.preferences.saveDirectory.path)) ?? []
        #expect(saved.isEmpty)
    }

    @Test func dragRefusesWhenAnnotationsCannotBeBaked() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        services.dragDirectory = f.directory.appendingPathComponent("Drag")
        var writes = 0, beeps = 0
        services.write = { image, url, format, scale, backing in
            writes += 1
            return try Exporter.write(image, to: url, format: format, scale: scale, backingScale: backing)
        }
        services.beep = { beeps += 1 }
        let controller = failingController(f, services: services)
        defer { controller.window?.close() }
        var exports = 0
        controller.onExported = { _ in exports += 1 }

        #expect(controller.prepareDragFile() == nil)
        #expect(writes == 0 && exports == 0 && beeps == 1)
        #expect(controller.model.statusMessage == "Drag export failed: \(notAppliedMessage)")
        let dragged = (try? FileManager.default.contentsOfDirectory(atPath: services.dragDirectory.path)) ?? []
        #expect(dragged.isEmpty)
    }

    // MARK: Retry without losing edits or weakening export checks

    private func expectRedacted(_ image: CGImage, x: Int = 10, y: Int = 10) throws {
        let pixels = try #require(PixelBuffer(image))
        let pixel = pixels.pixel(x, y)
        #expect(pixel.0 < 10 && pixel.1 < 10 && pixel.2 < 10 && pixel.3 == 255)
    }

    @Test(arguments: [false, true])
    func copyRetryKeepsEditsAndUndoAndRespectsClosePreference(closeAfterCopy: Bool) throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.closeAfterCopy = closeAfterCopy
        var services = EditorExportServices()
        var copies: [CGImage] = [], beeps = 0
        services.copy = { copies.append($0); return true }
        services.beep = { beeps += 1 }
        let controller = f.controller(services: services)
        defer { controller.window?.close() }
        let model = controller.model
        model.undoManager.groupsByEvent = false
        model.undoManager.beginUndoGrouping()
        model.setAnnotations([redaction], actionName: "Redact")
        model.undoManager.endUndoGrouping()
        model.selection = [redaction.id]
        model.renderer = failingBakeRenderer
        var exports = 0, closes = 0
        controller.onExported = { _ in exports += 1 }
        controller.onClose = { closes += 1 }

        controller.copyAndMaybeClose()
        let firstRetry = try #require(controller.actions.retryExport)
        firstRetry()
        let secondRetry = try #require(controller.actions.retryExport)
        secondRetry()
        #expect(copies.isEmpty && exports == 0 && closes == 0 && beeps == 3)
        #expect(model.image === f.context.image)
        #expect(model.annotations == [redaction] && model.selection == [redaction.id])
        #expect(model.canUndo && model.undoManager.undoActionName == "Redact")

        var expanded = redaction
        expanded.kind = .redact(CGRect(x: 0, y: 0, width: 100, height: 80))
        model.undoManager.beginUndoGrouping()
        model.setAnnotations([expanded], actionName: "Expand redaction")
        model.undoManager.endUndoGrouping()
        model.undoManager.undo()
        #expect(model.annotations == [redaction])
        model.undoManager.redo()
        #expect(model.annotations == [expanded])

        model.renderer = EditorModel.compositorRenderer
        let finalRetry = try #require(controller.actions.retryExport)
        finalRetry()
        #expect(copies.count == 1 && exports == 1 && closes == (closeAfterCopy ? 1 : 0))
        try expectRedacted(try #require(copies.first), x: 75, y: 60)
        #expect(model.annotations == [expanded] && model.canUndo)
        #expect(controller.actions.retryExport == nil)
        firstRetry()
        secondRetry()
        finalRetry()
        #expect(copies.count == 1 && exports == 1 && beeps == 3)
    }

    @Test func publicCopyRetryDoesNotCloseEvenWithCloseAfterCopyEnabled() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.closeAfterCopy = true
        var services = EditorExportServices()
        var copies: [CGImage] = []
        services.copy = { copies.append($0); return true }
        services.beep = {}
        let controller = failingController(f, services: services)
        defer { controller.window?.close() }
        var closes = 0
        controller.onClose = { closes += 1 }

        #expect(!controller.copyToClipboard())
        let retry = try #require(controller.actions.retryExport)
        controller.model.renderer = EditorModel.compositorRenderer
        retry()
        #expect(copies.count == 1 && closes == 0)
        try expectRedacted(try #require(copies.first))
        #expect(controller.actions.retryExport == nil)
    }

    @Test func saveAsRetryKeepsChosenURLAndFormatThroughRenderAndWriteFailures() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.exportScale = .original
        let target = f.directory.appendingPathComponent("Chosen/Keep this name.tiff")
        var services = EditorExportServices()
        var attempts: [(URL, ExportFormat)] = [], beeps = 0
        var refuseWrite = true
        services.write = { image, url, format, scale, backing in
            attempts.append((url, format))
            if refuseWrite { throw ExportTestFailure.refused }
            return try Exporter.write(image, to: url, format: format, scale: scale, backingScale: backing)
        }
        services.beep = { beeps += 1 }
        let controller = failingController(f, services: services)
        defer { controller.window?.close() }
        var exports: [URL?] = []
        controller.onExported = { exports.append($0) }

        // Save As passes its accepted panel URL and format to this same method.
        controller.write(to: target, format: .tiff)
        let firstRetry = try #require(controller.actions.retryExport)
        firstRetry()
        #expect(attempts.isEmpty && exports.isEmpty && beeps == 2)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(controller.model.annotations == [redaction])

        f.preferences.compressToJPEG = true
        f.preferences.saveDirectory = f.directory.appendingPathComponent("Different")
        controller.model.renderer = EditorModel.compositorRenderer
        let writeRetry = try #require(controller.actions.retryExport)
        writeRetry()
        #expect(attempts.count == 1 && exports.isEmpty && beeps == 3)
        #expect(controller.actions.retryExport != nil)
        refuseWrite = false
        let finalRetry = try #require(controller.actions.retryExport)
        finalRetry()
        #expect(attempts.count == 2 && attempts.allSatisfy { $0.0 == target && $0.1 == .tiff })
        #expect(exports == [target])
        try expectRedacted(try #require(GlintImageIO.load(url: target)))
        #expect(controller.model.statusMessage == "Saved Keep this name.tiff")
        #expect(controller.actions.retryExport == nil)
        firstRetry()
        finalRetry()
        #expect(attempts.count == 2 && exports.count == 1)
    }

    @Test func manualSaveRetryKeepsOriginalTargetAfterPreferencesChange() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.compressToJPEG = false
        f.preferences.exportFormat = .plainPNG
        var services = EditorExportServices()
        var attempts: [(URL, ExportFormat)] = []
        var refuseWrite = true
        services.write = { _, url, format, _, _ in
            attempts.append((url, format))
            if refuseWrite { throw ExportTestFailure.refused }
            return url
        }
        services.beep = {}
        let controller = f.controller(services: services)
        defer { controller.window?.close() }
        controller.saveOutput()
        let first = try #require(attempts.first)

        f.preferences.saveDirectory = f.directory.appendingPathComponent("Different")
        f.preferences.compressToJPEG = true
        refuseWrite = false
        let retry = try #require(controller.actions.retryExport)
        retry()
        #expect(attempts.count == 2 && attempts[1].0 == first.0 && attempts[1].1 == first.1)
        #expect(controller.actions.retryExport == nil)
    }

    @Test func shareRetryOnlyShowsPickerAfterAnnotationsAreBaked() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        var shared: [CGImage] = [], beeps = 0
        services.share = { image, _ in shared.append(image) }
        services.beep = { beeps += 1 }
        let controller = failingController(f, services: services)
        defer { controller.window?.close() }
        var exports = 0
        controller.onExported = { _ in exports += 1 }

        controller.actions.share()
        #expect(controller.model.statusMessage == "Share failed: \(notAppliedMessage)")
        let firstRetry = try #require(controller.actions.retryExport)
        firstRetry()
        #expect(shared.isEmpty && exports == 0 && beeps == 2)
        #expect(controller.model.annotations == [redaction])
        controller.model.renderer = EditorModel.compositorRenderer
        let retry = try #require(controller.actions.retryExport)
        retry()
        #expect(shared.count == 1 && exports == 0)
        try expectRedacted(try #require(shared.first))
        #expect(controller.model.statusMessage == "Choose where to share")
        #expect(controller.actions.retryExport == nil)
        retry()
        #expect(shared.count == 1)
    }

    @Test func dragRetryPreparesRedactedPayloadAndRequestsAnotherGesture() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        services.dragDirectory = f.directory.appendingPathComponent("Drag")
        var payloads: [URL] = [], beeps = 0
        services.write = { image, url, format, scale, backing in
            let saved = try Exporter.write(image, to: url, format: format, scale: scale, backingScale: backing)
            payloads.append(saved)
            return saved
        }
        services.beep = { beeps += 1 }
        let controller = failingController(f, services: services)
        defer { controller.window?.close() }
        var exports = 0
        controller.onExported = { _ in exports += 1 }

        #expect(controller.prepareDragFile() == nil)
        let firstRetry = try #require(controller.actions.retryExport)
        firstRetry()
        #expect(payloads.isEmpty && exports == 0 && beeps == 2)
        #expect(controller.model.annotations == [redaction])
        controller.model.renderer = EditorModel.compositorRenderer
        let retry = try #require(controller.actions.retryExport)
        retry()
        #expect(payloads.count == 1 && exports == 0)
        let payload = try #require(payloads.first)
        try expectRedacted(try #require(GlintImageIO.load(url: payload)))
        #expect(controller.model.statusMessage == "Drag to share again.")
        #expect(controller.actions.retryExport == nil)
        retry()
        #expect(payloads.count == 1)

        // Starting the next drag must render again, not reuse the previously prepared file.
        controller.model.renderer = failingBakeRenderer
        #expect(controller.prepareDragFile() == nil)
        #expect(payloads.count == 1 && exports == 0)
        controller.window?.close()
        #expect(controller.actions.retryExport == nil)
        #expect(payloads.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func closingWindowInvalidatesPendingRetry() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        var copies = 0
        services.copy = { _ in copies += 1; return true }
        services.beep = {}
        let controller = failingController(f, services: services)
        #expect(!controller.copyToClipboard())
        let retry = try #require(controller.actions.retryExport)
        controller.window?.close()
        #expect(controller.actions.retryExport == nil)
        controller.model.renderer = EditorModel.compositorRenderer
        retry()
        #expect(copies == 0)
    }

    @Test func previewNeverShowsUnredactedPixelsWhenBakingFails() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        model.renderer = failingBakeRenderer
        model.updateLive([redaction])
        for _ in 0..<200 where model.statusMessage == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(model.statusMessage == notAppliedMessage)
        #expect(model.preview == nil)

        model.renderer = EditorModel.compositorRenderer
        model.updateLive([redaction])
        for _ in 0..<200 where model.preview == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let preview = try #require(model.preview)
        #expect(preview.image.width == 100 && preview.image.height == 80)
    }

    @Test func solidRedactionReachesSaveClipboardAndDragPayloads() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let pasteboard = NSPasteboard(name: .init("glint.editor.redaction.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var services = EditorExportServices()
        services.copy = { Exporter.copyToClipboard($0, pasteboard: pasteboard) }
        services.dragDirectory = f.directory.appendingPathComponent("Drag")
        let controller = f.controller(services: services)
        defer { controller.window?.close() }
        controller.model.updateLive([Annotation(
            kind: .redact(CGRect(x: 10, y: 20, width: 80, height: 40)),
            style: AnnotationStyle(color: .black.with(alpha: 0.1), opacity: 0.1)
        )])
        controller.model.redactStyle = .blur
        var saved: URL?
        controller.onExported = { if let url = $0 { saved = url } }
        controller.saveOutput()
        let savedURL = try #require(saved)
        let file = try #require(GlintImageIO.load(url: savedURL))
        #expect(controller.copyToClipboard())
        let clipboardData = try #require(pasteboard.data(forType: .png))
        let clipboard = try #require(GlintImageIO.load(data: clipboardData))
        let dragURL = try #require(controller.prepareDragFile())
        let dragged = try #require(GlintImageIO.load(url: dragURL))
        for output in [file, clipboard, dragged] {
            let pixels = try #require(PixelBuffer(output))
            for y in 20..<60 { for x in 10..<90 {
                #expect(pixels.pixel(x, y) == (0, 0, 0, 255))
            } }
            #expect(pixels.pixel(0, 0) == (255, 255, 255, 255))
        }
    }

    @Test(arguments: [RedactionStyle.solid, .pixelate], [false, true])
    func secureStylesAgreeAcrossPreviewAndAllOutputs(mode: RedactionStyle, decorated: Bool) async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let pasteboard = NSPasteboard(name: .init("glint.editor.secure-styles.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var shared: CGImage?
        var services = EditorExportServices()
        services.copy = { Exporter.copyToClipboard($0, pasteboard: pasteboard) }
        services.share = { image, _ in shared = image }
        services.dragDirectory = f.directory.appendingPathComponent("Drag")
        let controller = f.controller(services: services)
        defer { controller.window?.close() }
        let region = CGRect(x: 10.25, y: 20.5, width: 79.5, height: 39.25)
        let style = AnnotationStyle(
            color: RGBAColor(r: 0.8, g: 0.1, b: 0.3, a: 0.05),
            opacity: 0.05, intensity: 8,
            redactionPattern: decorated ? .checkerboard : .plain,
            redactionSecondaryColor: RGBAColor(r: 0.1, g: 0.3, b: 0.8, a: 0),
            pixelateHighlight: decorated
        )
        controller.model.updateLive([Annotation(kind: mode == .solid ? .redact(region) : .pixelate(region), style: style)])
        // Output follows stored annotations, not the next drawing mode or its defaults.
        controller.model.redactStyle = .blur
        controller.model.defaultStyle = AnnotationStyle(color: .white)
        let expected = try controller.model.renderFinal()
        let expectedPixels = try #require(PixelBuffer(expected))
        func matches(_ image: CGImage) -> Bool {
            guard image.width == expected.width, image.height == expected.height,
                  let pixels = PixelBuffer(image) else { return false }
            return (0..<image.height).allSatisfy { y in
                (0..<image.width).allSatisfy { x in pixels.pixel(x, y) == expectedPixels.pixel(x, y) }
            }
        }
        for _ in 0..<200 {
            if let preview = controller.model.preview, matches(preview.image) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(matches(try #require(controller.model.preview).image))

        var saved: URL?
        controller.onExported = { if let url = $0 { saved = url } }
        controller.saveOutput()
        let savedURL = try #require(saved)
        #expect(controller.copyToClipboard())
        let clipboardData = try #require(pasteboard.data(forType: .png))
        let dragURL = try #require(controller.prepareDragFile())
        controller.actions.share()
        #expect(matches(try #require(shared)))
        for data in [try Data(contentsOf: savedURL), clipboardData, try Data(contentsOf: dragURL)] {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            #expect(CGImageSourceGetCount(source) == 1)
            let image = try #require(GlintImageIO.load(data: data))
            #expect(matches(image))
        }

        var colors = Set<UInt32>()
        for y in 20..<60 { for x in 10..<90 {
            let pixel = expectedPixels.pixel(x, y)
            #expect(pixel.3 == 255)
            colors.insert(UInt32(pixel.0) << 16 | UInt32(pixel.1) << 8 | UInt32(pixel.2))
        } }
        if mode == .pixelate || decorated { #expect(colors.count > 1) }
        else { #expect(colors.count == 1) }
        #expect(expectedPixels.pixel(0, 0) == (255, 255, 255, 255))
    }
}
