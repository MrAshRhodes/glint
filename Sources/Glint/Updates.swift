import AppKit
import GlintCore
import os

let updateLog = Logger(subsystem: "io.github.mrashrhodes.glint", category: "updates")

/// The updater operations Glint relies on. Sparkle in the app; a fake in tests.
@MainActor
protocol UpdateEngine: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var updateCheckInterval: TimeInterval { get set }
    var canCheckForUpdates: Bool { get }
    var lastUpdateCheckDate: Date? { get }
    /// Called when `canCheckForUpdates` or `lastUpdateCheckDate` may have changed.
    var onChange: (() -> Void)? { get set }
    func start() throws
    func checkForUpdates()
}

/// Owns "Check for Updates…" and the automatic-check schedule.
///
/// - Automatic checks start off. The updater isn't even started at launch unless the user picked a schedule,
///   so nothing is requested until they choose one or check by hand.
/// - A copy installed by Homebrew never builds an updater; it points to `brew upgrade` instead.
/// - A build without an update signing key (built from source, ad-hoc) explains that it can't update itself.
@MainActor
final class UpdateController: NSObject, ObservableObject, NSMenuItemValidation {
    enum Availability: Equatable {
        case ready
        /// `hint` is set when Homebrew's records disagree with the running version.
        case homebrew(hint: String?)
        case unavailable(String)
    }

    struct Notice: Equatable {
        var title: String
        var message: String
        var copyableCommand: String?
        var link: URL?
    }

    static let releasesURL = GlintInfo.repositoryURL.appendingPathComponent("releases/latest")
    static let guideURL = URL(string: "https://mrashrhodes.github.io/glint/guide.html#updates")!

    /// The app's updater. Created at launch so a schedule the user chose keeps running.
    static let shared = UpdateController.makeDefault()

    let availability: Availability
    @Published private(set) var frequency: UpdateCheckFrequency = .never
    @Published private(set) var canCheckNow = true
    @Published private(set) var lastCheck: Date?

    private let engine: UpdateEngine?
    private let presentNotice: @MainActor (Notice) -> Void
    private(set) var isStarted = false

    /// `makeEngine` runs only for a direct install with a valid feed and key.
    init(
        source: UpdateInstallSource,
        configuration: Result<UpdateConfiguration, UpdateConfiguration.Problem>,
        runningVersion: String? = AppInfo.version,
        makeEngine: () -> UpdateEngine,
        presentNotice: @escaping @MainActor (Notice) -> Void = UpdateController.presentAlert
    ) {
        self.presentNotice = presentNotice
        switch (source, configuration) {
        case (.homebrew, _):
            availability = .homebrew(hint: source.staleRecordHint(runningVersion: runningVersion))
            engine = nil
        case (.direct, .failure(let problem)):
            availability = .unavailable(problem.explanation)
            engine = nil
        case (.direct, .success):
            availability = .ready
            engine = makeEngine()
        }
        super.init()

        guard let engine else {
            updateLog.info("Updater not started: \(String(describing: self.availability), privacy: .public)")
            return
        }
        engine.onChange = { [weak self] in self?.refresh() }
        frequency = UpdateCheckFrequency(
            automaticChecks: engine.automaticallyChecksForUpdates,
            interval: engine.updateCheckInterval
        )
        // Only a schedule the user chose needs the updater running at launch.
        if frequency != .never { _ = startIfNeeded(reportingErrors: false) }
        refresh()
    }

    /// The app's own updater: Sparkle, unless Homebrew manages this copy or the build has no update key.
    static func makeDefault() -> UpdateController {
        UpdateController(
            source: UpdateInstallSource.detect(bundleURL: Bundle.main.bundleURL),
            configuration: UpdateConfiguration.resolve(from: Bundle.main.infoDictionary),
            makeEngine: { SparkleUpdateEngine() }
        )
    }

    // MARK: - Actions

    @objc func checkForUpdates(_ sender: Any?) {
        switch availability {
        case .ready:
            guard let engine, startIfNeeded(reportingErrors: true) else { return }
            engine.checkForUpdates()
            refresh()
        case .homebrew(let hint):
            presentNotice(Self.homebrewNotice(hint: hint))
        case .unavailable(let reason):
            presentNotice(Notice(
                title: "This Copy of Glint Can’t Update Itself",
                message: reason + "\n\nDownload the latest version from the releases page.",
                link: Self.releasesURL
            ))
        }
    }

    /// Turns automatic checks on at the chosen interval, or off. Writes only when the user changes it.
    func setFrequency(_ newValue: UpdateCheckFrequency) {
        guard availability == .ready, let engine, newValue != frequency else { return }
        guard startIfNeeded(reportingErrors: true) else { return }
        if let interval = newValue.interval {
            // Interval first, so the cycle Sparkle schedules when checks turn on already uses it.
            engine.updateCheckInterval = interval
            engine.automaticallyChecksForUpdates = true
        } else {
            engine.automaticallyChecksForUpdates = false
        }
        frequency = newValue
        updateLog.info("Automatic update checks: \(newValue.rawValue, privacy: .public)")
        refresh()
    }

    func refresh() {
        guard let engine else {
            canCheckNow = true
            return
        }
        // Before the updater starts, a manual check is always possible: it starts the updater first.
        let canCheck = isStarted ? engine.canCheckForUpdates : true
        if canCheckNow != canCheck { canCheckNow = canCheck }
        let last = engine.lastUpdateCheckDate
        if lastCheck != last { lastCheck = last }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) { return canCheckNow }
        return true
    }

    // MARK: - Private

    private func startIfNeeded(reportingErrors: Bool) -> Bool {
        guard let engine else { return false }
        if isStarted { return true }
        do {
            try engine.start()
            isStarted = true
            return true
        } catch {
            updateLog.error("Updater failed to start: \(error.localizedDescription, privacy: .public)")
            if reportingErrors {
                presentNotice(Notice(
                    title: "Couldn’t Check for Updates",
                    message: error.localizedDescription,
                    link: Self.releasesURL
                ))
            }
            return false
        }
    }

    static func homebrewNotice(hint: String? = nil) -> Notice {
        var message = "This copy of Glint was installed with Homebrew, so Homebrew keeps it up to date. "
            + "Save your edits and quit Glint, then run this in Terminal:\n\n"
            + UpdateInstallSource.homebrewUpdateCommand
            + "\n\nReopen Glint afterward. The tap may briefly lag a new release."
        if let hint { message += "\n\n" + hint }
        return Notice(
            title: "Homebrew Keeps Glint Up to Date",
            message: message,
            copyableCommand: UpdateInstallSource.homebrewUpdateCommand
        )
    }

    @discardableResult
    static func copy(_ command: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(command, forType: .string)
    }

    static func presentAlert(_ notice: Notice) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = notice.title
        alert.informativeText = notice.message
        if notice.copyableCommand != nil {
            alert.addButton(withTitle: "Copy Command")
        } else if notice.link != nil {
            alert.addButton(withTitle: "Open Releases Page")
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let command = notice.copyableCommand {
            copy(command)
        } else if let link = notice.link {
            NSWorkspace.shared.open(link)
        }
    }
}
