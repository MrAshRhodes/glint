import AppKit
import Carbon.HIToolbox
import Combine
import GlintCore
import SwiftUI
import Testing
@testable import Glint
@testable import GlintCapture

// macOS is replaced by a fake that behaves like RegisterEventHotKey: it refuses a combination that is already
// claimed, plus any the test marks as taken. That shows what the app does when a shortcut can't be registered
// without registering anything system-wide.

@MainActor
private final class FakeHotkeyBackend: HotkeyBackend {
    struct Claim: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    enum Call: Equatable {
        case claim(Claim)
        case release(Claim)
    }

    /// Combinations macOS refuses, with the status it answers with.
    var refused: [Claim: OSStatus] = [:]
    private(set) var active: [UInt32: Claim] = [:]
    private(set) var calls: [Call] = []

    func register(keyCode: UInt32, modifiers: UInt32, numericID: UInt32) -> OSStatus {
        let claim = Claim(keyCode: keyCode, modifiers: modifiers)
        calls.append(.claim(claim))
        if let status = refused[claim] { return status }
        guard !active.values.contains(claim) else { return OSStatus(eventHotKeyExistsErr) }
        active[numericID] = claim
        return noErr
    }

    func unregister(numericID: UInt32) {
        guard let claim = active.removeValue(forKey: numericID) else { return }
        calls.append(.release(claim))
    }

    func numericID(of combo: KeyCombo) -> UInt32? {
        active.first { $0.value == Claim(combo) }?.key
    }
}

private extension FakeHotkeyBackend.Claim {
    init(_ combo: KeyCombo) { self.init(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) }
}

private func claim(_ combo: KeyCombo) -> FakeHotkeyBackend.Call { .claim(.init(combo)) }
private func release(_ combo: KeyCombo) -> FakeHotkeyBackend.Call { .release(.init(combo)) }

private let taken = OSStatus(eventHotKeyExistsErr)
private let area = HotkeyAction.captureArea.defaultCombo // ⌃⌥⌘4
private let window = HotkeyAction.captureWindow.defaultCombo // ⌃⌥⌘6
/// Combinations no action uses by default: ⌃⌥⌘0 and ⌃⌥⌘1.
private let spare = KeyCombo(keyCode: 29, modifiers: [.control, .option, .command])
private let otherSpare = KeyCombo(keyCode: 18, modifiers: [.control, .option, .command])

@MainActor
private final class Log {
    var performed: [HotkeyAction] = []
    var reports: [[HotkeyAction: HotkeyProblem]] = []
}

@MainActor
private final class Fixture {
    let suite = "glint.shortcuts.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let prefs: AppPreferences
    let backend = FakeHotkeyBackend()
    let controller: HotkeyController
    let log = Log()
    private let center: HotkeyCenter

    init() {
        defaults = UserDefaults(suiteName: suite)!
        prefs = AppPreferences(defaults: defaults)
        center = HotkeyCenter(backend: backend)
        let log = self.log
        controller = HotkeyController(prefs: prefs, center: center) { log.performed.append($0) }
        controller.report = { problems in
            log.reports.append(Dictionary(uniqueKeysWithValues: problems.map { ($0.action, $0.problem) }))
        }
    }

    /// Plays macOS reporting that `combo` was pressed; fails if macOS isn't holding it for Glint.
    func press(_ combo: KeyCombo) throws {
        center.fire(numeric: try #require(backend.numericID(of: combo)))
    }

    func isActive(_ combo: KeyCombo) -> Bool { backend.numericID(of: combo) != nil }

    /// A new instance over the same suite, as after a restart.
    var persisted: AppPreferences { AppPreferences(defaults: UserDefaults(suiteName: suite)!) }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

@Suite("Global shortcut controller")
@MainActor
struct HotkeyControllerTests {
    // MARK: Launch

    @Test func launchRegistersEveryShortcutOnceAndPressesRunTheirActions() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.controller.sync()

        #expect(f.backend.calls == HotkeyAction.allCases.map { claim($0.defaultCombo) })
        #expect(f.controller.problems.isEmpty)
        #expect(f.log.reports.isEmpty)
        for action in HotkeyAction.allCases { try f.press(action.defaultCombo) }
        #expect(f.log.performed == HotkeyAction.allCases)
    }

    @Test func syncingAgainOrAfterAnUnrelatedPreferenceChangeLeavesTheSystemAlone() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.controller.sync()
        let calls = f.backend.calls

        f.prefs.snapToEdges = true
        f.controller.sync()
        f.prefs.soundsEnabled = false
        f.controller.sync()
        f.controller.sync()

        #expect(f.backend.calls == calls)
        #expect(f.controller.problems.isEmpty)
    }

    @Test func aShortcutMacOSRefusesAtLaunchIsReportedOnceAndNotAskedForAgain() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.backend.refused[.init(window)] = taken
        f.controller.sync()

        let problem = HotkeyProblem(combo: window, reason: .taken)
        #expect(f.controller.problems == [.captureWindow: problem])
        #expect(f.log.reports == [[.captureWindow: problem]])
        #expect(!f.isActive(window))
        // The rest still work.
        try f.press(area)
        #expect(f.log.performed == [.captureArea])

        let calls = f.backend.calls
        f.prefs.snapToEdges = true
        f.controller.sync()
        f.controller.sync()
        #expect(f.backend.calls == calls)
        #expect(f.log.reports.count == 1)
    }

    @Test func aRefusalOtherThanTakenKeepsItsStatus() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.backend.refused[.init(window)] = OSStatus(paramErr)
        f.controller.sync()

        let problem = f.controller.problems[.captureWindow]
        #expect(problem == HotkeyProblem(combo: window, reason: .failed(OSStatus(paramErr))))
        #expect(problem?.message == "macOS couldn't register ⌃⌥⌘6 (error -50).")
    }

    @Test func aRefusedShortcutIsAskedForAgainOnceAnotherOneMoves() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.backend.refused[.init(window)] = taken
        f.controller.sync()
        let problem = HotkeyProblem(combo: window, reason: .taken)

        // Still refused: the problem stays and nobody is told twice.
        #expect(f.controller.change(.captureArea, to: spare) == nil)
        f.controller.sync()
        #expect(f.backend.calls.last == claim(window))
        #expect(f.controller.problems == [.captureWindow: problem])
        #expect(f.log.reports.count == 1)

        // The other app lets go, and the next change elsewhere gives it another go.
        f.backend.refused = [:]
        #expect(f.controller.change(.captureArea, to: otherSpare) == nil)
        f.controller.sync()
        #expect(f.controller.problems.isEmpty)
        try f.press(window)
        #expect(f.log.performed == [.captureWindow])
        #expect(f.log.reports.count == 1)
    }

    @Test func savedShortcutsThatCollideFlagTheLaterActionAndKeepTheEarlierOne() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        // What an older version could have saved.
        f.prefs.setHotkey(area, for: .captureWindow)
        f.controller.sync()

        let problem = HotkeyProblem(combo: area, reason: .usedByGlint(.captureArea))
        #expect(f.controller.problems == [.captureWindow: problem])
        #expect(f.log.reports == [[.captureWindow: problem]])
        #expect(f.backend.calls.count == HotkeyAction.allCases.count - 1)
        try f.press(area)
        #expect(f.log.performed == [.captureArea])

        #expect(f.controller.change(.captureWindow, to: spare) == nil)
        #expect(f.controller.problems.isEmpty)
        try f.press(spare)
        #expect(f.log.performed == [.captureArea, .captureWindow])
    }

    // MARK: Changing a shortcut

    @Test func aChangeToAShortcutAnotherActionHasIsRejectedWithoutTouchingTheSystem() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.controller.sync()
        let calls = f.backend.calls

        let problem = f.controller.change(.captureArea, to: window)

        #expect(problem == HotkeyProblem(combo: window, reason: .usedByGlint(.captureWindow)))
        #expect(problem?.message == "⌃⌥⌘6 is already used by Capture window.")
        #expect(problem?.rejectedMessage == "⌃⌥⌘6 is already used by Capture window. Your shortcut was not changed.")
        #expect(f.backend.calls == calls)
        #expect(f.persisted.hotkey(for: .captureArea) == area)
        #expect(f.controller.problems.isEmpty)
        try f.press(area)
        #expect(f.log.performed == [.captureArea])
    }

    @Test func aChangeMacOSRefusesKeepsTheWorkingShortcutAndTheSavedOne() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.controller.sync()
        let launchCalls = f.backend.calls
        f.backend.refused[.init(spare)] = taken

        let problem = f.controller.change(.captureArea, to: spare)

        #expect(problem == HotkeyProblem(combo: spare, reason: .taken))
        #expect(f.backend.calls == launchCalls + [claim(spare)])
        #expect(f.persisted.hotkey(for: .captureArea) == area)
        #expect(f.prefs.hotkey(for: .captureArea) == area)
        #expect(f.isActive(area) && !f.isActive(spare))
        #expect(f.controller.problems.isEmpty)
        try f.press(area)
        #expect(f.log.performed == [.captureArea])

        f.controller.sync()
        #expect(f.backend.calls == launchCalls + [claim(spare)])
    }

    @Test func aChangeThatWorksIsSavedRegisteredAndReleasesTheOldShortcut() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.controller.sync()

        #expect(f.controller.change(.captureArea, to: spare) == nil)

        #expect(f.persisted.hotkey(for: .captureArea) == spare)
        #expect(f.isActive(spare) && !f.isActive(area))
        #expect(Array(f.backend.calls.suffix(2)) == [claim(spare), release(area)])
        let calls = f.backend.calls
        f.controller.sync()
        #expect(f.backend.calls == calls)
        try f.press(spare)
        #expect(f.log.performed == [.captureArea])
        // The shortcut it let go of is free for another action.
        #expect(f.controller.change(.captureWindow, to: area) == nil)
    }

    @Test func choosingAShortcutMacOSRefusedEarlierAsksAgain() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.controller.sync()
        f.backend.refused[.init(spare)] = taken
        #expect(f.controller.change(.captureArea, to: spare) != nil)

        f.backend.refused = [:]
        #expect(f.controller.change(.captureArea, to: spare) == nil)
        #expect(f.isActive(spare))
        #expect(f.persisted.hotkey(for: .captureArea) == spare)
    }

    @Test func aShortcutThatIsNotActiveCanBeReplacedAndTheProblemGoesAway() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.backend.refused[.init(window)] = taken
        f.controller.sync()
        #expect(f.controller.problems[.captureWindow] != nil)

        // Asking for the same refused combination again says so, and the problem stays.
        #expect(f.controller.change(.captureWindow, to: window) == HotkeyProblem(combo: window, reason: .taken))
        #expect(f.controller.problems[.captureWindow] != nil)

        #expect(f.controller.change(.captureWindow, to: spare) == nil)
        #expect(f.controller.problems.isEmpty)
        f.controller.sync()
        #expect(f.controller.problems.isEmpty)
        #expect(f.persisted.hotkey(for: .captureWindow) == spare)
        try f.press(spare)
        #expect(f.log.performed == [.captureWindow])
    }

    @Test func shortcutsThatWereSwappedWorkAndRestoringDefaultsRegistersThemAll() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.controller.sync()
        // A swap goes through a spare combination, as it would in Settings.
        #expect(f.controller.change(.captureArea, to: spare) == nil)
        #expect(f.controller.change(.captureWindow, to: area) == nil)
        #expect(f.controller.change(.captureArea, to: window) == nil)
        f.controller.sync()
        #expect(f.controller.problems.isEmpty)
        try f.press(window)
        try f.press(area)
        #expect(f.log.performed == [.captureArea, .captureWindow])

        f.prefs.resetToDefaults()
        f.controller.sync()

        #expect(f.controller.problems.isEmpty)
        #expect(!f.isActive(spare))
        f.log.performed = []
        for action in HotkeyAction.allCases { try f.press(action.defaultCombo) }
        #expect(f.log.performed == HotkeyAction.allCases)
    }

    // MARK: What the user sees

    @Test func problemsReadAsWhatHappenedAndWhatToDo() {
        #expect(HotkeyProblem(combo: window, reason: .taken).message == "⌃⌥⌘6 is already used by another app or macOS.")
        #expect(HotkeyProblem(combo: window, reason: .failed(OSStatus(paramErr))).message
            == "macOS couldn't register ⌃⌥⌘6 (error -50).")
        #expect(HotkeyProblem(combo: window, reason: .failed(nil)).message == "macOS couldn't register ⌃⌥⌘6.")
        #expect(HotkeyProblem(combo: area, reason: .usedByGlint(.captureWindow)).message
            == "⌃⌥⌘4 is already used by Capture window.")
        #expect(HotkeyProblem(combo: window, reason: .taken).rejectedMessage
            == "⌃⌥⌘6 is already used by another app or macOS. Your shortcut was not changed.")
        #expect(HotkeyProblem(combo: window, reason: .taken).inactiveMessage
            == "⌃⌥⌘6 is already used by another app or macOS. This shortcut isn't active; choose another.")
    }

    @Test func theLaunchNotificationNamesTheShortcutsThatWontWork() {
        let inUse = HotkeyProblem(combo: window, reason: .taken)
        let failed = HotkeyProblem(combo: HotkeyAction.captureText.defaultCombo, reason: .failed(nil))

        let one = HotkeyController.notification(for: [(.captureWindow, inUse)])
        #expect(one.title == "Shortcut unavailable")
        #expect(one.body == "⌃⌥⌘6 is already used by another app or macOS. “Capture window” won't work until you choose another in Settings.")

        let two = HotkeyController.notification(for: [(.captureWindow, inUse), (.captureText, failed)])
        #expect(two.title == "2 shortcuts unavailable")
        #expect(two.body == "These won't work until you choose others in Settings: Capture window, Capture text (OCR).")
    }

    @Test func theMenuFlagsShortcutProblemsFirstAndOnlyWhenThereAreSome() throws {
        _ = NSApplication.shared
        let f = Fixture()
        defer { f.cleanUp() }
        let menu = NSMenu()
        let delegate = AppDelegate(prefs: f.prefs, menu: menu)
        delegate.hotkeys = f.controller

        f.controller.sync()
        delegate.menuNeedsUpdate(menu)
        #expect(menu.items.first?.title == "Capture Area")
        #expect(menu.item(withTitle: "Shortcut Problem…") == nil)

        f.backend.refused[.init(spare)] = taken
        f.prefs.setHotkey(spare, for: .captureWindow)
        f.controller.sync()
        #expect(f.controller.problems.count == 1)
        delegate.menuNeedsUpdate(menu)
        let item = try #require(menu.items.first)
        #expect(item.title == "Shortcut Problem…")
        #expect(item.target === delegate)
        #expect(item.action.map(NSStringFromSelector) == "showShortcutProblems")
        #expect(item.image != nil)
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items[2].title == "Capture Area")

        f.backend.refused[.init(otherSpare)] = taken
        f.prefs.setHotkey(otherSpare, for: .captureText)
        f.controller.sync()
        #expect(f.controller.problems.count == 2)
        delegate.menuNeedsUpdate(menu)
        #expect(menu.items.first?.title == "Shortcut Problems…")

        f.backend.refused = [:]
        #expect(f.controller.change(.captureWindow, to: window) == nil)
        #expect(f.controller.change(.captureText, to: HotkeyAction.captureText.defaultCombo) == nil)
        delegate.menuNeedsUpdate(menu)
        #expect(menu.items.first?.title == "Capture Area")
    }

    @Test func thePreferencesModelFollowsTheControllersProblems() {
        let f = Fixture()
        defer { f.cleanUp() }
        let model = PrefsModel(prefs: f.prefs, store: PresetStore(url: URL(fileURLWithPath: "/dev/null/presets.json")),
                               hotkeys: f.controller)
        var changes = 0
        let observer = model.objectWillChange.sink { changes += 1 }
        defer { observer.cancel() }

        f.controller.sync()
        #expect(changes == 0)
        f.backend.refused[.init(spare)] = taken
        #expect(f.controller.change(.captureArea, to: spare) != nil)
        #expect(changes == 0)

        f.prefs.setHotkey(spare, for: .captureWindow)
        f.controller.sync()
        #expect(f.controller.problems.count == 1)
        #expect(changes == 1)
        f.controller.sync()
        #expect(changes == 1)

        #expect(f.controller.change(.captureWindow, to: otherSpare) == nil)
        #expect(f.controller.problems.isEmpty)
        #expect(changes == 2)
    }

    @Test func settingsOpensOnTheShortcutsFromTheProblemMenuItem() throws {
        _ = NSApplication.shared
        let f = Fixture()
        defer { f.cleanUp() }
        let standard = UserDefaults.standard
        let keys = [CollapsibleSection<EmptyView>.storageKey("shortcuts"), PreferencesTabViewController.selectedPaneKey]
        let saved = keys.map { ($0, standard.object(forKey: $0)) }
        defer { for (key, value) in saved { standard.set(value, forKey: key) } }
        standard.set(PreferencesPane.general.rawValue, forKey: PreferencesTabViewController.selectedPaneKey)
        standard.set(false, forKey: keys[0])

        let controller = PreferencesWindowController(
            prefs: f.prefs, store: PresetStore(url: URL(fileURLWithPath: "/dev/null/presets.json")), hotkeys: f.controller)
        let tabs = try #require(controller.contentViewController as? PreferencesTabViewController)
        #expect(tabs.selectedPane == .general)

        controller.revealShortcuts()

        #expect(tabs.selectedPane == .capture)
        #expect(standard.bool(forKey: keys[0]))
    }
}
