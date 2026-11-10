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
