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

    private func snapshot(
        _ list: [[String: Any]], excludingOwnProcess: Bool = true, excludingWindowIDs: Set<CGWindowID> = []
    ) -> SelectionWindowSnapshot {
        WindowEnumerator.selectionSnapshot(from: list, ownPID: me, excludingOwnProcess: excludingOwnProcess,
                                           excludingWindowIDs: excludingWindowIDs, screenSaverLevel: screenSaverLevel)
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

    @Test func floatingAndStatusSurfacesAreTargetsAlongsideNormalWindows() {
        let list = [
            entry(1, pid: other, layer: 3, frame: CGRect(x: 0, y: 0, width: 300, height: 300)),
            entry(2, pid: me, layer: 0, frame: CGRect(x: 0, y: 0, width: 300, height: 300)),
            entry(3, pid: other, layer: 0, frame: CGRect(x: 0, y: 0, width: 23, height: 300)),
            entry(4, pid: other, layer: 0, frame: CGRect(x: 0, y: 0, width: 24, height: 24)),
            entry(5, pid: other, layer: 0, frame: CGRect(x: 0, y: 0, width: 500, height: 400), alpha: 0.04),
            entry(6, pid: other, layer: 25, frame: CGRect(x: 900, y: 0, width: 40, height: 30))
        ]
        let result = snapshot(list)
        #expect(result.windows.map(\.id) == [1, 4, 6])
        #expect(result.transientWindows.map(\.id) == [1, 6])
        #expect(snapshot(list, excludingOwnProcess: false).windows.map(\.id) == [1, 2, 4, 6])
    }

    @Test func ownEditorAndPopoversFollowOwnWindowOption() {
        let list = [entry(1, pid: me, layer: menuLevel, frame: CGRect(x: 0, y: 0, width: 200, height: 200)),
                    entry(2, pid: me, layer: 200, frame: CGRect(x: 0, y: 0, width: 200, height: 200)),
                    entry(3, pid: me, layer: 3, frame: CGRect(x: 0, y: 0, width: 200, height: 200)),
                    entry(4, pid: me, layer: 0, frame: CGRect(x: 0, y: 0, width: 200, height: 200))]
        let excluded = snapshot(list)
        #expect(excluded.windows.isEmpty)
        #expect(excluded.transientWindows.isEmpty)
        let included = snapshot(list, excludingOwnProcess: false)
        #expect(included.windows.map(\.id) == [1, 2, 3, 4])
        #expect(included.transientWindows.map(\.id) == [1, 2, 3])
        #expect(included.snapWindows.allSatisfy { $0.isTarget })
    }

    @Test func explicitHelperIdentitiesAreExcludedEvenDuringSelfCapture() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let list = [entry(1, pid: me, layer: 3, frame: frame),
                    entry(2, pid: other, layer: 0, frame: frame),
                    entry(3, pid: me, layer: menuLevel, frame: frame),
                    entry(4, pid: me, layer: 0, frame: frame)]
        let included = snapshot(list, excludingOwnProcess: false, excludingWindowIDs: [1, 2])
        #expect(included.windows.map(\.id) == [3, 4])
        #expect(included.transientWindows.map(\.id) == [3])
        #expect(included.snapWindows.count == 2)
        let excluded = snapshot(list, excludingWindowIDs: [1, 2])
        #expect(excluded.windows.isEmpty && excluded.transientWindows.isEmpty)
    }

    @Test func lowerTransientLevelsArePreservedInFrontToBackOrder() {
        let levels: [CGWindowLevelKey] = [
            .helpWindow, .popUpMenuWindow, .statusWindow, .utilityWindow, .modalPanelWindow, .floatingWindow
        ]
        let list = levels.enumerated().map { index, level in
            entry(UInt32(index + 1), pid: other, layer: Int(CGWindowLevelForKey(level)),
                  frame: CGRect(x: CGFloat(index * 10), y: CGFloat(index * 10), width: 200, height: 200))
        }
        let result = snapshot(list)
        #expect(result.windows.map(\.id) == [1, 2, 3, 4, 5, 6])
        #expect(result.transientWindows.map(\.id) == [1, 2, 3, 4, 5, 6])
        #expect(result.snapWindows.allSatisfy { $0.isTarget })
        #expect(WindowEnumerator.window(at: CGPoint(x: 100, y: 100), in: result.windows)?.id == 1)
    }

    @Test func chromeAndAboveScreenSaverSurfacesOnlyOccludeSnapping() {
        let levels: [CGWindowLevelKey] = [.screenSaverWindow, .mainMenuWindow, .dockWindow,
                                         .desktopIconWindow, .desktopWindow]
        var list = levels.enumerated().map { index, level in
            entry(UInt32(index + 1), pid: other, layer: Int(CGWindowLevelForKey(level)),
                  frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        list.append(entry(6, pid: me, layer: screenSaverLevel + 1,
                          frame: CGRect(x: 0, y: 0, width: 200, height: 200)))
        let result = snapshot(list, excludingOwnProcess: false)
        #expect(result.windows.isEmpty && result.transientWindows.isEmpty)
        #expect(result.snapWindows.count == list.count)
        #expect(result.snapWindows.allSatisfy { !$0.isTarget })
    }

    @Test func targetingDoesNotDependOnOwnerOrWindowNames() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        var unnamed = entry(1, pid: other, layer: 3, frame: frame)
        unnamed[kCGWindowOwnerName as String] = nil
        var systemOwned = entry(2, pid: other, layer: 8, frame: frame)
        systemOwned[kCGWindowOwnerName as String] = "SystemUIServer"
        systemOwned[kCGWindowName as String] = ""
        let result = snapshot([unnamed, systemOwned])
        #expect(result.windows.map(\.id) == [1, 2])
        #expect(result.transientWindows.map(\.id) == [1, 2])
    }

    @Test func tinySurfacesOccludeButOnlyVisibleSizedTransientsAreRetained() {
        let list = [
            entry(1, pid: other, layer: 3, frame: CGRect(x: 0, y: 0, width: 3, height: 3)),
            entry(2, pid: other, layer: 8, frame: CGRect(x: 0, y: 0, width: 4, height: 4)),
            entry(3, pid: other, layer: 19, frame: CGRect(x: 0, y: 0, width: 24, height: 24), alpha: 0.05),
            entry(4, pid: other, layer: 25, frame: CGRect(x: 0, y: 0, width: 200, height: 200), alpha: 0.049)
        ]
        let result = snapshot(list)
        #expect(result.windows.map(\.id) == [3])
        #expect(result.transientWindows.map(\.id) == [2, 3])
        #expect(result.snapWindows.map(\.isTarget) == [false, false, true])
    }

    @Test func malformedEntriesAreIgnored() {
        var missingBounds = entry(1, pid: other, layer: menuLevel, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        missingBounds[kCGWindowBounds as String] = nil
        var missingLayer = entry(2, pid: other, layer: 0, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        missingLayer[kCGWindowLayer as String] = nil
        var offscreen = entry(3, pid: other, layer: 3, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        offscreen[kCGWindowIsOnscreen as String] = false
        let result = snapshot([
            missingBounds, missingLayer, offscreen,
            entry(0, pid: other, layer: 0, frame: CGRect(x: 0, y: 0, width: 200, height: 200)),
            entry(4, pid: other, layer: 8, frame: CGRect(x: CGFloat.nan, y: 0, width: 200, height: 200)),
            entry(5, pid: other, layer: 3, frame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 200)),
            entry(6, pid: other, layer: 3, frame: CGRect(x: 0, y: 0, width: 0, height: 200)),
            entry(7, pid: other, layer: 3, frame: CGRect(x: 0, y: 0, width: -5, height: 200)),
            entry(8, pid: other, layer: 3, frame: CGRect(x: 0, y: 0, width: 200, height: 200), alpha: .nan)
        ])
        #expect(result.windows.isEmpty && result.transientWindows.isEmpty && result.snapWindows.isEmpty)
    }

    @Test func onScreenFrameReadsTheLiveBoundsOfTheListedWindowOnly() {
        let frame = CGRect(x: 40, y: 60, width: 500, height: 300)
        func listed(_ id: UInt32, onScreen: Bool?, frame: CGRect = frame) -> [String: Any] {
            var d = entry(id, pid: other, layer: 0, frame: frame)
            if let onScreen { d[kCGWindowIsOnscreen as String] = onScreen }
            return d
        }
        #expect(WindowEnumerator.onScreenFrame(of: 5, in: [listed(5, onScreen: true)]) == frame)
        #expect(WindowEnumerator.onScreenFrame(of: 5, in: [listed(4, onScreen: true,
                                                                  frame: CGRect(x: 0, y: 0, width: 9, height: 9)),
                                                           listed(5, onScreen: true)]) == frame)
        // Off screen, unflagged, absent or empty all mean the window is gone.
        #expect(WindowEnumerator.onScreenFrame(of: 5, in: [listed(5, onScreen: false)]) == nil)
        #expect(WindowEnumerator.onScreenFrame(of: 5, in: [listed(5, onScreen: nil)]) == nil)
        #expect(WindowEnumerator.onScreenFrame(of: 5, in: [listed(6, onScreen: true)]) == nil)
        #expect(WindowEnumerator.onScreenFrame(of: 5, in: []) == nil)

        var unreadable = listed(5, onScreen: true)
        unreadable[kCGWindowBounds as String] = nil
        #expect(WindowEnumerator.onScreenFrame(of: 5, in: [unreadable]) == nil)
    }

    @Test func defaultLevelsExcludeChromeWithoutExcludingPanels() {
        #expect(WindowEnumerator.popUpMenuLevel == Int(CGWindowLevelForKey(.popUpMenuWindow)))
        #expect(WindowEnumerator.screenSaverLevel == Int(CGWindowLevelForKey(.screenSaverWindow)))
        #expect(WindowEnumerator.reservedChromeLevels.contains(Int(CGWindowLevelForKey(.mainMenuWindow))))
        #expect(WindowEnumerator.reservedChromeLevels.contains(Int(CGWindowLevelForKey(.dockWindow))))
        let levels: [CGWindowLevelKey] = [.floatingWindow, .modalPanelWindow, .utilityWindow, .statusWindow,
                                        .popUpMenuWindow, .helpWindow]
        for key in levels {
            let level = Int(CGWindowLevelForKey(key))
            #expect(level > 0 && level < WindowEnumerator.screenSaverLevel)
            #expect(!WindowEnumerator.reservedChromeLevels.contains(level))
        }
    }

    @Test func theOwnerOfAWindowComesFromItsEntryInTheList() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let list = [entry(1, pid: me, layer: 0, frame: frame), entry(2, pid: other, layer: 0, frame: frame)]
        #expect(WindowEnumerator.ownerPID(of: 1, in: list) == me)
        #expect(WindowEnumerator.ownerPID(of: 2, in: list) == other)
        // A window that is gone has no entry.
        #expect(WindowEnumerator.ownerPID(of: 3, in: list) == nil)
        #expect(WindowEnumerator.ownerPID(of: 1, in: []) == nil)

        var withoutOwner = entry(4, pid: other, layer: 0, frame: frame)
        withoutOwner[kCGWindowOwnerPID as String] = nil
        #expect(WindowEnumerator.ownerPID(of: 4, in: [withoutOwner]) == nil)
    }
}
