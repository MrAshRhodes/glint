import AppKit

/// Keeps what the next capture needs close at hand, so the hotkey does not wait for it: ScreenCaptureKit's shareable
/// content is queried after launch and after anything that can change it, and the overlay's drawing caches are filled.
/// Only metadata is read, and never without permission: asking for it is left to a capture the user starts.
@MainActor
public final class CapturePrewarmer {
    struct Services {
        /// Whether screen recording is already granted; checking does not prompt.
        var isPermitted: @MainActor () -> Bool = { ScreenRecordingPermission.isGranted }
        var invalidate: @MainActor () -> Void = { ShareableContentCache.invalidate() }
        var warm: @MainActor () async -> Void = { await ShareableContentCache.shared.warm() }
        var warmOverlay: @MainActor () -> Void = { OverlayView.warmUp(scales: Set(WindowEnumerator.displays().map(\.scale))) }
        var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var notificationCenter: NotificationCenter = .default
        var workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
        /// How long things must stay quiet before the content is queried again: waking a Mac or plugging in a
        /// display sends several notifications in a row, and the screens are still changing between them.
        var settleDelay: Duration = .seconds(1)
    }

    /// What can change the displays or the windows a kept snapshot describes.
    private static let screenChanges: [Notification.Name] = [NSApplication.didChangeScreenParametersNotification]
    private static let sessionChanges: [Notification.Name] = [
        NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
        NSWorkspace.sessionDidBecomeActiveNotification
    ]

    private let services: Services
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var pending: Task<Void, Never>?

    public init() {
        services = Services()
    }

    init(services: Services) {
        self.services = services
    }

    /// Warms once now and again whenever the screens or the session change. Calling it again does nothing.
    public func start() {
        guard observers.isEmpty else { return }
        for name in Self.screenChanges { observe(name, in: services.notificationCenter) }
        for name in Self.sessionChanges { observe(name, in: services.workspaceNotificationCenter) }
        scheduleWarm()
    }

    public func stop() {
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
        pending?.cancel()
        pending = nil
    }

    private func observe(_ name: Notification.Name, in center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.contentMayHaveChanged() }
        }
        observers.append((center, token))
    }

    /// Forgets the kept snapshot at once, so no capture trusts it, and rebuilds it when things have settled.
    func contentMayHaveChanged() {
        services.invalidate()
        scheduleWarm()
    }

    /// Each call restarts the wait, so a burst of changes costs one query.
    private func scheduleWarm() {
        pending?.cancel()
        let services = services
        pending = Task {
            do { try await services.sleep(services.settleDelay) } catch { return }
            services.warmOverlay()
            guard services.isPermitted() else { return }
            await services.warm()
        }
    }

    /// Resolves once the warm-up scheduled so far has finished, so a test can look at what it did.
    func waitUntilWarm() async {
        await pending?.value
    }
}
