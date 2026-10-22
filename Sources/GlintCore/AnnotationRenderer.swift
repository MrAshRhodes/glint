import CoreGraphics
import CoreImage
import CoreText
import Foundation

enum TextDrawing {
    static func font(name: String, size: CGFloat, bold: Bool) -> CTFont {
        let base = CTFontCreateWithName(name as CFString, size, nil)
        guard bold else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .boldTrait, .boldTrait) ?? base
    }

    static func lines(_ string: String, font: CTFont, color: CGColor, maxWidth: CGFloat) -> [CTLine] {
        var result: [CTLine] = []
        for paragraph in string.components(separatedBy: "\n") {
            let attr = NSAttributedString(string: paragraph.isEmpty ? " " : paragraph, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ])
            if maxWidth > 0 {
                let typesetter = CTTypesetterCreateWithAttributedString(attr)
                var start: CFIndex = 0
                while start < attr.length {
                    let count = max(CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth)), 1)
                    result.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
                    start += count
                }
            } else {
                result.append(CTLineCreateWithAttributedString(attr))
            }
        }
        return result
    }

    static func lineHeight(_ font: CTFont) -> CGFloat {
        CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }

    static func blockSize(_ lines: [CTLine], font: CTFont) -> CGSize {
        let w = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        return CGSize(width: w, height: lineHeight(font) * CGFloat(lines.count))
    }

    /// Draws `lines` with their top-left at `topLeft`. `flipped` = the context's y axis points down.
    static func draw(_ lines: [CTLine], font: CTFont, topLeft: CGPoint, in ctx: CGContext, flipped: Bool,
                     centeredIn width: CGFloat? = nil) {
        let ascent = CTFontGetAscent(font), lh = lineHeight(font)
        ctx.saveGState()
        ctx.textMatrix = flipped ? CGAffineTransform(scaleX: 1, y: -1) : .identity
        for (i, line) in lines.enumerated() {
            var x = topLeft.x
            if let width {
                x += (width - CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) / 2
            }
            let baseline = flipped ? topLeft.y + ascent + CGFloat(i) * lh : topLeft.y - ascent - CGFloat(i) * lh
            ctx.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }
}

enum ImageDrawing {
    /// Draws an image upright inside a rect in a context whose y axis points down.
    static func drawFlipped(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    static let ciContext = CIContext(options: [
        .workingColorSpace: ColorSpaces.sRGB, .outputColorSpace: ColorSpaces.sRGB,
    ])
}

public enum AnnotationRenderer {
    /// Draws annotations in z order. `ctx` must map image space (pixels, origin top-left, y down) onto the target.
    /// `source` supplies pixels for Blur only; if nil Blur falls back to solid boxes.
    /// Secure redactions are removed from the sampling source before any Blur is drawn.
    public static func draw(in ctx: CGContext, annotations: [Annotation], imageSize: CGSize, source: CGImage? = nil) {
        let ordered = annotations.enumerated().sorted {
            $0.element.z != $1.element.z ? $0.element.z < $1.element.z : $0.offset < $1.offset
        }.map(\.element)
        let redactions = ordered.filter(\.isRedaction)
        let samplingSource: CGImage?
        if let source, !redactions.isEmpty, ordered.contains(where: \.isObfuscation) {
            // A later Blur must not restore a secret or spread it outside its redaction.
            samplingSource = redactedSource(source, annotations: redactions, imageSize: imageSize)
        } else {
            samplingSource = source
        }
        for a in ordered {
            ctx.saveGState()
            draw(a, in: ctx, imageSize: imageSize, source: samplingSource)
            ctx.restoreGState()
        }
    }

    private static func redactedSource(_ source: CGImage, annotations: [Annotation], imageSize: CGSize) -> CGImage? {
        guard imageSize.width > 0, imageSize.height > 0,
              let ctx = GlintBitmap.makeContext(width: source.width, height: source.height) else { return nil }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        ctx.translateBy(x: 0, y: CGFloat(source.height))
        ctx.scaleBy(x: CGFloat(source.width) / imageSize.width, y: -CGFloat(source.height) / imageSize.height)
        for a in annotations {
            ctx.saveGState()
            draw(a, in: ctx, imageSize: imageSize, source: nil)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// Returns the `region` (image space, may extend beyond the image; defaults to the whole image) with
    /// annotations burned in. Areas outside the source are filled with `fill`.
    public static func bake(source: CGImage, annotations: [Annotation], region: CGRect? = nil,
                            fill: RGBAColor = .clear) -> CGImage? {
        let full = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let r = (region ?? full).integral
        guard let ctx = GlintBitmap.makeContext(width: Int(r.width), height: Int(r.height)) else { return nil }
        ctx.translateBy(x: 0, y: r.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        if fill.a > 0 {
            ctx.setFillColor(fill.cgColor)
            ctx.fill(r)
        }
        ImageDrawing.drawFlipped(source, in: full, ctx: ctx)
        draw(in: ctx, annotations: annotations, imageSize: full.size, source: source)
        return ctx.makeImage()
    }

    private static func applyStroke(_ a: Annotation, _ ctx: CGContext, widthScale: CGFloat = 1) {
        let w = CGFloat(a.style.strokeWidth) * widthScale
        ctx.setStrokeColor(a.style.color.cgColor)
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if a.style.dashed { ctx.setLineDash(phase: 0, lengths: [w * 2, w * 1.5]) }
    }

    private static func draw(_ a: Annotation, in ctx: CGContext, imageSize: CGSize, source: CGImage?) {
        let s = a.style
        let opacity = CGFloat(min(max(s.opacity, 0), 1))
        let needsLayer = opacity < 1 && !a.isRedaction && !a.isObfuscation
        if needsLayer {
            ctx.setAlpha(opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer { if needsLayer { ctx.endTransparencyLayer() } }

        switch a.kind {
        case .line(let p, let q):
            applyStroke(a, ctx)
            ctx.move(to: p); ctx.addLine(to: q); ctx.strokePath()

        case .arrow(let p, let q):
            let dx = q.x - p.x, dy = q.y - p.y
            let len = hypot(dx, dy)
            guard len > 0.5 else { return }
            let ux = dx / len, uy = dy / len
            let head = min(max(CGFloat(s.strokeWidth) * 3.5, 14), len)
            let base = CGPoint(x: q.x - ux * head * 0.8, y: q.y - uy * head * 0.8)
            applyStroke(a, ctx)
            ctx.move(to: p); ctx.addLine(to: base); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            let nx = -uy * head * 0.45, ny = ux * head * 0.45
            ctx.setFillColor(s.color.cgColor)
            ctx.move(to: q)
            ctx.addLine(to: CGPoint(x: q.x - ux * head + nx, y: q.y - uy * head + ny))
            ctx.addLine(to: CGPoint(x: q.x - ux * head - nx, y: q.y - uy * head - ny))
            ctx.closePath()
            ctx.fillPath()

        case .rectangle(let r):
            let path = CGPath(roundedRect: r.standardized, cornerWidth: min(CGFloat(s.cornerRadius), min(abs(r.width), abs(r.height)) / 2),
                              cornerHeight: min(CGFloat(s.cornerRadius), min(abs(r.width), abs(r.height)) / 2), transform: nil)
            if let f = s.fill { ctx.setFillColor(f.cgColor); ctx.addPath(path); ctx.fillPath() }
            applyStroke(a, ctx)
            ctx.addPath(path); ctx.strokePath()

        case .ellipse(let r):
            if let f = s.fill { ctx.setFillColor(f.cgColor); ctx.fillEllipse(in: r.standardized) }
            applyStroke(a, ctx)
            ctx.strokeEllipse(in: r.standardized)

        case .pen(let pts):
            guard pts.count > 1 else {
                if let p = pts.first {
                    ctx.setFillColor(s.color.cgColor)
                    let w = CGFloat(s.strokeWidth)
                    ctx.fillEllipse(in: CGRect(x: p.x - w / 2, y: p.y - w / 2, width: w, height: w))
                }
                return
            }
            applyStroke(a, ctx)
            addSmoothPath(pts, ctx)
            ctx.strokePath()

        case .highlighter(let pts):
            guard pts.count > 1 else { return }
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(s.color.with(alpha: 0.45).cgColor)
            ctx.setLineWidth(CGFloat(s.strokeWidth) * 3)
            ctx.setLineCap(.butt)
            ctx.setLineJoin(.round)
            addSmoothPath(pts, ctx)
            ctx.strokePath()

        case .text(let origin, let string, let maxWidth):
            let font = TextDrawing.font(name: s.fontName, size: CGFloat(s.fontSize), bold: s.bold)
            let lines = TextDrawing.lines(string, font: font, color: s.color.cgColor, maxWidth: CGFloat(maxWidth))
            let size = TextDrawing.blockSize(lines, font: font)
            if let f = s.fill {
                let box = CGRect(origin: origin, size: size).insetBy(dx: -6, dy: -4)
                ctx.setFillColor(f.cgColor)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            }
            TextDrawing.draw(lines, font: font, topLeft: origin, in: ctx, flipped: true)

        case .counter(let c, let n):
            let r = counterRadius(s)
            let circle = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            ctx.setFillColor((s.fill ?? s.color).cgColor)
            ctx.fillEllipse(in: circle)
            ctx.setStrokeColor(RGBAColor.white.cgColor)
            ctx.setLineWidth(max(2, r * 0.1))
            ctx.strokeEllipse(in: circle.insetBy(dx: r * 0.05, dy: r * 0.05))
            let font = TextDrawing.font(name: s.fontName, size: r * 1.1, bold: true)
            let lines = TextDrawing.lines(String(n), font: font, color: RGBAColor.white.cgColor, maxWidth: 0)
            let size = TextDrawing.blockSize(lines, font: font)
            TextDrawing.draw(lines, font: font, topLeft: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2),
                             in: ctx, flipped: true)

        case .emoji(let c, let string):
            let font = TextDrawing.font(name: "Apple Color Emoji", size: CGFloat(s.fontSize) * 1.3, bold: false)
            let lines = TextDrawing.lines(string, font: font, color: RGBAColor.black.cgColor, maxWidth: 0)
            let size = TextDrawing.blockSize(lines, font: font)
            TextDrawing.draw(lines, font: font, topLeft: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2),
                             in: ctx, flipped: true)

        case .spotlight(let r):
            let full = CGRect(origin: .zero, size: imageSize)
            ctx.addRect(full)
            ctx.addPath(CGPath(roundedRect: r.standardized, cornerWidth: min(CGFloat(s.cornerRadius), r.width / 2),
                               cornerHeight: min(CGFloat(s.cornerRadius), r.height / 2), transform: nil))
            ctx.setFillColor(RGBAColor.black.with(alpha: 0.6 * Double(opacity)).cgColor)
            ctx.fillPath(using: .evenOdd)

        case .redact(let r):
            drawRedaction(r, style: s, mosaic: false, in: ctx, imageSize: imageSize)

        case .blur(let r):
            drawSampled(r.standardized, in: ctx, imageSize: imageSize, source: source, fallback: s.color) { crop in
                blurred(crop, radius: max(CGFloat(s.intensity), 6))
            }

        case .pixelate(let r):
            drawRedaction(r, style: s, mosaic: true, in: ctx, imageSize: imageSize)
        }
    }

    private static let mosaicPalette: [RGBAColor] = [0.18, 0.28, 0.38, 0.48, 0.58].map {
        RGBAColor(r: $0, g: $0, b: $0)
    }

    private static func drawRedaction(_ rect: CGRect, style: AnnotationStyle, mosaic: Bool,
                                      in ctx: CGContext, imageSize: CGSize) {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else { return }
        let clipped = rect.standardized.intersection(CGRect(origin: .zero, size: imageSize))
        guard !clipped.isNull, !clipped.isEmpty else { return }
        // Cover every touched device pixel, including tiny selections at fractional preview/export scales.
        let coverage = ctx.convertToUserSpace(ctx.convertToDeviceSpace(clipped).integral)
        ctx.setShouldAntialias(false)
        ctx.setAlpha(1)
        ctx.setBlendMode(.normal)
        ctx.setFillColor((mosaic ? mosaicPalette[0] : style.color).with(alpha: 1).cgColor)
        ctx.fill(coverage)
        guard mosaic || style.redactionPattern == .checkerboard else { return }

        // The opaque undercoat makes tile seams safe even if the target transform rounds them differently.
        ctx.clip(to: coverage)
        let cell = CGFloat(style.intensity.isFinite ? max(style.intensity, 6) : 12)
        let columns = Int(ceil((coverage.maxX - clipped.minX) / cell))
        let rows = Int(ceil((coverage.maxY - clipped.minY) / cell))
        for row in 0..<rows {
            for column in 0..<columns {
                let color: RGBAColor
                if mosaic {
                    var hash = UInt64(column) &* 0x9E3779B97F4A7C15 &+ UInt64(row) &* 0xBF58476D1CE4E5B9
                    hash = (hash ^ (hash >> 30)) &* 0xBF58476D1CE4E5B9
                    hash = (hash ^ (hash >> 27)) &* 0x94D049BB133111EB
                    let index = Int((hash ^ (hash >> 31)) % UInt64(mosaicPalette.count))
                    color = style.pixelateHighlight && index == 0 ? style.color : mosaicPalette[index]
                } else {
                    color = (row + column).isMultiple(of: 2) ? style.color : style.redactionSecondaryColor
                }
                ctx.setFillColor(color.with(alpha: 1).cgColor)
                let x = column == 0 ? coverage.minX : clipped.minX + CGFloat(column) * cell
                let y = row == 0 ? coverage.minY : clipped.minY + CGFloat(row) * cell
                ctx.fill(CGRect(x: x, y: y,
                                width: clipped.minX + CGFloat(column + 1) * cell - x,
                                height: clipped.minY + CGFloat(row + 1) * cell - y))
            }
        }
    }

    private static func addSmoothPath(_ pts: [CGPoint], _ ctx: CGContext) {
        ctx.move(to: pts[0])
        if pts.count == 2 { ctx.addLine(to: pts[1]); return }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            ctx.addQuadCurve(to: mid, control: pts[i])
        }
        ctx.addLine(to: pts[pts.count - 1])
    }

    private static func drawSampled(_ rect: CGRect, in ctx: CGContext, imageSize: CGSize, source: CGImage?,
                                    fallback: RGBAColor, transform: (CGImage) -> CGImage?) {
        let bounds = CGRect(origin: .zero, size: imageSize)
        let clipped = rect.intersection(bounds).integral.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return }
        guard let source else {
            ctx.setFillColor(fallback.with(alpha: 1).cgColor)
            ctx.fill(clipped)
            return
        }
        let sx = CGFloat(source.width) / imageSize.width, sy = CGFloat(source.height) / imageSize.height
        let srcRect = CGRect(x: clipped.minX * sx, y: clipped.minY * sy, width: clipped.width * sx, height: clipped.height * sy).integral
        guard let crop = source.glintCropped(to: srcRect), let result = transform(crop) else {
            ctx.setFillColor(fallback.with(alpha: 1).cgColor)
            ctx.fill(clipped)
            return
        }
        ctx.saveGState()
        ctx.clip(to: clipped)
        ImageDrawing.drawFlipped(result, in: clipped, ctx: ctx)
        ctx.restoreGState()
    }

    static func blurred(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let out = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return ImageDrawing.ciContext.createCGImage(out, from: input.extent, format: .RGBA8, colorSpace: ColorSpaces.sRGB)
    }

}
