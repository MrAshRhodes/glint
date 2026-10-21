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

public enum WindowEnumerator {
    /// On-screen, normal-layer windows, ordered front to back, excluding this process.
    public static func onScreenWindows(excludingOwnProcess: Bool = true, minSize: CGFloat = 24) -> [WindowInfo] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { d in
            guard let num = d[kCGWindowNumber as String] as? UInt32,
                  let pid = d[kCGWindowOwnerPID as String] as? Int32,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bd),
                  let layer = d[kCGWindowLayer as String] as? Int else { return nil }
            if layer != 0 { return nil }
            if (d[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 { return nil }
            if excludingOwnProcess && pid == me { return nil }
            if frame.width < minSize || frame.height < minSize { return nil }
            return WindowInfo(id: num, pid: pid,
                              ownerName: d[kCGWindowOwnerName as String] as? String ?? "",
                              title: d[kCGWindowName as String] as? String ?? "",
                              frame: frame, layer: layer)
        }
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
