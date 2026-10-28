import AppKit
import CoreGraphics
import ScreenCaptureKit

public struct WindowInfo: Hashable, Sendable {
    public let id: CGWindowID
    public let pid: pid_t
    public let ownerName: String
    public let title: String
    /// Global coordinates, origin top-left of the main display.
    public let frame: CGRect
    public let layer: Int
}

public struct DisplayInfo: Sendable {
    public let id: CGDirectDisplayID
    /// Global coordinates, origin top-left of the main display.
    public let frame: CGRect
    public let scale: CGFloat
    public let name: String
    public let isMain: Bool
}

struct SelectionWindowSnapshot {
    var windows: [WindowInfo] = []
    var snapWindows: [SnapWindow] = []
    /// Other apps' menus, pop-ups and tooltips. They can close as soon as the overlay is clicked.
    var transientWindows: [WindowInfo] = []
}

public enum WindowEnumerator {
    static let popUpMenuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
    static let screenSaverLevel = Int(CGWindowLevelForKey(.screenSaverWindow))

    /// On-screen windows that can be picked (normal-layer windows and other apps' open menus),
    /// ordered front to back, excluding this process.
    public static func onScreenWindows(excludingOwnProcess: Bool = true, minSize: CGFloat = 24) -> [WindowInfo] {
        selectionSnapshot(excludingOwnProcess: excludingOwnProcess, minSize: minSize).windows
    }

    /// One metadata-only snapshot, taken before the overlay appears. Non-target windows still occlude edges.
    static func selectionSnapshot(excludingOwnProcess: Bool = true, minSize: CGFloat = 24) -> SelectionWindowSnapshot {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return SelectionWindowSnapshot()
        }
        return selectionSnapshot(from: list, ownPID: ProcessInfo.processInfo.processIdentifier,
                                 excludingOwnProcess: excludingOwnProcess, minSize: minSize)
    }

    /// Parses CGWindowList dictionaries (front to back). Targets are normal-layer windows plus other apps'
    /// pop-up menus; transient windows are other apps' windows between the pop-up menu and screen saver levels.
    static func selectionSnapshot(
        from list: [[String: Any]], ownPID: pid_t, excludingOwnProcess: Bool = true, minSize: CGFloat = 24,
        transientMinSize: CGFloat = 4, popUpMenuLevel: Int = WindowEnumerator.popUpMenuLevel,
        screenSaverLevel: Int = WindowEnumerator.screenSaverLevel
    ) -> SelectionWindowSnapshot {
        var snapshot = SelectionWindowSnapshot()
        for d in list {
            guard let num = d[kCGWindowNumber as String] as? UInt32,
                  let pid = d[kCGWindowOwnerPID as String] as? Int32,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bd),
                  let layer = d[kCGWindowLayer as String] as? Int else { continue }
            if (d[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 { continue }
            let own = pid == ownPID
            let isTarget = ((layer == 0 && !(excludingOwnProcess && own)) || (layer == popUpMenuLevel && !own))
                && frame.width >= minSize && frame.height >= minSize
            let isTransient = !own && layer >= popUpMenuLevel && layer < screenSaverLevel
                && frame.width >= transientMinSize && frame.height >= transientMinSize
            snapshot.snapWindows.append(SnapWindow(frame: frame, isTarget: isTarget))
            guard isTarget || isTransient else { continue }
            let info = WindowInfo(id: num, pid: pid, ownerName: d[kCGWindowOwnerName as String] as? String ?? "",
                                  title: d[kCGWindowName as String] as? String ?? "", frame: frame, layer: layer)
            if isTarget { snapshot.windows.append(info) }
            if isTransient { snapshot.transientWindows.append(info) }
        }
        return snapshot
    }

    /// Whether the window is still on screen, e.g. a picked menu that may have closed meanwhile.
    static func isOnScreen(_ id: CGWindowID) -> Bool {
        let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
        return list.contains {
            ($0[kCGWindowNumber as String] as? UInt32) == id && ($0[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    @MainActor
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Topmost window under a global (top-left origin) point.
    public static func window(at point: CGPoint, in windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.frame.contains(point) }
    }

    @MainActor
    public static func displays() -> [DisplayInfo] {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.compactMap { s in
            guard let id = displayID(of: s) else { return nil }
            return DisplayInfo(id: id,
                               frame: CaptureGeometry.appKitToCG(s.frame, primaryHeight: primaryH),
                               scale: s.backingScaleFactor, name: s.localizedName,
                               isMain: id == CGMainDisplayID())
        }
    }

    /// ScreenCaptureKit shareable content (requires permission).
    public static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }
}
