import AppKit

@MainActor
public final class ScreenCapturer {
    public static let shared = ScreenCapturer()
    public var options = CaptureOptions()

    private let lastAreaKey = "glint.lastCaptureArea"
    public init() {}

    /// Last area in global (top-left origin) display coordinates.
    public var lastArea: CGRect? {
        get {
            guard let a = UserDefaults.standard.array(forKey: lastAreaKey) as? [Double], a.count == 4 else { return nil }
            return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        }
        set {
            if let r = newValue {
                UserDefaults.standard.set([r.minX, r.minY, r.width, r.height].map(Double.init), forKey: lastAreaKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastAreaKey)
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
        let all = WindowEnumerator.displays()
        let target = display ?? displayUnderMouse(all)?.id ?? CGMainDisplayID()
        guard let d = all.first(where: { $0.id == target }) else { throw CaptureError.noDisplay }
        let g = try await ImageGrabber.grabDisplay(d, options: options)
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
        switch mode {
        case .area: outcome = try await select(.area)
        case .window: outcome = try await select(.window)
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

    // MARK: Internals

    private func requirePermission() async throws {
        let granted = ScreenRecordingPermission.refreshGrant()
        guard granted else {
            // A stale entry is recovered from the app's permissions window, not by reopening Settings.
            if !ScreenRecordingPermission.needsReauthorization(granted: granted) {
                ScreenRecordingPermission.ensure()
            }
            throw CaptureError.permissionDenied
        }
    }

    private func select(_ mode: OverlayStartMode) async throws -> SelectionOutcome {
        let session = SelectionSession(mode: mode, lastArea: lastArea)
        return try await session.run()
    }

    private func interactive(start: OverlayStartMode, kind: CaptureKind) async throws -> CaptureResult {
        try await requirePermission()
        let outcome = try await select(start)
        return try await grab(outcome, kind: kind)
    }

    private func grab(_ outcome: SelectionOutcome, kind: CaptureKind) async throws -> CaptureResult {
        try await Task.sleep(nanoseconds: UInt64(options.settleDelay * 1_000_000_000)) // let overlay vanish
        switch outcome {
        case .area(let r, _):
            lastArea = r
            return try await grabArea(r, kind: kind)
        case .window(let w):
            let displays = WindowEnumerator.displays()
            let d = CaptureGeometry.index(containing: CGPoint(x: w.frame.midX, y: w.frame.midY),
                                          in: displays.map(\.frame)).map { displays[$0] }
            let g = try await ImageGrabber.grabWindow(w, scale: d?.scale ?? 2, options: options)
            return CaptureResult(image: g.image, scale: g.scale, displayID: d?.id ?? CGMainDisplayID(),
                                 rect: w.frame, kind: kind == .textOnly ? .textOnly : .window, windowInfo: w)
        }
    }

    private func grabArea(_ r: CGRect, kind: CaptureKind) async throws -> CaptureResult {
        let displays = WindowEnumerator.displays()
        guard r.width >= 1, r.height >= 1 else { throw CaptureError.invalidRect }
        guard let i = CaptureGeometry.index(containing: CGPoint(x: r.midX, y: r.midY), in: displays.map(\.frame)) else {
            throw CaptureError.noDisplay
        }
        let d = displays[i]
        let clipped = r.intersection(d.frame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { throw CaptureError.invalidRect }
        let g = try await ImageGrabber.grabRect(clipped, display: d, options: options)
        return CaptureResult(image: g.image, scale: g.scale, displayID: d.id, rect: clipped, kind: kind, windowInfo: nil)
    }

    private func displayUnderMouse(_ all: [DisplayInfo]) -> DisplayInfo? {
        let h = NSScreen.screens.first?.frame.height ?? 0
        let p = CaptureGeometry.appKitToCG(NSEvent.mouseLocation, primaryHeight: h)
        return CaptureGeometry.index(containing: p, in: all.map(\.frame)).map { all[$0] }
    }
}
