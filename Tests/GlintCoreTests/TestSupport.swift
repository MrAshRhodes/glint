import CoreGraphics
import CoreText
import Foundation
@testable import GlintCore

enum TestImages {
    /// Solid-colour image.
    static func solid(_ w: Int, _ h: Int, _ c: RGBAColor) -> CGImage {
        let ctx = GlintBitmap.makeContext(width: w, height: h)!
        ctx.setFillColor(c.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Uniform `border` margins (top-left px coords) around a deterministic noisy block.
    static func framed(width: Int, height: Int, margins: EdgeMargins, border: RGBAColor = .white) -> CGImage {
        let ctx = GlintBitmap.makeContext(width: width, height: height)!
        ctx.setFillColor(border.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let inner = CGRect(x: margins.left, y: margins.bottom, width: width - margins.left - margins.right,
                           height: height - margins.top - margins.bottom)
        var rng = SplitMix64(seed: 42)
        var y = Int(inner.minY)
        while y < Int(inner.maxY) {
            var x = Int(inner.minX)
            while x < Int(inner.maxX) {
                let v = Double(rng.next() % 200) / 255
                ctx.setFillColor(RGBAColor(r: v, g: v * 0.5, b: 1 - v).cgColor)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
                x += 1
            }
            y += 1
        }
        return ctx.makeImage()!
    }

    /// Black text on white.
    static func text(_ string: String, size: CGFloat = 40, width: Int = 900, height: Int = 120) -> CGImage {
        let ctx = GlintBitmap.makeContext(width: width, height: height)!
        ctx.setFillColor(RGBAColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = TextDrawing.font(name: "Helvetica", size: size, bold: false)
        let lines = TextDrawing.lines(string, font: font, color: RGBAColor.black.cgColor, maxWidth: 0)
        TextDrawing.draw(lines, font: font, topLeft: CGPoint(x: 20, y: CGFloat(height) - 30), in: ctx, flipped: false)
        return ctx.makeImage()!
    }

    /// RGBA at a top-left pixel coordinate.
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let p = PixelBuffer(image)!.pixel(x, y)
        return (p.0, p.1, p.2, p.3)
    }
}
