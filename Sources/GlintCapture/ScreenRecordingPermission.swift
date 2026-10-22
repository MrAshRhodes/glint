import AppKit
import CoreGraphics

public enum ScreenRecordingPermission {
    public enum State: String, Sendable { case granted, denied, unknown }

    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Preflight without prompting. macOS cannot distinguish "not asked yet" from "denied",
    /// so `denied` means: not granted and we have already requested once.
    public static var state: State { state(granted: isGranted) }

    static func state(granted: Bool, defaults: UserDefaults = .standard) -> State {
        if granted { return .granted }
        return defaults.bool(forKey: requestedKey) ? .denied : .unknown
    }

    static let requestedKey = "glint.screenRecordingRequested"
    static let grantedVersionKey = "glint.screenRecordingGrantedVersion"

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

    // MARK: Stale grants after updates

    /// Preflights access and remembers a successful grant, so a later loss (for example after an
    /// update changes the code signature macOS recorded) can be recognised as a stale entry.
    @discardableResult
    public static func refreshGrant() -> Bool {
        let granted = isGranted
        recordObservation(granted: granted, version: currentVersion)
        return granted
    }

    static func recordObservation(granted: Bool, version: String, defaults: UserDefaults = .standard) {
        guard granted, defaults.string(forKey: grantedVersionKey) != version else { return }
        defaults.set(version, forKey: grantedVersionKey)
    }

    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty, build != short else { return short }
        return "\(short) (\(build))"
    }

    /// Access is missing although Glint was granted it before, or we already asked once. macOS keeps
    /// such entries tied to the old signature, so the toggle can look on while captures still fail.
    public static var needsReauthorization: Bool { needsReauthorization(granted: isGranted) }

    public static func needsReauthorization(granted: Bool, defaults: UserDefaults = .standard) -> Bool {
        needsReauthorization(granted: granted,
                             requested: defaults.bool(forKey: requestedKey),
                             grantedVersion: defaults.string(forKey: grantedVersionKey))
    }

    static func needsReauthorization(granted: Bool, requested: Bool, grantedVersion: String?) -> Bool {
        !granted && (requested || grantedVersion != nil)
    }

    /// Access is missing although Glint positively observed it granted before. Unlike
    /// `needsReauthorization`, an earlier request or denial alone does not count.
    public static func lostRecordedGrant(granted: Bool, defaults: UserDefaults = .standard) -> Bool {
        lostRecordedGrant(granted: granted, grantedVersion: defaults.string(forKey: grantedVersionKey))
    }

    static func lostRecordedGrant(granted: Bool, grantedVersion: String?) -> Bool {
        !granted && grantedVersion != nil
    }

    // MARK: Re-authorization

    public struct ResetCommand: Equatable, Sendable {
        public var executableURL: URL
        public var arguments: [String]
    }

    /// Returns whether the command exited successfully.
    public typealias CommandRunner = @Sendable (ResetCommand) async -> Bool

    public enum ReauthorizationOutcome: Equatable, Sendable {
        /// Access is already granted; nothing was reset.
        case alreadyGranted
        /// Glint's old entry was cleared and macOS was asked to prompt again.
        case requestedAgain
        /// Not running as a bundled app, so there is no entry to reset; System Settings was opened.
        case missingBundleIdentifier
        /// `tccutil` failed; System Settings was opened instead.
        case resetFailed
    }

    /// Clears only Glint's own Screen Recording entry. Returns nil without a usable bundle identifier.
    static func resetCommand(bundleIdentifier: String?) -> ResetCommand? {
        guard let id = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return ResetCommand(executableURL: URL(fileURLWithPath: "/usr/bin/tccutil"),
                            arguments: ["reset", "ScreenCapture", id])
    }

    struct ReauthorizationServices {
        var bundleIdentifier: String? = Bundle.main.bundleIdentifier
        var isGranted: () -> Bool = { ScreenRecordingPermission.isGranted }
        var runReset: CommandRunner = ScreenRecordingPermission.runProcess
        var request: () -> Bool = { ScreenRecordingPermission.request() }
        var openSettings: () -> Void = { ScreenRecordingPermission.openSystemSettings() }
    }

    /// Clears Glint's stale Screen Recording entry and asks macOS to prompt again. Call only from an
    /// explicit user action: the reset revokes whatever entry macOS currently holds for Glint.
    @MainActor
    @discardableResult
    public static func reauthorize() async -> ReauthorizationOutcome {
        await reauthorize(using: ReauthorizationServices())
    }

    @MainActor
    static func reauthorize(using services: ReauthorizationServices) async -> ReauthorizationOutcome {
        if services.isGranted() { return .alreadyGranted }
        guard let command = resetCommand(bundleIdentifier: services.bundleIdentifier) else {
            services.openSettings()
            return .missingBundleIdentifier
        }
        guard await services.runReset(command) else {
            services.openSettings()
            return .resetFailed
        }
        if !services.request() { services.openSettings() }
        return .requestedAgain
    }

    static let resetTimeout: TimeInterval = 10

    static let runProcess: CommandRunner = { command in
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = command.executableURL
            process.arguments = command.arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationReason == .exit && finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + resetTimeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}
