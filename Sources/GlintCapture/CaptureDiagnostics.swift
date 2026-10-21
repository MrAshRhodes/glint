import AppKit

public enum CaptureDiagnostics {
    /// Headless report: permission state, displays, windows, and (if permitted) SCK visibility.
    @MainActor
    public static func run() async -> String {
        var out: [String] = ["== Glint capture diagnostics =="]
        out.append("Screen Recording: granted=\(ScreenRecordingPermission.isGranted) state=\(ScreenRecordingPermission.state.rawValue)")
        out.append("screencapture binary: \(FileManager.default.isExecutableFile(atPath: "/usr/sbin/screencapture") ? "present" : "MISSING")")
        let displays = WindowEnumerator.displays()
        out.append("Displays (\(displays.count)):")
        for d in displays {
            out.append("  #\(d.id) \(d.name)\(d.isMain ? " [main]" : "") frame=\(fmt(d.frame)) scale=\(d.scale)x")
        }
        let wins = WindowEnumerator.onScreenWindows()
        out.append("On-screen windows (\(wins.count)):")
        for w in wins.prefix(15) {
            out.append("  id=\(w.id) pid=\(w.pid) \(w.ownerName) — \(w.title.isEmpty ? "(untitled)" : w.title) \(fmt(w.frame))")
        }
        if wins.count > 15 { out.append("  … \(wins.count - 15) more") }
        if ScreenRecordingPermission.isGranted {
            do {
                let c = try await WindowEnumerator.shareableContent()
                out.append("ScreenCaptureKit: \(c.displays.count) displays, \(c.windows.count) windows, \(c.applications.count) apps")
            } catch {
                out.append("ScreenCaptureKit error: \(error.localizedDescription)")
            }
        } else {
            out.append("ScreenCaptureKit: skipped (no permission)")
        }
        return out.joined(separator: "\n")
    }

    private static func fmt(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
    }
}
