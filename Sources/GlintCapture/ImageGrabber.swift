import AppKit
import CoreGraphics
import GlintCore
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

    /// One shareable-content snapshot with the window policy applied, reusable for every display it lists. It is the
    /// kept one when that can serve the capture (see `ContentReuse`), else a new query.
    struct ScreenContent {
        /// How the filter leaves Glint's windows out of the pixels.
        enum Exclusion {
            case applications([SCRunningApplication])
            case windows([SCWindow])
        }

        let content: SCShareableContent
        let exclusion: Exclusion
        /// Where `content` came from, so a capture that fails with it can drop it from the cache.
        let entry: ShareableContentCache.Entry
        /// The snapshot is older than the request for it: it was kept, or it was a query already under way.
        let isCached: Bool

        static func current(options: CaptureOptions, displays: [DisplayInfo],
                            cache: ContentCache<SCShareableContent> = ShareableContentCache.shared) async throws -> ScreenContent {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let (entry, isCached) = try await cache.snapshot(for: cache.now()) { entry, predatesRequest in
                servedExclusion(of: entry, options: options, displays: displays, ownPID: ownPID,
                                predatesRequest: predatesRequest) != nil
            }
            let facts = ContentFacts(entry.snapshot, ownPID: ownPID)
            let cached = isCached ? ContentReuse.cachedExclusion(for: options, in: facts, ownPID: ownPID,
                                                                 liveOwner: WindowEnumerator.ownerPID(of:)) : nil
            ContentCacheSignposts.event(isCached ? "ShareableContentKept" : "ShareableContentQueried",
                                        "displays=\(displays.count)")
            return ScreenContent(entry: entry, isCached: isCached,
                                 decision: cached ?? ContentReuse.exclusion(for: options, in: facts, ownPID: ownPID),
                                 options: options, ownPID: ownPID)
        }

        /// How `entry` leaves windows out for this capture; nil when a snapshot that predates the capture cannot serve it.
        private static func servedExclusion(of entry: ShareableContentCache.Entry, options: CaptureOptions,
                                            displays: [DisplayInfo], ownPID: pid_t,
                                            predatesRequest: Bool) -> ContentExclusion? {
            let facts = ContentFacts(entry.snapshot, ownPID: ownPID)
            guard predatesRequest else { return ContentReuse.exclusion(for: options, in: facts, ownPID: ownPID) }
            guard ContentReuse.lists(displays, in: facts) else { return nil }
            return ContentReuse.cachedExclusion(for: options, in: facts, ownPID: ownPID,
                                                liveOwner: WindowEnumerator.ownerPID(of:))
        }

        private init(entry: ShareableContentCache.Entry, isCached: Bool, decision: ContentExclusion,
                     options: CaptureOptions, ownPID: pid_t) {
            let content = entry.snapshot
            self.content = content
            self.entry = entry
            self.isCached = isCached
            switch decision {
            case .ownApplication where content.applications.contains { $0.processID == ownPID }:
                exclusion = .applications(content.applications.filter { $0.processID == ownPID })
            case .ownApplication:
                exclusion = .windows(content.windows.filter {
                    options.excludesWindow($0.windowID, pid: $0.owningApplication?.processID, ownPID: ownPID)
                })
            case .windows(let ids):
                exclusion = .windows(content.windows.filter { ids.contains($0.windowID) })
            }
        }

        /// Drops this snapshot from the cache, which it failed, and takes a newer one.
        func refreshed(options: CaptureOptions, displays: [DisplayInfo],
                       cache: ContentCache<SCShareableContent> = ShareableContentCache.shared) async throws -> ScreenContent {
            cache.discard(entry)
            ContentCacheSignposts.event("ShareableContentRetried", "displays=\(displays.count)")
            return try await Self.current(options: options, displays: displays, cache: cache)
        }

        /// `work` with the current content; when the content was not queried for this capture and `work` fails, once
        /// more with a new query.
        static func run<Output>(options: CaptureOptions, displays: [DisplayInfo],
                                cache: ContentCache<SCShareableContent> = ShareableContentCache.shared,
                                work: (ScreenContent) async throws -> Output) async throws -> Output {
            try await retryingOnFreshSnapshot(try await current(options: options, displays: displays, cache: cache),
                                              isCached: { $0.isCached },
                                              refresh: { try await $0.refreshed(options: options, displays: displays, cache: cache) },
                                              work: work)
        }

        func grab(_ rect: CGRect, display: DisplayInfo, options: CaptureOptions) async throws -> Grab {
            guard let scd = content.displays.first(where: { $0.displayID == display.id }) else { throw CaptureError.noDisplay }
            let filter: SCContentFilter
            switch exclusion {
            case .applications(let applications):
                filter = SCContentFilter(display: scd, excludingApplications: applications, exceptingWindows: [])
            case .windows(let windows):
                filter = SCContentFilter(display: scd, excludingWindows: windows)
            }
            let cfg = SCStreamConfiguration()
            let local = CaptureGeometry.displayLocal(rect, display: display.frame, scale: display.scale)
            cfg.sourceRect = local
            cfg.width = Int((local.width * display.scale).rounded())
            cfg.height = Int((local.height * display.scale).rounded())
            cfg.showsCursor = !options.hideCursor
            cfg.scalesToFit = false
            let img = try await CaptureSignposts.measure("CaptureImage") {
                try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            }
            return Grab(image: img, scale: display.scale)
        }
    }

    /// Runs `work` on `content`. When `content` was not queried for this capture and `work` fails, it is run once more
    /// on what `refresh` returns: a stale snapshot costs a query, never a failed capture. A cancelled capture is not
    /// retried.
    static func retryingOnFreshSnapshot<Content, Output>(
        _ content: Content, isCached: (Content) -> Bool, refresh: (Content) async throws -> Content,
        work: (Content) async throws -> Output
    ) async throws -> Output {
        do {
            return try await work(content)
        } catch {
            try Task.checkCancellation()
            guard isCached(content), !isCancellation(error) else { throw error }
            return try await work(try await refresh(content))
        }
    }

    static func grabRect(_ rect: CGRect, display: DisplayInfo, options: CaptureOptions) async throws -> Grab {
        try await captureWithFallback(allowed: allowsRectFallback(options), capture: {
            try await ScreenContent.run(options: options, displays: [display]) {
                try await $0.grab(rect, display: display, options: options)
            }
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
            let screenContent = try await ScreenContent.current(options: options, displays: displays)
            windows = Dictionary(screenContent.content.windows.map { ($0.windowID, $0 as any QueriedWindow) },
                                 uniquingKeysWith: { first, _ in first })
            return screenContent
        }, capture: { display, options, content in
            try await retryingOnFreshSnapshot(content, isCached: { $0.isCached },
                                              refresh: { try await $0.refreshed(options: options, displays: displays) },
                                              work: { try await $0.grab(display.frame, display: display, options: options) })
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
                let content = try await CaptureSignposts.measure("ShareableContent") {
                    try await WindowEnumerator.shareableContent()
                }
                return content.windows.first { $0.windowID == win.id }
            }, grab: { w in
                let filter = SCContentFilter(desktopIndependentWindow: w)
                let cfg = SCStreamConfiguration()
                cfg.width = Int((w.frame.width * scale).rounded())
                cfg.height = Int((w.frame.height * scale).rounded())
                cfg.showsCursor = !options.hideCursor
                cfg.ignoreShadowsSingleWindow = !options.includeWindowShadow
                cfg.backgroundColor = .clear
                let img = try await CaptureSignposts.measure("CaptureImage") {
                    try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                }
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
