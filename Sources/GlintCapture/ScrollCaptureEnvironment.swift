import AppKit
import GlintCore
import ScreenCaptureKit

/// Grabs the region of a scrolling capture. `signature()` is a cheap, low-resolution look used about ten times a
/// second to notice scrolling; `frame()` is the full-resolution grab that goes to the stitcher.
protocol ScrollFrameSource: AnyObject {
    func signature() async throws -> ScrollSignature
    func frame() async throws -> CGImage
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

    var isPaused: Bool { warning != nil }
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
        let width = min(Self.signatureWidth, pixelSize.width)
        let height = max(Int((Double(width) * Double(pixelSize.height) / Double(pixelSize.width)).rounded()), 1)
        // The pointer is never part of the signature: moving it must not count as scrolling.
        let image = try await grab(width: width, height: height, showsCursor: false)
        guard let signature = ScrollSignature(image: image) else { throw CaptureError.failed("Could not read the screen.") }
        return signature
    }

    func frame() async throws -> CGImage {
        try await grab(width: pixelSize.width, height: pixelSize.height, showsCursor: showsCursor)
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
