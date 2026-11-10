import CoreGraphics
import Foundation

/// The screenshot export path on a synthetic frame, so it can be timed on any machine without reading screen pixels.
public enum ExportTiming {
    /// A full-screen capture of a 1440×900-point display at 2×.
    public static let syntheticWidth = 2880
    public static let syntheticHeight = 1800

    /// A deterministic frame with the mix a screenshot has: a gradient desktop, a window with text, and a block of
    /// photo-like noise. Identical for identical sizes.
    public static func syntheticFrame(width: Int = syntheticWidth, height: Int = syntheticHeight) -> CGImage? {
        guard let ctx = GlintBitmap.makeContext(width: width, height: height) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let desktop = [RGBAColor(r: 0.16, g: 0.30, b: 0.60).cgColor, RGBAColor(r: 0.58, g: 0.32, b: 0.62).cgColor]
        if let gradient = CGGradient(colorsSpace: ColorSpaces.sRGB, colors: desktop as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }

        let window = CGRect(x: w * 0.08, y: h * 0.08, width: w * 0.84, height: h * 0.80)
        ctx.setFillColor(RGBAColor(r: 0.97, g: 0.97, b: 0.98).cgColor)
        ctx.fill(window)
        ctx.setFillColor(RGBAColor(r: 0.88, g: 0.88, b: 0.90).cgColor)
        ctx.fill(CGRect(x: window.minX, y: window.maxY - h * 0.045, width: window.width, height: h * 0.045))

        let font = TextDrawing.font(name: "Helvetica", size: h * 0.016, bold: false)
        let paragraph = (0..<40).map { "Line \($0 + 1): the quick brown fox jumps over the lazy dog, 0123456789" }
            .joined(separator: "\n")
        let lines = TextDrawing.lines(paragraph, font: font, color: RGBAColor.black.cgColor, maxWidth: 0)
        TextDrawing.draw(lines, font: font, topLeft: CGPoint(x: window.minX + w * 0.02, y: window.maxY - h * 0.07),
                         in: ctx, flipped: false)

        fillWithNoise(ctx, in: CGRect(x: w * 0.55, y: h * 0.14, width: w * 0.32, height: h * 0.36))
        return ctx.makeImage()
    }

    /// One export as the app does it for a file or the clipboard: default styling, then a PNG at the capture's density.
    public static func renderAndEncode(_ frame: CGImage, backingScale: CGFloat = 2,
                                       settings: RenderSettings = .default) throws -> Data {
        let rendered = try Compositor.render(image: frame, settings: settings, backingScale: backingScale)
        return try Exporter.data(for: rendered, format: .plainPNG, scale: .original, backingScale: backingScale)
    }

    /// Smooth ramps plus seeded jitter: compresses worse than flat colour and better than pure noise, like a photo.
    private static func fillWithNoise(_ ctx: CGContext, in rect: CGRect) {
        guard let base = ctx.data else { return }
        let bounds = rect.integral.intersection(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        guard !bounds.isNull else { return }
        let minX = Int(bounds.minX), maxX = Int(bounds.maxX), minY = Int(bounds.minY), maxY = Int(bounds.maxY)
        let span = max(maxX - minX, 1)
        var rng = SplitMix64(seed: 0x6C69_6E74)
        for y in minY..<maxY {
            let row = base.advanced(by: y * ctx.bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in minX..<maxX {
                let bits = rng.next()
                let tone = 90 + (x - minX) * 120 / span
                let pixel = row + x * 4
                pixel[0] = UInt8(clamping: tone + Int(bits & 0x1F) - 16)
                pixel[1] = UInt8(clamping: tone / 2 + 60 + Int((bits >> 8) & 0x1F) - 16)
                pixel[2] = UInt8(clamping: 200 - tone / 2 + Int((bits >> 16) & 0x1F) - 16)
                pixel[3] = 255
            }
        }
    }
}
