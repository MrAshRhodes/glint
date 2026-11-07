import AppKit
import Testing
@testable import GlintCore
@testable import GlintEditor

@Suite("Recording presentation", .serialized)
@MainActor
struct RecordingPresentationTests {
    private func striped() throws -> CGImage {
        let ctx = try #require(GlintBitmap.makeContext(width: 160, height: 90))
        for x in stride(from: 0, to: 160, by: 8) {
            ctx.setFillColor(RGBAColor(r: Double(x) / 160, g: 0.5, b: 1 - Double(x) / 160).cgColor)
            ctx.fill(CGRect(x: x, y: 0, width: 8, height: 90))
        }
        return try #require(ctx.makeImage())
    }

    private func model(_ fixture: EditorFixture, image: CGImage) -> EditorModel {
        let context = EditorContext(image: image, backingScale: 2, rawURL: nil, source: nil, isRecording: true)
        let model = EditorModel(context: context, preferences: fixture.preferences, presetStore: fixture.presets)
        model.undoManager.groupsByEvent = false
        return model
    }

    private func presentation() -> Presentation {
        let click = ClickEvent(time: 1, position: CGPoint(x: 70, y: 40))
        let capture = PresentationCapture(
            pointer: PointerTrack(samples: [PointerSample(time: 0, position: CGPoint(x: 70, y: 40)),
                                            PointerSample(time: 5, position: CGPoint(x: 90, y: 50))]),
            clicks: [click], pointerIsBaked: false)
        return Presentation(capture: capture, settings: PresentationSettings(
            clicks: ClickHighlightStyle(enabled: true),
            cursor: CursorEmphasis(scale: 2, halo: true),
            zooms: [ZoomSegment(start: 1, end: 3, rect: CGRect(x: 60, y: 30, width: 40, height: 22.5))]))
    }

    @Test func previewFinalAndFrozenExporterMatchWithZoomClicksAndPointer() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let image = try striped()
        let editor = model(f, image: image)
        editor.updateLive([Annotation(kind: .redact(CGRect(x: 75, y: 35, width: 10, height: 10)),
                                      style: AnnotationStyle(color: .black))])
        editor.presentation = presentation()
        let snapshot = editor.recordingFrameRenderer()
        editor.presentation = nil
        for time in [0.5, 1.1, 2.0] {
            editor.updateRecordingFrame(image, at: time)
            editor.presentation = presentation()
            let expected = try #require(PixelBuffer(snapshot(image, time)))
            let output = try #require(PixelBuffer(editor.renderFinal()))
            #expect(output.data == expected.data, "Final output matches the frozen exporter at \(time)")
            await waitUntil(seconds: 60) { editor.preview.flatMap { PixelBuffer($0.image) }?.data == expected.data }
            #expect(editor.preview.flatMap { PixelBuffer($0.image) }?.data == expected.data, "Preview at \(time)")
            editor.presentation = nil
            let plain = try #require(PixelBuffer(editor.renderFinal()))
            #expect(plain.data != expected.data, "Presentation effects show at \(time)")
        }
    }

    @Test func choosingTheAreaShowsTheWholeFrameButExportsStillZoom() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let image = try striped()
        let editor = model(f, image: image)
        var zoomOnly = Presentation()
        zoomOnly.settings.zooms = [ZoomSegment(start: 0, end: 4, rect: CGRect(x: 0, y: 0, width: 40, height: 22.5))]
        editor.updateRecordingFrame(image, at: 2)
        editor.presentation = zoomOnly
        let zoomed = try #require(PixelBuffer(editor.renderFinal()))
        editor.showsWholeFrame = true
        #expect(try #require(PixelBuffer(editor.renderFinal())).data == zoomed.data)
        editor.presentation = nil
        let whole = try #require(PixelBuffer(editor.renderFinal()))
        editor.presentation = zoomOnly
        await waitUntil(seconds: 60) { editor.preview.flatMap { PixelBuffer($0.image) }?.data == whole.data }
        #expect(editor.preview.flatMap { PixelBuffer($0.image) }?.data == whole.data)
        #expect(editor.preview?.mapper.region == CGRect(x: 0, y: 0, width: 160, height: 90))
        #expect(whole.data != zoomed.data)
    }

    @Test func inertPresentationKeepsTheOrdinaryRenderer() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let editor = model(f, image: try striped())
        final class Flag: @unchecked Sendable { var value = false }
        let used = Flag()
        editor.presentationRenderer = { image, settings, annotations, scale, background, wallpaper, time, presentation in
            used.value = true
            return try EditorModel.compositorPresentationRenderer(image, settings, annotations, scale, background,
                                                                  wallpaper, time, presentation)
        }
        var baked = try #require(presentation().capture)
        baked.pointerIsBaked = true
        editor.presentation = Presentation(capture: baked)
        _ = try editor.renderFinal()
        #expect(!used.value, "Recorded data alone changes nothing")
        baked.pointerIsBaked = false
        editor.presentation = Presentation(capture: baked)
        _ = try editor.renderFinal()
        #expect(used.value, "A pointer left out of the footage is drawn by Glint")
        used.value = false
        editor.presentation = presentation()
        _ = try editor.renderFinal()
        #expect(used.value)
    }

    // MARK: Model

    @Test func zoomsAreAddedInsideTheClipAndClamped() throws {
        let model = RecordingPresentationModel(capture: nil, frameSize: CGSize(width: 160, height: 90))
        let id = try #require(model.addZoom(at: 9, sourceDuration: 10))
        var zoom = try #require(model.selectedZoom)
        #expect(zoom.id == id && zoom.start == 8 && zoom.end == 10)
        #expect(zoom.rect == CGRect(x: 40, y: 22.5, width: 80, height: 45))

        model.setZoomBoundary(9.99, isStart: true, id: id, sourceDuration: 10)
        zoom = try #require(model.selectedZoom)
        #expect(abs(zoom.start - (10 - ZoomSegment.minimumDuration)) < 1e-9, "A zoom keeps a minimum duration")
        model.setZoomBoundary(-5, isStart: true, id: id, sourceDuration: 10)
        model.setZoomBoundary(50, isStart: false, id: id, sourceDuration: 10)
        #expect(model.selectedZoom?.start == 0 && model.selectedZoom?.end == 10)
        model.setZoomBoundary(4, isStart: false, id: id, sourceDuration: 10)
        model.moveZoom(to: 8, id: id, sourceDuration: 10)
        #expect(model.selectedZoom?.start == 6 && model.selectedZoom?.end == 10, "Moving keeps the duration")
        model.setZoomBoundary(.nan, isStart: true, id: id, sourceDuration: 10)
        #expect(model.selectedZoom?.start == 6)

        model.setZoomRect(CGRect(x: 150, y: 80, width: 40, height: 40), id: id)
        #expect(model.selectedZoom?.rect == CGRect(x: 150, y: 80, width: 10, height: 10), "The area stays in the frame")
        model.setZoomRect(CGRect(x: 500, y: 500, width: 10, height: 10), id: id)
        #expect(model.selectedZoom?.rect == CGRect(x: 150, y: 80, width: 10, height: 10))

        model.editingArea = true
        model.deleteZoom(id)
        #expect(model.settings.zooms.isEmpty && model.selectedZoomID == nil && !model.editingArea)
        #expect(RecordingPresentationModel(capture: nil, frameSize: .zero).addZoom(at: 0, sourceDuration: 10) == nil)
    }

    @Test func dragsUndoInOneStepAndEditsUndoSeparately() throws {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = RecordingPresentationModel(capture: nil, frameSize: CGSize(width: 160, height: 90))
        model.undoManager = undo
        undo.beginUndoGrouping()
        let id = try #require(model.addZoom(at: 1, sourceDuration: 10))
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        model.beginInteraction()
        model.moveZoom(to: 2, id: id, sourceDuration: 10)
        model.moveZoom(to: 3, id: id, sourceDuration: 10)
        model.endInteraction(actionName: "Move Zoom")
        undo.endUndoGrouping()
        #expect(model.selectedZoom?.start == 3)
        #expect(undo.undoActionName == "Move Zoom")
        undo.undo()
        #expect(model.selectedZoom?.start == 1)
        undo.redo()
        #expect(model.selectedZoom?.start == 3)
        undo.undo()
        undo.undo()
        #expect(model.settings.zooms.isEmpty && model.selectedZoomID == nil)
        #expect(!undo.canUndo)
    }

    @Test func clicksCanBeRemovedAndRestored() throws {
        let first = ClickEvent(time: 1, position: .zero), second = ClickEvent(time: 1.2, position: .zero, button: .right)
        let model = RecordingPresentationModel(
            capture: PresentationCapture(pointer: PointerTrack(samples: [PointerSample(time: 0, position: .zero)]),
                                         clicks: [first, second]),
            frameSize: CGSize(width: 160, height: 90))
        #expect(model.hasPointerData && model.hasClicks && !model.pointerIsEditable)
        #expect(model.click(near: 1.15)?.id == second.id)
        #expect(model.click(near: 3) == nil)
        model.removeClick(second.id)
        #expect(model.click(near: 1.15)?.id == first.id)
        #expect(model.presentation.settings.clicks.removed == [second.id])
        model.restoreClicks()
        #expect(model.settings.clicks.removed.isEmpty)
        model.setClicksEnabled(true)
        model.setCursor { $0.halo = true }
        #expect(model.presentation.settings.clicks.enabled && model.presentation.settings.cursor.halo)
        #expect(!model.presentation.isInert)
    }

    @Test func theRecordingEditorPassesRecordedDataAndEditsToTheCanvas() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        var recording = try await fixture.recording()
        recording.presentation = presentation().capture
        let controller = RecordingEditorWindowController(recording: recording, services: fixture.services())
        defer { controller.window?.close() }
        let presentation = controller.model.presentation
        #expect(presentation.capture == recording.presentation)
        #expect(controller.editor.model.presentation?.capture == recording.presentation)
        #expect(controller.editor.model.presentation?.settings == PresentationSettings())
        #expect(presentation.undoManager === controller.editor.model.undoManager)

        let id = try #require(presentation.addZoom(at: 0, sourceDuration: recording.duration))
        #expect(controller.editor.model.presentation?.settings.zooms.map(\.id) == [id])
        presentation.editingArea = true
        #expect(controller.editor.model.showsWholeFrame)
        await waitUntil { controller.editor.model.editedZoomArea == presentation.selectedZoom?.rect }
        controller.editor.model.onZoomAreaEdit?(.zero, .began)
        controller.editor.model.onZoomAreaEdit?(CGRect(x: 10, y: 10, width: 50, height: 30), .changed)
        controller.editor.model.onZoomAreaEdit?(.zero, .ended)
        #expect(presentation.selectedZoom?.rect == CGRect(x: 10, y: 10, width: 50, height: 30))
        await waitUntil { controller.editor.model.editedZoomArea == CGRect(x: 10, y: 10, width: 50, height: 30) }
        presentation.editingArea = false
        await waitUntil { controller.editor.model.editedZoomArea == nil }
        #expect(controller.editor.model.editedZoomArea == nil && !controller.editor.model.showsWholeFrame)
    }

    @Test func mp4ExportsAreResampledOnlyWhenEffectsAnimateByTime() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        var recording = try await fixture.recording()
        var capture = try #require(presentation().capture)
        capture.pointerIsBaked = true
        recording.presentation = capture
        final class Box { var options: [RecordingExportOptions] = [] }
        let box = Box()
        var services = fixture.services()
        services.export = { _, _, options, _, _, _ in
            box.options.append(options)
            throw CancellationError()
        }
        let controller = RecordingEditorWindowController(recording: recording, services: services)
        defer { controller.window?.close() }
        controller.model.options.format = .mp4

        controller.model.start(.prepare)
        await controller.model.waitForExport()
        #expect(box.options.last?.resamplesStyledFrames == false, "Without effects every source frame is used as is")

        _ = try #require(controller.model.presentation.addZoom(at: 0, sourceDuration: recording.duration))
        controller.model.start(.prepare)
        await controller.model.waitForExport()
        #expect(box.options.last?.resamplesStyledFrames == true, "A zoom must keep moving between source frames")
        #expect(controller.model.options.resamplesStyledFrames == false, "The user's options are left alone")
    }

    @Test func choosingAZoomAreaSuspendsAnnotationSelectionSoDeleteKeepsRedactions() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let editor = model(f, image: try striped())
        let redaction = Annotation(kind: .redact(CGRect(x: 75, y: 35, width: 10, height: 10)),
                                   style: AnnotationStyle(color: .black))
        editor.updateLive([redaction])
        editor.selection = [redaction.id]

        editor.editedZoomArea = CGRect(x: 60, y: 30, width: 40, height: 22.5)
        #expect(editor.selection.isEmpty)
        editor.selectAll()
        #expect(editor.selection.isEmpty, "Nothing can be selected while the zoom area is edited")
        let canvas = CanvasView(model: editor)
        let delete = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "\u{7F}",
                                                   charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51))
        editor.undoManager.beginUndoGrouping()
        canvas.keyDown(with: delete)
        editor.deleteSelected()
        editor.nudge(dx: 5, dy: 0)
        editor.duplicateSelected()
        editor.undoManager.endUndoGrouping()
        #expect(editor.annotations == [redaction], "Delete, nudge and duplicate leave annotations untouched")

        editor.editedZoomArea = nil
        editor.selectAll()
        #expect(editor.selection == [redaction.id], "Selection works again afterwards")
    }
}
