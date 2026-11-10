import AppKit
import Testing
@testable import GlintCapture

@MainActor
@Suite("Selection overlay redraw")
struct SelectionOverlayTests {
    private let size = NSSize(width: 640, height: 480)

    private func view(_ session: SelectionSession, origin: CGPoint = .zero, scale: CGFloat = 1) -> OverlayView {
        OverlayView(frame: NSRect(origin: .zero, size: size), session: session,
                    screenFrameCG: CGRect(origin: origin, size: size), scale: scale)
    }

    /// A frozen screen of `size` points; `color` receives pixel coordinates with the origin at the top left.
    private func frozenScreen(size: NSSize? = nil, scale: CGFloat,
                              color: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        let size = size ?? self.size
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Bitmap memory starts with the top row.
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let i = (y * width + x) * 4
                (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]) = (r, g, b, 255)
            }
        }
        return try #require(context.makeImage())
    }

    private func window(_ frame: CGRect, id: CGWindowID = 1) -> WindowInfo {
        WindowInfo(id: id, pid: 1, ownerName: "Test", title: "Window", frame: frame, layer: 0)
    }

    @MainActor
    private final class Bitmap {
        let context: CGContext
        let size: NSSize
        let scale: CGFloat

        init(size: NSSize, scale: CGFloat) throws {
            context = try #require(CGContext(data: nil, width: Int(size.width * scale),
                                            height: Int(size.height * scale), bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: scale, y: scale)
            self.size = size
            self.scale = scale
        }

        func paint(_ view: OverlayView, damage: [NSRect]) {
            guard !damage.isEmpty else { return }
            context.saveGState()
            context.clip(to: damage)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            view.draw(damage.reduce(.null) { $0.union($1) })
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
        }

        /// What the window server shows: this chrome composited source-over the frozen background layer.
        func composited(over background: CGImage) throws -> Bitmap {
            let result = try Bitmap(size: size, scale: scale)
            let rect = NSRect(origin: .zero, size: size)
            result.context.draw(background, in: rect)
            result.context.draw(try #require(context.makeImage()), in: rect)
            return result
        }

        var pixels: Data {
            Data(bytes: context.data!, count: context.bytesPerRow * context.height)
        }

        /// RGBA at a view point (non-flipped, origin bottom left).
        func pixel(at p: NSPoint, scale: CGFloat) -> [UInt8] {
            let x = Int(p.x * scale), y = context.height - 1 - Int(p.y * scale)
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            return (0..<4).map { bytes[y * context.bytesPerRow + x * 4 + $0] }
        }
    }

    private func expectFullRedrawMatches(_ bitmap: Bitmap, view: OverlayView, scale: CGFloat,
                                        over background: CGImage? = nil,
                                        sourceLocation: SourceLocation = #_sourceLocation) throws {
        let reference = try Bitmap(size: view.bounds.size, scale: scale)
        reference.paint(view, damage: [view.bounds])
        let differences = zip(bitmap.pixels, reference.pixels).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        #expect(differences == 0, "Partial redraw must match a clean full redraw", sourceLocation: sourceLocation)
        guard let background else { return }
        let shown = try bitmap.composited(over: background).pixels
        let expected = try reference.composited(over: background).pixels
        #expect(shown == expected, "Composited partial redraw must match a clean full redraw",
                sourceLocation: sourceLocation)
    }

    @Test func dirtyRegionDistinguishesCrosshairCoverageFromItsBoundingBox() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let region = OverlayPerformance.DirtyRegion(
            rects: [CGRect(x: 20, y: 0, width: 1, height: 100),
                    CGRect(x: 0, y: 30, width: 100, height: 1)],
            bounds: bounds, fromAppKit: true)
        #expect(region.rectCount == 2 && region.fromAppKit)
        #expect(abs(region.coveredFraction - 0.0199) < 0.000001)
        #expect(region.boundingFraction == 1)
    }

    @Test func dirtyRegionClipsAndCountsOverlapsOnlyOnce() {
        let bounds = CGRect(x: -50, y: 20, width: 100, height: 100)
        let left = CGRect(x: -100, y: 0, width: 100, height: 200)
        let top = CGRect(x: -100, y: 70, width: 200, height: 100)
        let region = OverlayPerformance.DirtyRegion(rects: [left, top, left, .zero, .null],
                                                   bounds: bounds, fromAppKit: true)
        #expect(region.rectCount == 3)
        #expect(region.coveredFraction == 0.75)
        #expect(region.boundingFraction == 1)
    }

    @Test func dirtyRegionMergesNestedAndSeparatedSpans() {
        let region = OverlayPerformance.DirtyRegion(
            rects: [CGRect(x: 0, y: 0, width: 10, height: 5),
                    CGRect(x: 0, y: 1, width: 10, height: 1),
                    CGRect(x: 0, y: 8, width: 10, height: 2)],
            bounds: CGRect(x: 0, y: 0, width: 10, height: 10), fromAppKit: true)
        #expect(region.coveredFraction == 0.7)
        #expect(region.boundingFraction == 1)
    }

    @Test func emptyDirtyRegionsHaveZeroCoverage() {
        for bounds in [CGRect.zero, CGRect(x: 0, y: 0, width: 100, height: 100)] {
            let region = OverlayPerformance.DirtyRegion(
                rects: [CGRect(x: 200, y: 200, width: 10, height: 10)], bounds: bounds, fromAppKit: true)
            #expect(region.rectCount == 0)
            #expect(region.coveredFraction == 0 && region.boundingFraction == 0)
        }
    }

    @Test func directDrawMarksTheDirtyRectFallbackRatherThanClaimingAnAppKitRegion() throws {
        let session = SelectionSession(mode: .area, lastArea: nil)
        let overlay = view(session)
        let bitmap = try Bitmap(size: size, scale: 1)
        var observed: [OverlayPerformance.DirtyRegion] = []
        overlay.onDirtyRegion = { observed.append($0) }
        bitmap.paint(overlay, damage: [NSRect(x: 0, y: 0, width: size.width / 2, height: size.height)])
        let region = try #require(observed.first)
        #expect(observed.count == 1)
        #expect(!region.fromAppKit && region.rectCount == 1)
        #expect(region.coveredFraction == 0.5 && region.boundingFraction == 0.5)
        // Observing a draw does not change the pixels.
        overlay.onDirtyRegion = nil
        let reference = try Bitmap(size: size, scale: 1)
        reference.paint(overlay, damage: [NSRect(x: 0, y: 0, width: size.width / 2, height: size.height)])
        #expect(reference.pixels == bitmap.pixels)
    }

    @Test func movementOnlyInvalidatesTheAffectedDisplayAndChangedAxes() {
        let session = SelectionSession(mode: .area, lastArea: nil)
        session.cursor = CGPoint(x: 100, y: 100)
        let active = view(session)
        let other = view(session, origin: CGPoint(x: -640, y: -120), scale: 2)
        #expect(active.refresh() == [active.bounds])
        #expect(other.refresh() == [other.bounds])

        session.mouseMoved(to: CGPoint(x: 110, y: 100))
        let damage = active.refresh()
        #expect(!damage.isEmpty)
        #expect(other.refresh().isEmpty)
        #expect(active.refresh().isEmpty)
        #expect(damage.filter { $0.height == size.height }.count == 2)
        #expect(damage.allSatisfy { $0.width < size.width })
        #expect(damage.reduce(0) { $0 + $1.width * $1.height } < size.width * size.height / 10)
    }

    @Test func mouseCoordinatesRemainInGlobalPointsOnOffsetRetinaDisplay() throws {
        let session = SelectionSession(mode: .area, lastArea: nil)
        let overlay = view(session, origin: CGPoint(x: -640, y: -120), scale: 2)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 100.25, y: 200.75),
                                                  modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                  context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        overlay.mouseMoved(with: event)
        #expect(session.cursor == CGPoint(x: -539.75, y: 159.25))
    }

    @Test func crossingDisplaysErasesOldCrosshairAndLabelsAtMixedScales() throws {
        let session = SelectionSession(mode: .area, lastArea: nil)
        session.cursor = CGPoint(x: -150.5, y: 160.25)
        let left = view(session, origin: CGPoint(x: -640, y: -120), scale: 1)
        let right = view(session, origin: CGPoint(x: 0, y: 80), scale: 2)
        let leftPixels = try Bitmap(size: size, scale: 1)
        let rightPixels = try Bitmap(size: size, scale: 2)
        leftPixels.paint(left, damage: left.refresh())
        rightPixels.paint(right, damage: right.refresh())

        session.mouseMoved(to: CGPoint(x: 100.25, y: 220.75))
        let leftDamage = left.refresh()
        let rightDamage = right.refresh()
        #expect(!leftDamage.isEmpty && !rightDamage.isEmpty)
        #expect(leftDamage.contains { $0.width == size.width })
        #expect(rightDamage.contains { $0.height == size.height })
        #expect(rightDamage.allSatisfy {
            [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy { ($0 * 2).rounded() == $0 * 2 }
        })
        leftPixels.paint(left, damage: leftDamage)
        rightPixels.paint(right, damage: rightDamage)
        try expectFullRedrawMatches(leftPixels, view: left, scale: 1)
        try expectFullRedrawMatches(rightPixels, view: right, scale: 2)
    }

    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func coalescedMovesKeepAllOldAndNewDamageWithoutAlphaAccumulation(scale: CGFloat) throws {
        let session = SelectionSession(mode: .area, lastArea: nil)
        session.cursor = CGPoint(x: 20.25, y: 40.75)
        let overlay = view(session, scale: scale)
        let bitmap = try Bitmap(size: size, scale: scale)
        bitmap.paint(overlay, damage: overlay.refresh())
        var pending: [NSRect] = []
        for point in [CGPoint(x: 90.75, y: 130.25), CGPoint(x: 540.25, y: 440.75),
                      CGPoint(x: 320.5, y: 220.25)] {
            session.mouseMoved(to: point)
            pending += overlay.refresh()
        }
        #expect(pending.allSatisfy { $0 != overlay.bounds })
        bitmap.paint(overlay, damage: pending)
        try expectFullRedrawMatches(bitmap, view: overlay, scale: scale)
        bitmap.paint(overlay, damage: pending)
        try expectFullRedrawMatches(bitmap, view: overlay, scale: scale)
    }

    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func selectionChangesEraseHolesBordersAndHints(scale: CGFloat) throws {
        let session = SelectionSession(mode: .area, lastArea: nil)
        session.cursor = CGPoint(x: 130.25, y: 160.75)
        let overlay = view(session, scale: scale)
        let bitmap = try Bitmap(size: size, scale: scale)
        bitmap.paint(overlay, damage: overlay.refresh())

        let selections: [CGRect?] = [
            CGRect(x: 130.25, y: 160.75, width: 0, height: 0),
            CGRect(x: 130.25, y: 160.75, width: 0.5, height: 0.75),
            CGRect(x: 130.25, y: 160.75, width: 330.5, height: 220.25),
            CGRect(x: 130.25, y: 160.75, width: 335.5, height: 222.25),
            CGRect(x: 2.25, y: 2.75, width: 300, height: 200),
            CGRect(x: -30.5, y: 450.25, width: 200, height: 100),
            nil
        ]
        for selection in selections {
            session.selection = selection
            bitmap.paint(overlay, damage: overlay.refresh())
            try expectFullRedrawMatches(bitmap, view: overlay, scale: scale)
        }
    }

    @Test func growingSelectionDoesNotInvalidateItsUnchangedInterior() {
        let session = SelectionSession(mode: .area, lastArea: nil)
        session.cursor = CGPoint(x: 500, y: 400)
        session.selection = CGRect(x: 50, y: 50, width: 450, height: 350)
        let overlay = view(session, scale: 2)
        overlay.refresh()
        session.selection = CGRect(x: 50, y: 50, width: 452, height: 352)
        let damage = overlay.refresh()
        #expect(!damage.isEmpty)
        #expect(!damage.contains { $0.contains(CGPoint(x: 300, y: 250)) })
        #expect(damage.reduce(0) { $0 + $1.width * $1.height } < size.width * size.height / 10)
    }

    @Test func unchangedWindowHoverAndOffscreenWindowsDoNotRedraw() {
        let session = SelectionSession(mode: .window, lastArea: nil)
        session.hoverWindow = window(CGRect(x: 100, y: 100, width: 200, height: 150))
        let overlay = view(session)
        let other = view(session, origin: CGPoint(x: 640, y: -100), scale: 2)
        overlay.refresh()
        other.refresh()
        session.cursor = CGPoint(x: 150, y: 150)
        #expect(overlay.refresh().isEmpty)
        #expect(other.refresh().isEmpty)
        session.hoverWindow = window(CGRect(x: 100, y: 100, width: 200, height: 150), id: 2)
        #expect(overlay.refresh().isEmpty)
        session.hoverWindow = window(CGRect(x: 120, y: 120, width: 250, height: 200))
        #expect(!overlay.refresh().isEmpty)
        #expect(other.refresh().isEmpty)
    }

    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func windowHoverAndModeTransitionsMatchFullRedraw(scale: CGFloat) throws {
        let session = SelectionSession(mode: .area, lastArea: nil)
        session.cursor = CGPoint(x: 100, y: 100)
        session.selection = CGRect(x: 40, y: 50, width: 300, height: 250)
        let overlay = view(session, scale: scale)
        let bitmap = try Bitmap(size: size, scale: scale)
        bitmap.paint(overlay, damage: overlay.refresh())

        session.toggleMode()
        session.hoverWindow = window(CGRect(x: 40, y: 50, width: 300, height: 250))
        bitmap.paint(overlay, damage: overlay.refresh())
        try expectFullRedrawMatches(bitmap, view: overlay, scale: scale)
        for frame in [CGRect(x: -20.5, y: -10.25, width: 300, height: 250),
                      CGRect(x: 600.25, y: 420.75, width: 300, height: 250)] {
            session.hoverWindow = window(frame)
            bitmap.paint(overlay, damage: overlay.refresh())
            try expectFullRedrawMatches(bitmap, view: overlay, scale: scale)
        }
        session.hoverWindow = nil
        bitmap.paint(overlay, damage: overlay.refresh())
        try expectFullRedrawMatches(bitmap, view: overlay, scale: scale)
        session.toggleMode()
        bitmap.paint(overlay, damage: overlay.refresh())
        try expectFullRedrawMatches(bitmap, view: overlay, scale: scale)
    }

    @Test func mouseAndKeyboardEventsKeepImmediateSelectionSemantics() throws {
        let display = try #require(WindowEnumerator.displays().first)
        let session = SelectionSession(mode: .area, lastArea: nil)
        session.useDisplays([display])
        let overlay = OverlayView(frame: NSRect(origin: .zero, size: display.frame.size), session: session,
                                  screenFrameCG: display.frame, scale: display.scale)
        let anchor = CGPoint(x: display.frame.minX + 80, y: display.frame.minY + 80)
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, shift: Bool = false) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type,
                                           location: CGPoint(x: point.x - display.frame.minX,
                                                             y: display.frame.maxY - point.y),
                                           modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func key(_ code: UInt16, shift: Bool = false) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [],
                                         timestamp: 0, windowNumber: 0, context: nil, characters: "",
                                         charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        overlay.mouseMoved(with: try mouse(.mouseMoved, anchor))
        #expect(session.cursor == anchor)
        overlay.mouseDown(with: try mouse(.leftMouseDown, anchor))
        #expect(session.selection == CGRect(origin: anchor, size: .zero))
        let end = CGPoint(x: anchor.x + 40, y: anchor.y + 20)
        overlay.mouseDragged(with: try mouse(.leftMouseDragged, end, shift: true))
        #expect(session.cursor == end)
        #expect(session.selection?.size == CGSize(width: 40, height: 40))
        // Arrow events while dragging exercise nudging without warping the global pointer.
        overlay.keyDown(with: try key(124, shift: true))
        #expect(session.cursor == CGPoint(x: end.x + 10, y: end.y))
        #expect(session.selection == CGRect(x: anchor.x + 10, y: anchor.y, width: 40, height: 40))
        overlay.keyDown(with: try key(125))
        #expect(session.cursor == CGPoint(x: end.x + 10, y: end.y + 1))
        overlay.keyDown(with: try key(123))
        overlay.keyDown(with: try key(126, shift: true))
        #expect(session.cursor == CGPoint(x: end.x + 9, y: end.y - 9))
        overlay.keyDown(with: try key(36))
        overlay.keyDown(with: try key(76))
        #expect(session.selection != nil)
        let outside = CGPoint(x: display.frame.maxX + 100, y: display.frame.maxY + 100)
        overlay.mouseDragged(with: try mouse(.leftMouseDragged, outside, shift: true))
        #expect(session.cursor == CGPoint(x: display.frame.maxX, y: display.frame.maxY))
        let boundedSelection = try #require(session.selection)
        #expect(boundedSelection.intersection(display.frame) == boundedSelection)
        // Releasing Shift before the mouse-up relaxes the square constraint; the drag then ends.
        overlay.mouseUp(with: try mouse(.leftMouseUp, outside))
        let released = try #require(session.selection)
        #expect(released.intersection(display.frame) == released)
        overlay.mouseDragged(with: try mouse(.leftMouseDragged, end))
        #expect(session.selection == released)

        overlay.keyDown(with: try key(49))
        #expect(session.mode == .window && session.selection == nil)
        overlay.mouseDragged(with: try mouse(.leftMouseDragged, end))
        #expect(session.selection == nil)
        overlay.keyDown(with: try key(49))
        #expect(session.mode == .area)
        overlay.mouseDown(with: try mouse(.leftMouseDown, anchor))
        overlay.mouseUp(with: try mouse(.leftMouseUp, anchor))
        #expect(session.selection == nil)
        overlay.mouseDown(with: try mouse(.leftMouseDown, anchor))
        let tinyEnd = CGPoint(x: anchor.x + 2, y: anchor.y + 2)
        overlay.mouseDragged(with: try mouse(.leftMouseDragged, tinyEnd))
        overlay.mouseUp(with: try mouse(.leftMouseUp, tinyEnd))
        #expect(session.selection == nil)
        overlay.mouseDragged(with: try mouse(.leftMouseDragged, end))
        #expect(session.selection == nil)
        overlay.keyDown(with: try key(53))
        overlay.rightMouseDown(with: try mouse(.rightMouseDown, anchor))
    }

    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func frozenScreenShowsUndimmedInTheSelectionAndUprightUnderTheDim(scale: CGFloat) throws {
        // Red in the top-left 100 × 100 points, blue elsewhere.
        let limit = Int(100 * scale)
        let frozen = try frozenScreen(scale: scale) { x, y in x < limit && y < limit ? (255, 0, 0) : (0, 0, 255) }
        let session = SelectionSession(mode: .area, lastArea: nil)
        session.cursor = CGPoint(x: 600, y: 400)
        session.selection = CGRect(x: 10, y: 10, width: 60, height: 60)
        let overlay = view(session, scale: scale)
        let chrome = try Bitmap(size: size, scale: scale)
        chrome.paint(overlay, damage: overlay.refresh())
        let bitmap = try chrome.composited(over: frozen)

        // CG (40, 40) is inside the selection, near the display's top-left corner.
        #expect(bitmap.pixel(at: NSPoint(x: 40, y: size.height - 40), scale: scale) == [255, 0, 0, 255])
        let dimmedRed = bitmap.pixel(at: NSPoint(x: 85, y: size.height - 20), scale: scale)
        #expect(dimmedRed[0] > 100 && dimmedRed[0] < 200 && dimmedRed[1] == 0 && dimmedRed[2] == 0)
        #expect(dimmedRed[3] == 255)
        let dimmedBlue = bitmap.pixel(at: NSPoint(x: 300, y: size.height - 300), scale: scale)
        #expect(dimmedBlue[0] == 0 && dimmedBlue[1] == 0 && dimmedBlue[2] > 100 && dimmedBlue[2] < 200)

        // The chrome alone leaves the hole clear and only dims elsewhere; without a frozen screen,
        // the live display shows through.
        #expect(chrome.pixel(at: NSPoint(x: 40, y: size.height - 40), scale: scale) == [0, 0, 0, 0])
        #expect(chrome.pixel(at: NSPoint(x: 85, y: size.height - 20), scale: scale)[3] < 255)
    }

    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func frozenScreenPartialRedrawsMatchFullRedraw(scale: CGFloat) throws {
        let frozen = try frozenScreen(scale: scale) { x, y in
            (UInt8(x % 256), UInt8(y % 256), UInt8((x * 7 + y * 13) % 256))
        }
        let session = SelectionSession(mode: .area, lastArea: nil)
        session.cursor = CGPoint(x: 130.25, y: 160.75)
        let overlay = view(session, scale: scale)
        let bitmap = try Bitmap(size: size, scale: scale)
        bitmap.paint(overlay, damage: overlay.refresh())

        var pending: [NSRect] = []
        for point in [CGPoint(x: 90.75, y: 130.25), CGPoint(x: 540.25, y: 440.75), CGPoint(x: 320.5, y: 220.25)] {
            session.mouseMoved(to: point)
            pending += overlay.refresh()
        }
        bitmap.paint(overlay, damage: pending)
        try expectFullRedrawMatches(bitmap, view: overlay, scale: scale, over: frozen)

        for selection in [CGRect(x: 130.25, y: 160.75, width: 330.5, height: 220.25),
                          CGRect(x: 2.25, y: 2.75, width: 300, height: 200),
                          CGRect(x: -30.5, y: 450.25, width: 200, height: 100), nil] {
            session.selection = selection
            bitmap.paint(overlay, damage: overlay.refresh())
            try expectFullRedrawMatches(bitmap, view: overlay, scale: scale, over: frozen)
        }

        session.toggleMode()
        for frame in [CGRect(x: 40, y: 50, width: 300, height: 250),
                      CGRect(x: 600.25, y: 420.75, width: 300, height: 250)] {
            session.hoverWindow = window(frame)
            bitmap.paint(overlay, damage: overlay.refresh())
            try expectFullRedrawMatches(bitmap, view: overlay, scale: scale, over: frozen)
        }
    }

    @Test func overlayTakesKeyFocusWithoutActivatingUnlessThatFails() {
        var calls: [String] = []
        var becomesKey = true
        let makeKey = { calls.append("makeKey") }
        let activate = { calls.append("activate") }
        #expect(!OverlayFocus.makeKey(makeKey, isKey: { becomesKey }, activate: activate))
        #expect(calls == ["makeKey"])

        calls = []
        becomesKey = false
        #expect(OverlayFocus.makeKey(makeKey, isKey: { becomesKey }, activate: activate))
        #expect(calls == ["makeKey", "activate", "makeKey"])
    }

    @Test func overlayPanelIsNonActivatingAndCanBecomeKey() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let session = SelectionSession(mode: .area, lastArea: nil)
        let panel = OverlayPanel(screen: screen, session: session, level: .screenSaver,
                                 primaryHeight: screen.frame.height)
        defer { panel.close() }
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey && !panel.canBecomeMain)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.animationBehavior == .none)
        #expect(panel.firstResponder === panel.overlayView)
    }

    /// A frozen screen covering `screen`; the layer stretches it to the panel either way.
    private func frozenScreen(of screen: NSScreen) throws -> CGImage {
        try frozenScreen(size: screen.frame.size, scale: 1) { _, _ in (20, 140, 60) }
    }

    @Test func overlayPanelCompositesTheFrozenScreenInALayerBelowTheChrome() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let frozen = try frozenScreen(of: screen)
        let session = SelectionSession(mode: .area, lastArea: nil)
        let panel = OverlayPanel(screen: screen, session: session, level: .screenSaver,
                                 primaryHeight: screen.frame.height, background: frozen)
        defer { panel.close() }
        let container = try #require(panel.contentView)
        #expect(container.subviews == [panel.backgroundView, panel.overlayView])
        #expect(panel.backgroundView.frame == container.bounds && panel.overlayView.frame == container.bounds)
        let containerLayer = try #require(container.layer)
        let backgroundLayer = try #require(panel.backgroundView.layer)
        let chromeLayer = try #require(panel.overlayView.layer)
        // AppKit attaches the subviews' layers when the window first displays, before it is ordered in.
        panel.displayIfNeeded()
        let sublayers = containerLayer.sublayers ?? []
        let backgroundIndex = try #require(sublayers.firstIndex { $0 === backgroundLayer })
        let chromeIndex = try #require(sublayers.firstIndex { $0 === chromeLayer })
        #expect(backgroundIndex < chromeIndex)
        #expect((backgroundLayer.contents as CFTypeRef?) === frozen)
        #expect(backgroundLayer.contentsGravity == .resize && backgroundLayer.isOpaque)
        #expect(panel.backgroundView.isOpaque && !panel.overlayView.isOpaque)
        // Input always reaches the overlay view, never the background.
        #expect(container.hitTest(NSPoint(x: 20, y: 20)) === panel.overlayView)

        // The chrome is drawn the same with or without the frozen screen: the view never paints it.
        let plain = OverlayPanel(screen: screen, session: session, level: .screenSaver,
                                 primaryHeight: screen.frame.height)
        defer { plain.close() }
        session.selection = CGRect(x: 10, y: 10, width: 60, height: 60)
        let withFrozen = try Bitmap(size: screen.frame.size, scale: 1)
        let without = try Bitmap(size: screen.frame.size, scale: 1)
        withFrozen.paint(panel.overlayView, damage: [panel.overlayView.bounds])
        without.paint(plain.overlayView, damage: [plain.overlayView.bounds])
        #expect(withFrozen.pixels == without.pixels)
        #expect(withFrozen.pixel(at: NSPoint(x: 40, y: screen.frame.height - 40), scale: 1) == [0, 0, 0, 0])

        panel.close()
        #expect(panel.backgroundView.image == nil && backgroundLayer.contents == nil)
    }

    @Test func aPanelSnapshottedBeforeItIsShownDrawsItsFirstFrameOnce() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let session = SelectionSession(mode: .area, lastArea: nil)
        session.cursor = CGPoint(x: 100, y: 100)
        let panel = OverlayPanel(screen: screen, session: session, level: .screenSaver,
                                 primaryHeight: screen.frame.height)
        defer { panel.close() }
        let overlay = panel.overlayView
        #expect(overlay.refresh() == [overlay.bounds])
        panel.displayIfNeeded()
        #expect(!overlay.needsDisplay)
        // Nothing changed since the first snapshot, so focusing the panel does not redraw it.
        #expect(overlay.refresh().isEmpty)
        #expect(!overlay.needsDisplay)
    }

    @Test func overlayPanelWithoutAFrozenScreenIsTransparentUnderTheChrome() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let session = SelectionSession(mode: .area, lastArea: nil)
        let panel = OverlayPanel(screen: screen, session: session, level: .screenSaver,
                                 primaryHeight: screen.frame.height)
        defer { panel.close() }
        #expect(!panel.isOpaque && panel.backgroundColor == .clear)
        let backgroundLayer = try #require(panel.backgroundView.layer)
        #expect(backgroundLayer.contents == nil && !backgroundLayer.isOpaque)
        #expect(!panel.backgroundView.isOpaque)
    }

    @Test func chromeFadesInOverAnAlreadyOpaqueFrozenScreenUnlessReduceMotionIsOn() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let frozen = try frozenScreen(of: screen)
        let session = SelectionSession(mode: .area, lastArea: nil)
        let panel = OverlayPanel(screen: screen, session: session, level: .screenSaver,
                                 primaryHeight: screen.frame.height, background: frozen)
        defer { panel.close() }
        let chromeLayer = try #require(panel.overlayView.layer)
        let backgroundLayer = try #require(panel.backgroundView.layer)

        panel.revealChrome(reduceMotion: true)
        #expect(chromeLayer.animation(forKey: OverlayPanel.chromeFadeKey) == nil)
        #expect(chromeLayer.opacity == 1 && panel.overlayView.alphaValue == 1)

        panel.revealChrome(reduceMotion: false)
        let fade = try #require(chromeLayer.animation(forKey: OverlayPanel.chromeFadeKey) as? CABasicAnimation)
        #expect(fade.keyPath == "opacity")
        #expect((fade.fromValue as? NSNumber)?.doubleValue == 0 && (fade.toValue as? NSNumber)?.doubleValue == 1)
        #expect(fade.duration == OverlayPanel.chromeFadeDuration && fade.duration <= 0.15)
        let easeOut = CAMediaTimingFunction(name: .easeOut)
        for index in 0..<4 {
            var actual: [Float] = [0, 0], expected: [Float] = [0, 0]
            fade.timingFunction?.getControlPoint(at: index, values: &actual)
            easeOut.getControlPoint(at: index, values: &expected)
            #expect(actual == expected)
        }
        // The model value is already opaque, so the chrome stays at full strength once the fade ends.
        #expect(chromeLayer.opacity == 1 && panel.overlayView.alphaValue == 1)
        // The frozen screen is never faded: it matches the display, so it is fully opaque from the first frame.
        #expect(backgroundLayer.animationKeys() == nil && backgroundLayer.opacity == 1)
        #expect(panel.backgroundView.alphaValue == 1 && (backgroundLayer.contents as CFTypeRef?) === frozen)

        panel.revealChrome(reduceMotion: true)
        #expect(chromeLayer.animation(forKey: OverlayPanel.chromeFadeKey) == nil)
    }

    @Test func warmingUpFillsTheSharedCachesOnceForEachScale() {
        OverlayView.warmUp(scales: [3])
        let hints = OverlayView.cachedHintCount
        let backgrounds = OverlayView.cachedBackgroundCount
        #expect(hints >= 5, "Four area hints and the window hint")
        #expect(backgrounds > 0)

        OverlayView.warmUp(scales: [3])
        #expect(OverlayView.cachedHintCount == hints)
        #expect(OverlayView.cachedBackgroundCount == backgrounds)

        // The capsule behind a hint is rendered in backing pixels, so another scale needs its own.
        OverlayView.warmUp(scales: [4])
        #expect(OverlayView.cachedHintCount == hints)
        #expect(OverlayView.cachedBackgroundCount != backgrounds)
    }

    @Test func aFirstFrameAtAWarmedScaleBuildsNoHintText() throws {
        OverlayView.warmUp(scales: [3])
        let hints = OverlayView.cachedHintCount

        let session = SelectionSession(mode: .area, lastArea: nil)
        let overlay = view(session, scale: 3)
        let bitmap = try Bitmap(size: size, scale: 3)
        bitmap.paint(overlay, damage: overlay.refresh())
        session.toggleMode()
        bitmap.paint(overlay, damage: overlay.refresh())

        #expect(OverlayView.cachedHintCount == hints)
    }
}
