import AppKit
import CoreGraphics
import Testing
@testable import GlintCapture

@Suite("Visible capture snap targets")
struct SnapTargetTests {
    private let display = CGRect(x: 0, y: 0, width: 500, height: 400)

    @Test func emptyWindowsStillProvideFiniteDisplayBoundaries() {
        let bounds = CGRect(x: -500, y: -400, width: 500, height: 400)
        let edges = SnapTargets.visibleEdges(in: bounds, windows: [])
        #expect(edges.count == 4)
        #expect(edges.allSatisfy { $0.windowIndex == nil && $0.lower < $0.upper })
        #expect(edges.filter { $0.axis == .x }.map(\.coordinate) == [-500, 0])
        #expect(edges.filter { $0.axis == .y }.map(\.coordinate) == [-400, 0])
    }

    @Test func clippingDoesNotInventWindowEdges() {
        let window = SnapWindow(frame: CGRect(x: -100, y: -100, width: 300, height: 300))
        let edges = SnapTargets.visibleEdges(in: display, windows: [window]).filter { $0.windowIndex != nil }
        #expect(edges.count == 2)
        #expect(edges.allSatisfy { $0.coordinate == 200 && $0.lower == 0 && $0.upper == 200 })
        let enclosing = SnapWindow(frame: display.insetBy(dx: -10, dy: -10))
        #expect(SnapTargets.visibleEdges(in: display, windows: [enclosing]).count == 4)
    }

    @Test func fullyOccludedAndOffDisplayWindowsHaveNoTargets() {
        let front = SnapWindow(frame: CGRect(x: 40, y: 40, width: 200, height: 200))
        let behind = SnapWindow(frame: CGRect(x: 60, y: 60, width: 100, height: 100))
        let offscreen = SnapWindow(frame: CGRect(x: 600, y: 0, width: 200, height: 200))
        let edges = SnapTargets.visibleEdges(in: display, windows: [front, behind, offscreen])
        #expect(edges.count == 8)
        #expect(!edges.contains { $0.windowIndex == 1 || $0.windowIndex == 2 })
    }

    @Test func partialOcclusionSplitsOriginalSegments() {
        let front = SnapWindow(frame: CGRect(x: 80, y: 40, width: 40, height: 20))
        let behind = SnapWindow(frame: CGRect(x: 100, y: 0, width: 100, height: 100))
        let edges = SnapTargets.visibleEdges(in: display, windows: [front, behind])
        let left = edges.filter { $0.windowIndex == 1 && $0.axis == .x && $0.coordinate == 100 }
        #expect(left == [
            SnapEdge(axis: .x, coordinate: 100, lower: 0, upper: 40, windowIndex: 1),
            SnapEdge(axis: .x, coordinate: 100, lower: 60, upper: 100, windowIndex: 1),
        ])
        #expect(!edges.contains { $0.windowIndex == 1 && $0.axis == .y && $0.coordinate == 40 })
    }

    @Test func nonTargetWindowsStillOccludeAndAlignedEdgesAreNotDuplicated() {
        let front = SnapWindow(frame: CGRect(x: 100, y: 20, width: 100, height: 60), isTarget: false)
        let back = SnapWindow(frame: CGRect(x: 100, y: 0, width: 100, height: 100))
        let edges = SnapTargets.visibleEdges(in: display, windows: [front, back])
        #expect(!edges.contains { $0.windowIndex == 0 })
        let left = edges.filter { $0.windowIndex == 1 && $0.axis == .x && $0.coordinate == 100 }
        #expect(left.map(\.lower) == [0, 80])
        #expect(left.map(\.upper) == [20, 100])
        let covered = SnapTargets.visibleEdges(in: display, windows: [back, back])
        #expect(!covered.contains { $0.windowIndex == 1 })
    }

    @Test func invalidGeometryIsIgnored() {
        #expect(SnapTargets.visibleEdges(in: .null, windows: []).isEmpty)
        let windows = [CGRect.null, .infinite, .zero].map { SnapWindow(frame: $0) }
        #expect(SnapTargets.visibleEdges(in: display, windows: windows).count == 4)
    }

    @Test func displayScaleNeverChangesPointTargets() {
        let frame = CGRect(x: -1000, y: -200, width: 1000, height: 800)
        let displays = [1.0, 2.0].map {
            DisplayInfo(id: 1, frame: frame, scale: $0, name: "Fixture", isMain: false)
        }
        let windows = [SnapWindow(frame: CGRect(x: -800, y: -100, width: 350, height: 250))]
        #expect(SnapTargets.visibleEdges(in: displays[0].frame, windows: windows)
                == SnapTargets.visibleEdges(in: displays[1].frame, windows: windows))
    }
}

@Suite("Capture snapping interaction")
struct SnappingSelectionTests {
    private let bounds = CGRect(x: 0, y: 0, width: 500, height: 400)

    private func vertical(_ x: CGFloat, lower: CGFloat = 0, upper: CGFloat = 400) -> SnapEdge {
        SnapEdge(axis: .x, coordinate: x, lower: lower, upper: upper, windowIndex: 0)
    }

    private func horizontal(_ y: CGFloat, lower: CGFloat = 0, upper: CGFloat = 500) -> SnapEdge {
        SnapEdge(axis: .y, coordinate: y, lower: lower, upper: upper, windowIndex: 0)
    }

    private func selection(targets: [SnapEdge], enabled: Bool = true,
                           anchor: CGPoint = CGPoint(x: 20, y: 20)) -> SnappingSelection {
        SnappingSelection(anchor: anchor, bounds: bounds, targets: targets, snapToEdges: enabled)
    }

    @Test func acquireAndReleaseThresholdsAreInclusive() {
        var drag = selection(targets: [vertical(100)])
        drag.move(to: CGPoint(x: 93.99, y: 80))
        #expect(drag.rectangle.maxX == 93.99 && drag.guides.isEmpty)
        drag.move(to: CGPoint(x: 94, y: 80))
        #expect(drag.rectangle.maxX == 100 && drag.guides.count == 1)
        drag.move(to: CGPoint(x: 110, y: 80))
        #expect(drag.rectangle.maxX == 100)
        drag.move(to: CGPoint(x: 110.01, y: 80))
        #expect(drag.rectangle.maxX == 110.01 && drag.guides.isEmpty)
        drag.move(to: CGPoint(x: 106.01, y: 80))
        #expect(drag.rectangle.maxX == 106.01)
        drag.move(to: CGPoint(x: 106, y: 80))
        #expect(drag.rectangle.maxX == 100)
    }

    @Test func equalDistanceUsesStableOrderAndLatchPreventsJitter() {
        var drag = selection(targets: [vertical(100), vertical(104)])
        drag.move(to: CGPoint(x: 102, y: 80))
        #expect(drag.rectangle.maxX == 100)
        drag.move(to: CGPoint(x: 105, y: 80))
        #expect(drag.rectangle.maxX == 100)
        drag.move(to: CGPoint(x: 111, y: 80))
        #expect(drag.rectangle.maxX == 111)
        drag.move(to: CGPoint(x: 110, y: 80))
        #expect(drag.rectangle.maxX == 104)
    }

    @Test(arguments: [false, true])
    func commandInvertsBothSavedDefaultsWithoutMovementOrDrift(saved: Bool) {
        var drag = selection(targets: [vertical(100), horizontal(100)], enabled: saved)
        drag.move(to: CGPoint(x: 96, y: 97))
        let free = CGRect(x: 20, y: 20, width: 76, height: 77)
        let snapped = CGRect(x: 20, y: 20, width: 80, height: 80)
        #expect(drag.rectangle == (saved ? snapped : free))
        for _ in 0..<5 {
            drag.setModifiers(shift: false, command: true)
            #expect(drag.rectangle == (saved ? free : snapped))
            #expect(drag.snappingEnabled == !saved)
            drag.setModifiers(shift: false, command: false)
            #expect(drag.rectangle == (saved ? snapped : free))
        }
        #expect(drag.rawCursor == CGPoint(x: 96, y: 97))
        #expect(drag.rawAnchor == CGPoint(x: 20, y: 20))
    }

    @Test func anchorAndMovingCornerCanBothSnapWithoutChangingRawAnchor() {
        var drag = selection(targets: [vertical(100), horizontal(100), vertical(300), horizontal(300)],
                             anchor: CGPoint(x: 96, y: 97))
        drag.move(to: CGPoint(x: 296, y: 297))
        #expect(drag.rectangle == CGRect(x: 100, y: 100, width: 200, height: 200))
        #expect(drag.guides.count == 4)
        drag.setModifiers(shift: false, command: true)
        #expect(drag.rectangle == CGRect(x: 96, y: 97, width: 200, height: 200))
        #expect(drag.guides.isEmpty)
    }

    @Test func finiteSegmentsDoNotActLikeInfiniteLinesAndReleaseWhenNoLongerOverlapping() {
        var drag = selection(targets: [vertical(100, lower: 100, upper: 200)])
        drag.move(to: CGPoint(x: 96, y: 80))
        #expect(drag.rectangle.maxX == 96 && drag.guides.isEmpty)
        drag.move(to: CGPoint(x: 96, y: 120))
        #expect(drag.rectangle.maxX == 100)
        drag.move(to: CGPoint(x: 96, y: 80))
        #expect(drag.rectangle.maxX == 96 && drag.guides.isEmpty)
    }

    @Test func fullyHiddenPortionDoesNotAttractASelection() {
        let windows = [
            SnapWindow(frame: CGRect(x: 80, y: 40, width: 40, height: 40), isTarget: false),
            SnapWindow(frame: CGRect(x: 100, y: 0, width: 100, height: 100)),
        ]
        let targets = SnapTargets.visibleEdges(in: bounds, windows: windows)
        var drag = selection(targets: targets, anchor: CGPoint(x: 20, y: 50))
        drag.move(to: CGPoint(x: 96, y: 70))
        #expect(drag.rectangle.maxX == 96 && drag.guides.isEmpty)
        drag.move(to: CGPoint(x: 96, y: 90))
        #expect(drag.rectangle.maxX == 100)
    }

    @Test func allDragDirectionsSnapLogicalEdges() {
        let targets = [vertical(100), vertical(300), horizontal(100), horizontal(300)]
        for dx: CGFloat in [-1, 1] {
            for dy: CGFloat in [-1, 1] {
                var drag = selection(targets: targets, anchor: CGPoint(x: 200, y: 200))
                drag.move(to: CGPoint(x: 200 + dx * 96, y: 200 + dy * 97))
                #expect(drag.rectangle.width == 100 && drag.rectangle.height == 100)
                #expect(drag.rectangle.minX == (dx < 0 ? 100 : 200))
                #expect(drag.rectangle.minY == (dy < 0 ? 100 : 200))
                #expect(drag.guides.count == 2)
            }
        }
    }

    @Test func squareSnapsOnlyDominantAxisAndDerivesOtherInAllQuadrants() {
        for dx: CGFloat in [-1, 1] {
            for dy: CGFloat in [-1, 1] {
                for horizontalDominates in [false, true] {
                    let x = 200 + dx * 100, y = 200 + dy * 100
                    var drag = selection(targets: [vertical(x), horizontal(y)],
                                         anchor: CGPoint(x: 200, y: 200))
                    drag.setModifiers(shift: true, command: false)
                    drag.move(to: CGPoint(x: 200 + dx * (horizontalDominates ? 96 : 70),
                                          y: 200 + dy * (horizontalDominates ? 70 : 96)))
                    #expect(drag.rectangle.width == 100 && drag.rectangle.height == 100)
                    #expect(drag.guides.count == 1)
                    #expect(drag.guides.first?.axis == (horizontalDominates ? .x : .y))
                    #expect(drag.rectangle.minX == (dx < 0 ? 100 : 200))
                    #expect(drag.rectangle.minY == (dy < 0 ? 100 : 200))
                }
            }
        }
    }

    @Test func squareRemainsSquareAtEveryDisplayBoundary() {
        let small = CGRect(x: -100, y: -100, width: 200, height: 200)
        for dx: CGFloat in [-1, 1] {
            for dy: CGFloat in [-1, 1] {
                let anchor = CGPoint(x: dx * 80, y: dy * 60)
                var drag = SnappingSelection(anchor: anchor, bounds: small,
                                             targets: SnapTargets.visibleEdges(in: small, windows: []),
                                             snapToEdges: true)
                drag.setModifiers(shift: true, command: false)
                drag.move(to: CGPoint(x: anchor.x + dx * 18, y: anchor.y + dy * 35))
                #expect(drag.rectangle.width == 20 && drag.rectangle.height == 20)
                #expect(drag.rectangle.intersection(small) == drag.rectangle)
                // The non-dominant display edge is reached by the square constraint, not a snap.
                #expect(drag.guides.isEmpty)
                drag.setModifiers(shift: false, command: false)
                #expect(drag.rectangle.width == 20 && drag.rectangle.height == 40)
            }
        }
    }

    @Test func squareCannotBeSnappedBeyondItsOtherDisplayBoundary() {
        var drag = selection(targets: [vertical(150)], anchor: CGPoint(x: 50, y: 310))
        drag.setModifiers(shift: true, command: false)
        drag.move(to: CGPoint(x: 146, y: 360))
        #expect(drag.rectangle == CGRect(x: 50, y: 310, width: 90, height: 90))
        #expect(drag.guides.isEmpty)
    }

    @Test func shiftChangesGeometryWhilePointerIsStationary() {
        var drag = selection(targets: [vertical(100)])
        drag.move(to: CGPoint(x: 96, y: 70))
        drag.setModifiers(shift: true, command: false)
        #expect(drag.rectangle.width == 80 && drag.rectangle.height == 80)
        drag.setModifiers(shift: false, command: false)
        #expect(drag.rectangle.width == 80 && drag.rectangle.height == 50)
        #expect(drag.rawCursor == CGPoint(x: 96, y: 70))
    }

    @Test func noTargetsAndMixedScaleDisplaysKeepPointDistancesAndBounds() {
        for scale: CGFloat in [1, 2] {
            let display = DisplayInfo(id: 1, frame: CGRect(x: -500, y: -300, width: 500, height: 400),
                                      scale: scale, name: "Fixture", isMain: false)
            let edge = SnapEdge(axis: .x, coordinate: -100, lower: -300, upper: 100, windowIndex: 0)
            var drag = SnappingSelection(anchor: CGPoint(x: -400, y: -200), bounds: display.frame,
                                         targets: [edge], snapToEdges: true)
            drag.move(to: CGPoint(x: -106, y: -100))
            #expect(drag.rectangle.maxX == -100)
            drag.setModifiers(shift: false, command: true)
            #expect(drag.rectangle.maxX == -106)
            drag.move(to: CGPoint(x: 1000, y: 1000))
            #expect(drag.rectangle.maxX == 0 && drag.rectangle.maxY == 100)
        }
        var free = selection(targets: [])
        free.move(to: CGPoint(x: 96, y: 97))
        #expect(free.rectangle == CGRect(x: 20, y: 20, width: 76, height: 77))
        #expect(free.guides.isEmpty)
    }

    @Test func snapCannotCollapseAValidSelectionBelowMinimumSize() {
        var drag = selection(targets: [vertical(20), horizontal(20)])
        drag.move(to: CGPoint(x: 24, y: 24))
        #expect(drag.rectangle == CGRect(x: 20, y: 20, width: 4, height: 4))
        #expect(drag.isValid)
        #expect(drag.guides.allSatisfy { $0.coordinate == 20 })
        var free = selection(targets: [])
        free.move(to: CGPoint(x: 22.99, y: 23))
        #expect(!free.isValid)
        free.move(to: CGPoint(x: 23, y: 23))
        #expect(free.isValid)
    }

    @Test func nudgesTranslateRawGeometryAndPreserveSquareAndDisplayLimits() {
        var drag = selection(targets: [vertical(100)])
        drag.move(to: CGPoint(x: 96, y: 70))
        drag.setModifiers(shift: true, command: false)
        let square = drag.rectangle
        drag.nudge(dx: 10, dy: 10)
        #expect(drag.rectangle == square.offsetBy(dx: 10, dy: 10))
        #expect(drag.rawAnchor == CGPoint(x: 30, y: 30))
        #expect(drag.rawCursor == CGPoint(x: 106, y: 80))
        #expect(drag.rectangle.width == drag.rectangle.height)
        drag.setModifiers(shift: true, command: true)
        #expect(drag.rectangle == CGRect(x: 30, y: 30, width: 76, height: 76))
        drag.nudge(dx: -1000, dy: -1000)
        #expect(drag.rawAnchor == .zero)
        #expect(drag.rawCursor == CGPoint(x: 76, y: 50))
        #expect(drag.rectangle == CGRect(x: 0, y: 0, width: 76, height: 76))
    }

    @Test(arguments: [CGFloat(1), CGFloat(10)])
    func keyboardTranslationIsNotSwallowedBySnapHysteresis(step: CGFloat) {
        var drag = selection(targets: [vertical(200), horizontal(150)])
        drag.move(to: CGPoint(x: 196, y: 146))
        let snapped = drag.rectangle
        #expect(snapped.maxX == 200 && snapped.maxY == 150)
        drag.nudge(dx: step, dy: step)
        #expect(drag.rectangle == snapped.offsetBy(dx: step, dy: step))
        #expect(drag.rawAnchor == CGPoint(x: 20 + step, y: 20 + step))
        #expect(drag.rawCursor == CGPoint(x: 196 + step, y: 146 + step))
        #expect(drag.guides.isEmpty)
        drag.nudge(dx: step, dy: step)
        #expect(drag.rectangle == snapped.offsetBy(dx: 2 * step, dy: 2 * step))
        drag.setModifiers(shift: false, command: false)
        #expect(drag.rectangle == snapped.offsetBy(dx: 2 * step, dy: 2 * step))
        for _ in 0..<3 {
            drag.setModifiers(shift: false, command: true)
            #expect(drag.rectangle == CGRect(x: 20 + 2 * step, y: 20 + 2 * step, width: 176, height: 126))
            drag.setModifiers(shift: false, command: false)
        }
        #expect(drag.rawCursor == CGPoint(x: 196 + 2 * step, y: 146 + 2 * step))
    }

    @Test func keyboardTranslationClampsThePreviewWithoutChangingItsSize() {
        var drag = selection(targets: [vertical(200), horizontal(150)])
        drag.move(to: CGPoint(x: 196, y: 146))
        let size = drag.rectangle.size
        drag.nudge(dx: 1000, dy: 1000)
        #expect(drag.rectangle.maxX == bounds.maxX && drag.rectangle.maxY == bounds.maxY)
        #expect(drag.rectangle.size == size)
        let bounded = drag.rectangle
        drag.nudge(dx: 10, dy: 10)
        #expect(drag.rectangle == bounded)
        drag.nudge(dx: -1000, dy: -1000)
        #expect(drag.rectangle.origin == .zero && drag.rectangle.size == size)
    }

    @MainActor @Test func captureOptionIsDefaultOffAndSessionKeepsSnapshot() {
        var options = CaptureOptions()
        #expect(!options.snapToEdges)
        options.snapToEdges = true
        let session = SelectionSession(mode: .area, lastArea: nil, snapToEdges: options.snapToEdges)
        options.snapToEdges = false
        #expect(session.snapToEdges && session.snappingEnabled)
        #expect(session.snappingHint.contains("Hold ⌘: off"))
        session.modifiersChanged(shift: false, command: true)
        #expect(!session.snappingEnabled)
        #expect(session.snappingHint.contains("Release ⌘: on"))
        session.toggleMode()
        #expect(session.mode == .window && session.snapGuides.isEmpty)
        session.toggleMode()
        session.modifiersChanged(shift: false, command: false)
        #expect(session.mode == .area && session.snappingEnabled)
    }

    @MainActor @Test func overlayPanelStaysPutAndMouseMovesResyncModifiers() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { return }
        let session = SelectionSession(mode: .area, lastArea: nil, snapToEdges: true)
        let panel = OverlayPanel(screen: screen, session: session, level: .normal,
                                 primaryHeight: screen.frame.height)
        defer { panel.close() }
        #expect(!panel.isMovable)

        let view = try #require(panel.contentView as? OverlayView)
        func moved(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 20, y: 20),
                                            modifierFlags: flags, timestamp: 0, windowNumber: panel.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        }
        view.mouseMoved(with: try moved([.command]))
        #expect(!session.snappingEnabled)
        view.mouseMoved(with: try moved([]))
        #expect(session.snappingEnabled)
    }

    @Test func guidedEdgesAlwaysMatchFinalBoundedGeometryAcrossModifierTransitions() {
        let display = CGRect(x: -100, y: -100, width: 200, height: 200)
        let targets = SnapTargets.visibleEdges(in: display, windows: [
            SnapWindow(frame: CGRect(x: -40, y: -70, width: 80, height: 140)),
            SnapWindow(frame: CGRect(x: -90, y: -90, width: 180, height: 180)),
        ])
        let positions: [CGFloat] = [-150, -94, -44, -6, 6, 44, 94, 150]
        for anchor in [CGPoint(x: -86, y: -86), CGPoint(x: 86, y: 86)] {
            for x in positions {
                for y in positions {
                    var drag = SnappingSelection(anchor: anchor, bounds: display, targets: targets, snapToEdges: true)
                    drag.move(to: CGPoint(x: x, y: y))
                    for shift in [false, true, false] {
                        for command in [false, true, false] {
                            drag.setModifiers(shift: shift, command: command)
                            let rect = drag.rectangle
                            #expect(rect.minX >= display.minX && rect.maxX <= display.maxX)
                            #expect(rect.minY >= display.minY && rect.maxY <= display.maxY)
                            if shift { #expect(rect.width == rect.height) }
                            if command { #expect(drag.guides.isEmpty) }
                            for edge in drag.guides {
                                if edge.axis == .x {
                                    #expect(edge.coordinate == rect.minX || edge.coordinate == rect.maxX)
                                    #expect(max(rect.minY, edge.lower) < min(rect.maxY, edge.upper))
                                } else {
                                    #expect(edge.coordinate == rect.minY || edge.coordinate == rect.maxY)
                                    #expect(max(rect.minX, edge.lower) < min(rect.maxX, edge.upper))
                                }
                            }
                        }
                    }
                    #expect(drag.rawAnchor == anchor)
                    #expect(drag.rawCursor == CaptureGeometry.clamp(CGPoint(x: x, y: y), to: display))
                }
            }
        }
    }

    @Test func syntheticCachedDragMeasurement() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windows = (0..<80).map {
            SnapWindow(frame: CGRect(x: 40 + ($0 % 16) * 110, y: 40 + ($0 / 16) * 190,
                                     width: 90, height: 150))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let targets = SnapTargets.visibleEdges(in: display, windows: windows)
        let prepared = clock.now
        var targetCount = 0
        for _ in 0..<20 {
            targetCount += SnapTargets.visibleEdges(in: display, windows: windows).count
        }
        let warmPrepared = clock.now
        #expect(targets.count == 324)
        #expect(targetCount == 20 * targets.count)
        print("Synthetic geometry only (not UI latency): 80 windows, \(targets.count) edges; first preparation \(start.duration(to: prepared)); warm preparation mean \(prepared.duration(to: warmPrepared) / 20)")
        for enabled in [false, true] {
            var drag = SnappingSelection(anchor: CGPoint(x: 20, y: 20), bounds: display,
                                         targets: targets, snapToEdges: enabled)
            let firstStart = clock.now
            drag.move(to: CGPoint(x: 126, y: 186))
            let firstEnd = clock.now
            var totalWidth: CGFloat = 0
            for i in 0..<2_000 {
                drag.move(to: CGPoint(x: 30 + i % 1_880, y: 30 + (i * 17) % 1_030))
                totalWidth += drag.rectangle.width
            }
            let end = clock.now
            #expect(totalWidth > 0)
            print("Synthetic snap \(enabled ? "on" : "off"): first solve \(firstStart.duration(to: firstEnd)); warm 2000 solves \(firstEnd.duration(to: end)); mean \(firstEnd.duration(to: end) / 2_000)")
        }
    }
}
