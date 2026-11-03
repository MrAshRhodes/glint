import AppKit
import Sparkle

/// `UpdateEngine` backed by Sparkle's standard controller. Sparkle keeps the schedule and last-check date in the
/// app's defaults, verifies the signed appcast and archive against `SUPublicEDKey`, and always asks before installing.
@MainActor
final class SparkleUpdateEngine: UpdateEngine {
    var onChange: (() -> Void)?

    private let controller: SPUStandardUpdaterController
    /// Retained here because Sparkle holds its delegates weakly.
    private let delegate: SparkleUpdaterDelegate
    private var observation: NSKeyValueObservation?

    /// Creating the controller with `startingUpdater: false` makes no network request and reads no feed;
    /// `start()` does that, and only once the user asked for an update check or chose a schedule.
    init() {
        let delegate = SparkleUpdaterDelegate()
        self.delegate = delegate
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: delegate
        )
        delegate.onCycleFinished = { [weak self] in self?.onChange?() }
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.onChange?() }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var updateCheckInterval: TimeInterval {
        get { controller.updater.updateCheckInterval }
        set { controller.updater.updateCheckInterval = newValue }
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    func start() throws {
        // The updater itself rather than `controller.startUpdater()`, which swallows the error.
        try controller.updater.start()
    }

    func checkForUpdates() {
        // An agent app isn't active when its menu is used; bring Sparkle's window to the front.
        NSApp.activate()
        controller.updater.checkForUpdates()
    }
}

/// Sparkle delegate callbacks. A separate object because the controller takes its delegates up front.
@MainActor
final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    var onCycleFinished: (() -> Void)?

    /// Never ask "Check for updates automatically?": the choice lives in Settings and starts off.
    /// (Info.plist already sets `SUEnableAutomaticChecks`, which also suppresses the prompt.)
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        updateLog.info("Next update check in \(Int(delay), privacy: .public)s")
    }

    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        updateLog.info("Automatic update checks are off")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error = error as NSError?, error.code != Int(SUError.noUpdateError.rawValue) {
            updateLog.error("Update check ended: \(error.localizedDescription, privacy: .public)")
        }
        onCycleFinished?()
    }

    /// Scheduled update alerts from a menu bar app shouldn't steal focus; Sparkle shows them behind the active app.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
