import CoreGraphics
import Foundation

public struct AnnotationStyle: Codable, Equatable, Hashable, Sendable {
    public var color: RGBAColor
    public var fill: RGBAColor?
    /// Stroke width in image pixels.
    public var strokeWidth: Double
    public var opacity: Double
    public var fontName: String
    public var fontSize: Double
    public var bold: Bool
    /// Blur radius (blur) or cell size (pixelate), image pixels.
    public var intensity: Double
    public var dashed: Bool
    public var cornerRadius: Double

    public init(color: RGBAColor = .red, fill: RGBAColor? = nil, strokeWidth: Double = 5, opacity: Double = 1,
                fontName: String = "Helvetica Neue", fontSize: Double = 30, bold: Bool = true,
                intensity: Double = 12, dashed: Bool = false, cornerRadius: Double = 0) {
        self.color = color; self.fill = fill; self.strokeWidth = strokeWidth; self.opacity = opacity
        self.fontName = fontName; self.fontSize = fontSize; self.bold = bold; self.intensity = intensity
        self.dashed = dashed; self.cornerRadius = cornerRadius
    }
}

/// Geometry is in image pixels, origin top-left.
public enum AnnotationKind: Codable, Equatable, Hashable, Sendable {
    case arrow(from: CGPoint, to: CGPoint)
    case line(from: CGPoint, to: CGPoint)
    case rectangle(CGRect)
    case ellipse(CGRect)
    case pen([CGPoint])
    case highlighter([CGPoint])
    /// `origin` = top-left of the text box; `maxWidth` 0 = no wrapping.
    case text(origin: CGPoint, string: String, maxWidth: Double)
    case counter(center: CGPoint, number: Int)
    case blur(CGRect)
    case pixelate(CGRect)
    /// Solid, always fully opaque box.
    case redact(CGRect)
    /// Dims everything outside the rect.
    case spotlight(CGRect)
    case emoji(center: CGPoint, string: String)
}

public struct Annotation: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Draw order, ascending.
    public var z: Int
    public var kind: AnnotationKind
    public var style: AnnotationStyle

    public init(id: UUID = UUID(), z: Int = 0, kind: AnnotationKind, style: AnnotationStyle = AnnotationStyle()) {
        self.id = id; self.z = z; self.kind = kind; self.style = style
    }

    public var isRedaction: Bool {
        switch kind { case .blur, .pixelate, .redact: return true; default: return false }
    }

    public var boundingBox: CGRect {
        let pad = CGFloat(style.strokeWidth) / 2
        switch kind {
        case .arrow(let a, let b), .line(let a, let b):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                .insetBy(dx: -pad - 8, dy: -pad - 8)
        case .rectangle(let r), .ellipse(let r): return r.insetBy(dx: -pad, dy: -pad)
        case .blur(let r), .pixelate(let r), .redact(let r), .spotlight(let r): return r
        case .pen(let pts), .highlighter(let pts):
            guard let f = pts.first else { return .zero }
            var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
            for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -pad, dy: -pad)
        case .text(let o, let s, let maxW):
            let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            let longest = lines.map(\.count).max() ?? 1
            let w = maxW > 0 ? maxW : Double(longest) * style.fontSize * 0.6
            return CGRect(x: o.x, y: o.y, width: w, height: Double(lines.count) * style.fontSize * 1.25)
        case .counter(let c, _):
            let r = counterRadius(style)
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .emoji(let c, _):
            let r = style.fontSize * 0.65
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        }
    }

    public func translated(by d: CGSize) -> Annotation {
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.width, y: p.y + d.height) }
        var copy = self
        switch kind {
        case .arrow(let a, let b): copy.kind = .arrow(from: m(a), to: m(b))
        case .line(let a, let b): copy.kind = .line(from: m(a), to: m(b))
        case .rectangle(let r): copy.kind = .rectangle(r.offsetBy(dx: d.width, dy: d.height))
        case .ellipse(let r): copy.kind = .ellipse(r.offsetBy(dx: d.width, dy: d.height))
        case .pen(let p): copy.kind = .pen(p.map(m))
        case .highlighter(let p): copy.kind = .highlighter(p.map(m))
        case .text(let o, let s, let w): copy.kind = .text(origin: m(o), string: s, maxWidth: w)
        case .counter(let c, let n): copy.kind = .counter(center: m(c), number: n)
        case .blur(let r): copy.kind = .blur(r.offsetBy(dx: d.width, dy: d.height))
        case .pixelate(let r): copy.kind = .pixelate(r.offsetBy(dx: d.width, dy: d.height))
        case .redact(let r): copy.kind = .redact(r.offsetBy(dx: d.width, dy: d.height))
        case .spotlight(let r): copy.kind = .spotlight(r.offsetBy(dx: d.width, dy: d.height))
        case .emoji(let c, let s): copy.kind = .emoji(center: m(c), string: s)
        }
        return copy
    }
}

func counterRadius(_ style: AnnotationStyle) -> CGFloat { CGFloat(max(style.fontSize, 16)) * 0.75 }
