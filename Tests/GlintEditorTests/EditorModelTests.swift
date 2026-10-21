import CoreGraphics
import GlintCore
import Testing
@testable import GlintEditor

@Suite("Editor model")
@MainActor
struct EditorModelTests {
    @Test func interactionHasOneUndoStepAndRedoRestoresFinalState() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        let annotation = model.makeAnnotation(.rectangle(CGRect(x: 10, y: 10, width: 20, height: 15)))
        model.undoManager.beginUndoGrouping()
        model.beginInteraction()
        model.append(annotation)
        let moved = annotation.translated(by: CGSize(width: 5, height: 8))
        model.replace(moved)
        model.endInteraction(actionName: "Draw")
        model.undoManager.endUndoGrouping()
        #expect(model.annotations == [moved] && model.canUndo)
        model.undoManager.undo()
        #expect(model.annotations.isEmpty && !model.canUndo && model.canRedo)
        model.undoManager.redo()
        #expect(model.annotations == [moved])
    }

    @Test func cancelAndUnchangedInteractionsDoNotAddUndo() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        model.beginInteraction()
        model.append(model.makeAnnotation(.redact(CGRect(x: 1, y: 1, width: 5, height: 5))))
        model.cancelInteraction()
        #expect(model.annotations.isEmpty && !model.canUndo)
        model.beginInteraction()
        model.endInteraction(actionName: "No change")
        #expect(!model.canUndo)
    }

    @Test func duplicationOffsetsAtBackingScaleAndSelectsNewIdentity() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        let original = model.makeAnnotation(.rectangle(CGRect(x: 0, y: 0, width: 20, height: 10)))
        model.updateLive([original])
        model.selection = [original.id]
        model.undoManager.beginUndoGrouping()
        model.duplicateSelected()
        model.undoManager.endUndoGrouping()
        let copy = try #require(model.annotations.last)
        #expect(model.annotations.count == 2 && copy.id != original.id)
        #expect(copy.kind == .rectangle(CGRect(x: 40, y: 40, width: 20, height: 10)))
        #expect(copy.z > original.z && model.selection == [copy.id])
        model.undoManager.undo()
        #expect(model.annotations == [original] && model.selection.isEmpty)
    }

    @Test func reorderingSelectedBlockPreservesOrderAndSupportsUndo() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        let annotations = (0..<4).map { Annotation(z: $0, kind: .counter(center: CGPoint(x: $0 * 10, y: 10), number: $0 + 1)) }
        model.updateLive(annotations)
        model.selection = [annotations[1].id, annotations[2].id]
        model.undoManager.beginUndoGrouping()
        model.reorder(.forward)
        model.undoManager.endUndoGrouping()
        #expect(model.annotations.map(\.id) == [annotations[0].id, annotations[3].id, annotations[1].id, annotations[2].id])
        #expect(model.annotations.map(\.z) == [0, 1, 2, 3])
        model.undoManager.undo()
        #expect(model.annotations == annotations)
    }

    @Test func deleteAndNudgeAffectOnlySelection() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        let a = Annotation(z: 0, kind: .redact(CGRect(x: 10, y: 10, width: 20, height: 20)))
        let b = Annotation(z: 1, kind: .redact(CGRect(x: 50, y: 10, width: 20, height: 20)))
        model.updateLive([a, b])
        model.selection = [a.id]
        model.undoManager.beginUndoGrouping()
        model.nudge(dx: 3, dy: -2)
        model.undoManager.endUndoGrouping()
        #expect(model.annotations == [a.translated(by: CGSize(width: 3, height: -2)), b])
        model.undoManager.beginUndoGrouping()
        model.deleteSelected()
        model.undoManager.endUndoGrouping()
        #expect(model.annotations == [b] && model.selection.isEmpty)
        model.undoManager.undo()
        #expect(model.annotations.count == 2)
    }

    @Test func toolVariantsCycleAndTransformsDisableEditing() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        #expect(model.isEditable)
        model.pressToolKey(.arrow)
        #expect(!model.arrowIsLine)
        model.pressToolKey(.arrow)
        #expect(model.arrowIsLine)
        model.pressToolKey(.shape)
        for variant in [ShapeVariant.rounded, .ellipse, .line, .rectangle] {
            model.pressToolKey(.shape)
            #expect(model.shapeVariant == variant)
        }
        model.rotate(clockwise: true)
        #expect(!model.isEditable)
        model.rotate(clockwise: false)
        #expect(model.isEditable)
        model.settings.flipHorizontal = true
        #expect(!model.isEditable)
        model.settings.flipHorizontal = false
        model.settings.tilt = Tilt(x: 8, y: 0)
        #expect(!model.isEditable)
    }

    @Test func finalRenderIncludesAnnotationBeingEdited() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        let annotation = Annotation(kind: .redact(CGRect(x: 0, y: 0, width: 100, height: 80)), style: AnnotationStyle(color: .black))
        model.updateLive([annotation])
        model.editingID = annotation.id
        let rendered = model.renderFinal()
        #expect(rendered.width == 100 && rendered.height == 80)
        let bitmap = try #require(GlintBitmap.makeContext(width: 100, height: 80))
        bitmap.draw(rendered, in: CGRect(x: 0, y: 0, width: 100, height: 80))
        let bytes = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 255)
    }
}
