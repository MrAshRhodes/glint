import CoreGraphics
import Foundation
import Testing
@testable import GlintCapture

@Suite("Window enumeration")
struct WindowEnumeratorTests {
    private let me: pid_t = 42
    private let other: pid_t = 7
    private let menuLevel = 101
    private let screenSaverLevel = 1000

    private func entry(_ id: UInt32, pid: pid_t, layer: Int, frame: CGRect, alpha: Double = 1) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id),
         kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowLayer as String: NSNumber(value: layer),
         kCGWindowBounds as String: frame.dictionaryRepresentation,
         kCGWindowAlpha as String: NSNumber(value: alpha),
         kCGWindowOwnerName as String: "App \(pid)"]
    }

    private func snapshot(_ list: [[String: Any]], excludingOwnProcess: Bool = true) -> SelectionWindowSnapshot {
        WindowEnumerator.selectionSnapshot(from: list, ownPID: me, excludingOwnProcess: excludingOwnProcess,
                                           popUpMenuLevel: menuLevel, screenSaverLevel: screenSaverLevel)
    }

    @Test func otherAppsMenusArePickableAndTransient() {
        let menu = CGRect(x: 100, y: 30, width: 220, height: 300)
        let window = CGRect(x: 50, y: 50, width: 800, height: 600)
        let list = [
            entry(1, pid: other, layer: screenSaverLevel, frame: CGRect(x: 0, y: 0, width: 400, height: 400)),
            entry(2, pid: me, layer: menuLevel, frame: CGRect(x: 0, y: 30, width: 200, height: 200)),
            entry(3, pid: other, layer: 200, frame: CGRect(x: 300, y: 300, width: 60, height: 20)),
            entry(4, pid: other, layer: menuLevel, frame: menu),
            entry(5, pid: other, layer: menuLevel, frame: CGRect(x: 10, y: 10, width: 3, height: 3)),
            entry(6, pid: other, layer: menuLevel, frame: CGRect(x: 10, y: 10, width: 100, height: 100), alpha: 0.01),
            entry(7, pid: other, layer: menuLevel, frame: CGRect(x: 10, y: 10, width: 12, height: 10)),
            entry(8, pid: other, layer: 24, frame: CGRect(x: 0, y: 0, width: 1440, height: 30)),
            entry(9, pid: other, layer: 0, frame: window)
        ]
        let result = snapshot(list)
        #expect(result.windows.map(\.id) == [4, 9])
        #expect(result.transientWindows.map(\.id) == [3, 4, 7])
        #expect(result.windows.first?.layer == menuLevel)
        #expect(result.windows.first?.frame == menu)
        // Transparent windows are skipped entirely; everything else still occludes snapping edges.
        #expect(result.snapWindows.count == list.count - 1)
        #expect(result.snapWindows.map(\.isTarget) == [false, false, false, true, false, false, false, true])
        // Front-to-back order lets an open menu win over the window behind it.
        #expect(WindowEnumerator.window(at: CGPoint(x: 150, y: 100), in: result.windows)?.id == 4)
        #expect(WindowEnumerator.window(at: CGPoint(x: 600, y: 400), in: result.windows)?.id == 9)
    }

    @Test func normalLayerTargetsAreUnchanged() {
        let list = [
            entry(1, pid: other, layer: 3, frame: CGRect(x: 0, y: 0, width: 300, height: 300)),
            entry(2, pid: me, layer: 0, frame: CGRect(x: 0, y: 0, width: 300, height: 300)),
            entry(3, pid: other, layer: 0, frame: CGRect(x: 0, y: 0, width: 23, height: 300)),
            entry(4, pid: other, layer: 0, frame: CGRect(x: 0, y: 0, width: 24, height: 24)),
            entry(5, pid: other, layer: 0, frame: CGRect(x: 0, y: 0, width: 500, height: 400), alpha: 0.04),
            entry(6, pid: other, layer: 25, frame: CGRect(x: 900, y: 0, width: 40, height: 30))
        ]
        let result = snapshot(list)
        #expect(result.windows.map(\.id) == [4])
        #expect(result.transientWindows.isEmpty)
        #expect(snapshot(list, excludingOwnProcess: false).windows.map(\.id) == [2, 4])
    }

    @Test func ownMenusAreNeverTargetsOrTransientEvenWhenIncludingOwnWindows() {
        let list = [entry(1, pid: me, layer: menuLevel, frame: CGRect(x: 0, y: 0, width: 200, height: 200)),
                    entry(2, pid: me, layer: 200, frame: CGRect(x: 0, y: 0, width: 200, height: 200))]
        let result = snapshot(list, excludingOwnProcess: false)
        #expect(result.windows.isEmpty)
        #expect(result.transientWindows.isEmpty)
    }

    @Test func malformedEntriesAreIgnored() {
        var missingBounds = entry(1, pid: other, layer: menuLevel, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        missingBounds[kCGWindowBounds as String] = nil
        var missingLayer = entry(2, pid: other, layer: 0, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        missingLayer[kCGWindowLayer as String] = nil
        let result = snapshot([missingBounds, missingLayer])
        #expect(result.windows.isEmpty && result.transientWindows.isEmpty && result.snapWindows.isEmpty)
    }

    @Test func defaultLevelsCoverMenusAndTooltipsButNotTheOverlay() {
        #expect(WindowEnumerator.popUpMenuLevel == Int(CGWindowLevelForKey(.popUpMenuWindow)))
        #expect(WindowEnumerator.screenSaverLevel == Int(CGWindowLevelForKey(.screenSaverWindow)))
        let transient = WindowEnumerator.popUpMenuLevel..<WindowEnumerator.screenSaverLevel
        #expect(transient.contains(Int(CGWindowLevelForKey(.helpWindow))))
        #expect(!transient.contains(Int(CGWindowLevelForKey(.mainMenuWindow))))
        #expect(!transient.contains(WindowEnumerator.screenSaverLevel + 1))
    }
}
