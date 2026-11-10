import AppKit
import Combine
import SwiftUI

/// Beats only while the view it watches is on screen. A pane that re-reads system state this way costs
/// nothing while its window is closed, minimised or on another tab, and catches up the moment it returns.
final class OnScreenPoller: ObservableObject {
    /// Starts calling `fire` every `interval` seconds and returns the closure that stops it.
    typealias Schedule = (_ interval: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void

    /// One value per poll; the first is sent as soon as the view comes on screen.
    let beats = PassthroughSubject<Void, Never>()
    private(set) var isOnScreen = false
    var isPolling: Bool { stop != nil }

    private let interval: TimeInterval
    private let schedule: Schedule
    private var stop: (() -> Void)?

    init(interval: TimeInterval = 1, schedule: @escaping Schedule = OnScreenPoller.mainRunLoopTimer) {
        self.interval = interval
        self.schedule = schedule
    }

    deinit { stop?() }

    func setOnScreen(_ onScreen: Bool) {
        guard onScreen != isOnScreen else { return }
        isOnScreen = onScreen
        if onScreen {
            beats.send()
            stop = schedule(interval) { [weak self] in self?.beats.send() }
        } else {
            stop?()
            stop = nil
        }
    }

    /// Common run-loop modes keep it ticking while a menu is open or a window is being dragged.
    static let mainRunLoopTimer: Schedule = { interval, fire in
        let timer = Timer(timeInterval: interval, repeats: true) { _ in fire() }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}

/// Tells `onChange` whether the window holding this view is on screen: ordered in, not minimised, and the
/// view still attached to it (a pane on a tab that is not selected is detached). Reports arrive on a later
/// run-loop turn, outside SwiftUI's view updates and after the window has settled.
struct WindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> WindowVisibilityView { WindowVisibilityView(onChange: onChange) }

    func updateNSView(_ view: WindowVisibilityView, context: Context) { view.onChange = onChange }
}

final class WindowVisibilityView: NSView {
    var onChange: (Bool) -> Void
    private var lastReported: Bool?
    private var visibleObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { stopObserving() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        if let window {
            visibleObservation = window.observe(\.isVisible) { [weak self] _, _ in self?.scheduleReport() }
            let center = NotificationCenter.default
            let names: [(Notification.Name, AnyObject?)] = [
                (NSWindow.didMiniaturizeNotification, window), (NSWindow.didDeminiaturizeNotification, window),
                (NSWindow.willCloseNotification, window),
                (NSApplication.didHideNotification, nil), (NSApplication.didUnhideNotification, nil),
            ]
            observers = names.map { name, object in
                center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.scheduleReport() }
            }
        }
        scheduleReport()
    }

    private func stopObserving() {
        visibleObservation = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func scheduleReport() {
        DispatchQueue.main.async { [weak self] in self?.report() }
    }

    private func report() {
        let onScreen = window.map { $0.isVisible && !$0.isMiniaturized && !NSApplication.shared.isHidden } ?? false
        guard onScreen != lastReported else { return }
        lastReported = onScreen
        onChange(onScreen)
    }
}
