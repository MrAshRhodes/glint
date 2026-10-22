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
}

public enum WindowEnumerator {
    /// On-screen, normal-layer windows, ordered front to back, excluding this process.
    public static func onScreenWindows(excludingOwnProcess: Bool = true, minSize: CGFloat = 24) -> [WindowInfo] {
        selectionSnapshot(excludingOwnProcess: excludingOwnProcess, minSize: minSize).windows
    }

    /// One metadata-only snapshot, taken before the overlay appears. Non-target windows still occlude edges.
    static func selectionSnapshot(excludingOwnProcess: Bool = true, minSize: CGFloat = 24) -> SelectionWindowSnapshot {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return SelectionWindowSnapshot()
        }
        let me = ProcessInfo.processInfo.processIdentifier
        var snapshot = SelectionWindowSnapshot()
        for d in list {
            guard let num = d[kCGWindowNumber as String] as? UInt32,
                  let pid = d[kCGWindowOwnerPID as String] as? Int32,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bd),
                  let layer = d[kCGWindowLayer as String] as? Int else { continue }
            if (d[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 { continue }
            let isTarget = layer == 0 && !(excludingOwnProcess && pid == me)
                && frame.width >= minSize && frame.height >= minSize
            snapshot.snapWindows.append(SnapWindow(frame: frame, isTarget: isTarget))
            if isTarget {
                snapshot.windows.append(WindowInfo(id: num, pid: pid,
                                                   ownerName: d[kCGWindowOwnerName as String] as? String ?? "",
                                                   title: d[kCGWindowName as String] as? String ?? "",
                                                   frame: frame, layer: layer))
            }
        }
        return snapshot
    }

    /// Topmost window under a global (top-left origin) point.
    public static func window(at point: CGPoint, in windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.frame.contains(point) }
    }

    @MainActor
    public static func displays() -> [DisplayInfo] {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.compactMap { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(n.uint32Value)
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
