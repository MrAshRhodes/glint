import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import GlintCore
@testable import Glint

/// Lets the main thread go back to its run loop, which a synchronous test would never allow: main-queue
/// blocks (and with them window-visibility reports) only run between tests' suspension points.
@MainActor
private func spin(_ seconds: TimeInterval) async {
    try? await Task.sleep(for: .seconds(seconds))
}

/// Waits until `condition` holds or `timeout` passes.
@MainActor
private func wait(timeout: TimeInterval = 3, until condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { await spin(0.01) }
    return condition()
}

/// Timers whose ticks run only when a test fires them.
private final class ManualTimers {
    private var active: [Int: () -> Void] = [:]
    private(set) var intervals: [TimeInterval] = []
    var started: Int { intervals.count }
    var running: Int { active.count }

    func start(_ interval: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void {
        let id = intervals.count
        intervals.append(interval)
        active[id] = fire
        return { [self] in active[id] = nil }
    }

    func tick() {
        for fire in active.values { fire() }
    }
}

private final class Tally {
    var beats = 0
}

@Suite("Polling only while on screen")
struct OnScreenPollerTests {
    @Test func staysIdleUntilTheViewIsOnScreen() {
        let timers = ManualTimers()
        let poller = OnScreenPoller(schedule: timers.start)
        let tally = Tally()
        let subscription = poller.beats.sink { tally.beats += 1 }
        defer { subscription.cancel() }

        poller.setOnScreen(false)
        timers.tick()

        #expect(tally.beats == 0)
        #expect(timers.started == 0)
        #expect(!poller.isPolling)
    }

    @Test func beatsAsSoonAsItIsShownThenOnEveryTick() {
        let timers = ManualTimers()
        let poller = OnScreenPoller(interval: 2.5, schedule: timers.start)
        let tally = Tally()
        let subscription = poller.beats.sink { tally.beats += 1 }
        defer { subscription.cancel() }

        poller.setOnScreen(true)
        #expect(tally.beats == 1)
        #expect(timers.intervals == [2.5])
        #expect(poller.isPolling)

        timers.tick()
        timers.tick()
        #expect(tally.beats == 3)
    }

    @Test func stopsWhenHiddenAndCatchesUpWhenShownAgain() {
        let timers = ManualTimers()
        let poller = OnScreenPoller(schedule: timers.start)
        let tally = Tally()
        let subscription = poller.beats.sink { tally.beats += 1 }
        defer { subscription.cancel() }

        poller.setOnScreen(true)
        poller.setOnScreen(false)
        #expect(!poller.isPolling)
        #expect(timers.running == 0)
        timers.tick()
        #expect(tally.beats == 1)

        poller.setOnScreen(true)
        #expect(tally.beats == 2)
        #expect(timers.running == 1)
        #expect(timers.started == 2)
    }

    @Test func repeatedReportsDoNotStackTimers() {
        let timers = ManualTimers()
        let poller = OnScreenPoller(schedule: timers.start)
        let tally = Tally()
        let subscription = poller.beats.sink { tally.beats += 1 }
        defer { subscription.cancel() }

        poller.setOnScreen(true)
        poller.setOnScreen(true)
        #expect(timers.started == 1)
        #expect(tally.beats == 1)

        poller.setOnScreen(false)
        poller.setOnScreen(false)
        #expect(timers.running == 0)
    }

    @Test func releasingThePollerStopsItsTimer() {
        let timers = ManualTimers()
        var poller: OnScreenPoller? = OnScreenPoller(schedule: timers.start)
        poller?.setOnScreen(true)
        #expect(timers.running == 1)

        poller = nil
        #expect(timers.running == 0)
    }

    @MainActor
    @Test func theDefaultTimerTicksOnTheMainRunLoopUntilStopped() async {
        var ticks = 0
        let stop = OnScreenPoller.mainRunLoopTimer(0.01) { ticks += 1 }
        #expect(await wait { ticks >= 2 })

        stop()
        await spin(0.05)
        let stopped = ticks
        await spin(0.1)
        #expect(ticks == stopped)
    }
}

@Suite("Screen Recording status")
struct ScreenRecordingStatusTests {
    private final class Grant {
        var value: Bool
        var reads = 0
        init(_ value: Bool) { self.value = value }
        func read() -> Bool {
            reads += 1
            return value
        }
    }

    @Test func readsTheGrantOnceWhenCreated() {
        let grant = Grant(false)
        let status = ScreenRecordingStatus(readGrant: grant.read, needsReauthorization: { _ in false })
        #expect(grant.reads == 1)
        #expect(!status.isGranted)
    }

    @Test func recoversOnceAccessIsGrantedInSystemSettings() {
        let grant = Grant(false)
        let status = ScreenRecordingStatus(readGrant: grant.read, needsReauthorization: { !$0 })
        #expect(!status.isGranted)
        #expect(status.isStale)

        status.refresh()
        #expect(!status.isGranted)
        #expect(status.isStale)

        grant.value = true
        status.refresh()
        #expect(status.isGranted)
        #expect(!status.isStale)

        grant.value = false
        status.refresh()
        #expect(!status.isGranted)
        #expect(status.isStale)
    }

    @Test func aRequestMadeFromThePaneIsNotAStaleEntry() {
        let status = ScreenRecordingStatus(readGrant: { false }, needsReauthorization: { !$0 })
        #expect(status.isStale)

        status.requestedHere = true
        status.refresh()
        #expect(!status.isStale)
        #expect(!status.isGranted)
    }

    @Test func anUnchangedPollDoesNotInvalidateTheView() {
        let grant = Grant(false)
        let status = ScreenRecordingStatus(readGrant: grant.read, needsReauthorization: { _ in true })
        var changes = 0
        let subscription = status.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        for _ in 0..<5 { status.refresh() }
        #expect(changes == 0)

        grant.value = true
        status.refresh()
        #expect(changes == 1)
    }
}

@Suite("Window visibility", .serialized)
@MainActor
struct WindowVisibilityTests {
    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func followsAttachmentAndWhetherTheWindowIsOnScreen() async throws {
        let window = makeWindow()
        defer { window.close() }
        let content = try #require(window.contentView)
        var reports: [Bool] = []
        let view = WindowVisibilityView { reports.append($0) }

        content.addSubview(view)
        #expect(await wait { reports == [false] })

        window.orderFront(nil)
        #expect(await wait { reports.last == true })

        view.removeFromSuperview()
        #expect(await wait { reports.last == false })

        content.addSubview(view)
        #expect(await wait { reports.last == true })

        window.orderOut(nil)
        #expect(await wait { reports.last == false })

        window.orderFront(nil)
        #expect(await wait { reports.last == true })
        window.close()
        #expect(await wait { reports.last == false })
        #expect(reports == [false, true, false, true, false, true, false])
    }
}

@Suite("Permissions pane in a window", .serialized)
@MainActor
struct PermissionsPaneWindowTests {
    private final class Grant {
        var value = false
        var reads = 0
    }

    private func makeWindow(_ grant: Grant, interval: TimeInterval) -> (NSWindow, ScreenRecordingStatus) {
        _ = NSApplication.shared
        let status = ScreenRecordingStatus(readGrant: {
            grant.reads += 1
            return grant.value
        }, needsReauthorization: { _ in false })
        let pane = PermissionsPane(grant: status, poller: OnScreenPoller(interval: interval))
        let window = NSWindow(contentViewController: NSHostingController(rootView: pane))
        window.isReleasedWhenClosed = false
        return (window, status)
    }

    @Test func readsThePermissionOnlyWhileItsWindowIsOnScreen() async {
        let grant = Grant()
        let (window, _) = makeWindow(grant, interval: 0.2)
        defer { window.close() }
        let created = grant.reads

        await spin(0.5)
        #expect(grant.reads == created)

        window.orderFront(nil)
        #expect(await wait { grant.reads >= created + 3 })

        window.orderOut(nil)
        await spin(0.1)
        let hidden = grant.reads
        await spin(0.8)
        #expect(grant.reads == hidden)

        window.orderFront(nil)
        #expect(await wait { grant.reads > hidden })
        window.close()
        await spin(0.1)
        let closed = grant.reads
        await spin(0.8)
        #expect(grant.reads == closed)
    }

    @Test func deniedPermissionRecoversTheMomentTheWindowIsShownAgain() async {
        let grant = Grant()
        // Far longer than the test, so only the catch-up on showing the window can refresh it.
        let (window, status) = makeWindow(grant, interval: 600)
        defer { window.close() }

        window.orderFront(nil)
        #expect(await wait { grant.reads >= 2 })
        #expect(!status.isGranted)

        window.orderOut(nil)
        await spin(0.1)
        grant.value = true
        let before = grant.reads

        window.orderFront(nil)
        #expect(await wait { status.isGranted })
        #expect(grant.reads == before + 1)
    }
}

@Suite("Settings and the menu bar menu", .serialized)
@MainActor
struct SettingsOnDemandTests {
    private func makeDelegate(menu: NSMenu = NSMenu()) throws -> (delegate: AppDelegate, prefs: AppPreferences, directory: URL, cleanUp: () -> Void) {
        _ = NSApplication.shared
        let suite = "glint.launch.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glint-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefs = AppPreferences(defaults: defaults)
        prefs.saveDirectory = directory.appendingPathComponent("Manual")
        prefs.historyDirectory = directory.appendingPathComponent("History")
        let delegate = AppDelegate(prefs: prefs, menu: menu)
        delegate.pipeline = CapturePipeline(prefs: prefs, presetStore: PresetStore(url: directory.appendingPathComponent("presets.json")))
        return (delegate, prefs, directory, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func recentTitles(_ menu: NSMenu) throws -> [String] {
        let submenu = try #require(menu.item(withTitle: "Open Recent")?.submenu)
        return submenu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    @Test func settingsAreNotBuiltByLaunchWorkOrTheMenu() throws {
        let menu = NSMenu()
        let fixture = try makeDelegate(menu: menu)
        defer { fixture.cleanUp() }
        #expect(!fixture.delegate.isSettingsBuilt)

        fixture.delegate.menuNeedsUpdate(menu)
        #expect(menu.item(withTitle: "Preferences…") != nil)
        _ = fixture.delegate.hotkeys
        #expect(!fixture.delegate.isSettingsBuilt)
    }

    @Test func settingsAreBuiltOnFirstUseAndReusedAfterwards() throws {
        let key = PreferencesTabViewController.selectedPaneKey
        let stored = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(stored, forKey: key) }
        let fixture = try makeDelegate()
        defer { fixture.cleanUp() }

        let settings = fixture.delegate.settings
        #expect(fixture.delegate.isSettingsBuilt)
        #expect(fixture.delegate.settings === settings)
        #expect(settings.window?.isVisible == false)

        let tabs = try #require(settings.contentViewController as? PreferencesTabViewController)
        #expect(tabs.tabViewItems.map(\.label) == PreferencesPane.allCases.map(\.title))
        tabs.select(.about)
        #expect(tabs.selectedPane == .about)
    }

    @Test func openRecentListsOnlyFilesThatExistEachTimeTheMenuOpens() throws {
        let menu = NSMenu()
        let fixture = try makeDelegate(menu: menu)
        defer { fixture.cleanUp() }
        let files = try ["a.png", "b.png", "c.png"].map { name -> URL in
            let url = fixture.directory.appendingPathComponent(name)
            try Data([1]).write(to: url)
            RecentFiles.add(url, defaults: fixture.prefs.defaults, noteInSystemRecents: false)
            return url
        }

        fixture.delegate.menuNeedsUpdate(menu)
        #expect(try recentTitles(menu) == ["c.png", "b.png", "a.png", "Clear Menu"])

        try FileManager.default.removeItem(at: files[1])
        fixture.delegate.menuNeedsUpdate(menu)
        #expect(try recentTitles(menu) == ["c.png", "a.png", "Clear Menu"])

        try FileManager.default.moveItem(at: files[2], to: fixture.directory.appendingPathComponent("moved.png"))
        fixture.delegate.menuNeedsUpdate(menu)
        #expect(try recentTitles(menu) == ["a.png", "Clear Menu"])

        try FileManager.default.removeItem(at: files[0])
        fixture.delegate.menuNeedsUpdate(menu)
        #expect(try recentTitles(menu) == ["No Recent Items"])
        let placeholder = try #require(menu.item(withTitle: "Open Recent")?.submenu?.items.first)
        #expect(!placeholder.isEnabled)
    }

    @Test func recentFilesAddedWhileTheMenuIsClosedAppearWhenItOpens() throws {
        let menu = NSMenu()
        let fixture = try makeDelegate(menu: menu)
        defer { fixture.cleanUp() }
        let file = fixture.directory.appendingPathComponent("late.png")
        try Data([1]).write(to: file)

        fixture.delegate.menuNeedsUpdate(menu)
        #expect(try recentTitles(menu) == ["No Recent Items"])

        RecentFiles.add(file, defaults: fixture.prefs.defaults, noteInSystemRecents: false)
        #expect(try recentTitles(menu) == ["No Recent Items"])
        fixture.delegate.menuNeedsUpdate(menu)
        #expect(try recentTitles(menu) == ["late.png", "Clear Menu"])
    }
}

@Suite("Launch signposts")
struct AppPerformanceTests {
    @Test func processStartTimeIsAvailableForLaunchMilestones() throws {
        let elapsed = try #require(AppPerformance.millisecondsSinceProcessStart())
        #expect(elapsed > 0)
        #expect(elapsed < 24 * 3600 * 1000)
    }

    @Test func measuringReturnsTheResultAndRethrows() {
        struct Failure: Error {}
        #expect(AppPerformance.measure("Test") { 42 } == 42)
        #expect(throws: Failure.self) { try AppPerformance.measure("Test") { throw Failure() } }
    }
}
