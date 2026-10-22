import CoreGraphics
import CoreText
import Foundation
import GlintCore

/// Original, built-in demo "screenshot" used to preview presets without taking a capture.
public enum SampleImage {
    /// Logical size in points of the drawn sample.
    public static let pointSize = CGSize(width: 720, height: 450)

    /// Draws the sample at `scale` pixels per point (clamped to 0.1…8). Deterministic; safe to call from any thread.
    public static func make(scale: CGFloat = 2) -> CGImage {
        let s = min(max(scale, 0.1), 8)
        let w = max(Int((pointSize.width * s).rounded()), 1), h = max(Int((pointSize.height * s).rounded()), 1)
        // A bounded RGBA bitmap always allocates.
        let ctx = GlintBitmap.makeContext(width: w, height: h)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(w) / pointSize.width, y: -CGFloat(h) / pointSize.height) // top-down points
        draw(Painter(ctx: ctx))
        return ctx.makeImage()!
    }

    private static let accent = "#4F6BED"

    private static func draw(_ p: Painter) {
        let W = pointSize.width, H = pointSize.height, side: CGFloat = 188
        p.fill(CGRect(x: 0, y: 0, width: W, height: H), "#FFFFFF")

        // Sidebar
        p.fill(CGRect(x: 0, y: 0, width: side, height: H), "#F3F2F7")
        p.fill(CGRect(x: side, y: 0, width: 1, height: H), "#E2E1E7")
        for (i, hex) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() { p.dot(CGPoint(x: 20 + CGFloat(i) * 20, y: 20), 6, hex) }
        p.text("WORKSPACE", 18, 50, size: 10, "#9D9CA6", bold: true)
        for (i, name) in ["Overview", "Reports", "Customers", "Projects", "Settings"].enumerated() {
            let y = 66 + CGFloat(i) * 28, selected = i == 1
            if selected { p.fill(CGRect(x: 8, y: y, width: side - 16, height: 26), "#E1E5FB", radius: 7) }
            p.fill(CGRect(x: 18, y: y + 6, width: 14, height: 14), selected ? accent : "#AAA9B4", radius: 4)
            p.text(name, 42, y + 5, size: 13, selected ? "#2B3EB8" : "#3A3A42", bold: selected)
        }
        p.text("TEAMS", 18, 222, size: 10, "#9D9CA6", bold: true)
        for (i, (name, hex)) in [("Design", "#F59E0B"), ("Growth", "#10B981"), ("Platform", "#8B5CF6")].enumerated() {
            let y = 238 + CGFloat(i) * 28
            p.dot(CGPoint(x: 25, y: y + 13), 4, hex)
            p.text(name, 42, y + 5, size: 13, "#3A3A42")
        }
        p.dot(CGPoint(x: 29, y: 422), 11, "#C7D2FE")
        p.fill(CGRect(x: 48, y: 413, width: 72, height: 7), "#CFCED7", radius: 3.5)
        p.fill(CGRect(x: 48, y: 425, width: 48, height: 6), "#DFDEE5", radius: 3)

        // Toolbar
        let x0 = side + 25, cw = W - x0 - 24
        p.text("Weekly Report", x0, 16, size: 15, "#1C1C21", bold: true)
        p.fill(CGRect(x: 508, y: 13, width: 28, height: 26), accent, radius: 7)
        p.fill(CGRect(x: 516, y: 25, width: 12, height: 2), "#FFFFFF", radius: 1)
        p.fill(CGRect(x: 521, y: 20, width: 2, height: 12), "#FFFFFF", radius: 1)
        p.fill(CGRect(x: 546, y: 13, width: 150, height: 26), "#F1F1F5", radius: 7)
        p.ring(CGPoint(x: 560, y: 25), 4.5, "#9C9BA6")
        p.line(CGPoint(x: 563.5, y: 28.5), CGPoint(x: 567, y: 32), "#9C9BA6", width: 1.5)
        p.text("Search", 573, 18, size: 12, "#A3A2AC")
        p.fill(CGRect(x: side + 1, y: 52, width: W - side - 1, height: 1), "#ECEBF0")

        // Stat cards
        let stats = [("Visitors", "48.2k", "+12%", true), ("Sign-ups", "1,906", "+8%", true), ("Revenue", "$12.4k", "−3%", false)]
        let cardW = (cw - 24) / 3
        for (i, (label, value, delta, up)) in stats.enumerated() {
            let r = CGRect(x: x0 + CGFloat(i) * (cardW + 12), y: 72, width: cardW, height: 76)
            p.fill(r, "#FFFFFF", radius: 10)
            p.stroke(r, "#E6E5EB", radius: 10)
            p.text(label, r.minX + 14, r.minY + 13, size: 11, "#85848F")
            p.text(value, r.minX + 14, r.minY + 32, size: 22, "#17171C", bold: true)
            let pw = p.width(delta, size: 10, bold: true) + 14
            let pill = CGRect(x: r.maxX - 12 - pw, y: r.minY + 12, width: pw, height: 17)
            p.fill(pill, up ? "#E3F6EA" : "#FDE8E8", radius: 8.5)
            p.text(delta, pill.minX + 7, pill.minY + 2.5, size: 10, up ? "#15803D" : "#C42B2B", bold: true)
        }

        // Chart card
        let chart = CGRect(x: x0, y: 162, width: cw, height: 168)
        p.fill(chart, "#FFFFFF", radius: 12)
        p.stroke(chart, "#E6E5EB", radius: 12)
        p.text("Traffic", chart.minX + 16, chart.minY + 14, size: 13, "#1C1C21", bold: true)
        var lx = chart.maxX - 16
        for (name, hex) in [("Last week", "#C5CCF6"), ("This week", accent)] {
            lx -= p.width(name, size: 11)
            p.text(name, lx, chart.minY + 16, size: 11, "#85848F")
            p.dot(CGPoint(x: lx - 9, y: chart.minY + 23), 3.5, hex)
            lx -= 28
        }
        let plot = CGRect(x: chart.minX + 16, y: chart.minY + 46, width: chart.width - 32, height: 104)
        for g in 0...3 {
            p.fill(CGRect(x: plot.minX, y: plot.minY + CGFloat(g) * plot.height / 3, width: plot.width, height: 1), "#F0EFF4")
        }
        func points(_ v: [CGFloat]) -> [CGPoint] {
            v.enumerated().map { CGPoint(x: plot.minX + CGFloat($0.offset) * plot.width / CGFloat(v.count - 1),
                                         y: plot.maxY - $0.element * plot.height) }
        }
        let lastWeek = points([0.28, 0.34, 0.31, 0.45, 0.4, 0.52, 0.47, 0.56])
        let thisWeek = points([0.36, 0.5, 0.44, 0.63, 0.57, 0.8, 0.72, 0.92])
        p.area(thisWeek, baseline: plot.maxY, accent)
        p.curve(lastWeek, "#C5CCF6", width: 2)
        p.curve(thisWeek, accent, width: 2.5)
        p.dot(thisWeek[thisWeek.count - 1], 5, accent)
        p.dot(thisWeek[thisWeek.count - 1], 2.5, "#FFFFFF")

        // Activity rows
        let rows: [(avatar: String, name: CGFloat, detail: CGFloat, progress: CGFloat, status: String, tint: String, ink: String)] = [
            ("#FBCFE8", 150, 96, 1, "Done", "#DCFCE7", "#15803D"),
            ("#BFDBFE", 118, 132, 0.62, "Review", "#E0E7FF", "#3730A3"),
            ("#BBF7D0", 172, 84, 0.3, "Draft", "#FEF3C7", "#B45309"),
        ]
        for (i, row) in rows.enumerated() {
            let y = 342 + CGFloat(i) * 32
            p.dot(CGPoint(x: x0 + 12, y: y + 16), 12, row.avatar)
            p.fill(CGRect(x: x0 + 34, y: y + 8, width: row.name, height: 7), "#D5D4DC", radius: 3.5)
            p.fill(CGRect(x: x0 + 34, y: y + 20, width: row.detail, height: 6), "#E8E7ED", radius: 3)
            p.fill(CGRect(x: x0 + 240, y: y + 13, width: 120, height: 6), "#EFEEF3", radius: 3)
            p.fill(CGRect(x: x0 + 240, y: y + 13, width: 120 * row.progress, height: 6), row.ink, radius: 3)
            let tw = p.width(row.status, size: 10, bold: true) + 16
            let pill = CGRect(x: x0 + cw - tw, y: y + 7, width: tw, height: 18)
            p.fill(pill, row.tint, radius: 9)
            p.text(row.status, pill.minX + 8, pill.minY + 3, size: 10, row.ink, bold: true)
            if i < rows.count - 1 { p.fill(CGRect(x: x0, y: y + 31, width: cw, height: 1), "#F1F0F4") }
        }
    }
}

/// Minimal drawing helpers for a top-down (flipped) CGContext.
private struct Painter {
    let ctx: CGContext

    static func color(_ hex: String, alpha: Double = 1) -> CGColor {
        (RGBAColor(hex: hex) ?? .black).with(alpha: alpha).cgColor
    }

    func fill(_ r: CGRect, _ hex: String, radius: CGFloat = 0) {
        ctx.setFillColor(Self.color(hex))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    func stroke(_ r: CGRect, _ hex: String, radius: CGFloat) {
        ctx.setStrokeColor(Self.color(hex))
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.strokePath()
    }

    func dot(_ c: CGPoint, _ r: CGFloat, _ hex: String) {
        ctx.setFillColor(Self.color(hex))
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    func ring(_ c: CGPoint, _ r: CGFloat, _ hex: String) {
        ctx.setStrokeColor(Self.color(hex))
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    func line(_ a: CGPoint, _ b: CGPoint, _ hex: String, width: CGFloat) {
        ctx.setStrokeColor(Self.color(hex))
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.strokeLineSegments(between: [a, b])
    }

    private func smooth(_ pts: [CGPoint]) -> CGMutablePath {
        let path = CGMutablePath()
        path.move(to: pts[0])
        for (a, b) in zip(pts, pts.dropFirst()) {
            let mx = (a.x + b.x) / 2
            path.addCurve(to: b, control1: CGPoint(x: mx, y: a.y), control2: CGPoint(x: mx, y: b.y))
        }
        return path
    }

    func curve(_ pts: [CGPoint], _ hex: String, width: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(Self.color(hex))
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(smooth(pts))
        ctx.strokePath()
        ctx.restoreGState()
    }

    func area(_ pts: [CGPoint], baseline: CGFloat, _ hex: String) {
        let path = smooth(pts)
        path.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: baseline))
        path.addLine(to: CGPoint(x: pts[0].x, y: baseline))
        path.closeSubpath()
        let colors = [Self.color(hex, alpha: 0.24), Self.color(hex, alpha: 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: ColorSpaces.sRGB, colors: colors, locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: pts.map(\.y).min() ?? 0), end: CGPoint(x: 0, y: baseline),
                               options: [])
        ctx.restoreGState()
    }

    private func typeset(_ s: String, size: CGFloat, hex: String, bold: Bool) -> (CTLine, CTFont) {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attr = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): Self.color(hex),
        ])
        return (CTLineCreateWithAttributedString(attr), font)
    }

    func width(_ s: String, size: CGFloat, bold: Bool = false) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(typeset(s, size: size, hex: "#000000", bold: bold).0, nil, nil, nil))
    }

    /// Draws a single line of text with its top-left at (`x`, `top`).
    func text(_ s: String, _ x: CGFloat, _ top: CGFloat, size: CGFloat, _ hex: String, bold: Bool = false) {
        let (l, font) = typeset(s, size: size, hex: hex, bold: bold)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: top + CTFontGetAscent(font))
        CTLineDraw(l, ctx)
        ctx.restoreGState()
    }
}

/// Renders preset settings onto an image for previews/thumbnails.
public enum PresetPreview {
    /// Composes `image` with `settings` (no annotations), scaled down via `outputScale` so the output fits within
    /// `maxPixelSize`; never scaled up. `.image(path:)` backgrounds are loaded from disk by the compositor.
    /// Pass `wallpaper` when `settings.usesDesktopWallpaper` (otherwise the selected background is used).
    /// Returns nil if rendering fails or `maxPixelSize` is under 1 px. Safe to call off the main thread.
    public static func render(settings: RenderSettings, image: CGImage, backingScale: CGFloat,
                              fitting maxPixelSize: CGSize, wallpaper: CGImage? = nil) -> CGImage? {
        let bounds = CGSize(width: floor(maxPixelSize.width), height: floor(maxPixelSize.height))
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        let source = image.glintSRGB()
        var s = settings

        // Estimate the content the compositor will lay out (auto-balance crop, rotation, inset).
        var size = source.pixelSize, insetApplied = s.insetColor != nil
        if s.autoBalance, let border = AutoBalance.detectBorder(in: source) {
            size = AutoBalance.balanceCropRect(imageSize: size, border: border).integral.size
            insetApplied = true
        }
        if s.rotation == .cw90 || s.rotation == .cw270 { size = CGSize(width: size.height, height: size.width) }
        insetApplied = insetApplied && floor(s.inset) >= 1
        for _ in 0..<3 { // repeat to absorb the layout's pixel rounding
            let canvas = Compositor.layout(contentSize: size, insetApplied: insetApplied, settings: s,
                                           backingScale: backingScale).canvasSize
            let fit = min(bounds.width / canvas.width, bounds.height / canvas.height)
            guard fit < 1, s.outputScale > 0.02 else { break }
            s.outputScale = max(s.outputScale * Double(fit), 0.02)
        }

        guard let out = try? Compositor.render(image: source, settings: s, backingScale: backingScale,
                                               wallpaper: wallpaper) else { return nil }
        return downscaled(out, toFit: bounds)
    }

    /// Final guard for bounds below the compositor's minimum output scale.
    private static func downscaled(_ image: CGImage, toFit bounds: CGSize) -> CGImage? {
        let f = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        guard f < 1 else { return image }
        let w = min(max(Int((CGFloat(image.width) * f).rounded()), 1), Int(bounds.width))
        let h = min(max(Int((CGFloat(image.height) * f).rounded()), 1), Int(bounds.height))
        guard let ctx = GlintBitmap.makeContext(width: w, height: h) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
