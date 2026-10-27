import CoreGraphics
import CoreImage
import Foundation

public struct RenderLayout: Equatable, Sendable {
    /// All rects in output pixels, origin top-left.
    public var canvasSize: CGSize
    public var cardRect: CGRect
    /// The base content (auto-balance crop or full image) the card wraps.
    public var contentRect: CGRect
    /// Content plus the inset band: the area the frame chrome surrounds.
    public var screenRect: CGRect
    public var padding: CGFloat
    public var inset: CGFloat
    /// Top frame inset (title bar) in pixels.
    public var barHeight: CGFloat
    /// Total points→pixels factor (`backingScale × outputScale`).
    public var factor: CGFloat
    /// Where the content including magnifier insets beyond the base content is drawn; contains `contentRect`
    /// and equals it when nothing overflows.
    public var overflowRect: CGRect
}

public struct RenderResult {
    public var image: CGImage
    public var layout: RenderLayout
    public var border: BorderInfo?
    /// The base region in source image pixels (origin top-left) that `layout.contentRect` shows: the
    /// auto-balance crop rect or the full image.
    public var region: CGRect
}

/// Why a render could not produce a safe output.
public enum RenderError: Error, LocalizedError, Equatable {
    /// The annotations (including redactions) could not be burned into the image. Exporting the
    /// unannotated source instead could leak redacted content, so the render fails closed.
    case annotationsNotApplied

    public var errorDescription: String? {
        switch self {
        case .annotationsNotApplied:
            return "Annotations and redactions could not be applied to the image, so it was not exported."
        }
    }
}

public enum Compositor {
    /// Burns `annotations` into `source`, cropped to `region` with `fill` outside the source.
    typealias Baker = (_ source: CGImage, _ annotations: [Annotation], _ region: CGRect?, _ fill: RGBAColor) -> CGImage?

    static let defaultBaker: Baker = { AnnotationRenderer.bake(source: $0, annotations: $1, region: $2, fill: $3) }

    /// Output image of the full "beautify" pipeline. Deterministic for identical inputs.
    /// Throws `RenderError.annotationsNotApplied` instead of returning unannotated pixels.
    public static func render(image: CGImage, settings: RenderSettings, annotations: [Annotation] = [],
                              backingScale: CGFloat = 1, backgroundImage: CGImage? = nil,
                              wallpaper: CGImage? = nil) throws -> CGImage {
        try renderDetailed(image: image, settings: settings, annotations: annotations,
                           backingScale: backingScale, backgroundImage: backgroundImage, wallpaper: wallpaper).image
    }

    /// Throws `RenderError.annotationsNotApplied` instead of returning unannotated pixels.
    public static func renderDetailed(image: CGImage, settings: RenderSettings, annotations: [Annotation] = [],
                                      backingScale: CGFloat = 1, backgroundImage: CGImage? = nil,
                                      wallpaper: CGImage? = nil) throws -> RenderResult {
        try renderDetailed(image: image, settings: settings, annotations: annotations, backingScale: backingScale,
                           backgroundImage: backgroundImage, wallpaper: wallpaper, bake: defaultBaker)
    }

    static func renderDetailed(image: CGImage, settings: RenderSettings, annotations: [Annotation] = [],
                               backingScale: CGFloat = 1, backgroundImage: CGImage? = nil,
                               wallpaper: CGImage? = nil, bake: Baker) throws -> RenderResult {
        let source = image.glintSRGB()
        let imageBounds = CGRect(origin: .zero, size: source.pixelSize)

        // 1. auto-balance crop + annotations burned into content (redactions destroy pixels here)
        var border: BorderInfo?
        var region: CGRect?
        if settings.autoBalance, let b = AutoBalance.detectBorder(in: source) {
            border = b
            region = AutoBalance.balanceCropRect(imageSize: source.pixelSize, border: b)
        }
        let base = (region ?? imageBounds).integral
        let expanded = expandedRegion(base: base, annotations: annotations)
        var content = source
        var contentRegion = imageBounds
        var overflow = FrameInsets.zero
        if expanded != base {
            // Magnifier insets reach beyond the base content: bake them as well, transparent outside the base.
            // Crop the source to the visible base first so balanced-away borders and full-image effects
            // (spotlight dimming) never appear in the overflow area.
            var bakeSource = source, bakeAnnotations = annotations
            var bakeRegion = expanded, fillBase = base
            let visible = base.intersection(imageBounds).integral
            if visible != imageBounds, !visible.isNull, visible.width >= 1, visible.height >= 1,
               let cropped = source.cropping(to: visible) {
                let d = CGSize(width: -visible.minX, height: -visible.minY)
                bakeSource = cropped
                bakeAnnotations = annotations.map { $0.translated(by: d) }
                bakeRegion = expanded.offsetBy(dx: d.width, dy: d.height)
                fillBase = base.offsetBy(dx: d.width, dy: d.height)
            }
            guard let baked = bake(bakeSource, bakeAnnotations, bakeRegion, .clear) else {
                throw RenderError.annotationsNotApplied
            }
            content = underlay(border?.color ?? .clear, in: fillBase, of: bakeRegion, beneath: baked)
            contentRegion = base
            overflow = FrameInsets(top: base.minY - expanded.minY, left: base.minX - expanded.minX,
                                   bottom: expanded.maxY - base.maxY, right: expanded.maxX - base.maxX)
        } else if region != nil || !annotations.isEmpty {
            if let baked = bake(source, annotations, region, border?.color ?? .clear) {
                content = baked
                contentRegion = base
            } else if !annotations.isEmpty {
                // Fail closed: never fall back to the source when annotations (e.g. redactions) exist.
                throw RenderError.annotationsNotApplied
            }
            // Without annotations only the auto-balance crop is lost, so the source is a safe fallback.
        }

        // 2. orientation
        content = oriented(content, rotation: settings.rotation, flipH: settings.flipHorizontal, flipV: settings.flipVertical)
        overflow = oriented(overflow, rotation: settings.rotation, flipH: settings.flipHorizontal, flipV: settings.flipVertical)

        // 3. layout
        let insetColor: RGBAColor? = settings.insetColor ?? border?.color
        let insetApplied = insetColor != nil && floor(settings.inset) >= 1
        let baseSize = CGSize(width: content.pixelSize.width - overflow.left - overflow.right,
                              height: content.pixelSize.height - overflow.top - overflow.bottom)
        let layout = layout(contentSize: baseSize, insetApplied: insetApplied, settings: settings,
                            backingScale: backingScale, overflow: overflow)
        let W = Int(layout.canvasSize.width), H = Int(layout.canvasSize.height)
        guard let ctx = GlintBitmap.makeContext(width: W, height: H) else {
            return RenderResult(image: content, layout: layout, border: border, region: contentRegion)
        }
        let k = layout.factor

        // 4. background
        if settings.usesDesktopWallpaper, let wallpaper {
            BackgroundRenderer.fill(.image(path: "", fit: .fill), in: ctx, size: layout.canvasSize, scale: k, image: wallpaper)
        } else {
            var bgImage = backgroundImage
            if bgImage == nil, case .image(let path, _) = settings.background { bgImage = GlintImageIO.load(url: URL(fileURLWithPath: path)) }
            BackgroundRenderer.fill(settings.background, in: ctx, size: layout.canvasSize, scale: k, image: bgImage)
        }

        // 5. card (+shadow), optionally tilted
        if settings.tilt.isFlat {
            drawCard(in: ctx, content: content, layout: layout, settings: settings, insetColor: insetApplied ? insetColor : nil)
        } else if let layer = GlintBitmap.makeContext(width: W, height: H) {
            drawCard(in: layer, content: content, layout: layout, settings: settings, insetColor: insetApplied ? insetColor : nil)
            if let flat = layer.makeImage(), let tilted = perspective(flat, tilt: settings.tilt) {
                ctx.draw(tilted, in: CGRect(x: 0, y: 0, width: W, height: H))
            } else if let flat = layer.makeImage() {
                ctx.draw(flat, in: CGRect(x: 0, y: 0, width: W, height: H))
            }
        }

        // 6. watermark
        if settings.watermark.enabled { drawWatermark(settings.watermark, in: ctx, canvas: layout.canvasSize, factor: k) }

        return RenderResult(image: ctx.makeImage() ?? content, layout: layout, border: border, region: contentRegion)
    }

    /// Longest side, and largest area, in pixels the magnifier overflow may grow the content to (unless `base` is
    /// already larger). Only absurd geometry reaches them.
    static let maxExpandedSide: CGFloat = 16384
    static let maxExpandedArea: CGFloat = 16384 * 8192

    /// `base` grown to include every magnifier's render bounds (integral). Growth is capped to the
    /// `maxExpandedSide`/`maxExpandedArea` budget so absurd geometry cannot exhaust memory.
    static func expandedRegion(base: CGRect, annotations: [Annotation]) -> CGRect {
        var r = base
        for case let b? in annotations.map(\.magnifierRenderBounds)
        where !b.isNull && [b.minX, b.minY, b.maxX, b.maxY].allSatisfy(\.isFinite) {
            r = r.union(b)
        }
        guard r != base else { return base }
        var w = min(r.width, max(maxExpandedSide, base.width)), h = min(r.height, max(maxExpandedSide, base.height))
        let budget = max(maxExpandedArea, base.width * base.height)
        if w * h > budget {
            let s = (budget / (w * h)).squareRoot()
            w = max(base.width, (w * s).rounded(.down))
            h = max(base.height, (h * s).rounded(.down))
        }
        // Splits the allowed length between both sides, giving a side needing less than half the growth the rest.
        func fit(_ lo: CGFloat, _ hi: CGFloat, base b0: CGFloat, _ b1: CGFloat, length: CGFloat) -> (CGFloat, CGFloat) {
            let extra = max(length - (b1 - b0), 0)
            let before = b0 - lo, after = hi - b1
            guard before + after > extra else { return (lo, hi) }
            let first = min(before, max(extra / 2, extra - after))
            return (b0 - first, b1 + (extra - first))
        }
        let (x0, x1) = fit(r.minX, r.maxX, base: base.minX, base.maxX, length: w)
        let (y0, y1) = fit(r.minY, r.maxY, base: base.minY, base.maxY, length: h)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).integral
    }

    /// `baked` (covering `expanded`) over `fill` limited to `base`; both rects in image space.
    private static func underlay(_ fill: RGBAColor, in base: CGRect, of expanded: CGRect, beneath baked: CGImage) -> CGImage {
        guard fill.a > 0, let ctx = GlintBitmap.makeContext(width: baked.width, height: baked.height) else { return baked }
        ctx.setFillColor(fill.cgColor)
        ctx.fill(CGRect(x: base.minX - expanded.minX, y: expanded.maxY - base.maxY, width: base.width, height: base.height))
        ctx.draw(baked, in: CGRect(x: 0, y: 0, width: baked.width, height: baked.height))
        return ctx.makeImage() ?? baked
    }

    /// Geometry only. `contentSize` is the (balanced, rotated) base content in pixels before `outputScale`;
    /// `overflow` is how far magnifier insets reach beyond it on each side, in the same pixels. The card wraps
    /// only the base content; the canvas grows so the overflow keeps `padding` from every edge.
    public static func layout(contentSize: CGSize, insetApplied: Bool, settings: RenderSettings,
                              backingScale: CGFloat, overflow: FrameInsets = .zero) -> RenderLayout {
        let outScale = CGFloat(max(settings.outputScale, 0.1))
        let k = max(backingScale, 0.1) * outScale
        let padding = (CGFloat(floor(max(settings.padding, 0))) * k).rounded()
        let inset = insetApplied ? (CGFloat(floor(max(settings.inset, 0))) * k).rounded() : 0
        let frame = settings.windowFrame.insets
        func px(_ points: Double) -> CGFloat { (CGFloat(max(points, 0)) * k).rounded() }
        let bar = px(frame.top), left = px(frame.left), bottom = px(frame.bottom), right = px(frame.right)
        let cw = max((contentSize.width * outScale).rounded(), 1)
        let ch = max((contentSize.height * outScale).rounded(), 1)
        // Split the scaled expanded size so the overflow rect stays consistent with the drawn content.
        func split(_ size: CGFloat, _ base: CGFloat, _ lo: Double, _ hi: Double) -> (CGFloat, CGFloat) {
            let lo = CGFloat(lo.isFinite ? max(lo, 0) : 0), hi = CGFloat(hi.isFinite ? max(hi, 0) : 0)
            let total = max(((size + lo + hi) * outScale).rounded(), base)
            let first = min((lo * outScale).rounded(), total - base)
            return (first, total - base - first)
        }
        let (oLeft, oRight) = split(contentSize.width, cw, overflow.left, overflow.right)
        let (oTop, oBottom) = split(contentSize.height, ch, overflow.top, overflow.bottom)
        let cardW = cw + 2 * inset + left + right, cardH = ch + 2 * inset + bar + bottom
        let localCard = CGRect(x: 0, y: 0, width: cardW, height: cardH)
        let localContent = CGRect(x: left + inset, y: bar + inset, width: cw, height: ch)
        let localOverflow = CGRect(x: localContent.minX - oLeft, y: localContent.minY - oTop,
                                   width: cw + oLeft + oRight, height: ch + oTop + oBottom)
        let used = localCard.union(localOverflow)
        var W = used.width + 2 * padding, H = used.height + 2 * padding
        if let r = settings.aspectRatio.ratio {
            if W / H < r { W = (H * r).rounded(.up) } else { H = (W / r).rounded(.up) }
        }
        let dx = floor((W - used.width) / 2) - used.minX, dy = floor((H - used.height) / 2) - used.minY
        let card = localCard.offsetBy(dx: dx, dy: dy)
        let contentRect = localContent.offsetBy(dx: dx, dy: dy)
        return RenderLayout(canvasSize: CGSize(width: W, height: H), cardRect: card, contentRect: contentRect,
                            screenRect: contentRect.insetBy(dx: -inset, dy: -inset),
                            padding: padding, inset: inset, barHeight: bar, factor: k,
                            overflowRect: localOverflow.offsetBy(dx: dx, dy: dy))
    }

    // MARK: Orientation

    /// Per-side overflow after the same rotation and flips `oriented(_:rotation:flipH:flipV:)` applies.
    static func oriented(_ i: FrameInsets, rotation: Rotation, flipH: Bool, flipV: Bool) -> FrameInsets {
        var o: FrameInsets
        switch rotation {
        case .none: o = i
        case .cw90: o = FrameInsets(top: i.left, left: i.bottom, bottom: i.right, right: i.top)
        case .cw180: o = FrameInsets(top: i.bottom, left: i.right, bottom: i.top, right: i.left)
        case .cw270: o = FrameInsets(top: i.right, left: i.top, bottom: i.left, right: i.bottom)
        }
        if flipH { swap(&o.left, &o.right) }
        if flipV { swap(&o.top, &o.bottom) }
        return o
    }

    static func oriented(_ image: CGImage, rotation: Rotation, flipH: Bool, flipV: Bool) -> CGImage {
        guard rotation != .none || flipH || flipV else { return image }
        let swap = rotation == .cw90 || rotation == .cw270
        let w = swap ? image.height : image.width, h = swap ? image.width : image.height
        guard let ctx = GlintBitmap.makeContext(width: w, height: h) else { return image }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.scaleBy(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
        ctx.rotate(by: -CGFloat(rotation.rawValue) * .pi / 180)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage() ?? image
    }

    // MARK: Card

    private static func toBL(_ r: CGRect, canvasHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: canvasHeight - r.maxY, width: r.width, height: r.height)
    }

    private static func drawCard(in ctx: CGContext, content: CGImage, layout: RenderLayout, settings: RenderSettings,
                                 insetColor: RGBAColor?) {
        let H = layout.canvasSize.height, k = layout.factor
        let card = toBL(layout.cardRect, canvasHeight: H)
        let cornerRadius = settings.windowFrame.metrics.corner.resolve(settings.cornerRadius)
        let radius = min(CGFloat(max(cornerRadius, 0)) * k, min(card.width, card.height) / 2)
        let path = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // shadows: render the shape far off-canvas so only its shadow lands inside
        let far = layout.canvasSize.width + card.width + 1000
        for layer in settings.shadow.resolvedLayers where layer.opacity > 0 {
            ctx.saveGState()
            let c = settings.shadow.color
            ctx.setShadow(offset: CGSize(width: CGFloat(layer.offsetX) * k + far, height: -CGFloat(layer.offsetY) * k),
                          blur: CGFloat(layer.blur) * k,
                          color: c.with(alpha: c.a * min(max(layer.opacity, 0), 1)).cgColor)
            ctx.setFillColor(RGBAColor.black.cgColor)
            ctx.addPath(path.copy(using: [CGAffineTransform(translationX: -far, y: 0)]) ?? path)
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if let insetColor {
            ctx.setFillColor(insetColor.cgColor)
            ctx.fill(card)
        }
        let frame = FrameCanvas(ctx: ctx, card: card, screen: toBL(layout.screenRect, canvasHeight: H),
                                bar: layout.barHeight, k: k, radius: radius, frame: settings.windowFrame)
        FrameRenderer.drawChrome(frame)
        ctx.interpolationQuality = .high
        ctx.draw(content, in: toBL(layout.overflowRect, canvasHeight: H))
        FrameRenderer.drawOverlay(frame)
        ctx.restoreGState()

        if settings.border.enabled, settings.border.width > 0 {
            let w = CGFloat(settings.border.width) * k
            ctx.saveGState()
            ctx.setStrokeColor(settings.border.color.cgColor)
            ctx.setLineWidth(w)
            let inner = card.insetBy(dx: w / 2, dy: w / 2)
            let r = max(radius - w / 2, 0)
            ctx.addPath(CGPath(roundedRect: inner, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Magnifier insets beyond the card float over the background. The card already drew everything inside
        // it and the screenshot's own rectangle stays clipped by the card's corners.
        if layout.overflowRect != layout.contentRect {
            ctx.saveGState()
            let overflow = toBL(layout.overflowRect, canvasHeight: H)
            let everything = overflow.union(card)
            ctx.addRect(everything)
            ctx.addPath(path)
            ctx.clip(using: .evenOdd)
            ctx.addRect(everything)
            ctx.addRect(toBL(layout.contentRect, canvasHeight: H))
            ctx.clip(using: .evenOdd)
            ctx.interpolationQuality = .high
            ctx.draw(content, in: overflow)
            ctx.restoreGState()
        }
    }

    // MARK: Tilt

    private static func perspective(_ image: CGImage, tilt: Tilt) -> CGImage? {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let ax = CGFloat(tilt.x) * .pi / 180, ay = CGFloat(tilt.y) * .pi / 180
        let dist = 2 * max(W, H)
        func project(_ p: CGPoint) -> CGPoint {
            let x = p.x - W / 2, y = p.y - H / 2
            let y1 = y * cos(ax), z1 = y * sin(ax)
            let x2 = x * cos(ay) + z1 * sin(ay)
            let z2 = -x * sin(ay) + z1 * cos(ay)
            let s = dist / (dist - z2)
            return CGPoint(x: x2 * s, y: y1 * s)
        }
        let corners = [CGPoint(x: 0, y: H), CGPoint(x: W, y: H), CGPoint(x: W, y: 0), CGPoint(x: 0, y: 0)] // TL TR BR BL (bottom-left space)
        var projected = corners.map(project)
        let maxX = projected.map { abs($0.x) }.max() ?? 1, maxY = projected.map { abs($0.y) }.max() ?? 1
        let fit = min(1, (W / 2) / maxX, (H / 2) / maxY)
        projected = projected.map { CGPoint(x: $0.x * fit + W / 2, y: $0.y * fit + H / 2) }

        guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        let keys = ["inputTopLeft", "inputTopRight", "inputBottomRight", "inputBottomLeft"]
        for (key, p) in zip(keys, projected) { filter.setValue(CIVector(x: p.x, y: p.y), forKey: key) }
        guard let out = filter.outputImage else { return nil }
        return ImageDrawing.ciContext.createCGImage(out, from: CGRect(x: 0, y: 0, width: W, height: H),
                                                    format: .RGBA8, colorSpace: ColorSpaces.sRGB)
    }

    // MARK: Watermark

    private static func drawWatermark(_ wm: WatermarkSettings, in ctx: CGContext, canvas: CGSize, factor k: CGFloat) {
        let margin = 14 * k
        let alpha = CGFloat(min(max(wm.opacity, 0), 1))
        func origin(_ size: CGSize) -> CGPoint {
            let x: CGFloat, y: CGFloat
            switch wm.position {
            case .topLeft, .centerLeft, .bottomLeft: x = margin
            case .topCenter, .center, .bottomCenter: x = (canvas.width - size.width) / 2
            case .topRight, .centerRight, .bottomRight: x = canvas.width - size.width - margin
            }
            switch wm.position {
            case .topLeft, .topCenter, .topRight: y = canvas.height - size.height - margin
            case .centerLeft, .center, .centerRight: y = (canvas.height - size.height) / 2
            case .bottomLeft, .bottomCenter, .bottomRight: y = margin
            }
            return CGPoint(x: x, y: y)
        }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(alpha)
        switch wm.kind {
        case .text:
            guard !wm.text.isEmpty else { return }
            let font = TextDrawing.font(name: "Helvetica Neue", size: CGFloat(wm.size) * k, bold: false)
            let shadowLines = TextDrawing.lines(wm.text, font: font, color: RGBAColor.black.cgColor, maxWidth: 0)
            let lines = TextDrawing.lines(wm.text, font: font, color: wm.color.cgColor, maxWidth: 0)
            let size = TextDrawing.blockSize(lines, font: font)
            let o = origin(size)
            TextDrawing.draw(shadowLines, font: font, topLeft: CGPoint(x: o.x + k, y: o.y + size.height - k), in: ctx, flipped: false)
            TextDrawing.draw(lines, font: font, topLeft: CGPoint(x: o.x, y: o.y + size.height), in: ctx, flipped: false)
        case .image:
            guard let path = wm.imagePath, let img = GlintImageIO.load(url: URL(fileURLWithPath: path)) else { return }
            let h = CGFloat(wm.size) * k
            let size = CGSize(width: h * CGFloat(img.width) / CGFloat(img.height), height: h)
            let o = origin(size)
            ctx.draw(img, in: CGRect(origin: o, size: size))
        }
    }
}
