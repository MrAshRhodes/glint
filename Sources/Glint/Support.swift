import AppKit
import Foundation
import GlintCore
import UserNotifications

enum AppInfo {
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
    }
}

/// Extra, shell-only preference keys (the typed ones live in `AppPreferences`).
enum ShellKey {
    static let showMenuBarIcon = "glint.showMenuBarIcon"
    static let timerSeconds = "glint.timerSeconds"
    static let hideCursor = "glint.hideCursor"
    static let rememberArea = "glint.rememberArea"
    static let quickAccess = "glint.quickAccess"
    static let onboarded = "glint.onboarded"
    static let recentFiles = "glint.recentFiles"
}

extension Notification.Name {
    static let glintPreferencesChanged = Notification.Name("glint.preferencesChanged")
}

/// Posts user notifications; silently does nothing when the process is not a proper app bundle.
@MainActor
enum Notifier {
    private static var usable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func post(title: String, body: String, fileURL: URL? = nil) {
        guard AppPreferences.shared.notificationsEnabled, usable else { return }
        Task { @MainActor in
            guard await NotificationPermission.system.isGranted() else { return }
            add(title: title, body: body, fileURL: fileURL)
        }
    }

    /// For failures the user must not miss: a notification when one will be shown, otherwise a beep and an alert.
    static func postFailure(title: String, body: String, fileURL: URL? = nil) {
        guard usable else { return }
        Task { @MainActor in await FailureFeedback.system.report(title: title, message: body, fileURL: fileURL) }
    }

    static func add(title: String, body: String, fileURL: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let fileURL { content.userInfo = ["file": fileURL.path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func playSound() {
        guard AppPreferences.shared.soundsEnabled else { return }
        (NSSound(named: "Grab") ?? NSSound(named: "Pop"))?.play()
    }
}

@MainActor
enum CaptureRecovery {
    static func requestRetry(title: String, message: String) -> Bool {
        let alert = alert(title: title, message: message)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func alert(title: String, message: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = """
        \(message)

        No safe output was saved or copied. Your capture stays in memory while this dialog is open.

        Retry processes the same captured image again. Discard Capture releases it from memory. No additional raw image is saved for recovery.
        """
        alert.addButton(withTitle: "Retry").keyEquivalent = "\r"
        alert.addButton(withTitle: "Discard Capture")
        return alert
    }
}

/// Runs the blocking retention work (hashing, encoding, writing) one job at a time off the main thread, so a copy
/// or drag never waits for the disk. Jobs finish in the order they were queued.
@MainActor
final class RetentionQueue {
    private final class IdleWaiter {
        private var continuation: CheckedContinuation<Bool, Never>?
        var timeout: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

        func resume(_ idle: Bool) {
            timeout?.cancel()
            timeout = nil
            continuation?.resume(returning: idle)
            continuation = nil
        }
    }

    private(set) var pending = 0
    private var tail: Task<Void, Never>?
    private var waiters: [IdleWaiter] = []
    private let priority: TaskPriority

    var isIdle: Bool { pending == 0 }

    /// Background upkeep stays at utility priority; work somebody is waiting on asks for more.
    init(priority: TaskPriority = .utility) { self.priority = priority }

    /// Runs `work` off the main thread after every earlier job, then passes its result to `completion` on the main actor.
    func enqueue<Output: Sendable>(_ work: @escaping @Sendable () -> Output,
                                   completion: @escaping @MainActor (Output) -> Void) {
        pending += 1
        let previous = tail
        let priority = priority
        tail = Task { @MainActor [weak self] in
            await previous?.value
            let output = await Task.detached(priority: priority, operation: work).value
            completion(output)
            self?.finishJob()
        }
    }

    /// Counts work that isn't a queued job, such as a capture still being rendered, as pending, so waiting for the
    /// queue waits for it too. Call the returned closure once that work finished or queued its own jobs.
    func hold() -> @MainActor () -> Void {
        pending += 1
        var released = false
        return { [weak self] in
            guard !released else { return }
            released = true
            self?.finishJob()
        }
    }

    /// Returns true once every queued job has finished, or false when `timeout` ran out first.
    func waitUntilIdle(timeout: Duration? = nil) async -> Bool {
        guard pending > 0 else { return true }
        return await withCheckedContinuation { continuation in
            let waiter = IdleWaiter(continuation)
            waiters.append(waiter)
            guard let timeout else { return }
            waiter.timeout = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { waiter.resume(false) }
            }
        }
    }

    private func finishJob() {
        pending -= 1
        guard pending == 0 else { return }
        tail = nil
        let ready = waiters
        waiters = []
        ready.forEach { $0.resume(true) }
    }
}

/// Decides when the Output cleanup runs: shortly after launch, every few hours, and a little while after the
/// preferences change, so a misclick on the retention picker never removes anything right away.
@MainActor
final class OutputCleanupScheduler {
    struct Timing {
        var launchDelay: Duration = .seconds(30)
        var interval: Duration = .seconds(6 * 60 * 60)
        var debounce: Duration = .seconds(30)
    }

    /// Arms a one-shot timer and returns the closure that cancels it.
    typealias Schedule = @MainActor (Duration, @escaping @MainActor () -> Void) -> @MainActor () -> Void

    static let systemSchedule: Schedule = { delay, fire in
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { fire() }
        }
        return { task.cancel() }
    }

    private let timing: Timing
    private let schedule: Schedule
    private let run: @MainActor () async -> Void
    private var cancelPeriodic: (@MainActor () -> Void)?
    private var cancelDebounce: (@MainActor () -> Void)?
    private var current: Task<Void, Never>?
    private var runAgain = false

    /// `run` does one cleanup pass; it is never running twice at once.
    init(timing: Timing = Timing(), schedule: Schedule? = nil, run: @escaping @MainActor () async -> Void) {
        self.timing = timing
        self.schedule = schedule ?? Self.systemSchedule
        self.run = run
    }

    /// One pass after the launch delay, then one every interval.
    func start() {
        cancelPeriodic?()
        cancelPeriodic = schedule(timing.launchDelay) { [weak self] in self?.periodicFired() }
    }

    /// Every change restarts the wait, so the pass runs once the preferences have been quiet for the debounce time.
    func preferencesChanged() {
        cancelDebounce?()
        cancelDebounce = schedule(timing.debounce) { [weak self] in
            self?.cancelDebounce = nil
            self?.trigger()
        }
    }

    func stop() {
        cancelPeriodic?()
        cancelDebounce?()
        cancelPeriodic = nil
        cancelDebounce = nil
    }

    /// Returns once no pass is running; passes that are only scheduled are not waited for.
    func waitUntilIdle() async {
        while let task = current { await task.value }
    }

    private func periodicFired() {
        cancelPeriodic = schedule(timing.interval) { [weak self] in self?.periodicFired() }
        trigger()
    }

    /// A trigger that arrives mid-pass asks for one more pass afterwards, which sees the newer preferences.
    private func trigger() {
        guard current == nil else {
            runAgain = true
            return
        }
        current = Task { @MainActor [weak self] in
            repeat {
                guard let self else { return }
                runAgain = false
                await run()
            } while self?.runAgain == true
            self?.current = nil
        }
    }
}
