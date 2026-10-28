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
        return (ImageGrabber.Grab(image: cropped, scale: crop.scale), rect.intersection(display.frame))
    }
}

/// Low-level pixel grabbing: ScreenCaptureKit first, /usr/sbin/screencapture as fallback.
enum ImageGrabber {
    struct Grab { let image: CGImage; let scale: CGFloat }

    static func grabRect(_ rect: CGRect, display: DisplayInfo, options: CaptureOptions) async throws -> Grab {
        do {
            let content = try await WindowEnumerator.shareableContent()
            guard let scd = content.displays.first(where: { $0.displayID == display.id }) else { throw CaptureError.noDisplay }
            let me = ProcessInfo.processInfo.processIdentifier
            let own = content.windows.filter { $0.owningApplication?.processID == me }
            let filter = SCContentFilter(display: scd, excludingWindows: own)
            let cfg = SCStreamConfiguration()
            let local = CaptureGeometry.displayLocal(rect, display: display.frame, scale: display.scale)
            cfg.sourceRect = local
            cfg.width = Int((local.width * display.scale).rounded())
            cfg.height = Int((local.height * display.scale).rounded())
            cfg.showsCursor = !options.hideCursor
            cfg.scalesToFit = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            return Grab(image: img, scale: display.scale)
        } catch {
            guard options.allowScreencaptureFallback else { throw error }
            let r = rect.integral
            let args = ["-x", "-R", "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"]
                + (options.hideCursor ? [] : ["-C"])
            return Grab(image: try await runScreencapture(args), scale: display.scale)
        }
    }

    static func grabDisplay(_ display: DisplayInfo, options: CaptureOptions) async throws -> Grab {
        try await grabRect(display.frame, display: display, options: options)
    }

    /// Grabs every display concurrently. A display whose grab fails is left out and captured live later.
    static func freeze(_ displays: [DisplayInfo], options: CaptureOptions) async -> [FrozenDisplay] {
        await withTaskGroup(of: FrozenDisplay?.self) { group in
            for display in displays {
                group.addTask {
                    guard let grab = try? await grabDisplay(display, options: options) else { return nil }
                    return FrozenDisplay(display: display, image: grab.image)
                }
            }
            var frozen: [FrozenDisplay] = []
            for await display in group {
                if let display { frozen.append(display) }
            }
            return frozen
        }
    }

    static func grabWindow(_ win: WindowInfo, scale: CGFloat, options: CaptureOptions) async throws -> Grab {
        do {
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
        } catch {
            guard options.allowScreencaptureFallback else { throw error }
            // -o drops the shadow, -l captures a single window by id.
            let args = ["-x", "-l", "\(win.id)"] + (options.includeWindowShadow ? [] : ["-o"])
                + (options.hideCursor ? [] : ["-C"])
            return Grab(image: try await runScreencapture(args), scale: scale)
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
