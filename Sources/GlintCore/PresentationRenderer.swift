import CoreGraphics
import Foundation

/// Draws the pointer-based presentation effects of a recording frame.
///
/// Effects are painted onto the source frame before annotations are burned in, so they sit in source
/// coordinates like the footage itself: they zoom with it, and a redaction drawn over them still covers them.
enum PresentationRenderer {
    /// Dimming outside the spotlight circle.
    static let spotlightDim: Double = 0.5

    /// `source` with spotlight, halo, click ripples and the drawn pointer for `time`, or `source` itself when
    /// nothing applies then.
    static func decorate(_ source: CGImage, presentation: Presentation, time: TimeInterval) -> CGImage {
        guard let capture = presentation.capture, time.isFinite else { return source }
        let settings = presentation.settings
        let pointer = capture.pointer.position(at: time)
        let ripples = settings.clicks.enabled ? activeClicks(capture.clicks, style: settings.clicks, at: time) : []
        let cursor = settings.cursor
        let emphasis = pointer != nil && (cursor.halo || cursor.spotlight)
        let drawsPointer = pointer != nil && presentation.drawsPointer
        guard emphasis || drawsPointer || !ripples.isEmpty else { return source }
        let width = source.width, height = source.height
        guard let ctx = GlintBitmap.makeContext(width: width, height: height) else { return source }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.draw(source, in: bounds)
        // Source pixels with a top-left origin, like every recorded position.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        if let pointer, cursor.spotlight {
            ctx.saveGState()
            ctx.addRect(bounds)
            ctx.addEllipse(in: circle(at: pointer, radius: cursor.radius))
            ctx.setFillColor(RGBAColor.black.with(alpha: spotlightDim).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }
        if let pointer, cursor.halo {
            ctx.setFillColor(cursor.haloColor.cgColor)
            ctx.fillEllipse(in: circle(at: pointer, radius: cursor.radius))
        }
        for (click, progress) in ripples {
            drawRipple(click, progress: progress, style: settings.clicks, in: ctx)
        }
        if let pointer, drawsPointer {
            drawPointer(at: pointer, scale: CGFloat(capture.pointerScale * cursor.scale), in: ctx)
        }
        return ctx.makeImage() ?? source
    }

    /// Clicks whose ripple is visible at `time`, with how far through it they are (0 to 1).
    static func activeClicks(_ clicks: [ClickEvent], style: ClickHighlightStyle,
                             at time: TimeInterval) -> [(ClickEvent, Double)] {
        let duration = style.duration
        return clicks.compactMap { click in
            guard !style.removed.contains(click.id), time >= click.time, time < click.time + duration else {
                return nil
            }
            return (click, (time - click.time) / duration)
        }
    }

    /// Ring radius of a ripple `progress` of the way through; it grows from 30% to the full size.
    static func rippleRadius(size: Double, progress: Double) -> CGFloat {
        let eased = 1 - pow(1 - min(max(progress, 0), 1), 3)
        return CGFloat(size * (0.3 + 0.7 * eased))
    }

    static func rippleLineWidth(size: Double) -> CGFloat { max(CGFloat(size) * 0.14, 3) }

    private static func drawRipple(_ click: ClickEvent, progress: Double, style: ClickHighlightStyle,
                                   in ctx: CGContext) {
        let color = click.button == .left ? style.leftColor : style.rightColor
        let alpha = color.a * (1 - progress * 0.85)
        let radius = rippleRadius(size: style.size, progress: progress)
        let line = rippleLineWidth(size: style.size)
        ctx.saveGState()
        ctx.setStrokeColor(color.with(alpha: alpha).cgColor)
        ctx.setLineWidth(line)
        ctx.strokeEllipse(in: circle(at: click.position, radius: Double(radius)))
        // A second, inner ring tells right clicks apart without relying on colour alone.
        if click.button == .right {
            ctx.strokeEllipse(in: circle(at: click.position, radius: Double(max(radius - line * 2, line))))
        }
        ctx.restoreGState()
    }

    /// The classic arrow pointer, tip at `point`, in points scaled to video pixels.
    private static func drawPointer(at point: CGPoint, scale: CGFloat, in ctx: CGContext) {
        let outline: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 17), CGPoint(x: 4.2, y: 13.2), CGPoint(x: 7, y: 19.5),
            CGPoint(x: 9.6, y: 18.4), CGPoint(x: 6.9, y: 12.2), CGPoint(x: 12.2, y: 12.2)
        ]
        let path = CGMutablePath()
        path.addLines(between: outline.map { CGPoint(x: point.x + $0.x * scale, y: point.y + $0.y * scale) })
        path.closeSubpath()
        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.setLineWidth(2 * scale)
        ctx.setStrokeColor(RGBAColor.white.cgColor)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.setFillColor(RGBAColor.black.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func circle(at center: CGPoint, radius: Double) -> CGRect {
        let r = CGFloat(radius)
        return CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
    }

    // MARK: Zoom

    /// `viewport` (source pixels, top-left) as a rect inside the base content after the compositor's rotation and
    /// flips, relative to `base` (the part of the source the card shows).
    static func orientedViewport(_ viewport: CGRect, base: CGRect, rotation: Rotation,
                                 flipH: Bool, flipV: Bool) -> CGRect {
        let v = viewport.offsetBy(dx: -base.minX, dy: -base.minY)
        let w = base.width, h = base.height
        var r: CGRect
        switch rotation {
        case .none: r = v
        case .cw90: r = CGRect(x: h - v.maxY, y: v.minX, width: v.height, height: v.width)
        case .cw180: r = CGRect(x: w - v.maxX, y: h - v.maxY, width: v.width, height: v.height)
        case .cw270: r = CGRect(x: v.minY, y: w - v.maxX, width: v.height, height: v.width)
        }
        let swap = rotation == .cw90 || rotation == .cw270
        let ow = swap ? h : w, oh = swap ? w : h
        if flipH { r.origin.x = ow - r.maxX }
        if flipV { r.origin.y = oh - r.maxY }
        return r
    }
}
