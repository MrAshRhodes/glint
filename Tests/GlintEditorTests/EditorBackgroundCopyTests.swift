import AppKit
import Testing
import UniformTypeIdentifiers
@testable import GlintCore
@testable import GlintEditor

/// Stands in for the model's renderer: records where each render ran and can hold one until the test lets it go.
private final class RenderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let holds: Bool
    private let compose: EditorModel.Renderer
    private var calls = 0
    private var mainThreadCalls = 0

    @MainActor init(holding: Bool = false) {
        holds = holding
        compose = EditorModel.compositorRenderer
    }

    var started: Int { lock.withLock { calls } }
    var ranOnTheMainThread: Bool { lock.withLock { mainThreadCalls > 0 } }

    var renderer: EditorModel.Renderer {
        { [self] image, settings, annotations, scale, background, wallpaper, time in
            lock.withLock {
                calls += 1
                if Thread.isMainThread { mainThreadCalls += 1 }
            }
            if holds { _ = gate.wait(timeout: .now() + 30) }
            return try compose(image, settings, annotations, scale, background, wallpaper, time)
        }
    }

    func release() { gate.signal() }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<2000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(condition(), "Gave up waiting")
}

private func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                     context: nil, characters: characters, charactersIgnoringModifiers: characters,
                     isARepeat: false, keyCode: 0)!
}

@Suite("Editor copy off the main thread")
@MainActor
struct EditorBackgroundCopyTests {
    /// Starts a copy whose render is held, with the model's own renderer back in place for everything after it.
    private func startHeldCopy(_ controller: EditorWindowController, probe: RenderProbe,
                               closeAfterSuccess: Bool = false) async {
        controller.model.renderer = probe.renderer
        controller.startCopy(closeAfterSuccess: closeAfterSuccess)
        controller.model.renderer = EditorModel.compositorRenderer
        await waitUntil { probe.started > 0 }
    }

    @Test func theRenderLeavesTheMainThreadAndTheClipboardIsFilledOnIt() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        var copiedOnTheMainThread: [Bool] = []
        services.copy = { _, _, _ in copiedOnTheMainThread.append(Thread.isMainThread); return true }
        let controller = f.controller(services: services)
        defer { controller.window?.close() }
        let probe = RenderProbe()
        controller.model.renderer = probe.renderer

        #expect(await controller.copyToClipboard())
        #expect(probe.started >= 1)
        #expect(!probe.ranOnTheMainThread)
        #expect(copiedOnTheMainThread == [true])
    }

    @Test func startingACopyDoesNotWaitForTheRender() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        var copies = 0
        services.copy = { _, _, _ in copies += 1; return true }
        let controller = f.controller(services: services)
        defer { controller.window?.close() }
        let probe = RenderProbe(holding: true)
        defer { probe.release() }

        await startHeldCopy(controller, probe: probe)
        // The render is held, yet the main actor is free, and nothing is claimed before it ends.
        #expect(copies == 0)
        #expect(controller.model.statusMessage != "Copied to clipboard")

        probe.release()
        await controller.finishExports()
        #expect(copies == 1)
        #expect(controller.model.statusMessage == "Copied to clipboard")
    }

    @Test func commandCReturnsBeforeTheRenderEnds() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.closeAfterCopy = false
        var services = EditorExportServices()
        var copies = 0
        services.copy = { _, _, _ in copies += 1; return true }
        let controller = f.controller(services: services)
        defer { controller.window?.close() }
        let probe = RenderProbe(holding: true)
        defer { probe.release() }

        controller.model.renderer = probe.renderer
        #expect(controller.handleShortcut(keyEvent("c", modifiers: .command)))
        controller.model.renderer = EditorModel.compositorRenderer
        await waitUntil { probe.started > 0 }
        #expect(copies == 0)

        probe.release()
        await controller.finishExports()
        #expect(copies == 1)
    }

    @Test func editsAfterACopyStartedDoNotChangeIt() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        var copied: [CGImage] = []
        services.copy = { image, _, _ in copied.append(image); return true }
        let controller = f.controller(services: services)
        defer { controller.window?.close() }
        let probe = RenderProbe(holding: true)
        defer { probe.release() }

        await startHeldCopy(controller, probe: probe)
        let width = try controller.model.renderFinal().width
        controller.model.settings.padding = 40
        #expect(try controller.model.renderFinal().width > width)

        probe.release()
        await controller.finishExports()
        #expect(copied.map(\.width) == [width])
    }

    @Test func aNewerCopyReplacesOneStillRendering() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        var copied: [CGImage] = []
        services.copy = { image, _, _ in copied.append(image); return true }
        let controller = f.controller(services: services)
        defer { controller.window?.close() }
        var exports = 0, shared = 0
        controller.onExported = { _ in exports += 1 }
        controller.onImageShared = { _, _, _ in shared += 1 }
        let slow = RenderProbe(holding: true)
        defer { slow.release() }

        await startHeldCopy(controller, probe: slow)
        controller.model.settings.padding = 40
        let newest = try controller.model.renderFinal().width
        controller.startCopy(closeAfterSuccess: false)
        await waitUntil { copied.count == 1 }
        #expect(copied.map(\.width) == [newest])

        // The older render ends last and must not replace what the newer copy put on the clipboard.
        slow.release()
        await controller.finishExports()
        #expect(copied.map(\.width) == [newest])
        #expect(exports == 1 && shared == 1)
    }

    @Test func aCopyInAnotherEditorReplacesOneStillRendering() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        var copied: [CGImage] = []
        services.copy = { image, _, _ in copied.append(image); return true }
        let older = f.controller(services: services), newer = f.controller(services: services)
        defer { older.window?.close(); newer.window?.close() }
        var olderExports = 0, newerExports = 0
        older.onExported = { _ in olderExports += 1 }
        newer.onExported = { _ in newerExports += 1 }
        let slow = RenderProbe(holding: true)
        defer { slow.release() }

        await startHeldCopy(older, probe: slow)
        newer.model.settings.padding = 40
        let newest = try newer.model.renderFinal().width
        newer.startCopy(closeAfterSuccess: false)
        await waitUntil { copied.count == 1 }
        #expect(copied.map(\.width) == [newest])

        // There is one clipboard: the first editor's render ends last and must not replace what the second one put on it.
        slow.release()
        await older.finishExports()
        await newer.finishExports()
        #expect(copied.map(\.width) == [newest])
        #expect(olderExports == 0 && newerExports == 1)
    }

    @Test func aCopyStillRenderingWhenTheWindowClosesStillReachesTheClipboard() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.closeAfterCopy = true
        var services = EditorExportServices()
        var copies = 0, beeps = 0
        services.copy = { _, _, _ in copies += 1; return true }
        services.beep = { beeps += 1 }
        let controller = f.controller(services: services)
        let probe = RenderProbe(holding: true)
        defer { probe.release() }
        var exports = 0
        controller.onExported = { _ in exports += 1 }

        await startHeldCopy(controller, probe: probe, closeAfterSuccess: true)
        controller.window?.close()
        probe.release()
        await controller.finishExports()
        #expect(copies == 1 && exports == 1 && beeps == 0)
    }

    @Test func aFailedCopyAfterTheWindowClosedOnlyBeeps() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        var beeps = 0
        services.copy = { _, _, _ in false }
        services.beep = { beeps += 1 }
        let controller = f.controller(services: services)
        let probe = RenderProbe(holding: true)
        defer { probe.release() }
        var exports = 0
        controller.onExported = { _ in exports += 1 }

        await startHeldCopy(controller, probe: probe)
        controller.window?.close()
        probe.release()
        await controller.finishExports()
        #expect(beeps == 1 && exports == 0)
        #expect(controller.actions.retryExport == nil)
    }

    @Test func aRenderThatFailsOffTheMainThreadIsReportedWithARetry() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        var copies = 0, beeps = 0
        services.copy = { _, _, _ in copies += 1; return true }
        services.beep = { beeps += 1 }
        let controller = f.controller(services: services)
        defer { controller.window?.close() }
        var exports = 0
        controller.onExported = { _ in exports += 1 }
        controller.model.renderer = { _, _, _, _, _, _, _ in throw RenderError.annotationsNotApplied }

        controller.startCopy(closeAfterSuccess: false)
        await controller.finishExports()
        #expect(copies == 0 && exports == 0 && beeps == 1)
        #expect(controller.model.statusMessage == "Copy failed: \(RenderError.annotationsNotApplied.localizedDescription)")
        let retry = try #require(controller.actions.retryExport)

        controller.model.renderer = EditorModel.compositorRenderer
        retry()
        await controller.finishExports()
        #expect(copies == 1 && exports == 1)
        #expect(controller.actions.retryExport == nil)
    }
}

@Suite("Editor drag off the main thread")
@MainActor
struct EditorBackgroundDragTests {
    /// Starts a drag whose render is held, and waits until the probe has seen `renders` renders in all.
    private func startHeldDrag(_ controller: EditorWindowController, probe: RenderProbe,
                               renders: Int) async throws -> EditorDragPayload {
        controller.model.renderer = probe.renderer
        let payload = try #require(controller.dragPayload() as? EditorDragPayload)
        controller.model.renderer = EditorModel.compositorRenderer
        await waitUntil { probe.started >= renders }
        return payload
    }

    private func fileName(of payload: EditorDragPayload) throws -> String {
        try #require(payload.delegate?.filePromiseProvider(payload, fileNameForType: UTType.png.identifier))
    }

    /// What a destination that asks for the promised file at `url` is told.
    private func promiseWritten(by payload: EditorDragPayload, to url: URL) async -> Error? {
        guard let delegate = payload.delegate else { return CocoaError(.fileNoSuchFile) }
        return await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(payload, writePromiseTo: url) { continuation.resume(returning: $0) }
        }
    }

    @Test func dragsFromTwoEditorsNeverShareACacheFile() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.fileNameTemplate = "Dragged"
        var services = EditorExportServices()
        services.dragDirectory = f.directory.appendingPathComponent("Drag")
        let first = f.controller(services: services), second = f.controller(services: services)
        defer { first.window?.close(); second.window?.close() }
        let probe = RenderProbe(holding: true)
        defer { probe.release(); probe.release() }

        let firstPayload = try await startHeldDrag(first, probe: probe, renders: 1)
        let secondPayload = try await startHeldDrag(second, probe: probe, renders: 2)
        // Neither file exists yet while both render, and the two drags still must not write to the same one.
        #expect(try fileName(of: firstPayload) == "Dragged.png")
        #expect(try fileName(of: secondPayload) == "Dragged-2.png")

        probe.release()
        probe.release()
        await first.finishExports()
        await second.finishExports()
        guard case .success(let one) = await firstPayload.delivery(), case .success(let two) = await secondPayload.delivery()
        else {
            Issue.record("A drag did not deliver its file")
            return
        }
        #expect(one.url != two.url)
        #expect(GlintImageIO.load(url: one.url) != nil && GlintImageIO.load(url: two.url) != nil)

        // A name is held only while its file is being made: once both are gone it is free again.
        first.window?.close()
        second.window?.close()
        let third = f.controller(services: services)
        defer { third.window?.close() }
        #expect(try await dragFile(from: third)?.lastPathComponent == "Dragged.png")
    }

    @Test func aDragStillRenderingWhenTheWindowClosesKeepsItsFileUntilTheDragLetsGo() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        services.dragDirectory = f.directory.appendingPathComponent("Drag")
        let controller = f.controller(services: services)
        let probe = RenderProbe(holding: true)
        defer { probe.release() }
        var payload: EditorDragPayload? = try await startHeldDrag(controller, probe: probe, renders: 1)

        controller.window?.close()
        probe.release()
        await controller.finishExports()

        // The window's own clean-up ran before the file existed, yet a destination still waiting for it gets it.
        let delivery = try #require(try await payload?.delivery().get())
        #expect(FileManager.default.fileExists(atPath: delivery.url.path))
        let dropped = f.directory.appendingPathComponent("Dropped/Out.png")
        try FileManager.default.createDirectory(at: dropped.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(await promiseWritten(by: payload!, to: dropped) == nil)
        #expect(GlintImageIO.load(url: dropped) != nil)

        // Nothing can ask for the file once the drag has let go of the payload, so the file goes then.
        payload = nil
        await waitUntil { !FileManager.default.fileExists(atPath: delivery.url.path) }
        #expect(!FileManager.default.fileExists(atPath: delivery.url.path))
    }
}
