import AppKit
import GlintCore
import Testing
@testable import GlintEditor

private enum ExportTestFailure: Error { case refused }

@Suite("Editor export actions")
@MainActor
struct EditorExportTests {
    @Test func failedCopyKeepsWindowOpenAndDoesNotCallExportCallback() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        services.copy = { _ in false }
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
    }
}
