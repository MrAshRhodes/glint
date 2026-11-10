import AppKit
import Testing
@testable import GlintCapture

/// A prewarmer wired to private notification centers and counters in place of the real caches.
@MainActor
private final class PrewarmRig {
    let center = NotificationCenter()
    let workspaceCenter = NotificationCenter()
    var permitted = true
    private(set) var invalidations = 0
    private(set) var warms = 0
    private(set) var overlayWarms = 0
    private(set) var delays: [Duration] = []
    private(set) var prewarmer: CapturePrewarmer!

    /// `settle` stands in for the wait after a change; by default it ends at once.
    init(settle: @escaping @MainActor (Duration) async throws -> Void = { _ in }) {
        var services = CapturePrewarmer.Services()
        services.notificationCenter = center
        services.workspaceNotificationCenter = workspaceCenter
        services.isPermitted = { [unowned self] in self.permitted }
        services.invalidate = { [unowned self] in self.invalidations += 1 }
        services.warm = { [unowned self] in self.warms += 1 }
        services.warmOverlay = { [unowned self] in self.overlayWarms += 1 }
        services.sleep = { [unowned self] delay in
            self.delays.append(delay)
            try await settle(delay)
        }
        prewarmer = CapturePrewarmer(services: services)
    }

    func screensChanged() {
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
}

/// Lets the main queue run what was put on it, such as the blocks of observers registered with `queue: .main`.
@MainActor
private func mainQueueTurns(_ count: Int = 3) async {
    for _ in 0..<count {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
private func waitUntil(_ description: String, _ condition: () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    let holds = condition()
    #expect(holds, "Timed out waiting until \(description)")
}

/// A wait that ends when the test opens `gate`, and, like `Task.sleep`, fails when the waiting task was cancelled.
@MainActor
private func settling(on gate: AsyncGate) -> @MainActor (Duration) async throws -> Void {
    { _ in
        await gate.wait()
        try Task.checkCancellation()
    }
}

@MainActor
@Suite("Capture prewarming", .timeLimit(.minutes(1)))
struct CapturePrewarmerTests {
    @Test func startWarmsOnceAfterTheSettleDelay() async {
        let rig = PrewarmRig()
        rig.prewarmer.start()
        await rig.prewarmer.waitUntilWarm()
        rig.prewarmer.stop()

        #expect(rig.delays == [CapturePrewarmer.Services().settleDelay])
        #expect(rig.warms == 1)
        #expect(rig.overlayWarms == 1)
        #expect(rig.invalidations == 0)
    }

    @Test func startingAgainWhileStartedObservesOnlyOnce() async {
        let rig = PrewarmRig()
        rig.prewarmer.start()
        rig.prewarmer.start()
        rig.screensChanged()
        await waitUntil("the screen change is seen") { rig.invalidations >= 1 }
        await mainQueueTurns()
        #expect(rig.invalidations == 1)

        // After stopping it can start again, and still observes once.
        rig.prewarmer.stop()
        rig.prewarmer.start()
        rig.screensChanged()
        await waitUntil("the second screen change is seen") { rig.invalidations >= 2 }
        await mainQueueTurns()
        #expect(rig.invalidations == 2)
        rig.prewarmer.stop()
    }

    @Test func aChangeInvalidatesAtOnceAndWarmsOnlyOnceThingsHaveSettled() async {
        let settled = AsyncGate()
        let rig = PrewarmRig(settle: settling(on: settled))
        rig.prewarmer.start()
        rig.screensChanged()
        await waitUntil("the screen change is seen") { rig.invalidations == 1 }
        #expect(rig.warms == 0, "Nothing is queried while the screens may still be changing")

        await settled.open()
        await rig.prewarmer.waitUntilWarm()
        await mainQueueTurns()
        rig.prewarmer.stop()

        #expect(rig.warms == 1, "The warm-up that start() scheduled was replaced by the one after the change")
        #expect(rig.overlayWarms == 1)
    }

    @Test func aBurstOfChangesInvalidatesEachTimeButWarmsOnce() async {
        let settled = AsyncGate()
        let rig = PrewarmRig(settle: settling(on: settled))
        rig.prewarmer.start()
        rig.screensChanged()
        rig.workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        rig.workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await waitUntil("all three changes are seen") { rig.invalidations == 3 }
        #expect(rig.warms == 0)

        await settled.open()
        await rig.prewarmer.waitUntilWarm()
        await mainQueueTurns()
        rig.prewarmer.stop()

        #expect(rig.warms == 1)
        #expect(rig.overlayWarms == 1)
    }

    @Test func nothingIsQueriedWithoutScreenRecordingPermission() async {
        let rig = PrewarmRig()
        rig.permitted = false
        rig.prewarmer.start()
        await rig.prewarmer.waitUntilWarm()
        #expect(rig.warms == 0)
        #expect(rig.overlayWarms == 1, "The overlay's drawing caches need no permission")

        // Granting it later is picked up by the next change.
        rig.permitted = true
        rig.screensChanged()
        await waitUntil("the screen change is seen") { rig.invalidations == 1 }
        await rig.prewarmer.waitUntilWarm()
        rig.prewarmer.stop()
        #expect(rig.warms == 1)
    }

    @Test func stoppingDetachesTheObserversAndDropsAPendingWarmUp() async {
        let settled = AsyncGate()
        let rig = PrewarmRig(settle: settling(on: settled))
        rig.prewarmer.start()
        rig.prewarmer.stop()

        rig.screensChanged()
        rig.workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await settled.open()
        await mainQueueTurns()

        #expect(rig.invalidations == 0)
        #expect(rig.warms == 0)
        #expect(rig.overlayWarms == 0)
    }

    @Test func sessionChangesComeFromTheWorkspaceCenterAndScreenChangesFromTheOtherOne() async {
        let rig = PrewarmRig()
        rig.prewarmer.start()
        let sessionChanges = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                              NSWorkspace.sessionDidBecomeActiveNotification]
        for (index, name) in sessionChanges.enumerated() {
            rig.workspaceCenter.post(name: name, object: nil)
            await waitUntil("\(name.rawValue) is seen") { rig.invalidations == index + 1 }
        }

        rig.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        rig.workspaceCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await mainQueueTurns()
        rig.prewarmer.stop()
        #expect(rig.invalidations == 3)
    }

    @Test func aChangeReportedDirectlyInvalidatesAtOnce() async {
        let settled = AsyncGate()
        let rig = PrewarmRig(settle: settling(on: settled))
        rig.prewarmer.contentMayHaveChanged()
        #expect(rig.invalidations == 1)
        #expect(rig.warms == 0)

        await settled.open()
        await rig.prewarmer.waitUntilWarm()
        #expect(rig.warms == 1)
    }
}
