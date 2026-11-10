import AppKit

@MainActor
public final class ScreenCapturer {
    typealias Selection = (outcome: SelectionOutcome, frozen: [FrozenDisplay]?)

    struct Services {
        var permission: @MainActor () throws -> Void = { try ScreenCapturer.requirePermission() }
        var displays: @MainActor () -> [DisplayInfo] = { WindowEnumerator.displays() }
        var select: @MainActor (OverlayStartMode, CGRect?, CaptureOptions, Bool, (@MainActor () -> Void)?) async throws
            -> Selection = { mode, lastArea, options, freeze, presented in
            let session = SelectionSession(
                mode: mode, lastArea: lastArea, snapToEdges: options.snapToEdges,
                freeze: freeze ? { try await ImageGrabber.freeze($0, options: options) } : nil,
                excludeOwnWindows: options.excludeOwnWindows, excludedWindowIDs: options.excludedWindowIDs,
                onPresented: presented)
            let outcome = try await session.run()
            let frozen = session.takeFrozen()
            try Task.checkCancellation()
            return (outcome, freeze ? frozen : nil)
        }
        var isOnScreen: @MainActor (CGWindowID) -> Bool = { WindowEnumerator.isOnScreen($0) }
        var grabWindow: @MainActor (WindowInfo, CGFloat, CaptureOptions) async throws -> ImageGrabber.Grab = {
            try await ImageGrabber.grabWindow($0, scale: $1, options: $2)
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

    /// Interactive crosshair selection; Space toggles window picking, Esc cancels (throws `.cancelled`).
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
        var outcome: SelectionOutcome?
        // No freezing: the grab happens live after the countdown, so menus can be opened meanwhile.
        switch mode {
        case .area: outcome = try await select(.area, freeze: false).outcome
        case .window: outcome = try await select(.window, freeze: false).outcome
        case .fullscreen, .lastArea: break
        }
        var remaining = max(seconds, 0)
        while remaining > 0 {
            onTick?(remaining)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            remaining -= 1
        }
        onTick?(0)
        if let outcome { return try await grab(outcome, kind: mode == .window ? .window : .area) }
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
        try services.permission()
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
        let selection = try await services.select(mode, lastArea, options, freeze, presented)
        try Task.checkCancellation()
        return (selection.outcome, freeze ? selection.frozen ?? [] : nil)
    }

    private func interactive(start: OverlayStartMode, kind: CaptureKind) async throws -> CaptureResult {
        try await requirePermission()
        let selection = try await select(start)
        return try await grab(selection.outcome, kind: kind, frozen: selection.frozen)
    }

    /// A non-nil `frozen` requires the pre-focus pixels, including when a requested display is missing.
    private func grab(_ outcome: SelectionOutcome, kind: CaptureKind,
                      frozen: [FrozenDisplay]? = nil) async throws -> CaptureResult {
        try Task.checkCancellation()
        switch outcome {
        case .area(let r, let displayID):
            if let frozen {
                let result = try frozenResult(r, kind: kind, frozen: frozen, displayID: displayID)
                lastArea = r
                return result
            }
            lastArea = r
            try await settle()
            return try await grabArea(r, kind: kind)
        case .window(let w):
            let windowKind: CaptureKind = kind == .textOnly ? .textOnly : .window
            if let frozen, w.layer != 0 || !services.isOnScreen(w.id) {
                return try frozenResult(w.frame, kind: windowKind, frozen: frozen, window: w)
            }
            try await settle()
            let displays = services.displays()
            let d = CaptureGeometry.index(containing: CGPoint(x: w.frame.midX, y: w.frame.midY),
                                          in: displays.map(\.frame)).map { displays[$0] }
            do {
                let g = try await services.grabWindow(w, d?.scale ?? 2, options)
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

    private func settle() async throws {
        try await Task.sleep(nanoseconds: UInt64(options.settleDelay * 1_000_000_000)) // let overlay vanish
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
