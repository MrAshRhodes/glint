import CoreGraphics
import CoreText
import Foundation

/// Everything a frame style needs to draw. All rects are output pixels in a bottom-left-origin
/// context that is already clipped to the rounded card.
struct FrameCanvas {
    let ctx: CGContext
    /// The whole card: chrome plus screen.
    let card: CGRect
    /// The screenshot plus its inset band. Chrome surrounds it; only overlays may draw over it.
    let screen: CGRect
    /// Top inset (title bar) height in pixels.
    let bar: CGFloat
    /// Points → pixels.
    let k: CGFloat
    /// Resolved card corner radius in pixels.
    let radius: CGFloat
    let frame: WindowFrameSettings

    var dark: Bool { frame.dark }
    var title: String { frame.title }
    /// The top inset band.
    var topBand: CGRect { CGRect(x: card.minX, y: screen.maxY, width: card.width, height: card.maxY - screen.maxY) }
    var bottomBand: CGRect { CGRect(x: card.minX, y: card.minY, width: card.width, height: screen.minY - card.minY) }
    var leftBand: CGRect { CGRect(x: card.minX, y: screen.minY, width: screen.minX - card.minX, height: screen.height) }
    var rightBand: CGRect { CGRect(x: screen.maxX, y: screen.minY, width: card.maxX - screen.maxX, height: screen.height) }
}

/// Draws window frame chrome. Each style keeps its metrics and drawing in its own extension:
/// `FrameStyles+Window.swift` (code editor, terminal, phone), `FrameStyles+Retro.swift` (retro monitor,
/// pixel arcade, handheld) and `FrameStyles+Print.swift` (comic panel, film strip, photo print).
enum FrameRenderer {
    /// Drawn after the inset band and before the screenshot.
    static func drawChrome(_ c: FrameCanvas) {
        guard c.frame.style != .none else { return }
        c.ctx.saveGState()
        defer { c.ctx.restoreGState() }
        switch c.frame.style {
        case .none: break
        case .macOS, .browser: drawTitleBar(c)
        case .ide: drawIDE(c)
        case .terminal: drawTerminal(c)
        case .phone: drawPhone(c)
        case .retro: drawRetro(c)
        case .arcade: drawArcade(c)
        case .handheld: drawHandheld(c)
        case .comic: drawComic(c)
        case .filmStrip: drawFilmStrip(c)
        case .photo: drawPhoto(c)
        }
    }

    /// Drawn after the screenshot, still clipped to the card. Keep overlays decorative and subtle.
    static func drawOverlay(_ c: FrameCanvas) {
        switch c.frame.style {
        case .none, .macOS, .browser: return
        default: break
        }
        c.ctx.saveGState()
        defer { c.ctx.restoreGState() }
        switch c.frame.style {
        case .none, .macOS, .browser: break
        case .ide: drawIDEOverlay(c)
        case .terminal: drawTerminalOverlay(c)
        case .phone: drawPhoneOverlay(c)
        case .retro: drawRetroOverlay(c)
        case .arcade: drawArcadeOverlay(c)
        case .handheld: drawHandheldOverlay(c)
        case .comic: drawComicOverlay(c)
        case .filmStrip: drawFilmStripOverlay(c)
        case .photo: drawPhotoOverlay(c)
        }
    }

    // MARK: Shared helpers

    static func color(_ hex: String) -> CGColor { (RGBAColor(hex: hex) ?? .black).cgColor }

    static func fill(_ rect: CGRect, _ color: CGColor, in ctx: CGContext) {
        ctx.setFillColor(color)
        ctx.fill(rect)
    }

    static func fillRounded(_ rect: CGRect, radius: CGFloat, _ color: CGColor, in ctx: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
    }

    static func strokeRounded(_ rect: CGRect, radius: CGFloat, width: CGFloat, _ color: CGColor, in ctx: CGContext) {
        guard rect.width > 0, rect.height > 0, width > 0 else { return }
        let inner = rect.insetBy(dx: width / 2, dy: width / 2)
        let r = max(0, min(radius - width / 2, min(inner.width, inner.height) / 2))
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.strokePath()
    }

    enum TextAlignment { case left, center, right }

    static func textWidth(_ text: String, font: CTFont) -> CGFloat {
        TextDrawing.blockSize(TextDrawing.lines(text, font: font, color: color("#000000"), maxWidth: 0), font: font).width
    }

    /// Draws one line of `text`, vertically centred on `midY` and aligned to `x` (left edge, centre or
    /// right edge). When `clip` is given, glyphs outside it are cut off. Newlines are flattened.
    static func drawText(_ text: String, font: CTFont, color: CGColor, x: CGFloat, midY: CGFloat,
                         align: TextAlignment = .left, clip: CGRect? = nil, in ctx: CGContext) {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        guard !single.isEmpty else { return }
        let lines = TextDrawing.lines(single, font: font, color: color, maxWidth: 0)
        let size = TextDrawing.blockSize(lines, font: font)
        let left: CGFloat
        switch align {
        case .left: left = x
        case .center: left = x - size.width / 2
        case .right: left = x - size.width
        }
        ctx.saveGState()
        if let clip { ctx.clip(to: clip) }
        TextDrawing.draw(lines, font: font, topLeft: CGPoint(x: left, y: midY + size.height / 2), in: ctx, flipped: false)
        ctx.restoreGState()
    }

    // MARK: macOS and browser title bars (unchanged since 1.0)

    private static func drawTitleBar(_ c: FrameCanvas) {
        let ctx = c.ctx, frame = c.frame, card = c.card, bar = c.bar, k = c.k
        let dark = frame.dark
        let barRect = CGRect(x: card.minX, y: card.maxY - bar, width: card.width, height: bar)
        ctx.setFillColor((RGBAColor(hex: dark ? "#2B2B2D" : "#ECECEC") ?? .white).cgColor)
        ctx.fill(barRect)
        ctx.setFillColor((RGBAColor(hex: dark ? "#000000" : "#D0D0D0") ?? .black).cgColor)
        ctx.fill(CGRect(x: barRect.minX, y: barRect.minY, width: barRect.width, height: max(1, k * 0.5)))

        let d = 12 * k
        for (i, hex) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
            ctx.setFillColor((RGBAColor(hex: hex) ?? .red).cgColor)
            ctx.fillEllipse(in: CGRect(x: card.minX + 14 * k + CGFloat(i) * 20 * k, y: barRect.midY - d / 2, width: d, height: d))
        }

        let textColor = (RGBAColor(hex: dark ? "#C8C8CC" : "#4A4A4F") ?? .black).cgColor
        let font = TextDrawing.font(name: "Helvetica Neue", size: 13 * k, bold: false)
        switch frame.style {
        case .macOS:
            guard !frame.title.isEmpty else { return }
            let lines = TextDrawing.lines(frame.title, font: font, color: textColor, maxWidth: 0)
            let size = TextDrawing.blockSize(lines, font: font)
            TextDrawing.draw(lines, font: font, topLeft: CGPoint(x: barRect.midX - size.width / 2, y: barRect.midY + size.height / 2),
                             in: ctx, flipped: false)
        case .browser:
            let pill = CGRect(x: card.minX + 80 * k, y: barRect.midY - 12 * k, width: max(card.width - 96 * k, 0), height: 24 * k)
            guard pill.width > 20 * k else { return }
            ctx.setFillColor((RGBAColor(hex: dark ? "#1C1C1E" : "#FFFFFF") ?? .white).cgColor)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 12 * k, cornerHeight: 12 * k, transform: nil))
            ctx.fillPath()
            if !frame.title.isEmpty {
                let lines = TextDrawing.lines(frame.title, font: font, color: textColor, maxWidth: 0)
                let size = TextDrawing.blockSize(lines, font: font)
                ctx.saveGState()
                ctx.clip(to: pill.insetBy(dx: 8 * k, dy: 0))
                TextDrawing.draw(lines, font: font, topLeft: CGPoint(x: pill.midX - size.width / 2, y: pill.midY + size.height / 2),
                                 in: ctx, flipped: false)
                ctx.restoreGState()
            }
        default: break
        }
    }
}
