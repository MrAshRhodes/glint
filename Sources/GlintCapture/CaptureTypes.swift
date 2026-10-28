import AppKit
import CoreGraphics

public enum CaptureKind: String, Sendable, Codable {
    case area, window, fullscreen, lastArea, textOnly
}

/// Modes usable with a countdown timer.
public enum TimedCaptureMode: String, Sendable, Codable {
    case area, window, fullscreen, lastArea
}

public struct CaptureResult {
    public let image: CGImage
    /// Pixels per point of the source display (2 on Retina).
    public let scale: CGFloat
    public let displayID: CGDirectDisplayID
    /// Captured region in global display coordinates (points, origin top-left of the main display).
    public let rect: CGRect
    public let kind: CaptureKind
    public let windowInfo: WindowInfo?

    public var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
}

public struct CaptureOptions: Sendable {
    public var hideCursor: Bool = true
    /// Snap area-selection edges to visible windows and display bounds. Command temporarily inverts this.
    public var snapToEdges: Bool = false
    /// For window capture: keep the system drop shadow (false = shadow-free, transparent corners).
    public var includeWindowShadow: Bool = false
    /// Seconds to wait after the overlay closes before grabbing pixels.
    public var settleDelay: TimeInterval = 0.12
    public var allowScreencaptureFallback: Bool = true
    public init() {}
}

public enum CaptureError: Error, LocalizedError {
    case cancelled
    case permissionDenied
    case noDisplay
    case windowNotFound
    case invalidRect
    case noLastArea
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Capture cancelled."
        case .permissionDenied: return "Screen Recording permission is not granted."
        case .noDisplay: return "No display found for the requested region."
        case .windowNotFound: return "The window could not be found."
        case .invalidRect: return "The capture region is empty."
        case .noLastArea: return "There is no previous capture area."
        case .failed(let m): return m
        }
    }
}

/// Pure geometry helpers. Global "CG" coordinates have their origin at the top-left of the
/// main display (y down); AppKit global coordinates have it at the bottom-left (y up).
enum CaptureGeometry {
    static func appKitToCG(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func cgToAppKit(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        appKitToCG(r, primaryHeight: primaryHeight)
    }

    static func appKitToCG(_ p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// Rectangle spanned by two points; `square` constrains to the larger side, keeping the anchor fixed.
    static func rect(from a: CGPoint, to b: CGPoint, square: Bool) -> CGRect {
        var dx = b.x - a.x, dy = b.y - a.y
        if square {
            let m = max(abs(dx), abs(dy))
            dx = dx < 0 ? -m : m
            dy = dy < 0 ? -m : m
        }
        return CGRect(x: min(a.x, a.x + dx), y: min(a.y, a.y + dy), width: abs(dx), height: abs(dy))
    }

    /// Clamps `p` into `bounds` (inclusive of edges).
    static func clamp(_ p: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    /// Rect relative to `display` origin (SCK sourceRect space), rounded to whole pixels at `scale`.
    static func displayLocal(_ r: CGRect, display: CGRect, scale: CGFloat) -> CGRect {
        let l = r.intersection(display).offsetBy(dx: -display.minX, dy: -display.minY)
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let x = snap(l.minX), y = snap(l.minY)
        return CGRect(x: x, y: y, width: max(snap(l.maxX) - x, 1 / scale), height: max(snap(l.maxY) - y, 1 / scale))
    }

    /// Pixel rect (top-left origin) of `r` inside a whole-display image, clipped to the display and snapped like
    /// a live grab. The scale comes from the image, so a fallback grab at another resolution still lines up.
    static func pixelCrop(_ r: CGRect, display: CGRect, imageSize: CGSize) -> (pixels: CGRect, scale: CGFloat)? {
        guard display.width > 0, imageSize.width >= 1, imageSize.height >= 1 else { return nil }
        let clipped = r.intersection(display)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        let scale = imageSize.width / display.width
        let local = displayLocal(clipped, display: display, scale: scale)
        let pixels = CGRect(x: (local.minX * scale).rounded(), y: (local.minY * scale).rounded(),
                            width: (local.width * scale).rounded(), height: (local.height * scale).rounded())
            .intersection(CGRect(origin: .zero, size: imageSize))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { return nil }
        return (pixels, scale)
    }

    /// Index of the frame containing `p` (falls back to the nearest by center distance).
    static func index(containing p: CGPoint, in frames: [CGRect]) -> Int? {
        if let i = frames.firstIndex(where: { $0.contains(p) }) { return i }
        return frames.indices.min {
            hypot(frames[$0].midX - p.x, frames[$0].midY - p.y) < hypot(frames[$1].midX - p.x, frames[$1].midY - p.y)
        }
    }

    static func dimensionLabel(_ r: CGRect) -> String {
        "\(Int(r.width.rounded())) × \(Int(r.height.rounded()))"
    }
}
