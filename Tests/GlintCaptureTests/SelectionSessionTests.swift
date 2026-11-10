import AppKit
import Testing
@testable import GlintCapture

@MainActor
@Suite("Selection snapshot lifecycle")
struct SelectionSessionTests {
    private let display = DisplayInfo(id: 7, frame: CGRect(x: -100, y: -20, width: 100, height: 80),
                                      scale: 2, name: "Test", isMain: true)
    private let area = CGRect(x: -80, y: 0, width: 20, height: 20)

    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 200, height: 160, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    private func services(present: @escaping (SelectionSession) -> Void) -> SelectionSession.Services {
        var services = SelectionSession.Services()
        services.snapshot = { _, _ in SelectionWindowSnapshot() }
        services.displays = { [display] }
        services.present = present
        return services
    }

    @Test func freezesWithoutDetectedTransientWindowsBeforePresentationAndTransfersBuffers() async throws {
        let image = try image()
        var events: [String] = []
        var services = services {
            events.append("present")
            #expect($0.frozen.count == 1)
            $0.selection = area
            $0.confirm()
        }
        services.snapshot = { _, _ in
            events.append("metadata")
            return SelectionWindowSnapshot()
        }
        services.displays = { events.append("displays"); return [display] }
        let session = SelectionSession(mode: .area, lastArea: nil, freeze: { displays in
            events.append("freeze")
            #expect(displays.map(\.id) == [display.id])
            return [FrozenDisplay(display: display, image: image)]
        }, services: services)

        let outcome = try await session.run()

        #expect(events == ["metadata", "displays", "freeze", "present"])
        guard case .area(let rect, let id) = outcome else {
            Issue.record("Expected an area selection")
            return
        }
        #expect(rect == area && id == display.id)
        #expect(session.frozen.count == 1)
        #expect(session.takeFrozen().count == 1)
        #expect(session.frozen.isEmpty)
    }

    @Test func ownWindowPolicyReachesMetadataAndDefaultSelectionRemainsLive() async throws {
        var services = services {
            #expect($0.frozen.isEmpty)
            $0.selection = area
            $0.confirm()
        }
        services.snapshot = { excludesOwn, excluded in
            #expect(!excludesOwn)
            #expect(excluded == [11, 12])
            return SelectionWindowSnapshot()
        }
        let session = SelectionSession(mode: .area, lastArea: nil,
                                       excludeOwnWindows: false, excludedWindowIDs: [11, 12],
                                       services: services)
        _ = try await session.run()
        #expect(session.takeFrozen().isEmpty)
    }

    @Test func overlayCloseTimeIsRecordedWhenTheSelectionEnds() async throws {
        var presentedAt: ContinuousClock.Instant?
        let session = SelectionSession(mode: .area, lastArea: nil, services: services {
            #expect($0.closedAt == nil, "The overlay is still up while selecting")
            presentedAt = .now
            $0.selection = area
            $0.confirm()
        })
        #expect(session.closedAt == nil)

        _ = try await session.run()

        let closedAt = try #require(session.closedAt)
        #expect(try #require(presentedAt) <= closedAt)
        #expect(closedAt <= .now)
    }

    @Test func failedOrIncompleteFreezeNeverPresentsAnOverlay() async throws {
        for incomplete in [false, true] {
            var presentations = 0
            let session = SelectionSession(mode: .area, lastArea: nil, freeze: { _ in
                if incomplete { return [] }
                throw CaptureError.failed("Snapshot failed")
            }, services: services { _ in presentations += 1 })

            await #expect(throws: CaptureError.self) { try await session.run() }
            #expect(presentations == 0)
            #expect(session.frozen.isEmpty)
        }
    }

    @Test func cancellationDuringFreezeCannotPresentALateOverlay() async throws {
        let started = Gate(), release = Gate()
        let image = try image()
        var presentations = 0
        let session = SelectionSession(mode: .area, lastArea: nil, freeze: { _ in
            started.open()
            await release.wait()
            return [FrozenDisplay(display: display, image: image)]
        }, services: services { _ in presentations += 1 })
        let task = Task { try await session.run() }
        await started.wait()
        task.cancel()
        release.open()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(presentations == 0)
        #expect(session.frozen.isEmpty)
    }

    @Test func escapeDuringFreezeCannotPresentALateOverlay() async throws {
        let started = Gate(), release = Gate()
        let image = try image()
        var presentations = 0
        let session = SelectionSession(mode: .area, lastArea: nil, freeze: { _ in
            started.open()
            await release.wait()
            return [FrozenDisplay(display: display, image: image)]
        }, services: services { _ in presentations += 1 })
        let task = Task { try await session.run() }
        await started.wait()
        session.cancel()
        release.open()

        await #expect(throws: CaptureError.self) { try await task.value }
        #expect(presentations == 0)
        #expect(session.frozen.isEmpty)
    }

    @Test func taskCancellationDuringSelectionResolvesOnceAndReleasesBuffers() async throws {
        let presented = Gate()
        let image = try image()
        let session = SelectionSession(mode: .area, lastArea: nil, freeze: { _ in
            [FrozenDisplay(display: display, image: image)]
        }, services: services { _ in presented.open() })
        let task = Task { try await session.run() }
        await presented.wait()
        #expect(session.frozen.count == 1)
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        session.cancel()
        session.selection = area
        session.confirm()
        #expect(session.frozen.isEmpty)
    }

    @Test func escapeDuringSelectionResolvesOnceAndReleasesBuffers() async throws {
        let image = try image()
        let session = SelectionSession(mode: .area, lastArea: nil, freeze: { _ in
            [FrozenDisplay(display: display, image: image)]
        }, services: services {
            $0.cancel()
            $0.cancel()
        })
        await #expect(throws: CaptureError.self) { try await session.run() }
        #expect(session.frozen.isEmpty)
    }

    @Test func presentationHookRunsOnceAfterTheFirstDrawWhileSelecting() async throws {
        var hooks = 0
        var selectingWhenHooked = false
        var session: SelectionSession!
        session = SelectionSession(mode: .area, lastArea: nil, services: services { session in
            let view = OverlayView(frame: NSRect(origin: .zero, size: display.frame.size), session: session,
                                   screenFrameCG: display.frame, scale: 1)
            self.draw(view)
            self.draw(view)
            #expect(hooks == 0, "The hook waits until the drawn frame can be committed")
            // Queued after the hook, so it runs while the selection is still active.
            DispatchQueue.main.async {
                session.selection = area
                session.confirm()
            }
        }, onPresented: {
            hooks += 1
            selectingWhenHooked = session.selection == nil
        })

        _ = try await session.run()
        #expect(hooks == 1)
        #expect(selectingWhenHooked)
    }

    @Test func presentationHookNeverRunsAfterTheSelectionFinished() async throws {
        var hooks = 0
        let session = SelectionSession(mode: .area, lastArea: nil, services: services { session in
            self.draw(OverlayView(frame: NSRect(origin: .zero, size: display.frame.size), session: session,
                                  screenFrameCG: display.frame, scale: 1))
            session.cancel()
        }, onPresented: { hooks += 1 })

        await #expect(throws: CaptureError.self) { try await session.run() }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(hooks == 0)
    }

    @Test func presentationHookNeedsAPresentedOverlay() async throws {
        var hooks = 0
        let session = SelectionSession(mode: .area, lastArea: nil, freeze: { _ in
            throw CaptureError.failed("Snapshot failed")
        }, services: services { _ in Issue.record("A failed freeze must not present") }, onPresented: { hooks += 1 })

        await #expect(throws: CaptureError.self) { try await session.run() }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(hooks == 0)
    }

    // MARK: Space held during a drag

    @Test func holdingSpaceDuringADragMovesTheSelectionAndTheOutcomeKeepsIt() async throws {
        var moved: CGRect?
        var modeWhileMoving: SelectionSession.Mode?
        let session = SelectionSession(mode: .area, lastArea: nil, services: services { session in
            session.mouseDown(at: CGPoint(x: -90, y: -10))
            session.mouseDragged(to: CGPoint(x: -70, y: 10))
            session.spaceDown()
            session.mouseDragged(to: CGPoint(x: -60, y: 20))
            moved = session.selection
            modeWhileMoving = session.mode
            session.spaceUp()
            session.mouseDragged(to: CGPoint(x: -50, y: 30))
            session.mouseUp(at: CGPoint(x: -50, y: 30))
        })

        let outcome = try await session.run()

        #expect(moved == CGRect(x: -80, y: 0, width: 20, height: 20))
        #expect(modeWhileMoving == .area)
        guard case .area(let rect, let id) = outcome else {
            Issue.record("Expected an area selection")
            return
        }
        #expect(rect == CGRect(x: -80, y: 0, width: 30, height: 30) && id == display.id)
    }

    @Test func releasingTheMouseWhileSpaceIsHeldEndsTheSelectionWithTheMovedRectangle() async throws {
        let session = SelectionSession(mode: .area, lastArea: nil, services: services { session in
            session.mouseDown(at: CGPoint(x: -90, y: -10))
            session.mouseDragged(to: CGPoint(x: -70, y: 10))
            session.spaceDown()
            session.mouseDragged(to: CGPoint(x: -65, y: 15))
            session.mouseUp(at: CGPoint(x: -65, y: 15))
            session.spaceUp()
        })

        let outcome = try await session.run()

        guard case .area(let rect, let id) = outcome else {
            Issue.record("Expected an area selection")
            return
        }
        #expect(rect == CGRect(x: -85, y: -5, width: 20, height: 20) && id == display.id)
    }

    @Test func movingTheSelectionCannotLeaveTheDisplayWhereTheDragStarted() async throws {
        let session = SelectionSession(mode: .area, lastArea: nil, services: services { session in
            session.mouseDown(at: CGPoint(x: -90, y: -10))
            session.mouseDragged(to: CGPoint(x: -70, y: 10))
            session.spaceDown()
            session.mouseDragged(to: CGPoint(x: 400, y: 500))
            session.mouseUp(at: CGPoint(x: 400, y: 500))
        })

        let outcome = try await session.run()

        guard case .area(let rect, let id) = outcome else {
            Issue.record("Expected an area selection")
            return
        }
        #expect(rect == CGRect(x: -20, y: 40, width: 20, height: 20) && id == display.id)
        #expect(display.frame.contains(rect))
    }

    @Test func nudgingDuringADragThenMovingTheMouseDoesNotUndoTheNudge() async throws {
        let session = SelectionSession(mode: .area, lastArea: nil, services: services { session in
            session.mouseDown(at: CGPoint(x: -90, y: -10))
            session.mouseDragged(to: CGPoint(x: -70, y: 10))
            session.nudge(dx: 5, dy: 0)
            session.mouseDragged(to: CGPoint(x: -70, y: 10))
            #expect(session.selection == CGRect(x: -85, y: -10, width: 20, height: 20))
            session.mouseDragged(to: CGPoint(x: -60, y: 10))
            session.mouseUp(at: CGPoint(x: -60, y: 10))
        })

        let outcome = try await session.run()

        guard case .area(let rect, _) = outcome else {
            Issue.record("Expected an area selection")
            return
        }
        #expect(rect == CGRect(x: -85, y: -10, width: 30, height: 20))
    }

    @Test func spaceBeforeADragStillSwitchesModes() {
        let session = SelectionSession(mode: .area, lastArea: nil)
        session.spaceDown()
        #expect(session.mode == .window)
        session.spaceUp()
        #expect(session.mode == .window)
        session.spaceDown()
        #expect(session.mode == .area)
    }

    @Test func theHintNamesWhatSpaceDoesBeforeAndDuringADrag() {
        let session = SelectionSession(mode: .area, lastArea: nil)
        #expect(session.hint.contains("Space: window"))
        #expect(session.hint.contains("Hold Space while dragging: move"))
        session.spaceDown()
        #expect(session.hint == "Click a window  ·  Space: area  ·  Esc: cancel")
    }

    // MARK: Nudging the pointer

    @MainActor
    private final class FakePointer {
        var location: CGPoint
        private(set) var warps: [CGPoint] = []

        init(_ location: CGPoint) { self.location = location }

        func warp(to point: CGPoint) {
            warps.append(point)
            location = point
        }
    }

    private func session(pointer: FakePointer, displays: [DisplayInfo]) -> SelectionSession {
        var services = SelectionSession.Services()
        services.pointerLocation = { pointer.location }
        services.movePointer = { pointer.warp(to: $0) }
        let session = SelectionSession(mode: .area, lastArea: nil, services: services)
        session.useDisplays(displays)
        return session
    }

    @Test func nudgingWithoutADragMovesTheRealPointerByTheStep() {
        let pointer = FakePointer(CGPoint(x: -50, y: 20))
        let session = session(pointer: pointer, displays: [display])
        session.nudge(dx: 10, dy: -1)
        #expect(pointer.warps == [CGPoint(x: -40, y: 19)])
        #expect(session.cursor == CGPoint(x: -40, y: 19))
    }

    @Test func nudgingStartsFromTheRealPointerNotFromTheLastMouseEvent() {
        let pointer = FakePointer(CGPoint(x: -50, y: 20))
        let session = session(pointer: pointer, displays: [display])
        // The pointer moved without a mouse event reaching the overlay.
        session.cursor = CGPoint(x: -90, y: 0)
        session.nudge(dx: 1, dy: 0)
        #expect(pointer.warps == [CGPoint(x: -49, y: 20)])
        #expect(session.cursor == CGPoint(x: -49, y: 20))
    }

    @Test func nudgingStopsAtTheEdgeOfTheDisplayAndDoesNotWarpWhenNothingWouldMove() {
        let pointer = FakePointer(CGPoint(x: -5, y: 20))
        let session = session(pointer: pointer, displays: [display])
        session.nudge(dx: 10, dy: 0)
        #expect(pointer.warps == [CGPoint(x: -1, y: 20)])
        #expect(session.cursor == CGPoint(x: -1, y: 20))
        session.nudge(dx: 10, dy: 0)
        #expect(pointer.warps.count == 1)
        #expect(session.cursor == CGPoint(x: -1, y: 20))
        session.nudge(dx: 0, dy: -1_000)
        #expect(pointer.warps.last == CGPoint(x: -1, y: -20))
        #expect(session.cursor == CGPoint(x: -1, y: -20))
    }

    @Test func nudgingCrossesIntoAnAdjacentDisplayButNotIntoTheGapBeforeAnother() {
        let right = DisplayInfo(id: 8, frame: CGRect(x: 0, y: -20, width: 100, height: 80), scale: 1,
                                name: "Right", isMain: false)
        let apart = DisplayInfo(id: 9, frame: CGRect(x: 110, y: -20, width: 100, height: 80), scale: 1,
                                name: "Apart", isMain: false)
        let pointer = FakePointer(CGPoint(x: -5, y: 20))
        let session = session(pointer: pointer, displays: [display, right, apart])
        session.nudge(dx: 10, dy: 0)
        #expect(pointer.location == CGPoint(x: 5, y: 20))
        pointer.location = CGPoint(x: 95, y: 20)
        session.nudge(dx: 10, dy: 0)
        #expect(pointer.location == CGPoint(x: 99, y: 20))
        #expect(session.cursor == CGPoint(x: 99, y: 20))
    }

    // MARK: Display and Space changes

    @MainActor
    private final class ChangeObservation {
        private(set) var registrations = 0
        private(set) var removals = 0
        private var handlers: [@MainActor () -> Void] = []

        func observe(_ handler: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            registrations += 1
            handlers.append(handler)
            return { self.removals += 1 }
        }

        func fire() { handlers.forEach { $0() } }
    }

    enum SystemChange: CaseIterable {
        case activeSpace, displayConfiguration

        @MainActor func post() {
            switch self {
            case .activeSpace:
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification,
                                                           object: NSWorkspace.shared)
            case .displayConfiguration:
                NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification,
                                                object: NSApplication.shared)
            }
        }
    }

    private static func isCancelled(_ error: any Error) -> Bool {
        if case CaptureError.cancelled = error { return true }
        return false
    }

    @Test func aDisplayOrSpaceChangeCancelsTheSelectionOnceAndReleasesEverything() async throws {
        let observation = ChangeObservation()
        let image = try image()
        var services = services { session in
            #expect(observation.registrations == 1)
            observation.fire()
            observation.fire()
            // Input that was already on its way must not complete a selection that has ended.
            session.selection = area
            session.confirm()
        }
        services.observeChanges = { observation.observe($0) }
        let session = SelectionSession(mode: .area, lastArea: nil, freeze: { _ in
            [FrozenDisplay(display: display, image: image)]
        }, services: services)

        await #expect { try await session.run() } throws: { Self.isCancelled($0) }

        #expect(observation.removals == 1)
        #expect(session.frozen.isEmpty)
        observation.fire()
        #expect(observation.removals == 1)
    }

    @Test func aChangeDuringTheFreezeCannotPresentALateOverlay() async throws {
        let observation = ChangeObservation()
        let started = Gate(), release = Gate()
        let image = try image()
        var presentations = 0
        var services = services { _ in presentations += 1 }
        services.observeChanges = { observation.observe($0) }
        let session = SelectionSession(mode: .area, lastArea: nil, freeze: { _ in
            started.open()
            await release.wait()
            return [FrozenDisplay(display: display, image: image)]
        }, services: services)
        let task = Task { try await session.run() }
        await started.wait()
        #expect(observation.registrations == 1)
        observation.fire()
        release.open()

        await #expect { try await task.value } throws: { Self.isCancelled($0) }
        #expect(presentations == 0)
        #expect(session.frozen.isEmpty)
        #expect(observation.removals == 1)
    }

    enum Ending: CaseIterable { case confirm, escape, change, taskCancellation, failedFreeze }

    @Test(arguments: Ending.allCases)
    func theChangeObserverIsRemovedExactlyOnceHoweverTheSelectionEnds(ending: Ending) async throws {
        let observation = ChangeObservation()
        let presented = Gate()
        var services = services { session in
            switch ending {
            case .confirm:
                session.selection = area
                session.confirm()
            case .escape: session.cancel()
            case .change: observation.fire()
            case .taskCancellation, .failedFreeze: presented.open()
            }
        }
        services.observeChanges = { observation.observe($0) }
        let freeze: (([DisplayInfo]) async throws -> [FrozenDisplay])? = ending == .failedFreeze
            ? { _ in throw CaptureError.failed("Snapshot failed") } : nil
        let session = SelectionSession(mode: .area, lastArea: nil, freeze: freeze, services: services)
        let task = Task { try await session.run() }
        if ending == .taskCancellation {
            await presented.wait()
            task.cancel()
        }

        _ = try? await task.value

        #expect(observation.registrations == 1)
        #expect(observation.removals == 1)
        observation.fire()
        session.cancel()
        session.selection = area
        session.confirm()
        #expect(observation.removals == 1)
    }

    @Test(arguments: SystemChange.allCases)
    func theRealSpaceAndDisplayNotificationsCancelTheSelectionAndStopBeingObserved(change: SystemChange) async throws {
        var deliveries = 0
        var removals = 0
        var services = services { _ in change.post() }
        let observe = services.observeChanges
        services.observeChanges = { handler in
            let remove = observe { deliveries += 1; handler() }
            return { removals += 1; remove() }
        }
        let session = SelectionSession(mode: .area, lastArea: nil, services: services)

        await #expect { try await session.run() } throws: { Self.isCancelled($0) }

        #expect(deliveries == 1 && removals == 1)
        change.post()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(deliveries == 1)
    }

    @Test func endingTheSelectionRestoresTheArrowCursor() async throws {
        NSCursor.crosshair.set()
        let session = SelectionSession(mode: .area, lastArea: nil, services: services { $0.cancel() })
        await #expect(throws: CaptureError.self) { try await session.run() }
        #expect(NSCursor.current == NSCursor.arrow)
    }

    private func draw(_ view: OverlayView) {
        guard let context = CGContext(data: nil, width: Int(view.bounds.width), height: Int(view.bounds.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            Issue.record("Could not create a bitmap context")
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
    }

    @MainActor
    private final class Gate {
        private var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }
}
