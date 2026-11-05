import AppKit
import ImageIO
import SwiftUI
import Testing
@testable import GlintCore
@testable import GlintEditor

@Suite("Recording annotation timing", .serialized)
@MainActor
struct RecordingAnnotationTimingTests {
    private func model(_ fixture: EditorFixture) -> EditorModel {
        let context = EditorContext(image: fixture.context.image, backingScale: 2, rawURL: nil,
                                    source: nil, isRecording: true)
        let model = EditorModel(context: context, preferences: fixture.preferences, presetStore: fixture.presets)
        return model
    }

    @Test func previewFinalAndFrozenExporterUseTheSameSourceTime() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let editor = model(f)
        let annotation = Annotation(kind: .redact(CGRect(x: 0, y: 0, width: 100, height: 80)),
                                    style: AnnotationStyle(color: .black),
                                    visibleRange: AnnotationTiming(start: 1, end: 2))
        editor.updateLive([annotation])
        let snapshot = editor.recordingFrameRenderer()
        for time in [0.9, 1, 1.99, 2] {
            editor.updateRecordingFrame(f.context.image, at: time)
            let expected = try #require(PixelBuffer(snapshot(f.context.image, time)))
            let output = try #require(PixelBuffer(editor.renderFinal()))
            #expect(output.data == expected.data)
            let visible = time >= 1 && time < 2
            #expect(editor.visibleAnnotations.count == (visible ? 1 : 0))
            #expect(output.data[0] == (visible ? 0 : 255))
            await waitUntil(seconds: 60) {
                editor.preview.flatMap { PixelBuffer($0.image) }?.data == expected.data
            }
            #expect(editor.preview.flatMap { PixelBuffer($0.image) }?.data == expected.data)
        }
        editor.showAnnotationsThroughout([annotation.id])
        #expect(try #require(PixelBuffer(snapshot(f.context.image, 0))).data[0] == 255,
                "An in-flight export retains its original timing")
        #expect(try #require(PixelBuffer(editor.recordingFrameRenderer()(f.context.image, 0))).data[0] == 0)
    }

    @Test func boundariesClampAndDragUndoesInOneStep() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let editor = model(f)
        editor.undoManager.groupsByEvent = false
        let a = editor.makeAnnotation(.arrow(from: .zero, to: CGPoint(x: 20, y: 20)))
        editor.updateLive([a])
        #expect(a.visibleRange == nil)
        editor.undoManager.beginUndoGrouping()
        editor.beginInteraction()
        editor.setAnnotationBoundary(2, isStart: true, ids: [a.id], sourceDuration: 10, live: true)
        editor.setAnnotationBoundary(4, isStart: true, ids: [a.id], sourceDuration: 10, live: true)
        editor.endInteraction(actionName: "Change Annotation Timing")
        editor.undoManager.endUndoGrouping()
        #expect(editor.annotations[0].visibleRange == AnnotationTiming(start: 4, end: 10))
        editor.undoManager.undo()
        #expect(editor.annotations[0].visibleRange == nil && !editor.canUndo)
        editor.undoManager.redo()
        editor.undoManager.beginUndoGrouping()
        editor.setAnnotationBoundary(0, isStart: false, ids: [a.id], sourceDuration: 10)
        let range = try #require(editor.annotations[0].visibleRange)
        #expect(range.end > range.start && range.end - range.start < 0.002)
        editor.setAnnotationBoundary(-10, isStart: true, ids: [a.id], sourceDuration: 10)
        editor.setAnnotationBoundary(20, isStart: false, ids: [a.id], sourceDuration: 10)
        #expect(editor.annotations[0].visibleRange == nil)
        editor.setAnnotationBoundary(.nan, isStart: true, ids: [a.id], sourceDuration: 10)
        editor.undoManager.endUndoGrouping()
        #expect(editor.annotations[0].visibleRange == nil)
        #expect(editor.statusMessage?.contains("finite") == true)
    }

    @Test func defaultRedactionsCoverWholeClipAndLimitedOnesWarnEvenWhenUnselected() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let editor = model(f)
        editor.undoManager.groupsByEvent = false
        for kind in [AnnotationKind.redact(.zero), .pixelate(.zero), .blur(.zero)] {
            let a = editor.makeAnnotation(kind)
            editor.updateLive([a])
            #expect(a.visibleRange == nil && !editor.hasTimeLimitedRedactions)
            editor.undoManager.beginUndoGrouping()
            editor.setAnnotationBoundary(1, isStart: true, ids: [a.id], sourceDuration: 10)
            editor.undoManager.endUndoGrouping()
            editor.selection = []
            #expect(editor.hasTimeLimitedRedactions)
            editor.undoManager.beginUndoGrouping()
            editor.showAnnotationsThroughout([a.id])
            editor.undoManager.endUndoGrouping()
            #expect(!editor.hasTimeLimitedRedactions)
            editor.undoManager.undo()
            #expect(editor.hasTimeLimitedRedactions)
        }
    }

    @Test func movingRangesPreservesDurationClampsToSourceAndRejectsInvalidTimes() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let editor = model(f)
        var annotation = editor.makeAnnotation(.rectangle(.zero))
        annotation.visibleRange = AnnotationTiming(start: 2, end: 6)
        let other = editor.makeAnnotation(.arrow(from: .zero, to: CGPoint(x: 20, y: 20)))
        editor.updateLive([annotation, other])
        editor.undoManager.removeAllActions()
        editor.undoManager.groupsByEvent = false
        editor.undoManager.beginUndoGrouping()
        editor.beginInteraction()
        for (requested, expected) in [(3.0, 3.0), (-5, 0), (12, 6), (1.5, 1.5)] {
            editor.moveAnnotationRange(to: requested, id: annotation.id, sourceDuration: 10, live: true)
            #expect(editor.annotations[0].visibleRange == AnnotationTiming(start: expected, end: expected + 4))
            #expect(editor.annotations[1] == other)
        }
        editor.endInteraction(actionName: "Move Annotation Timing")
        editor.undoManager.endUndoGrouping()
        editor.undoManager.undo()
        #expect(editor.annotations[0] == annotation && !editor.canUndo)
        editor.undoManager.redo()
        #expect(editor.annotations[0].visibleRange == AnnotationTiming(start: 1.5, end: 5.5))
        let beforeInvalid = editor.annotations
        for invalid in [Double.nan, .infinity, -.infinity] {
            editor.moveAnnotationRange(to: invalid, id: annotation.id, sourceDuration: 10)
            #expect(editor.annotations == beforeInvalid)
            #expect(editor.statusMessage?.contains("finite") == true)
        }
        editor.moveAnnotationRange(to: 2, id: annotation.id, sourceDuration: 0)
        editor.moveAnnotationRange(to: 2, id: other.id, sourceDuration: 10)
        #expect(editor.annotations == beforeInvalid)
        let screenshot = f.model()
        screenshot.updateLive([annotation])
        screenshot.moveAnnotationRange(to: 3, id: annotation.id, sourceDuration: 10)
        #expect(screenshot.annotations == [annotation])
    }

    @Test func screenshotsIgnoreTimingAndDuplicatedAnnotationsKeepIt() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let a = Annotation(kind: .redact(CGRect(x: 0, y: 0, width: 100, height: 80)),
                           style: AnnotationStyle(color: .black),
                           visibleRange: AnnotationTiming(start: 1, end: 2))
        let screenshot = f.model()
        screenshot.updateLive([a])
        #expect(screenshot.visibleAnnotations == [a])
        #expect(try #require(PixelBuffer(screenshot.renderFinal())).data[0] == 0)
        let editor = model(f)
        editor.updateLive([a])
        editor.selection = [a.id]
        editor.duplicateSelected()
        #expect(editor.annotations.count == 2)
        #expect(editor.annotations.allSatisfy { $0.visibleRange == a.visibleRange })
    }

    @Test func playheadShortcutsSetAnnotationRangeWithoutChangingTrim() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let video = try RecordingEditorFixture(); defer { video.cleanUp() }
        let controller = RecordingEditorWindowController(recording: try await video.recording(), services: video.services(),
                                                         preferences: f.preferences, presetStore: f.presets)
        defer { controller.window?.close() }
        let editor = controller.editor.model
        let a = editor.makeAnnotation(.rectangle(CGRect(x: 0, y: 0, width: 20, height: 20)))
        editor.updateLive([a])
        editor.selection = [a.id]
        for (text, time) in [("i", 0.5), ("o", 1.5)] {
            controller.playback.seek(to: time)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                                                     timestamp: 0, windowNumber: 0, context: nil,
                                                     characters: text.uppercased(), charactersIgnoringModifiers: text,
                                                     isARepeat: false, keyCode: 0))
            #expect(controller.editor.handleShortcut(event))
        }
        #expect(editor.annotations[0].visibleRange == AnnotationTiming(start: 0.5, end: 1.5))
        #expect(controller.model.trim.isFullRange)
        controller.model.setTrimStart(1)
        #expect(editor.annotations[0].visibleRange == AnnotationTiming(start: 0.5, end: 1.5))

        let window = try #require(controller.editor.window)
        let controls = try #require(window.contentView?.subviews.first { $0 is NSHostingView<RecordingBarView> })
        let left = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               characters: "\u{f702}", charactersIgnoringModifiers: "\u{f702}",
                                               isARepeat: false, keyCode: 123))
        #expect(window.makeFirstResponder(controls))
        controller.playback.seek(to: 1.5)
        #expect(!controller.editor.handleShortcut(left), "Focused timeline handles must receive their arrow keys")
        #expect(controller.playback.currentTime == 1.5)
        #expect(window.makeFirstResponder(nil))
        #expect(controller.editor.handleShortcut(left))
        #expect(abs(controller.playback.currentTime - (1.5 - 1.0 / 30)) < 0.001)
    }

    @Test func copiedGIFRespectsSourceRangesAfterTrimmingAndTimingEditsInvalidatePreparedFiles() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let video = try RecordingEditorFixture(); defer { video.cleanUp() }
        let recording = try await video.recording()
        let controller = RecordingEditorWindowController(recording: recording, services: video.services(),
                                                         preferences: f.preferences, presetStore: f.presets)
        defer { controller.window?.close() }
        let editor = controller.editor.model
        let a = Annotation(kind: .redact(CGRect(origin: .zero, size: recording.pixelSize)),
                           style: AnnotationStyle(color: .black),
                           visibleRange: AnnotationTiming(start: 0.7, end: 1.2))
        editor.updateLive([a])
        controller.model.setTrimStart(0.5)
        controller.model.setTrimEnd(1.5)
        controller.model.options.gif.framesPerSecond = 10
        controller.model.copy()
        await controller.model.waitForExport()
        let data = try #require(video.board.data(forType: .init("com.compuserve.gif")))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 10)
        for (index, black) in [(0, false), (3, true), (8, false)] {
            let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
            let bytes = try #require(PixelBuffer(image)).data
            #expect((bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0) == black)
        }
        _ = controller.model.prepareFile()
        await controller.model.waitForExport()
        #expect(controller.model.prepareFile() != nil)
        editor.showAnnotationsThroughout([a.id])
        #expect(controller.model.prepareFile() == nil, "Timing changes must invalidate the cached share/drag export")
        await controller.model.waitForExport()
    }
}
