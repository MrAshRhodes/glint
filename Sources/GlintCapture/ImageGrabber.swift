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
    static func freeze(_ displays: [DisplayInfo], options: CaptureOptions) async throws -> [FrozenDisplay] {
        try await freeze(displays, options: options, content: {
            try await ScreenContent.current(options: options)
        }, capture: { display, options, content in
            try await content.grab(display.frame, display: display, options: options)
        })
    }

    /// Fetches the content once for every display: each query is a slow round trip on the way to the overlay.
    static func freeze<Snapshot>(
        _ displays: [DisplayInfo], options: CaptureOptions,
        content: () async throws -> Snapshot,
        capture: @escaping @Sendable (DisplayInfo, CaptureOptions, Snapshot) async throws -> Grab
    ) async throws -> [FrozenDisplay] {
        try Task.checkCancellation()
        guard !displays.isEmpty else { throw CaptureError.noDisplay }
        let snapshot: Snapshot
        do {
            snapshot = try await content()
        } catch {
            try Task.checkCancellation()
            throw permissionDenial(error) ?? error
        }
        return try await freeze(displays, options: options) { display, options in
            do {
                return try await capture(display, options, snapshot)
            } catch {
                // As in captureWithFallback, a cancelled freeze reports cancellation rather than the failed grab.
                try Task.checkCancellation()
                throw permissionDenial(error) ?? error
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

    static func grabWindow(_ win: WindowInfo, scale: CGFloat, options: CaptureOptions) async throws -> Grab {
        try Task.checkCancellation()
        guard !options.excludesWindow(win.id, pid: win.pid, ownPID: ProcessInfo.processInfo.processIdentifier) else {
            throw CaptureError.windowNotFound
        }
        return try await captureWithFallback(allowed: options.allowScreencaptureFallback, capture: {
            let content = try await WindowEnumerator.shareableContent()
            guard let w = content.windows.first(where: { $0.windowID == win.id }) else { throw CaptureError.windowNotFound }
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let cfg = SCStreamConfiguration()
            cfg.width = Int((w.frame.width * scale).rounded())
            cfg.height = Int((w.frame.height * scale).rounded())
            cfg.showsCursor = !options.hideCursor
            cfg.ignoreShadowsSingleWindow = !options.includeWindowShadow
            cfg.backgroundColor = .clear
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            return Grab(image: img, scale: scale)
        }, fallback: {
            // -o drops the shadow, -l captures a single window by id.
            let args = ["-x", "-l", "\(win.id)"] + (options.includeWindowShadow ? [] : ["-o"])
                + (options.hideCursor ? [] : ["-C"])
            return Grab(image: try await runScreencapture(args), scale: scale)
        })
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
            if error is CancellationError { throw error }
            if case CaptureError.cancelled = error { throw error }
            // A refusal is not something the screencapture subprocess can repair, and it must open the permissions window.
            if let denial = permissionDenial(error) { throw denial }
            guard allowed else { throw error }
            let grab = try await fallback()
            try Task.checkCancellation()
            return grab
        }
    }

    /// ScreenCaptureKit reports a declined Screen Recording grant as an ordinary error; map it to
    /// `.permissionDenied` (as recording and scroll capture do) and leave every other error untouched.
    static func permissionDenial(_ error: Error) -> CaptureError? {
        guard case .permissionDenied = ScreenRecorder.captureError(from: error) else { return nil }
        return .permissionDenied
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
