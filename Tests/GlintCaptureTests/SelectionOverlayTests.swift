import AppKit
import Testing
@testable import GlintCapture

@MainActor
@Suite("Selection overlay redraw")
struct SelectionOverlayTests {
    private let size = NSSize(width: 640, height: 480)

    private func view(_ session: SelectionSession, origin: CGPoint = .zero, scale: CGFloat = 1,
                      background: CGImage? = nil) -> OverlayView {
        OverlayView(frame: NSRect(origin: .zero, size: size), session: session,
                    screenFrameCG: CGRect(origin: origin, size: size), scale: scale, background: background)
    }

    /// A display-sized frozen screen; `color` receives pixel coordinates with the origin at the top left.
    private func frozenScreen(scale: CGFloat, color: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
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

        init(size: NSSize, scale: CGFloat) throws {
            context = try #require(CGContext(data: nil, width: Int(size.width * scale),
                                            height: Int(size.height * scale), bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: scale, y: scale)
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
                                        sourceLocation: SourceLocation = #_sourceLocation) throws {
        let reference = try Bitmap(size: view.bounds.size, scale: scale)
        reference.paint(view, damage: [view.bounds])
        let differences = zip(bitmap.pixels, reference.pixels).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        #expect(differences == 0, "Partial redraw must match a clean full redraw", sourceLocation: sourceLocation)
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
        let overlay = view(session, scale: scale, background: frozen)
        let bitmap = try Bitmap(size: size, scale: scale)
        bitmap.paint(overlay, damage: overlay.refresh())

        // CG (40, 40) is inside the selection, near the display's top-left corner.
        #expect(bitmap.pixel(at: NSPoint(x: 40, y: size.height - 40), scale: scale) == [255, 0, 0, 255])
        let dimmedRed = bitmap.pixel(at: NSPoint(x: 85, y: size.height - 20), scale: scale)
        #expect(dimmedRed[0] > 100 && dimmedRed[0] < 200 && dimmedRed[1] == 0 && dimmedRed[2] == 0)
        #expect(dimmedRed[3] == 255)
        let dimmedBlue = bitmap.pixel(at: NSPoint(x: 300, y: size.height - 300), scale: scale)
        #expect(dimmedBlue[0] == 0 && dimmedBlue[1] == 0 && dimmedBlue[2] > 100 && dimmedBlue[2] < 200)

        let live = try Bitmap(size: size, scale: scale)
        live.paint(view(session, scale: scale), damage: [NSRect(origin: .zero, size: size)])
        #expect(live.pixel(at: NSPoint(x: 40, y: size.height - 40), scale: scale) == [0, 0, 0, 0])
        #expect(live.pixel(at: NSPoint(x: 85, y: size.height - 20), scale: scale)[3] < 255)
    }

    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func frozenScreenPartialRedrawsMatchFullRedraw(scale: CGFloat) throws {
        let frozen = try frozenScreen(scale: scale) { x, y in
            (UInt8(x % 256), UInt8(y % 256), UInt8((x * 7 + y * 13) % 256))
        }
        let session = SelectionSession(mode: .area, lastArea: nil)
        session.cursor = CGPoint(x: 130.25, y: 160.75)
        let overlay = view(session, scale: scale, background: frozen)
        let bitmap = try Bitmap(size: size, scale: scale)
        bitmap.paint(overlay, damage: overlay.refresh())

        var pending: [NSRect] = []
        for point in [CGPoint(x: 90.75, y: 130.25), CGPoint(x: 540.25, y: 440.75), CGPoint(x: 320.5, y: 220.25)] {
            session.mouseMoved(to: point)
            pending += overlay.refresh()
        }
        bitmap.paint(overlay, damage: pending)
        try expectFullRedrawMatches(bitmap, view: overlay, scale: scale)

        for selection in [CGRect(x: 130.25, y: 160.75, width: 330.5, height: 220.25),
                          CGRect(x: 2.25, y: 2.75, width: 300, height: 200),
                          CGRect(x: -30.5, y: 450.25, width: 200, height: 100), nil] {
            session.selection = selection
            bitmap.paint(overlay, damage: overlay.refresh())
            try expectFullRedrawMatches(bitmap, view: overlay, scale: scale)
        }

        session.toggleMode()
        for frame in [CGRect(x: 40, y: 50, width: 300, height: 250),
                      CGRect(x: 600.25, y: 420.75, width: 300, height: 250)] {
            session.hoverWindow = window(frame)
            bitmap.paint(overlay, damage: overlay.refresh())
            try expectFullRedrawMatches(bitmap, view: overlay, scale: scale)
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
    }
}
