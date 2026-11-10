import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit

/// A display grabbed before the overlay appeared, while other apps' menus and pop-ups were still open.
struct FrozenDisplay {
    let display: DisplayInfo
    let image: CGImage

    /// `rect` (global points) cropped from the frozen pixels, with the part of `rect` it covers.
    func crop(_ rect: CGRect) -> (grab: ImageGrabber.Grab, rect: CGRect)? {
        guard let crop = CaptureGeometry.pixelCrop(rect, display: display.frame,
                                                   imageSize: CGSize(width: image.width, height: image.height)),
              let cropped = image.cropping(to: crop.pixels) else { return nil }
        return (ImageGrabber.Grab(image: Self.detached(cropped), scale: crop.scale), rect.intersection(display.frame))
    }

    /// `cropping(to:)` shares the source's backing store; copy so the full display snapshot can be released.
    static func detached(_ image: CGImage) -> CGImage {
        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return image }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}

/// What the capture path reads from a ScreenCaptureKit window, so tests can stand in for `SCWindow`.
protocol QueriedWindow {
    var windowID: CGWindowID { get }
    var frame: CGRect { get }
}

extension SCWindow: QueriedWindow {}

/// ScreenCaptureKit first, with a subprocess fallback only when it can honor the window policy.
enum ImageGrabber {
    struct Grab { let image: CGImage; let scale: CGFloat }

    /// One shareable-content query with the window policy applied, reusable for every display it lists.
    struct ScreenContent {
        let content: SCShareableContent
        let excluded: [SCWindow]

        init(_ content: SCShareableContent, options: CaptureOptions) {
            let me = ProcessInfo.processInfo.processIdentifier
            self.content = content
            excluded = content.windows.filter {
                options.excludesWindow($0.windowID, pid: $0.owningApplication?.processID, ownPID: me)
            }
        }

        static func current(options: CaptureOptions) async throws -> ScreenContent {
            let content = try await WindowEnumerator.shareableContent()
            return ScreenContent(content, options: options)
        }

        func grab(_ rect: CGRect, display: DisplayInfo, options: CaptureOptions) async throws -> Grab {
            guard let scd = content.displays.first(where: { $0.displayID == display.id }) else { throw CaptureError.noDisplay }
            let filter = SCContentFilter(display: scd, excludingWindows: excluded)
            let cfg = SCStreamConfiguration()
            let local = CaptureGeometry.displayLocal(rect, display: display.frame, scale: display.scale)
            cfg.sourceRect = local
            cfg.width = Int((local.width * display.scale).rounded())
            cfg.height = Int((local.height * display.scale).rounded())
            cfg.showsCursor = !options.hideCursor
            cfg.scalesToFit = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            return Grab(image: img, scale: display.scale)
        }
    }

    static func grabRect(_ rect: CGRect, display: DisplayInfo, options: CaptureOptions) async throws -> Grab {
        try await captureWithFallback(allowed: allowsRectFallback(options), capture: {
            try await ScreenContent.current(options: options).grab(rect, display: display, options: options)
        }, fallback: {
            let r = rect.integral
            let args = ["-x", "-R", "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"]
                + (options.hideCursor ? [] : ["-C"])
            return Grab(image: try await runScreencapture(args), scale: display.scale)
        })
    }

    static func grabDisplay(_ display: DisplayInfo, options: CaptureOptions) async throws -> Grab {
        try await grabRect(display.frame, display: display, options: options)
    }

    /// All required displays are frozen in memory before focus changes, or the entire capture fails.
    /// The windows of that same content query come back too, so a window picked afterwards needs no second query.
    static func freezeKeepingWindows(
        _ displays: [DisplayInfo], options: CaptureOptions
    ) async throws -> (displays: [FrozenDisplay], windows: [CGWindowID: any QueriedWindow]) {
        var windows: [CGWindowID: any QueriedWindow] = [:]
        let frozen = try await freeze(displays, options: options, content: {
            let screenContent = try await ScreenContent.current(options: options)
            windows = Dictionary(screenContent.content.windows.map { ($0.windowID, $0 as any QueriedWindow) },
                                 uniquingKeysWith: { first, _ in first })
            return screenContent
        }, capture: { display, options, content in
            try await content.grab(display.frame, display: display, options: options)
        })
        return (frozen, windows)
    }

    /// Fetches the content once for every display: each query is a slow round trip on the way to the overlay.
    static func freeze<Snapshot>(
        _ displays: [DisplayInfo], options: CaptureOptions,
        content: () async throws -> Snapshot,
        capture: @escaping @Sendable (DisplayInfo, CaptureOptions, Snapshot) async throws -> Grab
    ) async throws -> [FrozenDisplay] {
        try Task.checkCancellation()
        guard !displays.isEmpty else { throw CaptureError.noDisplay }
        let snapshot = try await content()
        return try await freeze(displays, options: options) { display, options in
            do {
                return try await capture(display, options, snapshot)
            } catch {
                // As in captureWithFallback, a cancelled freeze reports cancellation rather than the failed grab.
                try Task.checkCancellation()
                throw error
            }
        }
    }

    static func freeze(
        _ displays: [DisplayInfo], options: CaptureOptions,
        capture: @escaping @Sendable (DisplayInfo, CaptureOptions) async throws -> Grab
    ) async throws -> [FrozenDisplay] {
        try Task.checkCancellation()
        guard !displays.isEmpty else { throw CaptureError.noDisplay }
        var inMemoryOptions = options
        inMemoryOptions.allowScreencaptureFallback = false
        let captureOptions = inMemoryOptions
        return try await withThrowingTaskGroup(of: (Int, FrozenDisplay).self) { group in
            for (index, display) in displays.enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    let grab = try await capture(display, captureOptions)
                    try Task.checkCancellation()
                    return (index, FrozenDisplay(display: display, image: grab.image))
                }
            }
            var frozen: [(Int, FrozenDisplay)] = []
            for try await display in group {
                frozen.append(display)
            }
            try Task.checkCancellation()
            return frozen.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// `known` is the window from the freeze-time content query. It saves the second query when still valid;
    /// a window the freeze did not list, or that fails to capture, gets one fresh query.
    static func grabWindow(_ win: WindowInfo, scale: CGFloat, options: CaptureOptions,
                           known: (any QueriedWindow)? = nil) async throws -> Grab {
        try Task.checkCancellation()
        guard !options.excludesWindow(win.id, pid: win.pid, ownPID: ProcessInfo.processInfo.processIdentifier) else {
            throw CaptureError.windowNotFound
        }
        let knownWindow = known.flatMap { $0.windowID == win.id ? $0 as? SCWindow : nil }
        return try await captureWithFallback(allowed: options.allowScreencaptureFallback, capture: {
            try await grabResolvingWindow(known: knownWindow, fresh: {
                try await WindowEnumerator.shareableContent().windows.first { $0.windowID == win.id }
            }, grab: { w in
                let filter = SCContentFilter(desktopIndependentWindow: w)
                let cfg = SCStreamConfiguration()
                cfg.width = Int((w.frame.width * scale).rounded())
                cfg.height = Int((w.frame.height * scale).rounded())
                cfg.showsCursor = !options.hideCursor
                cfg.ignoreShadowsSingleWindow = !options.includeWindowShadow
                cfg.backgroundColor = .clear
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                return Grab(image: img, scale: scale)
            })
        }, fallback: {
            // -o drops the shadow, -l captures a single window by id.
            let args = ["-x", "-l", "\(win.id)"] + (options.includeWindowShadow ? [] : ["-o"])
                + (options.hideCursor ? [] : ["-C"])
            return Grab(image: try await runScreencapture(args), scale: scale)
        })
    }

    /// The freeze-time window only while its size still matches the live window: the grab is sized from it,
    /// so a window resized since the freeze must come from a fresh query instead.
    static func reusable(_ known: (any QueriedWindow)?, liveFrame: CGRect?) -> (any QueriedWindow)? {
        guard let known, let liveFrame,
              abs(known.frame.width - liveFrame.width) < 0.01,
              abs(known.frame.height - liveFrame.height) < 0.01 else { return nil }
        return known
    }

    /// Grabs with `known` when there is one. If that fails, or there was none, the window is looked up once more:
    /// a missing window is gone (`windowNotFound`), anything else is retried on what the lookup returns.
    static func grabResolvingWindow<Window>(
        known: Window?, fresh: () async throws -> Window?, grab: (Window) async throws -> Grab
    ) async throws -> Grab {
        try Task.checkCancellation()
        if let known {
            do {
                return try await grab(known)
            } catch {
                try Task.checkCancellation()
                if isCancellation(error) { throw error }
            }
        }
        guard let window = try await fresh() else { throw CaptureError.windowNotFound }
        return try await grab(window)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case CaptureError.cancelled = error { return true }
        return false
    }

    static func allowsRectFallback(_ options: CaptureOptions) -> Bool {
        // A raw screen region cannot exclude individual windows or an owning process.
        options.allowScreencaptureFallback && !options.excludeOwnWindows && options.excludedWindowIDs.isEmpty
    }

    static func captureWithFallback(
        allowed: Bool, capture: () async throws -> Grab, fallback: () async throws -> Grab
    ) async throws -> Grab {
        try Task.checkCancellation()
        do {
            let grab = try await capture()
            try Task.checkCancellation()
            return grab
        } catch {
            try Task.checkCancellation()
            if isCancellation(error) { throw error }
            guard allowed else { throw error }
            let grab = try await fallback()
            try Task.checkCancellation()
            return grab
        }
    }

    private static func runScreencapture(_ args: [String]) async throws -> CGImage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let status: Int32 = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = args + [url.path]
                do { try p.run(); p.waitUntilExit(); cont.resume(returning: p.terminationStatus) }
                catch { cont.resume(returning: -1) }
            }
        }
        guard status == 0, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw CaptureError.failed("screencapture fallback failed (status \(status))")
        }
        return img
    }
}
