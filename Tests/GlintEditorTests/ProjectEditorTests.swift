import AppKit
import Foundation
import Testing
@testable import GlintCore
@testable import GlintEditor

@Suite("Editable projects in the editor")
@MainActor
struct ProjectEditorTests {
    private func savedLook() -> RenderSettings {
        RenderSettings(padding: 24, cornerRadius: 6, shadow: .none, background: .solid(RGBAColor(r: 0.2, g: 0.4, b: 0.8)),
                       autoBalance: false)
    }

    /// Stored once per test: every `Annotation` gets a fresh id.
    private let annotations: [Annotation] = [
        Annotation(z: 0, kind: .arrow(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 60, y: 40))),
        Annotation(z: 1, kind: .redact(CGRect(x: 40, y: 30, width: 30, height: 20))),
    ]

    private func savedAnnotations() -> [Annotation] { annotations }

    private func restoredModel(_ f: EditorFixture, recognized: @escaping () -> Void = {}) -> EditorModel {
        let restored = EditorRestoreState(settings: savedLook(), annotations: savedAnnotations(), projectName: "Bug report")
        let context = EditorContext(image: f.context.image, backingScale: 2, rawURL: nil, source: "test", restored: restored)
        return EditorModel(context: context, preferences: f.preferences, presetStore: f.presets,
                           recognizeText: { _ in recognized(); return [] })
    }

    @Test func aRestoredProjectStartsWithItsOwnLookAndIsNotRemembered() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.rememberSettings = true
        f.preferences.autoRedact = true
        let remembered = try #require(f.preferences.lastRenderSettings)
        var recognitions = 0
        let model = restoredModel(f) { recognitions += 1 }
        for _ in 0..<20 { await Task.yield() }

        #expect(model.settings == savedLook())
        #expect(model.annotations == savedAnnotations())
        #expect(recognitions == 0, "a project is never auto-redacted again")

        model.settings.padding = 64
        #expect(f.preferences.lastRenderSettings == remembered, "editing a project leaves the next capture's look alone")
        #expect(EditorContext(image: f.context.image, backingScale: 2, rawURL: nil, source: nil,
                              restored: EditorRestoreState(settings: .default, annotations: [], projectName: "Bug report"))
            .windowTitle == "Glint — Bug report")
    }

    @Test func savingAndReopeningRendersTheSamePixels() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = restoredModel(f)
        model.append(model.makeAnnotation(.text(origin: CGPoint(x: 8, y: 50), string: "Here", maxWidth: 0)))
        let before = try model.renderFinal()

        let url = f.directory.appendingPathComponent("Round trip.glint")
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        try ProjectStore.write(GlintProject(state: .screenshot(model.screenshotProjectState()), source: .image(model.image)),
                               to: url)
        let project = try ProjectStore.read(from: url, snapshotRoot: f.directory.appendingPathComponent("Snapshots"))
        guard case .screenshot(let state) = project.state, case .image(let image) = project.source else {
            Issue.record("expected a screenshot project"); return
        }
        #expect(state.annotations == model.annotations && state.settings == model.settings)
        let context = EditorContext(image: image, backingScale: CGFloat(state.backingScale), rawURL: nil, source: state.source,
                                    restored: EditorRestoreState(settings: state.settings, annotations: state.annotations))
        let reopened = EditorModel(context: context, preferences: f.preferences, presetStore: f.presets)
        try expectSamePixels(try reopened.renderFinal(), before)
    }

    @Test func saveAsProjectAsksWhereThenWritesTheOriginalCapture() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let destination = f.directory.appendingPathComponent("Saved.glint")
        var services = EditorExportServices()
        services.saveActivity = ProjectSaveActivity()
        var askedIn: URL?
        services.chooseProjectDestination = { _, directory, completion in
            askedIn = directory
            completion(destination)
        }
        services.beep = {}
        let controller = f.controller(services: services)
        controller.model.append(controller.model.makeAnnotation(.redact(CGRect(x: 1, y: 1, width: 10, height: 10))))
        let saved = await withCheckedContinuation { continuation in
            controller.onProjectSaved = { continuation.resume(returning: $0) }
            controller.saveAsProject(nil)
        }

        #expect(saved == destination && askedIn == f.preferences.saveDirectory)
        #expect(controller.model.statusMessage == "Saved project Saved")
        let project = try ProjectStore.read(from: destination, snapshotRoot: f.directory.appendingPathComponent("Snapshots"))
        guard case .image(let image) = project.source else { Issue.record("expected an image source"); return }
        try expectSamePixels(image, f.context.image)
        #expect(project.state.annotations == controller.model.annotations)
        controller.window?.close()
    }

    @Test func aCancelledPanelWritesNothing() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        services.saveActivity = ProjectSaveActivity()
        var writes = 0
        services.chooseProjectDestination = { _, _, completion in completion(nil) }
        services.writeProject = { _, _ in writes += 1 }
        let controller = f.controller(services: services)
        controller.saveAsProject(nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(writes == 0 && controller.model.statusMessage == nil)
        controller.window?.close()
    }

    @Test func aFailedSaveOffersRetry() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        struct Boom: LocalizedError { var errorDescription: String? { "disk full" } }
        var services = EditorExportServices()
        services.saveActivity = ProjectSaveActivity()
        services.chooseProjectDestination = { _, _, completion in completion(URL(fileURLWithPath: "/dev/null/x.glint")) }
        services.writeProject = { _, _ in throw Boom() }
        services.beep = {}
        let controller = f.controller(services: services)
        controller.saveAsProject(nil)
        for _ in 0..<200 where controller.actions.retryExport == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(controller.model.statusMessage == "Couldn't save the project: disk full")
        #expect(controller.actions.retryExport != nil)
        controller.window?.close()
    }

    @Test func theMenuItemIsOfferedOnlyOutsideThePresetDesigner() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let controller = f.controller(services: EditorExportServices())
        let item = NSMenuItem(title: "Save as Project…", action: #selector(EditorWindowController.saveAsProject(_:)),
                              keyEquivalent: "s")
        #expect(controller.validateMenuItem(item))
        controller.window?.close()
    }

    @Test func aReopenedRecordingKeepsItsTrimSettingsAndClip() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let temporary = try await fixture.recording()
        let clip = RecordedVideo(url: temporary.url, duration: temporary.duration, pixelSize: temporary.pixelSize,
                                 deletesFileOnClose: false)
        var trim = RecordingTrim(sourceDuration: clip.duration)
        trim.setStart(0.4)
        trim.setEnd(1.5)
        let options = RecordingExportOptions(format: .mp4)
        let click = ClickEvent(time: 0.6, position: CGPoint(x: 40, y: 30))
        let presentation = Presentation(
            capture: PresentationCapture(
                pointer: PointerTrack(samples: [PointerSample(time: 0, position: CGPoint(x: 20, y: 20)),
                                                PointerSample(time: 2, position: CGPoint(x: 100, y: 50))]),
                clicks: [click], pointerIsBaked: false),
            settings: PresentationSettings(
                clicks: ClickHighlightStyle(enabled: true, removed: [click.id]),
                cursor: CursorEmphasis(scale: 2, halo: true),
                zooms: [ZoomSegment(start: 0.5, end: 1.5, rect: CGRect(x: 40, y: 20, width: 60, height: 40))]))
        let state = RecordingProjectState(settings: savedLook(), annotations: savedAnnotations(), trim: trim,
                                          options: options, duration: clip.duration, pixelSize: clip.pixelSize,
                                          presentation: presentation)
        let controller = try RecordingEditorWindowController(recording: clip, services: fixture.services(), project: state,
                                                             projectName: "Demo")
        var closes = 0
        controller.onClose = { closes += 1 }

        #expect(controller.model.trim == trim && controller.model.options == options)
        #expect(controller.editor.model.settings.padding == savedLook().padding)
        #expect(controller.editor.model.annotations == savedAnnotations())
        #expect(controller.model.presentation.presentation == presentation)
        #expect(controller.editor.model.presentation == presentation)
        #expect(controller.model.presentation.pointerIsEditable)
        #expect(controller.window?.title == "Glint — Demo")
        let project = try #require(controller.editor.makeProject?())
        #expect(project.state == .recording(state))
        guard case .video(let url) = project.source else { Issue.record("expected a video source"); return }
        #expect(url == clip.url)

        let frame = controller.editor.model.image
        let renderer = controller.editor.model.recordingFrameRenderer()
        controller.editor.model.updateRecordingFrame(frame, at: 1)
        try expectSamePixels(try controller.editor.model.renderFinal(), try renderer(frame, 1))
        let undo = controller.editor.model.undoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        controller.model.presentation.restoreClicks()
        undo.endUndoGrouping()
        #expect(controller.editor.model.presentation?.settings.clicks.removed.isEmpty == true)
        undo.undo()
        #expect(controller.editor.model.presentation == presentation)
        let savedAgain = try #require(controller.editor.makeProject?())
        #expect(savedAgain.state == .recording(state))

        controller.window?.close()
        #expect(closes == 1)
        #expect(FileManager.default.fileExists(atPath: clip.url.path), "a project's clip belongs to the project")
    }
    @Test func aReopenedScrollingCaptureStartsAtFitWidth() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let bitmap = try #require(GlintBitmap.makeContext(width: 100, height: 800))
        bitmap.setFillColor(RGBAColor(r: 0.3, g: 0.6, b: 0.9).cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 100, height: 800))
        let tall = try #require(bitmap.makeImage())
        let url = f.directory.appendingPathComponent("Tall.glint")
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let state = ScreenshotProjectState(settings: savedLook(), annotations: savedAnnotations(), backingScale: 2,
                                           source: "scrolling")
        try ProjectStore.write(GlintProject(state: .screenshot(state), source: .image(tall)), to: url)
        let project = try ProjectStore.read(from: url, snapshotRoot: f.directory.appendingPathComponent("Snapshots"))
        defer { project.discardSnapshot() }
        guard case .image(let image) = project.source else { Issue.record("expected an image source"); return }
        let model = EditorModel(context: EditorContext(image: image, backingScale: 2, rawURL: nil, source: state.source,
                                                       restored: EditorRestoreState(settings: state.settings,
                                                                                    annotations: state.annotations)),
                                preferences: f.preferences, presetStore: f.presets)
        #expect(model.image.pixelSize == CGSize(width: 100, height: 800))
        #expect(model.canvasZoom == .fitWidth)
        #expect(model.annotations == savedAnnotations())
    }

    // MARK: - Opening safely

    @Test(arguments: [CGSize(width: 1e20, height: 90), CGSize(width: 160.5, height: 90), CGSize(width: 0, height: 90),
                      CGSize(width: CGFloat.infinity, height: 90)])
    func aRecordingProjectWithAnImpossibleSizeIsRefused(_ size: CGSize) throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let clip = RecordedVideo(url: fixture.directory.appendingPathComponent("none.mp4"), duration: 2, pixelSize: size,
                                 deletesFileOnClose: false)
        let state = RecordingProjectState(settings: .default, annotations: [], trim: RecordingTrim(sourceDuration: 2),
                                          options: RecordingExportOptions(), duration: 2, pixelSize: size)
        #expect(throws: RecordingEditorOpenError.invalidClip) {
            try RecordingEditorWindowController(recording: clip, services: fixture.services(), project: state,
                                                projectName: "Bad")
        }
    }

    @Test func placeholderFramesAreClampedInsteadOfTrapping() throws {
        let huge = try #require(RecordingEditorWindowController.placeholderFrame(for: CGSize(width: 1e20, height: .nan)))
        #expect(huge.width == RecordingProjectState.maxPixelSide && huge.height == 1)
        let normal = try #require(RecordingEditorWindowController.placeholderFrame(for: CGSize(width: 160, height: 90)))
        #expect(normal.width == 160 && normal.height == 90)
    }

    // MARK: - Saving while closing

    /// Lets a test hold a project write open until it says so.
    private final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func wait() { semaphore.wait() }
        func open() { semaphore.signal() }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(nanoseconds: 5_000_000) }
    }

    @Test func closingDuringASaveKeepsTheClipUntilTheSaveIsDone() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let clip = try await fixture.recording()
        let gate = Gate()
        var services = fixture.services()
        let activity = ProjectSaveActivity()
        services.editorExport.saveActivity = activity
        var removed: [URL] = []
        services.removeItem = { removed.append($0); try? FileManager.default.removeItem(at: $0) }
        services.editorExport.chooseProjectDestination = { _, _, completion in
            completion(fixture.directory.appendingPathComponent("Slow.glint"))
        }
        services.editorExport.writeProject = { project, _ in
            gate.wait()
            guard case .video(let url) = project.source else { return }
            _ = try Data(contentsOf: url)
        }
        let controller = RecordingEditorWindowController(recording: clip, services: services)
        var closes = 0
        var saved: URL?
        controller.onClose = { closes += 1 }
        controller.onProjectSaved = { saved = $0 }

        controller.saveAsProject(nil)
        try await waitUntil { controller.editor.isSavingProject }
        #expect(activity.isActive)
        #expect(await activity.waitUntilIdle(timeout: .milliseconds(10)) == false)
        controller.window?.close()
        for _ in 0..<20 { await Task.yield() }
        #expect(closes == 0 && removed.isEmpty, "the clip stays while the save reads it")
        #expect(FileManager.default.fileExists(atPath: clip.url.path))

        gate.open()
        try await waitUntil { closes == 1 }
        #expect(closes == 1 && saved != nil)
        #expect(removed.contains(clip.url))
        #expect(await activity.waitUntilIdle(timeout: .seconds(1)))
    }

    @Test func aSaveThatFailsAfterTheWindowClosedIsReported() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        struct Boom: LocalizedError { var errorDescription: String? { "disk full" } }
        let gate = Gate()
        var services = EditorExportServices()
        services.saveActivity = ProjectSaveActivity()
        services.chooseProjectDestination = { _, _, completion in completion(URL(fileURLWithPath: "/dev/null/x.glint")) }
        services.writeProject = { _, _ in gate.wait(); throw Boom() }
        services.beep = {}
        let controller = f.controller(services: services)
        var failure: (URL, String)?
        controller.onProjectSaveFailed = { failure = ($0, $1.localizedDescription) }

        controller.saveAsProject(nil)
        try await waitUntil { controller.isSavingProject }
        controller.window?.close()
        // A panel answered after closing starts nothing.
        controller.writeProject(GlintProject(state: .screenshot(controller.model.screenshotProjectState()),
                                             source: .image(controller.model.image)), to: URL(fileURLWithPath: "/dev/null/y.glint"))
        gate.open()
        await controller.waitForProjectSave()

        #expect(failure?.0.lastPathComponent == "x.glint" && failure?.1 == "disk full")
        #expect(controller.actions.retryExport == nil)
    }
}
