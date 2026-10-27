import CoreGraphics
import GlintCore
import Testing
@testable import GlintEditor

@Suite("Zoom tool")
@MainActor
struct MagnifierEditorTests {
    private func magnifier(_ a: Annotation?) -> Magnifier? {
        if case .magnify(let m) = a?.kind { return m }
        return nil
    }

    private func add(_ model: EditorModel, source: CGRect) -> Annotation? {
        model.undoManager.beginUndoGrouping()
        defer { model.undoManager.endUndoGrouping() }
        return model.addMagnifier(source: source)
    }

    @Test func creatingPlacesTwiceMagnifiedInsetBesideSourceAndSelectsIt() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        model.pressToolKey(.zoom)
        let a = try #require(add(model, source: CGRect(x: 10, y: 10, width: 10, height: 10)))
        let m = try #require(magnifier(a))
        #expect(m.source == CGRect(x: 10, y: 10, width: 10, height: 10))
        #expect(m.inset == CGRect(x: 68, y: 5, width: 20, height: 20))
        #expect(m.magnification == 2 && m.shape == .circle && m.showsSourceOutline && m.showsConnector)
        #expect(model.annotations == [a] && model.selection == [a.id] && model.tool == .select)
        #expect(model.undoManager.undoActionName == "Add Zoom")
    }

    @Test func creationClampsSourceToImageAndRejectsEmptySelections() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        #expect(add(model, source: CGRect(x: 200, y: 10, width: 10, height: 10)) == nil)
        let a = try #require(add(model, source: CGRect(x: 90, y: -5, width: 20, height: 15)))
        #expect(magnifier(a)?.source == CGRect(x: 90, y: 0, width: 10, height: 10))
    }

    @Test func insetFallsOutsideImageWhenThereIsNoRoomAndExportGrows() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        let plain = try model.renderFinal()
        let a = try #require(add(model, source: CGRect(x: 40, y: 20, width: 30, height: 30)))
        let m = try #require(magnifier(a))
        #expect(m.inset == CGRect(x: 148, y: 5, width: 60, height: 60))
        let grown = try model.renderFinal()
        #expect(plain.width == 100)
        #expect(grown.width >= 208 && grown.height >= plain.height)
    }

    @Test func defaultMagnificationIsLimitedButNeverBelowMinimum() {
        let size = CGSize(width: 100, height: 80)
        let big = EditorModel.magnifierInset(for: CGRect(x: 0, y: 0, width: 50, height: 25), magnification: 2,
                                             imageSize: size, gap: 4)
        #expect(big.width == 62.5 && big.height == 31.25)
        let limited = EditorModel.magnifierInset(for: CGRect(x: 0, y: 0, width: 20, height: 10), magnification: 2,
                                                 imageSize: size, gap: 4)
        #expect(limited.size == CGSize(width: 40, height: 20))
    }

    @Test func movingInsetOrSourceMovesOnlyThatPart() {
        let a = Annotation(kind: .magnify(Magnifier(source: CGRect(x: 0, y: 0, width: 10, height: 10),
                                                   inset: CGRect(x: 30, y: 0, width: 20, height: 20))))
        let d = CGSize(width: 5, height: 7)
        let inset = AnnotationGeometry.moved(a, part: .inset, by: d)
        #expect(magnifier(inset)?.inset == CGRect(x: 35, y: 7, width: 20, height: 20))
        #expect(magnifier(inset)?.source == CGRect(x: 0, y: 0, width: 10, height: 10))
        let source = AnnotationGeometry.moved(a, part: .source, by: d)
        #expect(magnifier(source)?.source == CGRect(x: 5, y: 7, width: 10, height: 10))
        #expect(magnifier(source)?.inset == CGRect(x: 30, y: 0, width: 20, height: 20))
        #expect(AnnotationGeometry.moved(a, part: nil, by: d) == a.translated(by: d))
        #expect(AnnotationGeometry.magnifierPart(a, at: CGPoint(x: 40, y: 10), tol: 1) == .inset)
        #expect(AnnotationGeometry.magnifierPart(a, at: CGPoint(x: 5, y: 5), tol: 1) == .source)
        #expect(AnnotationGeometry.magnifierPart(a, at: CGPoint(x: 31, y: 1), tol: 0) == nil)
    }

    @Test func sourceHandleResizeKeepsMagnificationAboutInsetCentre() throws {
        let a = Annotation(kind: .magnify(Magnifier(source: CGRect(x: 0, y: 0, width: 10, height: 10),
                                                   inset: CGRect(x: 30, y: 0, width: 30, height: 30))))
        let r = AnnotationGeometry.resized(a, handle: .sourceBR, to: CGPoint(x: 20, y: 14), constrain: false)
        let m = try #require(magnifier(r))
        #expect(m.source == CGRect(x: 0, y: 0, width: 20, height: 14))
        #expect(abs(m.magnification - 3) < 0.0001)
        #expect(m.inset == CGRect(x: 15, y: -6, width: 60, height: 42))
    }

    @Test func insetHandleResizeChangesMagnificationAndKeepsAspect() throws {
        let a = Annotation(kind: .magnify(Magnifier(source: CGRect(x: 0, y: 0, width: 20, height: 10),
                                                   inset: CGRect(x: 40, y: 0, width: 40, height: 20))))
        let r = AnnotationGeometry.resized(a, handle: .insetBR, to: CGPoint(x: 100, y: 5), constrain: false)
        let m = try #require(magnifier(r))
        #expect(m.source == CGRect(x: 0, y: 0, width: 20, height: 10))
        #expect(m.inset == CGRect(x: 40, y: 0, width: 60, height: 30))
        #expect(abs(m.magnification - 3) < 0.0001)
        let huge = try #require(magnifier(AnnotationGeometry.resized(a, handle: .insetTL, to: CGPoint(x: -1000, y: 0),
                                                                     constrain: false)))
        #expect(huge.magnification == 8 && huge.inset.maxX == 80 && huge.inset.maxY == 20)
    }

    @Test func nudgeMovesOnlyInsetOfSingleMagnifier() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        let a = try #require(add(model, source: CGRect(x: 10, y: 10, width: 10, height: 10)))
        model.undoManager.beginUndoGrouping()
        model.nudge(dx: 3, dy: -2)
        model.undoManager.endUndoGrouping()
        let m = try #require(magnifier(model.annotations.first))
        #expect(m.source == CGRect(x: 10, y: 10, width: 10, height: 10))
        #expect(m.inset == CGRect(x: 71, y: 3, width: 20, height: 20))
        let other = Annotation(z: 5, kind: .redact(CGRect(x: 0, y: 0, width: 5, height: 5)))
        model.updateLive(model.annotations + [other])
        model.selection = [a.id, other.id]
        model.undoManager.beginUndoGrouping()
        model.nudge(dx: 1, dy: 0)
        model.undoManager.endUndoGrouping()
        #expect(magnifier(model.annotations.first)?.source == CGRect(x: 11, y: 10, width: 10, height: 10))
    }

    @Test func pressingZAgainTogglesShapeAndInspectorSettersAreUndoable() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        model.pressToolKey(.zoom)
        #expect(model.tool == .zoom && model.magnifierShape == .circle && model.showsMagnifierControls)
        model.pressToolKey(.zoom)
        #expect(model.magnifierShape == .rectangle && model.variantDescription() == "Rectangle")
        model.pressToolKey(.zoom)
        #expect(model.magnifierShape == .circle)

        let a = try #require(add(model, source: CGRect(x: 10, y: 10, width: 10, height: 10)))
        model.undoManager.beginUndoGrouping()
        model.setMagnification(3)
        model.undoManager.endUndoGrouping()
        let m = try #require(magnifier(model.annotations.first))
        #expect(m.inset == CGRect(x: 63, y: 0, width: 30, height: 30) && model.currentMagnification == 3)
        model.undoManager.beginUndoGrouping()
        model.setMagnifierShape(.rectangle)
        model.setMagnifierShowsConnector(false)
        model.setMagnifierShowsSourceOutline(false)
        model.undoManager.endUndoGrouping()
        let changed = try #require(magnifier(model.annotations.first))
        #expect(changed.shape == .rectangle && !changed.showsConnector && !changed.showsSourceOutline)
        model.undoManager.undo()
        model.undoManager.undo()
        #expect(model.annotations == [a])
        model.undoManager.beginUndoGrouping()
        model.setMagnification(100)
        model.undoManager.endUndoGrouping()
        #expect(model.currentMagnification == 8)
    }

    @Test func undoRemovesAddedZoom() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        _ = try #require(add(model, source: CGRect(x: 10, y: 10, width: 10, height: 10)))
        model.undoManager.undo()
        #expect(model.annotations.isEmpty && model.selection.isEmpty)
        model.undoManager.redo()
        #expect(model.annotations.count == 1 && model.annotations.first?.isMagnifier == true)
    }

    @Test func annotationsAddedMidDragSurviveTheDragAndItsUndo() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        let a = try #require(add(model, source: CGRect(x: 10, y: 10, width: 10, height: 10)))
        let original = try #require(magnifier(a))
        model.beginInteraction()
        let base = Dictionary(uniqueKeysWithValues: model.selectedAnnotations.map { ($0.id, $0) })
        model.updateLive(AnnotationGeometry.moving(model.annotations, from: base, part: .inset, by: CGSize(width: 2, height: 0)))
        // Auto-redact finishes while the mouse is still down.
        let redaction = Annotation(z: 9, kind: .redact(CGRect(x: 0, y: 0, width: 5, height: 5)))
        model.undoManager.beginUndoGrouping()
        model.setAnnotations(model.annotations + [redaction], actionName: "Auto-Redact")
        model.undoManager.endUndoGrouping()
        model.updateLive(AnnotationGeometry.moving(model.annotations, from: base, part: .inset, by: CGSize(width: 5, height: 1)))
        #expect(model.annotations.contains(redaction))
        #expect(magnifier(model.annotations.first { $0.id == a.id })?.inset == original.inset.offsetBy(dx: 5, dy: 1))
        model.undoManager.beginUndoGrouping()
        model.endInteraction(actionName: "Move")
        model.undoManager.endUndoGrouping()
        let moved = model.annotations
        #expect(moved.contains(redaction))

        model.undoManager.undo()
        #expect(model.annotations == [a, redaction])
        model.undoManager.undo()
        #expect(model.annotations == [a])
        model.undoManager.redo()
        #expect(model.annotations == [a, redaction])
        model.undoManager.redo()
        #expect(model.annotations == moved)
    }

    @Test func zoomSelectionIsClampedAndSquareStaysInside() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        #expect(AnnotationGeometry.zoomSelection(from: CGPoint(x: 90, y: 10), to: CGPoint(x: 150, y: -20), square: false, in: bounds)
                == CGRect(x: 90, y: 0, width: 10, height: 10))
        #expect(AnnotationGeometry.zoomSelection(from: CGPoint(x: 80, y: 10), to: CGPoint(x: 95, y: 60), square: true, in: bounds)
                == CGRect(x: 80, y: 10, width: 20, height: 20))
    }
}
