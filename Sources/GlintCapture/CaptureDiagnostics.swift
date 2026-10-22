import Foundation

public enum CaptureDiagnostics {
    /// Headless report of permission state and aggregate counts, without window or display metadata.
    @MainActor
    public static func run() async -> String {
        await report(
            permission: ScreenRecordingPermission.state,
            captureBinaryAvailable: FileManager.default.isExecutableFile(atPath: "/usr/sbin/screencapture"),
            displayCount: WindowEnumerator.displays().count,
            windowCount: WindowEnumerator.onScreenWindows().count
        ) {
            let content = try await WindowEnumerator.shareableContent()
            return (content.displays.count, content.windows.count, content.applications.count)
        }
    }

    @MainActor
    static func report(
        permission: ScreenRecordingPermission.State,
        captureBinaryAvailable: Bool,
        displayCount: Int,
        windowCount: Int,
        shareableCounts: @MainActor () async throws -> (displays: Int, windows: Int, applications: Int)
    ) async -> String {
        var out: [String] = ["== Glint capture diagnostics =="]
        out.append("Screen Recording: granted=\(permission == .granted) state=\(permission.rawValue)")
        out.append("screencapture binary: \(captureBinaryAvailable ? "present" : "MISSING")")
        out.append("Displays: \(displayCount)")
        out.append("On-screen windows: \(windowCount)")
        if permission == .granted {
            do {
                let counts = try await shareableCounts()
                out.append("ScreenCaptureKit: \(counts.displays) displays, \(counts.windows) windows, \(counts.applications) apps")
            } catch {
                // Framework error descriptions may contain the same private metadata as window records.
                out.append("ScreenCaptureKit: unavailable (enumeration failed)")
            }
        } else {
            out.append("ScreenCaptureKit: skipped (no permission)")
        }
        return out.joined(separator: "\n")
    }
}
