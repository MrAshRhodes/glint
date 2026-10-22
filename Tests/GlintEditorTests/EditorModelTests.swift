import CoreGraphics
@testable import GlintCore
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
        let rendered = try model.renderFinal()
        #expect(rendered.width == 100 && rendered.height == 80)
        let bitmap = try #require(GlintBitmap.makeContext(width: 100, height: 80))
        bitmap.draw(rendered, in: CGRect(x: 0, y: 0, width: 100, height: 80))
        let bytes = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 255)
    }

    @Test(arguments: RedactionStyle.allCases)
    func manualModeStartsSolidAndNeverPersists(_ legacyStyle: RedactionStyle) throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.defaults.set(legacyStyle.rawValue, forKey: AppPreferences.Key.redactStyle)
        let model = f.model()
        model.pressToolKey(.redact)
        #expect(model.redactStyle == .solid && !model.showsObfuscationWarning)
        #expect(EditorTool.redact.title == "Redact / Obfuscate" && EditorTool.redact.keyHint == "3")
        #expect(model.variantDescription() == "Solid redaction")
        for mode in RedactionStyle.allCases {
            model.setRedactStyle(mode)
            for _ in 0..<3 { model.pressToolKey(.redact) }
            #expect(model.redactStyle == mode && model.variantDescription() == mode.displayName)
            #expect(model.showsObfuscationWarning == mode.isObfuscation)
            model.pressToolKey(.select)
            model.pressToolKey(.redact)
            #expect(model.redactStyle == mode)
        }
        model.redactStyle = .pixelate
        #expect(f.model().redactStyle == .solid)
        #expect(f.preferences.defaults.string(forKey: AppPreferences.Key.redactStyle) == legacyStyle.rawValue)
    }

    @Test func redactionAppearanceDefaultsApplyToNewRegionsButResetPerImage() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        let rect = CGRect(x: 4, y: 6, width: 30, height: 20)
        let foreground = RGBAColor(r: 0.2, g: 0.4, b: 0.8, a: 0.1)
        let background = RGBAColor(r: 0.8, g: 0.7, b: 0.6, a: 0.1)
        model.setRedactColor(foreground)
        model.setRedactPattern(.checkerboard)
        model.setRedactSecondaryColor(background)
        model.setPixelateHighlight(true)
        model.setRedactCellSize(46)
        model.defaultStyle.opacity = 0.2
        model.defaultStyle.cornerRadius = 100
        for kind in [AnnotationKind.redact(rect), .pixelate(rect)] {
            let annotation = model.makeAnnotation(kind)
            #expect(annotation.style.color == foreground.with(alpha: 1))
            #expect(annotation.style.redactionPattern == .checkerboard)
            #expect(annotation.style.redactionSecondaryColor == background.with(alpha: 1))
            #expect(annotation.style.pixelateHighlight)
            #expect(annotation.style.intensity == 46)
            #expect(annotation.style.opacity == 1 && annotation.style.cornerRadius == 0)
        }
        let fresh = f.model()
        let plain = fresh.makeAnnotation(.redact(rect))
        #expect(fresh.redactStyle == .solid && plain.style.redactionPattern == .plain)
        #expect(!plain.style.pixelateHighlight && plain.style.intensity == 28)
        #expect(plain.style.color == foreground.with(alpha: 1))
        #expect(plain.style.redactionSecondaryColor == AnnotationStyle().redactionSecondaryColor)
        #expect(!model.canUndo)
    }

    @Test func appearanceEditsTargetApplicableSelectionAndSupportUndoRedo() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        let rect = CGRect(x: 4, y: 6, width: 30, height: 20)
        let kinds: [AnnotationKind] = [.rectangle(rect), .redact(rect), .pixelate(rect), .blur(rect), .redact(rect)]
        let original = kinds.map { model.makeAnnotation($0) }
        model.updateLive(original)
        model.selection = Set(original.prefix(4).map(\.id))
        let annotationColor = f.preferences.annotationColor
        let accent = RGBAColor(r: 0.2, g: 0.8, b: 0.4)
        model.undoManager.beginUndoGrouping()
        model.setRedactPattern(.checkerboard)
        model.setRedactSecondaryColor(.white)
        model.setPixelateHighlight(true)
        model.setRedactColor(accent)
        model.setRedactCellSize(44)
        model.undoManager.endUndoGrouping()
        let edited = model.annotations
        #expect(edited[0] == original[0] && edited[3] == original[3] && edited[4] == original[4])
        #expect(edited[1].style.redactionPattern == .checkerboard && edited[1].style.redactionSecondaryColor == .white)
        #expect(!edited[1].style.pixelateHighlight)
        #expect(edited[2].style.pixelateHighlight && edited[2].style.redactionPattern == .plain)
        #expect(edited[1].style.color == accent && edited[2].style.color == accent)
        #expect(edited[1].style.intensity == 44 && edited[2].style.intensity == 44)
        #expect(model.redactionAppearance(for: .solid) == edited[1].style)
        #expect(model.redactionAppearance(for: .pixelate) == edited[2].style)
        #expect(f.preferences.annotationColor == annotationColor && f.preferences.redactColor == accent)
        model.undoManager.undo()
        #expect(model.annotations == original)
        #expect(model.redactionAppearance(for: .solid) == original[1].style)
        model.undoManager.redo()
        #expect(model.annotations == edited)
        model.undoManager.beginUndoGrouping()
        model.setPixelateHighlight(false)
        model.undoManager.endUndoGrouping()
        #expect(!model.annotations[2].style.pixelateHighlight)
        model.undoManager.undo()
        #expect(model.annotations[2].style.pixelateHighlight)
    }

    @Test func consecutiveAppearanceEditsRemainUndoableAcrossSelectionChanges() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        let rect = CGRect(x: 2, y: 2, width: 20, height: 20)
        let original = [model.makeAnnotation(.redact(rect)), model.makeAnnotation(.redact(rect))]
        model.updateLive(original)
        for annotation in original {
            model.selection = [annotation.id]
            model.undoManager.beginUndoGrouping()
            model.setRedactPattern(.checkerboard)
            model.undoManager.endUndoGrouping()
        }
        model.undoManager.undo()
        #expect(model.annotations[0].style.redactionPattern == .checkerboard)
        #expect(model.annotations[1] == original[1])
        model.undoManager.undo()
        #expect(model.annotations == original)
        model.undoManager.redo()
        model.undoManager.redo()
        #expect(model.annotations.allSatisfy { $0.style.redactionPattern == .checkerboard })
        model.undoManager.beginUndoGrouping()
        model.setRedactPattern(.plain)
        model.undoManager.endUndoGrouping()
        #expect(model.annotations[1].style.redactionPattern == .plain)
        model.undoManager.undo()
        #expect(model.annotations[1].style.redactionPattern == .checkerboard)
    }

    @Test func explicitModeChangesSelectedRegionsAndLabelsWithUndoRedo() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        let rect = CGRect(x: 1.2, y: 3.4, width: 18.6, height: 12.8)
        let blurred = Annotation(kind: .blur(rect), style: AnnotationStyle(color: .red, opacity: 0.2, cornerRadius: 12))
        let shape = model.makeAnnotation(.rectangle(rect))
        model.updateLive([blurred, shape])
        model.selection = [blurred.id, shape.id]
        #expect(model.currentRedactStyle == .blur && model.showsObfuscationWarning)
        model.undoManager.beginUndoGrouping()
        model.setRedactStyle(.pixelate)
        model.undoManager.endUndoGrouping()
        let secure = model.annotations[0]
        #expect(secure.kind == .pixelate(rect) && secure.id == blurred.id && secure.z == blurred.z)
        #expect(secure.style.color == model.redactColor && secure.style.opacity == 1 && secure.style.cornerRadius == 0)
        #expect(model.annotations[1] == shape)
        #expect(model.currentRedactStyle == .pixelate && !model.showsObfuscationWarning)
        #expect(model.activeRedactionModes == [.pixelate])
        model.undoManager.undo()
        #expect(model.annotations == [blurred, shape])
        #expect(model.currentRedactStyle == .blur && model.showsObfuscationWarning)
        model.undoManager.redo()
        #expect(model.annotations[0] == secure && model.currentRedactStyle == .pixelate)
        model.selection = []
        model.pressToolKey(.redact)
        #expect(model.variantDescription() == RedactionStyle.pixelate.displayName)
        #expect(!model.showsObfuscationWarning)
    }

    @Test func blurIntensityUpdatesNewAndSelectedBlurWithoutChangingSecureTiles() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        let rect = CGRect(x: 4, y: 6, width: 30, height: 20)
        model.setBlurIntensity(36)
        let blurred = model.makeAnnotation(.blur(rect))
        let mosaic = model.makeAnnotation(.pixelate(rect))
        #expect(blurred.style.intensity == 36)
        model.updateLive([mosaic, blurred])
        model.selection = [mosaic.id, blurred.id]
        model.undoManager.beginUndoGrouping()
        model.setBlurIntensity(52)
        model.undoManager.endUndoGrouping()
        #expect(model.annotations[0] == mosaic)
        #expect(model.annotations[1].style.intensity == 52)
        #expect(model.redactionAppearance(for: .blur).intensity == 52)
        model.undoManager.undo()
        #expect(model.annotations == [mosaic, blurred])
    }

    @Test func selectedObfuscationWarnsWithoutChangingColorPreferences() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        let region = CGRect(x: 10, y: 10, width: 20, height: 20)
        let originalColor = f.preferences.annotationColor
        for kind in [AnnotationKind.blur(region), .pixelate(region), .redact(region)] {
            let annotation = model.makeAnnotation(kind)
            let shape = model.makeAnnotation(.rectangle(region))
            model.updateLive([annotation, shape])
            model.selection = [annotation.id, shape.id]
            #expect(model.tool == .select)
            #expect(model.showsObfuscationWarning == annotation.isObfuscation)
            model.undoManager.beginUndoGrouping()
            model.updateStyle(key: "color") { $0.color = .black }
            model.undoManager.endUndoGrouping()
            #expect(f.preferences.annotationColor == originalColor)
        }
        model.selection = []
        #expect(!model.showsObfuscationWarning)
        model.updateStyle(key: "color") { $0.color = .black }
        #expect(f.preferences.annotationColor == .black)
    }

    @Test(arguments: RedactionStyle.allCases)
    func automaticRedactionIgnoresManualModeAndSupportsUndo(_ manualMode: RedactionStyle) async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 20, width: 80, height: 40))]
        let model = EditorModel(context: f.context, preferences: f.preferences, presetStore: f.presets,
                                recognizeText: { _ in lines })
        model.undoManager.groupsByEvent = false
        model.redactStyle = manualMode
        model.setRedactPattern(.checkerboard)
        model.setRedactSecondaryColor(.white)
        model.setPixelateHighlight(true)
        model.undoManager.beginUndoGrouping()
        await model.runAutoRedact()
        model.undoManager.endUndoGrouping()
        let annotations = model.annotations
        #expect(annotations.count == 1 && annotations.allSatisfy { $0.isRedaction && !$0.isObfuscation })
        #expect(annotations.allSatisfy { $0.style.redactionPattern == .plain && !$0.style.pixelateHighlight && $0.style.opacity == 1 })
        #expect(model.redactStyle == manualMode && !model.isBusy)
        let pixels = try #require(PixelBuffer(model.renderFinal()))
        for y in 14..<66 { for x in 4..<96 {
            #expect(pixels.pixel(x, y) == (0, 0, 0, 255))
        } }
        model.undoManager.undo()
        #expect(model.annotations.isEmpty)
        model.undoManager.redo()
        #expect(model.annotations == annotations)
        model.undoManager.beginUndoGrouping()
        await model.runAutoRedact()
        model.undoManager.endUndoGrouping()
        #expect(model.annotations.count == 1 && model.annotations.allSatisfy(\.isRedaction))
    }

    @Test(arguments: RedactionStyle.allCases)
    func headlessRedactionIgnoresLegacyStyle(_ legacyStyle: RedactionStyle) throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.defaults.set(legacyStyle.rawValue, forKey: AppPreferences.Key.redactStyle)
        f.preferences.autoRedact = true
        let output = try EditorHeadless.render(context: f.context, preferences: f.preferences, recognizeText: { _ in
            [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 20, width: 80, height: 40))]
        })
        let pixels = try #require(PixelBuffer(output))
        for y in 14..<66 { for x in 4..<96 {
            #expect(pixels.pixel(x, y) == (0, 0, 0, 255))
        } }
        #expect(pixels.pixel(0, 0) == (255, 255, 255, 255))
    }
}
