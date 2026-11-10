import AppKit
import GlintCore

@MainActor
public final class ScreenCapturer {
    /// What a selection hands to the grab that follows it.
    struct Selection {
        var outcome: SelectionOutcome
        var frozen: [FrozenDisplay]?
        /// When the overlay went away; nil when unknown, which owes the whole settle delay.
        var closedAt: ContinuousClock.Instant?
        /// Windows from the freeze's content query, so a window picked from them needs no second query.
        var windows: [CGWindowID: any QueriedWindow] = [:]
    }

    struct Services {
        var permission: @MainActor () throws -> Void = { try ScreenCapturer.requirePermission() }
        var displays: @MainActor () -> [DisplayInfo] = { WindowEnumerator.displays() }
        var select: @MainActor (OverlayStartMode, CGRect?, CaptureOptions, Bool, (@MainActor () -> Void)?) async throws
            -> Selection = { mode, lastArea, options, freeze, presented in
            var windows: [CGWindowID: any QueriedWindow] = [:]
            let capture: (([DisplayInfo]) async throws -> [FrozenDisplay]) = {
                let frozen = try await ImageGrabber.freezeKeepingWindows($0, options: options)
                windows = frozen.windows
                return frozen.displays
            }
            let session = SelectionSession(
                mode: mode, lastArea: lastArea, snapToEdges: options.snapToEdges,
                freeze: freeze ? capture : nil,
                excludeOwnWindows: options.excludeOwnWindows, excludedWindowIDs: options.excludedWindowIDs,
                onPresented: presented)
            let outcome = try await session.run()
            let frozen = session.takeFrozen()
            try Task.checkCancellation()
            return Selection(outcome: outcome, frozen: freeze ? frozen : nil, closedAt: session.closedAt,
                             windows: windows)
        }
        var now: @MainActor () -> ContinuousClock.Instant = { .now }
        var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var onScreenFrame: @MainActor (CGWindowID) -> CGRect? = { WindowEnumerator.onScreenFrame(of: $0) }
        var grabWindow: @MainActor (WindowInfo, CGFloat, CaptureOptions, (any QueriedWindow)?) async throws
            -> ImageGrabber.Grab = {
            try await ImageGrabber.grabWindow($0, scale: $1, options: $2, known: $3)
        }
        var grabRect: @MainActor (CGRect, DisplayInfo, CaptureOptions) async throws -> ImageGrabber.Grab = {
            try await ImageGrabber.grabRect($0, display: $1, options: $2)
        }
        var grabDisplay: @MainActor (DisplayInfo, CaptureOptions) async throws -> ImageGrabber.Grab = {
            try await ImageGrabber.grabDisplay($0, options: $1)
        }
    }

    public static let shared = ScreenCapturer()
    public var options = CaptureOptions()
    /// Runs once the next selection overlay is on screen and covering the displays, while selection is active.
    /// The next selection consumes it, whether or not it reaches the screen.
    public var onSelectionPresented: (@MainActor () -> Void)?

    private let lastAreaKey = "glint.lastCaptureArea"
    private let services: Services
    private let defaults: UserDefaults

    public init() {
        services = Services()
        defaults = .standard
    }

    init(services: Services, defaults: UserDefaults = .standard) {
        self.services = services
        self.defaults = defaults
    }

    /// Last area in global (top-left origin) display coordinates.
    public var lastArea: CGRect? {
        get {
            guard let a = defaults.array(forKey: lastAreaKey) as? [Double], a.count == 4 else { return nil }
            return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        }
        set {
            if let r = newValue {
                defaults.set([r.minX, r.minY, r.width, r.height].map(Double.init), forKey: lastAreaKey)
            } else {
                defaults.removeObject(forKey: lastAreaKey)
            }
        }
    }

    // MARK: Public API

    /// Interactive crosshair selection. Space before a drag toggles window picking and, while dragging, moves the
    /// selection; Esc cancels. A Space or display change ends it the same way (both throw `.cancelled`).
    public func captureArea() async throws -> CaptureResult {
        try await interactive(start: .area, kind: .area)
    }

    public func captureWindow() async throws -> CaptureResult {
        try await interactive(start: .window, kind: .window)
    }

    public func captureFullscreen(display: CGDirectDisplayID? = nil) async throws -> CaptureResult {
        try await requirePermission()
        let all = services.displays()
        let target = display ?? displayUnderMouse(all)?.id ?? CGMainDisplayID()
        guard let d = all.first(where: { $0.id == target }) else { throw CaptureError.noDisplay }
        let g = try await services.grabDisplay(d, options)
        try Task.checkCancellation()
        return CaptureResult(image: g.image, scale: g.scale, displayID: d.id, rect: d.frame,
                             kind: .fullscreen, windowInfo: nil)
    }

    public func captureLastArea() async throws -> CaptureResult {
        try await requirePermission()
        guard let r = lastArea else { throw CaptureError.noLastArea }
        return try await grabArea(r, kind: .lastArea)
    }

    /// Selection (if the mode needs one) happens first, then a countdown, then the grab.
    /// `onTick` is called each second with the remaining seconds.
    public func captureWithTimer(seconds: Int, mode: TimedCaptureMode,
                                 onTick: ((Int) -> Void)? = nil) async throws -> CaptureResult {
        try await requirePermission()
        var selection: Selection?
        // No freezing: the grab happens live after the countdown, so menus can be opened meanwhile.
        switch mode {
        case .area: selection = try await select(.area, freeze: false)
        case .window: selection = try await select(.window, freeze: false)
        case .fullscreen, .lastArea: break
        }
        var remaining = max(seconds, 0)
        while remaining > 0 {
            onTick?(remaining)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            remaining -= 1
        }
        onTick?(0)
        if let selection { return try await grab(selection, kind: mode == .window ? .window : .area) }
        return mode == .fullscreen ? try await captureFullscreen() : try await captureLastArea()
    }

    /// Area selection returning the bare image for OCR (Core performs recognition).
    public func captureTextOnly() async throws -> CGImage {
        let r = try await interactive(start: .area, kind: .textOnly)
        return r.image
    }

    /// A scrolling capture using the current options. Keep it to `finish()` or `cancel()` it from elsewhere.
    public func scrollingSession() -> any ScrollingCapture {
        ScrollCaptureSession(snapToEdges: options.snapToEdges, showsCursor: !options.hideCursor)
    }

    /// Select a region, scroll through it, and get one tall stitched image (kind `.scrolling`).
    public func captureScrolling() async throws -> CaptureResult {
        try await scrollingSession().run()
    }

    // MARK: Internals

    private func requirePermission() async throws {
        try CaptureSignposts.measure("PermissionCheck") { try services.permission() }
        try Task.checkCancellation()
    }

    /// Shared with screen recording, which needs the same Screen Recording grant.
    static func requirePermission() throws {
        let granted = ScreenRecordingPermission.refreshGrant()
        guard granted else {
            // A stale entry is recovered from the app's permissions window, not by reopening Settings.
            if !ScreenRecordingPermission.needsReauthorization(granted: granted) {
                ScreenRecordingPermission.ensure()
            }
            throw CaptureError.permissionDenied
        }
    }

    private func select(_ mode: OverlayStartMode,
                        freeze: Bool = true) async throws -> Selection {
        let presented = onSelectionPresented
        onSelectionPresented = nil
        var selection = try await services.select(mode, lastArea, options, freeze, presented)
        try Task.checkCancellation()
        selection.frozen = freeze ? selection.frozen ?? [] : nil
        return selection
    }

    private func interactive(start: OverlayStartMode, kind: CaptureKind) async throws -> CaptureResult {
        try await requirePermission()
        let selection = try await select(start)
        return try await CaptureSignposts.measure("SelectionToImage") {
            try await grab(selection, kind: kind)
        }
    }

    /// A non-nil `selection.frozen` requires the pre-focus pixels, including when a requested display is missing.
    private func grab(_ selection: Selection, kind: CaptureKind) async throws -> CaptureResult {
        try Task.checkCancellation()
        let frozen = selection.frozen
        switch selection.outcome {
        case .area(let r, let displayID):
            if let frozen {
                let result = try frozenResult(r, kind: kind, frozen: frozen, displayID: displayID)
                lastArea = r
                return result
            }
            lastArea = r
            try await settle(options.settleDelay, since: selection.closedAt)
            return try await grabArea(r, kind: kind)
        case .window(let w):
            let windowKind: CaptureKind = kind == .textOnly ? .textOnly : .window
            // The vanished-window probe also reads the live frame, which gates reusing the freeze's window.
            var liveFrame: CGRect?
            if let frozen {
                liveFrame = w.layer == 0 ? services.onScreenFrame(w.id) : nil
                if liveFrame == nil { return try frozenResult(w.frame, kind: windowKind, frozen: frozen, window: w) }
            }
            let waited = try await settle(options.windowSettleDelay, since: selection.closedAt)
            let displays = services.displays()
            let d = CaptureGeometry.index(containing: CGPoint(x: w.frame.midX, y: w.frame.midY),
                                          in: displays.map(\.frame)).map { displays[$0] }
            // The window can change during a real wait, after the frame it is checked against was read.
            let known = waited ? nil : ImageGrabber.reusable(selection.windows[w.id], liveFrame: liveFrame)
            do {
                let g = try await services.grabWindow(w, d?.scale ?? 2, options, known)
                try Task.checkCancellation()
                return CaptureResult(image: g.image, scale: g.scale, displayID: d?.id ?? CGMainDisplayID(),
                                     rect: w.frame, kind: windowKind, windowInfo: w)
            } catch is CancellationError {
                throw CancellationError()
            } catch CaptureError.cancelled {
                throw CaptureError.cancelled
            } catch {
                try Task.checkCancellation()
                if let frozen {
                    return try frozenResult(w.frame, kind: windowKind, frozen: frozen, window: w)
                }
                throw error
            }
        }
    }

    /// Waits only for what is left of `delay` since the overlay closed. Returns whether it waited at all.
    @discardableResult
    private func settle(_ delay: TimeInterval, since closedAt: ContinuousClock.Instant?) async throws -> Bool {
        let wait = CaptureSettle.remaining(delay, elapsed: closedAt.map { services.now() - $0 })
        try Task.checkCancellation()
        guard wait > .zero else { return false }
        try await services.sleep(wait)
        return true
    }

    /// Uses only the display geometry captured before focus changed, not a fresh display enumeration.
    private func frozenResult(_ r: CGRect, kind: CaptureKind, frozen: [FrozenDisplay],
                              displayID: CGDirectDisplayID? = nil, window: WindowInfo? = nil) throws -> CaptureResult {
        let index: Int?
        if let displayID {
            index = frozen.firstIndex { $0.display.id == displayID }
        } else {
            index = CaptureGeometry.index(containing: CGPoint(x: r.midX, y: r.midY), in: frozen.map(\.display.frame))
        }
        guard let index else { throw CaptureError.noDisplay }
        let display = frozen[index]
        guard let crop = display.crop(r) else { throw CaptureError.invalidRect }
        return CaptureResult(image: crop.grab.image, scale: crop.grab.scale, displayID: display.display.id,
                             rect: crop.rect, kind: kind, windowInfo: window)
    }

    private func grabArea(_ r: CGRect, kind: CaptureKind) async throws -> CaptureResult {
        let displays = services.displays()
        guard r.width >= 1, r.height >= 1 else { throw CaptureError.invalidRect }
        guard let i = CaptureGeometry.index(containing: CGPoint(x: r.midX, y: r.midY), in: displays.map(\.frame)) else {
            throw CaptureError.noDisplay
        }
        let d = displays[i]
        let clipped = r.intersection(d.frame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { throw CaptureError.invalidRect }
        let g = try await services.grabRect(clipped, d, options)
        try Task.checkCancellation()
        return CaptureResult(image: g.image, scale: g.scale, displayID: d.id, rect: clipped, kind: kind, windowInfo: nil)
    }

    private func displayUnderMouse(_ all: [DisplayInfo]) -> DisplayInfo? {
        let h = NSScreen.screens.first?.frame.height ?? 0
        let p = CaptureGeometry.appKitToCG(NSEvent.mouseLocation, primaryHeight: h)
        return CaptureGeometry.index(containing: p, in: all.map(\.frame)).map { all[$0] }
    }
}
