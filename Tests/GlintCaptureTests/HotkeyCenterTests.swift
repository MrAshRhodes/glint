import Carbon.HIToolbox
import GlintCore
import Testing
@testable import GlintCapture

// macOS is replaced by a fake that behaves like RegisterEventHotKey: it refuses a combination that is already
// claimed, plus any the test marks as taken, so the center's handling of a refusal can be checked.

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

    func numericID(of combo: RecordedKeyCombo) -> UInt32? {
        active.first { $0.value == Claim(combo) }?.key
    }
}

private extension FakeHotkeyBackend.Claim {
    init(_ combo: RecordedKeyCombo) { self.init(keyCode: combo.keyCode, modifiers: combo.modifiers.rawValue) }
}

private let area = RecordedKeyCombo(keyCode: 21, modifiers: [.control, .option, .command]) // ⌃⌥⌘4
private let clipboard = RecordedKeyCombo(keyCode: 23, modifiers: [.control, .option, .command]) // ⌃⌥⌘5

@Suite("Global hotkey registration")
@MainActor
struct HotkeyCenterTests {
    private let backend = FakeHotkeyBackend()
    private let center: HotkeyCenter

    init() { center = HotkeyCenter(backend: backend) }

    /// Plays macOS reporting that `combo` was pressed.
    private func press(_ combo: RecordedKeyCombo) throws {
        center.fire(numeric: try #require(backend.numericID(of: combo)))
    }

    private func failure(of attempt: () throws -> Void) -> HotkeyError? {
        do { try attempt(); return nil } catch { return error as? HotkeyError }
    }

    @Test func aRegisteredShortcutRunsItsHandler() throws {
        var fired = 0
        try center.register(id: "area", combo: area) { fired += 1 }
        #expect(center.registeredCombo(for: "area") == area)
        #expect(center.registeredIDs == ["area"])
        try press(area)
        #expect(fired == 1)
    }

    @Test func aRefusedReplacementKeepsTheExistingShortcutWorking() throws {
        var fired: [String] = []
        try center.register(id: "area", combo: area) { fired.append("old") }
        backend.refused[FakeHotkeyBackend.Claim(clipboard)] = OSStatus(eventHotKeyExistsErr)

        let error = try #require(failure { try center.register(id: "area", combo: clipboard) { fired.append("new") } })
        #expect(error.isAlreadyRegistered)
        #expect(center.registeredCombo(for: "area") == area)
        #expect(backend.numericID(of: clipboard) == nil)
        try press(area)
        #expect(fired == ["old"])
    }

    @Test func aReplacementClaimsTheNewShortcutBeforeReleasingTheOldOne() throws {
        try center.register(id: "area", combo: area) {}
        try center.register(id: "area", combo: clipboard) {}
        #expect(backend.calls == [.claim(.init(area)), .claim(.init(clipboard)), .release(.init(area))])
        #expect(center.registeredCombo(for: "area") == clipboard)
        #expect(backend.numericID(of: area) == nil)
    }

    @Test func registeringTheSameShortcutAgainOnlySwapsTheHandler() throws {
        var fired: [String] = []
        try center.register(id: "area", combo: area) { fired.append("first") }
        try center.register(id: "area", combo: area) { fired.append("second") }
        #expect(backend.calls == [.claim(.init(area))])
        try press(area)
        #expect(fired == ["second"])
    }

    @Test func aCombinationAnotherShortcutHoldsIsRefusedAsTaken() throws {
        try center.register(id: "area", combo: area) {}
        let error = try #require(failure { try center.register(id: "window", combo: area) {} })
        #expect(error.isAlreadyRegistered)
        #expect(center.registeredCombo(for: "window") == nil)
        #expect(center.registeredCombo(for: "area") == area)
    }

    @Test func theErrorCarriesTheStatusMacOSAnsweredWith() throws {
        backend.refused[FakeHotkeyBackend.Claim(area)] = OSStatus(paramErr)
        let error = try #require(failure { try center.register(id: "area", combo: area) {} })
        #expect(error.status == OSStatus(paramErr))
        #expect(!error.isAlreadyRegistered)
    }

    @Test func aFailedFirstRegistrationLeavesNothingBehind() throws {
        backend.refused[FakeHotkeyBackend.Claim(area)] = OSStatus(eventHotKeyExistsErr)
        #expect(failure { try center.register(id: "area", combo: area) {} } != nil)
        #expect(center.registeredIDs.isEmpty)
        #expect(center.registeredCombo(for: "area") == nil)
        #expect(backend.active.isEmpty)
    }

    @Test func unregisteringReleasesTheShortcutAndIgnoresLatePresses() throws {
        var fired = 0
        try center.register(id: "area", combo: area) { fired += 1 }
        let numeric = try #require(backend.numericID(of: area))

        center.unregister(id: "area")
        center.fire(numeric: numeric)
        center.unregister(id: "area")

        #expect(fired == 0)
        #expect(center.registeredCombo(for: "area") == nil)
        #expect(backend.active.isEmpty)
        #expect(backend.calls == [.claim(.init(area)), .release(.init(area))])
    }

    @Test func aReleasedShortcutCanBeClaimedByAnother() throws {
        try center.register(id: "area", combo: area) {}
        center.unregister(id: "area")
        try center.register(id: "window", combo: area) {}
        #expect(center.registeredCombo(for: "window") == area)
    }

    @Test func unregisterAllReleasesEveryShortcut() throws {
        try center.register(id: "area", combo: area) {}
        try center.register(id: "clipboard", combo: clipboard) {}
        center.unregisterAll()
        #expect(center.registeredIDs.isEmpty)
        #expect(backend.active.isEmpty)
    }

    @Test func aSavedShortcutRegistersWithCarbonModifiers() {
        #expect(RecordedKeyCombo(HotkeyAction.captureArea.defaultCombo) == area)
        #expect(RecordedKeyCombo(HotkeyAction.captureAreaToClipboard.defaultCombo) == clipboard)
    }
}
