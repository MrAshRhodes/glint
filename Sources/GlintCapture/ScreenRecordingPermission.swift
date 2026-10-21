import AppKit
import CoreGraphics

public enum ScreenRecordingPermission {
    public enum State: String, Sendable { case granted, denied, unknown }

    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Preflight without prompting. macOS cannot distinguish "not asked yet" from "denied",
    /// so `denied` means: not granted and we have already requested once.
    public static var state: State {
        if isGranted { return .granted }
        return UserDefaults.standard.bool(forKey: requestedKey) ? .denied : .unknown
    }

    private static let requestedKey = "glint.screenRecordingRequested"

    /// Triggers the system prompt (first time only). Returns whether access is now granted.
    @discardableResult
    public static func request() -> Bool {
        UserDefaults.standard.set(true, forKey: requestedKey)
        return CGRequestScreenCaptureAccess()
    }

    public static var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    }

    public static func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// Requests if undecided, otherwise opens Settings when denied. Returns current grant state.
    @discardableResult
    public static func ensure() -> Bool {
        if isGranted { return true }
        if state == .unknown { return request() }
        openSystemSettings()
        return false
    }
}
