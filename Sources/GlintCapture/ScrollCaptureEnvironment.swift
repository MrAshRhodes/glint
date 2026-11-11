import AppKit
import GlintCore
import ScreenCaptureKit

/// Grabs the region of a scrolling capture. `signature()` is a cheap, low-resolution look used about ten times a
/// second to notice scrolling; `frame()` is the full-resolution grab that goes to the stitcher.
/// `signature(of:)` makes the signature of a grabbed frame, comparable with `signature()`, so the reference for
/// later looks is exactly the snapshot the stitcher accepted.
protocol ScrollFrameSource: AnyObject {
    func signature() async throws -> ScrollSignature
    func frame() async throws -> CGImage
    func signature(of frame: CGImage) -> ScrollSignature?
}

/// Delivers one bounded step, never a repeating timer. The session decides when another step is safe.
@MainActor
protocol ScrollDriving: AnyObject {
    func scroll(by points: CGFloat) throws
    func stop()
}

struct ScrollAutoScrollTiming {
    var settleInterval: TimeInterval = 0.25
    var responseTimeout: TimeInterval = 2
    var noMovementLimit = 3
    var maxSteps = 200
    var maxDuration: TimeInterval = 120
}

/// What the scrolling-capture controls show.
struct ScrollCaptureStatus: Equatable {
    var frames = 0
    /// Height of the stitched image in pixels.
    var height = 0
    /// 0...1 of the height limit.
    var progress = 0.0
    var isNearLimit = false
    var canUndo = false
    /// Set while the capture is paused, waiting for the user to decide.
    var warning: ScrollStitchWarning?
    var isAutomatic = false
    var pace: ScrollCapturePace = .ready
    /// Automatic scrolling has stopped; completion must be confirmed rather than assuming this is the bottom.
    var automaticStop: String?
    /// Automatic scrolling is unavailable, but manual frame capture is still running.
    var manualFallback: String?

    var isPaused: Bool { warning != nil || automaticStop != nil }
    var pauseMessage: String? { warning?.message ?? automaticStop }
    var isAtLimit: Bool { warning == .heightLimit }
    /// Retry only makes sense for a join that was kept but may be wrong.
    var canRetry: Bool {
        if case .lowConfidence = warning { return true }
        return false
    }
}

/// What the on-screen controls can ask of the session.
struct ScrollCaptureControlActions {
    var done: () -> Void
    var undo: () -> Void
    var cancel: () -> Void
    /// Continues after a warning from what is on screen now, keeping what was stitched.
    var resume: () -> Void
    /// Drops the last join and grabs the current screen again.
    var retry: () -> Void
}

/// The on-screen side of a scrolling capture: the frame around the region and the controls beside it.
@MainActor
protocol ScrollCapturePresenting: AnyObject {
    func show(region: RecordingRegion, actions: ScrollCaptureControlActions)
    /// `preview` is a thumbnail of the stitched image so far.
    func update(_ status: ScrollCaptureStatus, preview: CGImage?)
    func dismiss()
}

/// The pieces a `ScrollCaptureSession` talks to. Tests replace them so the flow runs without a display, without
/// Screen Recording permission and without real time passing.
struct ScrollCaptureEnvironment {
    var requirePermission: @MainActor () throws -> Void
    var makePicker: @MainActor (_ snapToEdges: Bool) -> any RegionPicking
    var makePresenter: @MainActor () -> any ScrollCapturePresenting
    var makeSource: @MainActor (RecordingRegion, _ showsCursor: Bool) async throws -> any ScrollFrameSource
    var sleep: @Sendable (TimeInterval) async throws -> Void
    var now: @MainActor () -> TimeInterval
    /// Time between two looks at the region.
    var pollInterval: TimeInterval = 0.1
    var limits = ScrollStitchLimits()
    var automaticTiming = ScrollAutoScrollTiming()
    var makeScroller: @MainActor (RecordingRegion) throws -> any ScrollDriving = {
        try LiveScrollDriver(region: $0)
    }

    @MainActor
    static var live: ScrollCaptureEnvironment {
        ScrollCaptureEnvironment(
            requirePermission: { try ScreenCapturer.requirePermission() },
            makePicker: { SelectionRegionPicker(snapToEdges: $0) },
            makePresenter: { ScrollCaptureOverlayPresenter() },
            makeSource: { try await LiveScrollFrameSource.make(region: $0, showsCursor: $1) },
            sleep: { try await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1_000_000_000)) },
            now: { ProcessInfo.processInfo.systemUptime })
    }
}

/// A pixel-wheel event addressed only to the original application and a point inside the selected region.
/// Re-checking the window under that point prevents scrolling a replacement window or a different app.
@MainActor
final class LiveScrollDriver: ScrollDriving {
    struct Target: Equatable {
        let pid: pid_t
        let windowID: CGWindowID
        let bounds: CGRect
    }

    private let point: CGPoint
    private let target: Target
    private var stopped = false

    init(region: RecordingRegion) throws {
        point = CGPoint(x: region.rect.midX, y: region.rect.midY)
        guard let target = Self.target(at: point) else {
            throw CaptureError.failed("No application window was found inside the selected region.")
        }
        self.target = target
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            throw CaptureError.failed("Allow Glint in Privacy & Security → Accessibility to scroll automatically.")
        }
    }

    func scroll(by points: CGFloat) throws {
        guard !stopped else { return }
        guard CGPreflightPostEventAccess() else {
            throw CaptureError.failed("Accessibility permission is required for automatic scrolling.")
        }
        guard Self.target(at: point) == target else {
            throw CaptureError.failed("The selected window moved, closed, or was covered.")
        }
        guard let event = Self.event(at: point, points: points) else {
            throw CaptureError.failed("Could not create a scrolling event.")
        }
        event.postToPid(target.pid)
    }

    func stop() { stopped = true }

    /// Kept separate so direction and coordinates can be checked without posting an event.
    static func event(at point: CGPoint, points: CGFloat) -> CGEvent? {
        guard points.isFinite, points > 0,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: -Int32(min(max(points.rounded(), 1), 120)), wheel2: 0, wheel3: 0)
        else { return nil }
        event.location = point
        event.flags = []
        return event
    }

    private static func target(at point: CGPoint) -> Target? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        return target(at: point, windows: windows, excluding: ProcessInfo.processInfo.processIdentifier)
    }

    static func target(at point: CGPoint, windows: [[String: Any]], excluding ownPID: pid_t) -> Target? {
        for window in windows {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0, pid != ownPID,
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point),
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0 else { continue }
            return Target(pid: pid, windowID: id, bounds: rect)
        }
        return nil
    }
}

/// Grabs the region with ScreenCaptureKit, leaving out every window of Glint (the frame and controls).
final class LiveScrollFrameSource: ScrollFrameSource {
    /// Width of the image a signature is made from; small enough to grab often.
    static let signatureWidth = 128

    private let filter: SCContentFilter
    private let sourceRect: CGRect
    private let pixelSize: (width: Int, height: Int)
    private let showsCursor: Bool

    private init(filter: SCContentFilter, sourceRect: CGRect, scale: CGFloat, showsCursor: Bool) {
        self.filter = filter
        self.sourceRect = sourceRect
        pixelSize = (max(Int((sourceRect.width * scale).rounded()), 1), max(Int((sourceRect.height * scale).rounded()), 1))
        self.showsCursor = showsCursor
    }

    @MainActor
    static func make(region: RecordingRegion, showsCursor: Bool) async throws -> LiveScrollFrameSource {
        let content: SCShareableContent
        do {
            content = try await WindowEnumerator.shareableContent()
        } catch {
            throw ScreenRecorder.captureError(from: error)
        }
        guard let display = content.displays.first(where: { $0.displayID == region.display.id }) else {
            throw CaptureError.noDisplay
        }
        let local = CaptureGeometry.displayLocal(region.rect, display: region.display.frame, scale: region.display.scale)
        return LiveScrollFrameSource(filter: ScreenRecorder.filter(for: display, in: content), sourceRect: local,
                                     scale: region.display.scale, showsCursor: showsCursor)
    }

    func signature() async throws -> ScrollSignature {
        let (width, height) = signatureSize
        // The pointer is never part of the signature: moving it must not count as scrolling.
        let image = try await grab(width: width, height: height, showsCursor: false)
        guard let signature = ScrollSignature(image: image) else { throw CaptureError.failed("Could not read the screen.") }
        return signature
    }

    func frame() async throws -> CGImage {
        try await grab(width: pixelSize.width, height: pixelSize.height, showsCursor: showsCursor)
    }

    func signature(of frame: CGImage) -> ScrollSignature? {
        // Reduce to the size `signature()` grabs first, so both follow the same path to the signature.
        let (width, height) = signatureSize
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ColorSpaces.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage().flatMap { ScrollSignature(image: $0) }
    }

    private var signatureSize: (width: Int, height: Int) {
        let width = min(Self.signatureWidth, pixelSize.width)
        return (width, max(Int((Double(width) * Double(pixelSize.height) / Double(pixelSize.width)).rounded()), 1))
    }

    private func grab(width: Int, height: Int, showsCursor: Bool) async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = width
        config.height = height
        config.scalesToFit = width != pixelSize.width
        config.showsCursor = showsCursor
        config.colorSpaceName = CGColorSpace.sRGB
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw ScreenRecorder.captureError(from: error)
        }
    }
}
