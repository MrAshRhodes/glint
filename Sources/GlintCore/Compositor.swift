import CoreGraphics
import CoreImage
import Foundation

public struct RenderLayout: Equatable, Sendable {
    /// All rects in output pixels, origin top-left.
    public var canvasSize: CGSize
    public var cardRect: CGRect
    public var contentRect: CGRect
    /// Content plus the inset band: the area the frame chrome surrounds.
    public var screenRect: CGRect
    public var padding: CGFloat
    public var inset: CGFloat
    /// Top frame inset (title bar) in pixels.
    public var barHeight: CGFloat
    /// Total points→pixels factor (`backingScale × outputScale`).
    public var factor: CGFloat
}

public struct RenderResult {
    public var image: CGImage
    public var layout: RenderLayout
    public var border: BorderInfo?
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

        // 1. auto-balance crop + annotations burned into content (redactions destroy pixels here)
        var border: BorderInfo?
        var region: CGRect?
        if settings.autoBalance, let b = AutoBalance.detectBorder(in: source) {
            border = b
            region = AutoBalance.balanceCropRect(imageSize: source.pixelSize, border: b)
        }
        var content = source
        if region != nil || !annotations.isEmpty {
            if let baked = bake(source, annotations, region, border?.color ?? .clear) {
                content = baked
            } else if !annotations.isEmpty {
                // Fail closed: never fall back to the source when annotations (e.g. redactions) exist.
                throw RenderError.annotationsNotApplied
            }
            // Without annotations only the auto-balance crop is lost, so the source is a safe fallback.
        }

        // 2. orientation
        content = oriented(content, rotation: settings.rotation, flipH: settings.flipHorizontal, flipV: settings.flipVertical)

        // 3. layout
        let insetColor: RGBAColor? = settings.insetColor ?? border?.color
        let insetApplied = insetColor != nil && floor(settings.inset) >= 1
        let layout = layout(contentSize: content.pixelSize, insetApplied: insetApplied, settings: settings,
                            backingScale: backingScale)
        let W = Int(layout.canvasSize.width), H = Int(layout.canvasSize.height)
        guard let ctx = GlintBitmap.makeContext(width: W, height: H) else {
            return RenderResult(image: content, layout: layout, border: border)
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

        return RenderResult(image: ctx.makeImage() ?? content, layout: layout, border: border)
    }

    /// Geometry only. `contentSize` is the (balanced, rotated) content in pixels before `outputScale`.
    public static func layout(contentSize: CGSize, insetApplied: Bool, settings: RenderSettings,
                              backingScale: CGFloat) -> RenderLayout {
        let outScale = CGFloat(max(settings.outputScale, 0.1))
        let k = max(backingScale, 0.1) * outScale
        let padding = (CGFloat(floor(max(settings.padding, 0))) * k).rounded()
        let inset = insetApplied ? (CGFloat(floor(max(settings.inset, 0))) * k).rounded() : 0
        let frame = settings.windowFrame.insets
        func px(_ points: Double) -> CGFloat { (CGFloat(max(points, 0)) * k).rounded() }
        let bar = px(frame.top), left = px(frame.left), bottom = px(frame.bottom), right = px(frame.right)
        let cw = max((contentSize.width * outScale).rounded(), 1)
        let ch = max((contentSize.height * outScale).rounded(), 1)
        let cardW = cw + 2 * inset + left + right, cardH = ch + 2 * inset + bar + bottom
        var W = cardW + 2 * padding, H = cardH + 2 * padding
        if let r = settings.aspectRatio.ratio {
            if W / H < r { W = (H * r).rounded(.up) } else { H = (W / r).rounded(.up) }
        }
        let card = CGRect(x: floor((W - cardW) / 2), y: floor((H - cardH) / 2), width: cardW, height: cardH)
        let contentRect = CGRect(x: card.minX + left + inset, y: card.minY + bar + inset, width: cw, height: ch)
        return RenderLayout(canvasSize: CGSize(width: W, height: H), cardRect: card, contentRect: contentRect,
                            screenRect: contentRect.insetBy(dx: -inset, dy: -inset),
                            padding: padding, inset: inset, barHeight: bar, factor: k)
    }

    // MARK: Orientation

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
        ctx.draw(content, in: toBL(layout.contentRect, canvasHeight: H))
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
