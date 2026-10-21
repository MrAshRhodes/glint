import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Device-independent RGBA colour (components 0…1, sRGB).
public struct RGBAColor: Codable, Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Parses `#RGB`, `#RRGGBB` or `#RRGGBBAA` (leading `#` optional).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255,
                      b: Double(v & 0xFF) / 255, a: 1)
        } else {
            self.init(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255,
                      b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
        }
    }

    public init(red8: UInt8, green8: UInt8, blue8: UInt8, alpha8: UInt8 = 255) {
        self.init(r: Double(red8) / 255, g: Double(green8) / 255, b: Double(blue8) / 255, a: Double(alpha8) / 255)
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when not opaque.
    public var hexString: String {
        func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        let base = String(format: "#%02X%02X%02X", c(r), c(g), c(b))
        return a >= 0.999 ? base : base + String(format: "%02X", c(a))
    }

    public var cgColor: CGColor {
        CGColor(colorSpace: ColorSpaces.sRGB, components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])
            ?? CGColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    public init(_ cg: CGColor) {
        let converted = cg.converted(to: ColorSpaces.sRGB, intent: .defaultIntent, options: nil) ?? cg
        let c = converted.components ?? [0, 0, 0, 1]
        if c.count >= 4 {
            self.init(r: Double(c[0]), g: Double(c[1]), b: Double(c[2]), a: Double(c[3]))
        } else if c.count == 2 {
            self.init(r: Double(c[0]), g: Double(c[0]), b: Double(c[0]), a: Double(c[1]))
        } else {
            self.init(r: 0, g: 0, b: 0, a: 1)
        }
    }

    public init(_ ns: NSColor) {
        let c = ns.usingColorSpace(.sRGB) ?? ns
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent),
                  a: Double(c.alphaComponent))
    }

    public func with(alpha: Double) -> RGBAColor { RGBAColor(r: r, g: g, b: b, a: alpha) }

    public static let white = RGBAColor(r: 1, g: 1, b: 1)
    public static let black = RGBAColor(r: 0, g: 0, b: 0)
    public static let red = RGBAColor(r: 0.984, g: 0.008, b: 0.027)
    public static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)
}

public enum ColorSpaces {
    public static let sRGB: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
}

public enum GlintBitmap {
    /// RGBA8 premultiplied sRGB context (bottom-left origin), cleared to transparent.
    public static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: ColorSpaces.sRGB, bitmapInfo: info)
        ctx?.interpolationQuality = .high
        return ctx
    }
}

public extension CGImage {
    var pixelSize: CGSize { CGSize(width: width, height: height) }

    /// Redraws into an sRGB RGBA8 premultiplied bitmap.
    func glintSRGB() -> CGImage {
        if let cs = colorSpace, cs.name == CGColorSpace.sRGB, bitsPerComponent == 8,
           alphaInfo == .premultipliedLast || alphaInfo == .premultipliedFirst { return self }
        guard let ctx = GlintBitmap.makeContext(width: width, height: height) else { return self }
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? self
    }

    /// Crop in image space (top-left origin). The rect is clamped to the image.
    func glintCropped(to rect: CGRect) -> CGImage? {
        cropping(to: rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height)))
    }
}

public enum GlintImageIO {
    public static func load(url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return decode(src)
    }

    public static func load(data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decode(src)
    }

    private static func decode(_ src: CGImageSource) -> CGImage? {
        guard let first = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? Int) ?? 1
        if orientation != 1 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(first.width, first.height),
            ]
            if let t = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return t.glintSRGB() }
        }
        return first.glintSRGB()
    }
}
