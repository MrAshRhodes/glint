import CoreGraphics
import Foundation

public struct EdgeMargins: Equatable, Sendable {
    public var top: Int, left: Int, bottom: Int, right: Int
    public init(top: Int, left: Int, bottom: Int, right: Int) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
}

public struct BorderInfo: Equatable, Sendable {
    /// Modal colour of the 1-px outer perimeter.
    public var color: RGBAColor
    /// Share of perimeter pixels within tolerance of `color` (≥ threshold for a "primary" border).
    public var perimeterFraction: Double
    /// Width of the uniform-colour band touching each edge, in pixels.
    public var margins: EdgeMargins
}

public struct BalanceResult: Sendable {
    public var image: CGImage
    public var border: BorderInfo
    /// Crop rect in source pixel space (top-left origin); may extend beyond the source.
    public var cropRect: CGRect
}

/// Raw RGBA8 pixel access (sRGB, premultiplied, top row first).
struct PixelBuffer {
    let width: Int
    let height: Int
    var data: [UInt8]

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let ctx = GlintBitmap.makeContext(width: w, height: h) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let ptr = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let src = ptr.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h { // CGBitmapContext memory is top row first
                dst.baseAddress!.advanced(by: y * w * 4).update(from: src.advanced(by: y * bpr), count: w * 4)
            }
        }
        width = w; height = h; data = out
    }

    @inline(__always) func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 4
        return (data[i], data[i + 1], data[i + 2], data[i + 3])
    }
}

public enum AutoBalance {
    /// Detection is skipped above this pixel count (910k pixels).
    public static let maxPixels = 910_000
    public static let perimeterThreshold = 0.88
    public static let colorTolerance = 2
    /// Remaining uniform margin after balancing (top/left 10 px, bottom/right 9 px).
    public static let targetTopLeft = 10
    public static let targetBottomRight = 9

    /// Returns the "primary" border colour if the 1-px outer perimeter is (almost) uniform.
    public static func detectBorder(in image: CGImage, maxPixels: Int = AutoBalance.maxPixels) -> BorderInfo? {
        let w = image.width, h = image.height
        guard w >= 3, h >= 3, w * h <= maxPixels, let buf = PixelBuffer(image) else { return nil }

        var perimeter: [(UInt8, UInt8, UInt8, UInt8)] = []
        perimeter.reserveCapacity(2 * (w + h))
        for x in 0..<w { perimeter.append(buf.pixel(x, 0)); perimeter.append(buf.pixel(x, h - 1)) }
        for y in 1..<(h - 1) { perimeter.append(buf.pixel(0, y)); perimeter.append(buf.pixel(w - 1, y)) }

        var counts: [UInt32: Int] = [:]
        for p in perimeter { counts[key(p), default: 0] += 1 }
        guard let modal = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key else { return nil }
        let mc = unkey(modal)
        let within = perimeter.filter { close($0, mc) }.count
        let fraction = Double(within) / Double(perimeter.count)
        guard fraction >= perimeterThreshold else { return nil }

        func rowUniform(_ y: Int) -> Bool { (0..<w).allSatisfy { close(buf.pixel($0, y), mc) } }
        func colUniform(_ x: Int) -> Bool { (0..<h).allSatisfy { close(buf.pixel(x, $0), mc) } }
        var top = 0; while top < h, rowUniform(top) { top += 1 }
        guard top < h else { return nil } // fully uniform image: nothing to balance
        var bottom = 0; while bottom < h, rowUniform(h - 1 - bottom) { bottom += 1 }
        var left = 0; while left < w, colUniform(left) { left += 1 }
        var right = 0; while right < w, colUniform(w - 1 - right) { right += 1 }

        let a = Double(mc.3) / 255
        let color = a > 0
            ? RGBAColor(r: Double(mc.0) / 255 / a, g: Double(mc.1) / 255 / a, b: Double(mc.2) / 255 / a, a: a)
            : RGBAColor.clear
        return BorderInfo(color: color, perimeterFraction: fraction,
                          margins: EdgeMargins(top: top, left: left, bottom: bottom, right: right))
    }

    /// Crop rect (top-left origin) that normalises the uniform margins to ≈10/9 px. Axes whose margins are
    /// both zero, or both already below the target, are left alone. Negative origin / overflow adds margin.
    public static func balanceCropRect(imageSize: CGSize, border: BorderInfo) -> CGRect {
        let m = border.margins
        func axis(_ lo: Int, _ hi: Int, _ size: Int, _ tLo: Int, _ tHi: Int) -> (Int, Int) {
            if lo == 0 && hi == 0 { return (0, size) }
            if lo < tLo && hi < tHi { return (0, size) }
            return (lo - tLo, size - hi + tHi) // start, end in source coordinates
        }
        let w = Int(imageSize.width), h = Int(imageSize.height)
        let x = axis(m.left, m.right, w, targetTopLeft, targetBottomRight)
        let y = axis(m.top, m.bottom, h, targetTopLeft, targetBottomRight)
        return CGRect(x: x.0, y: y.0, width: x.1 - x.0, height: y.1 - y.0)
    }

    /// Crops to `rect` (source pixel space); regions outside the source are filled with `fill`.
    public static func crop(_ image: CGImage, to rect: CGRect, fill: RGBAColor) -> CGImage? {
        let r = rect.integral
        guard r.width >= 1, r.height >= 1,
              let ctx = GlintBitmap.makeContext(width: Int(r.width), height: Int(r.height)) else { return nil }
        ctx.setFillColor(fill.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: r.width, height: r.height))
        // bottom-left space: source origin sits at (-minX, rect.maxY - srcH)
        ctx.draw(image, in: CGRect(x: -r.minX, y: r.maxY - CGFloat(image.height),
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()
    }

    /// Detects the border and applies the balance crop. Nil if no primary border colour was found.
    public static func balance(_ image: CGImage) -> BalanceResult? {
        guard let border = detectBorder(in: image) else { return nil }
        let rect = balanceCropRect(imageSize: image.pixelSize, border: border)
        guard let cropped = crop(image, to: rect, fill: border.color) else { return nil }
        return BalanceResult(image: cropped, border: border, cropRect: rect)
    }

    private static func key(_ p: (UInt8, UInt8, UInt8, UInt8)) -> UInt32 {
        UInt32(p.0) << 24 | UInt32(p.1) << 16 | UInt32(p.2) << 8 | UInt32(p.3)
    }
    private static func unkey(_ k: UInt32) -> (UInt8, UInt8, UInt8, UInt8) {
        (UInt8(k >> 24), UInt8((k >> 16) & 0xFF), UInt8((k >> 8) & 0xFF), UInt8(k & 0xFF))
    }
    private static func close(_ a: (UInt8, UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        abs(Int(a.0) - Int(b.0)) <= colorTolerance && abs(Int(a.1) - Int(b.1)) <= colorTolerance
            && abs(Int(a.2) - Int(b.2)) <= colorTolerance && abs(Int(a.3) - Int(b.3)) <= colorTolerance
    }
}
