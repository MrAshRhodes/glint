import CoreGraphics
import Foundation

/// Where a capture sits in the editor's first frame, worked out without composing anything.
///
/// The editor draws this until the composed preview exists, so the capture is visible at once and the content stays
/// where the composed preview will put it. The crop, orientation and layout come from the same code the renderer
/// uses (`Compositor.balancedBase`, `Compositor.layout`). The background, shadow, frame chrome and annotations are
/// the composed preview's job, so a frame is only made where the render adds nothing to the content itself.
public struct ProvisionalFrame: Equatable, Sendable {
    /// Largest capture, in pixels, drawn directly instead of waiting for the composed preview.
    public static let maxPixels = 40_000_000

    public let layout: RenderLayout
    /// The source pixels (top-left origin) `layout.contentRect` shows. May extend beyond the image when
    /// auto-balance adds margin.
    public let region: CGRect
    /// Fills the part of `region` outside the image: the detected border colour, or clear without auto-balance.
    public let fill: RGBAColor
    public let rotation: Rotation
    public let flipHorizontal: Bool
    public let flipVertical: Bool

    /// Nil when the composed preview could differ from the capture beyond its frame: annotations (redactions
    /// among them) are burned in, a tilt reshapes the card, and a capture beyond `maxPixels` would be slow to
    /// draw directly.
    public init?(image: CGImage, settings: RenderSettings, annotations: [Annotation], backingScale: CGFloat,
                 maxPixels: Int = ProvisionalFrame.maxPixels) {
        let pixels = image.width * image.height
        guard annotations.isEmpty, settings.tilt.isFlat, pixels > 0, pixels <= maxPixels else { return nil }
        // Border detection only runs on small captures, where normalising for it costs next to nothing.
        let probe = settings.autoBalance && pixels <= AutoBalance.maxPixels ? image.glintSRGB() : image
        let (border, _, base) = Compositor.balancedBase(of: probe, settings: settings)
        let turned = settings.rotation == .cw90 || settings.rotation == .cw270
        let insetApplied = (settings.insetColor ?? border?.color) != nil && floor(settings.inset) >= 1
        layout = Compositor.layout(contentSize: turned ? CGSize(width: base.height, height: base.width) : base.size,
                                   insetApplied: insetApplied, settings: settings, backingScale: backingScale)
        self.region = base
        self.fill = border?.color ?? .clear
        rotation = settings.rotation
        flipHorizontal = settings.flipHorizontal
        flipVertical = settings.flipVertical
    }

    /// Draws `image` (the capture the frame was made for) into the content rect of the canvas, rotated, flipped and
    /// cropped like the composed preview. `ctx` has a bottom-left origin and shows the canvas at `scale` context
    /// units per canvas pixel; everything outside the content rect is left alone for the caller to paint.
    public func draw(_ image: CGImage, in ctx: CGContext, scale: CGFloat) {
        let content = layout.contentRect
        let turned = rotation == .cw90 || rotation == .cw270
        let shown = turned ? CGSize(width: region.height, height: region.width) : region.size
        guard shown.width > 0, shown.height > 0, content.width > 0, content.height > 0, scale > 0 else { return }
        let target = CGRect(x: content.minX * scale, y: (layout.canvasSize.height - content.maxY) * scale,
                            width: content.width * scale, height: content.height * scale)
        ctx.saveGState()
        ctx.clip(to: target)
        // Mirrors `Compositor.oriented` and the card's stretch of the oriented content into the content rect.
        ctx.translateBy(x: target.midX, y: target.midY)
        ctx.scaleBy(x: target.width / shown.width, y: target.height / shown.height)
        ctx.scaleBy(x: flipHorizontal ? -1 : 1, y: flipVertical ? -1 : 1)
        ctx.rotate(by: -CGFloat(rotation.rawValue) * .pi / 180)
        if fill.a > 0 {
            ctx.setFillColor(fill.cgColor)
            ctx.fill(CGRect(x: -region.width / 2, y: -region.height / 2, width: region.width, height: region.height))
        }
        ctx.draw(image, in: CGRect(x: -region.midX, y: region.midY - CGFloat(image.height),
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        ctx.restoreGState()
    }
}
