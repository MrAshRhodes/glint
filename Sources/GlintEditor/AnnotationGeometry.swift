import AppKit
import GlintCore

/// Maps source-image pixels (annotation space) to preview-canvas pixels.
/// Only valid for unrotated, unflipped, untilted renders (annotation editing is disabled otherwise).
struct CanvasMapper: Equatable {
    var region: CGRect
    var contentRect: CGRect

    var scaleX: CGFloat { contentRect.width / max(region.width, 1) }
    var scaleY: CGFloat { contentRect.height / max(region.height, 1) }

    func toCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: contentRect.minX + (p.x - region.minX) * scaleX, y: contentRect.minY + (p.y - region.minY) * scaleY)
    }

    func toImage(_ q: CGPoint) -> CGPoint {
        CGPoint(x: region.minX + (q.x - contentRect.minX) / scaleX, y: region.minY + (q.y - contentRect.minY) / scaleY)
    }
}

enum HandleID: Hashable {
    case p0, p1, tl, t, tr, r, br, b, bl, l
}

enum AnnotationGeometry {
    // MARK: Text metrics

    static func font(for style: AnnotationStyle) -> NSFont {
        var f = NSFont(name: style.fontName, size: CGFloat(style.fontSize)) ?? NSFont.systemFont(ofSize: CGFloat(style.fontSize))
        if style.bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
        return f
    }

    static func textSize(_ string: String, style: AnnotationStyle, maxWidth: Double) -> CGSize {
        let f = font(for: style)
        let text = string.isEmpty ? " " : string
        let attr = NSAttributedString(string: text, attributes: [.font: f])
        if maxWidth > 0 {
            let r = attr.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin])
            return CGSize(width: maxWidth, height: ceil(r.height))
        }
        let lineHeight = f.ascender - f.descender + f.leading
        let lines = max(text.components(separatedBy: "\n").count, 1)
        return CGSize(width: ceil(attr.size().width), height: ceil(lineHeight * CGFloat(lines)))
    }

    static func bounds(of a: Annotation) -> CGRect {
        switch a.kind {
        case .text(let origin, let string, let maxWidth):
            return CGRect(origin: origin, size: textSize(string, style: a.style, maxWidth: maxWidth))
        case .rectangle(let r), .ellipse(let r): return r
        default: return a.boundingBox
        }
    }

    // MARK: Rect-like helpers

    static func rect(of kind: AnnotationKind) -> CGRect? {
        switch kind {
        case .rectangle(let r), .ellipse(let r), .blur(let r), .pixelate(let r), .redact(let r), .spotlight(let r): return r
        default: return nil
        }
    }

    static func with(rect r: CGRect, kind: AnnotationKind) -> AnnotationKind {
        switch kind {
        case .rectangle: return .rectangle(r)
        case .ellipse: return .ellipse(r)
        case .blur: return .blur(r)
        case .pixelate: return .pixelate(r)
        case .redact: return .redact(r)
        case .spotlight: return .spotlight(r)
        default: return kind
        }
    }

    // MARK: Handles (image space)

    static func handles(of a: Annotation) -> [(HandleID, CGPoint)] {
        switch a.kind {
        case .arrow(let p, let q), .line(let p, let q): return [(.p0, p), (.p1, q)]
        default:
            guard let r = rect(of: a.kind) else { return [] }
            return [(.tl, CGPoint(x: r.minX, y: r.minY)), (.t, CGPoint(x: r.midX, y: r.minY)),
                    (.tr, CGPoint(x: r.maxX, y: r.minY)), (.r, CGPoint(x: r.maxX, y: r.midY)),
                    (.br, CGPoint(x: r.maxX, y: r.maxY)), (.b, CGPoint(x: r.midX, y: r.maxY)),
                    (.bl, CGPoint(x: r.minX, y: r.maxY)), (.l, CGPoint(x: r.minX, y: r.midY))]
        }
    }

    static func resized(_ a: Annotation, handle: HandleID, to p: CGPoint, constrain: Bool) -> Annotation {
        var out = a
        switch a.kind {
        case .arrow(let s, let e):
            if handle == .p0 { out.kind = .arrow(from: constrained(p, from: e, on: constrain), to: e) }
            else { out.kind = .arrow(from: s, to: constrained(p, from: s, on: constrain)) }
        case .line(let s, let e):
            if handle == .p0 { out.kind = .line(from: constrained(p, from: e, on: constrain), to: e) }
            else { out.kind = .line(from: s, to: constrained(p, from: s, on: constrain)) }
        default:
            guard let r = rect(of: a.kind) else { return a }
            var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
            var p = p
            if constrain, [.tl, .tr, .br, .bl].contains(handle) {
                let o = CGPoint(x: (handle == .tl || handle == .bl) ? maxX : minX,
                                y: (handle == .tl || handle == .tr) ? maxY : minY)
                let dx = p.x - o.x, dy = p.y - o.y
                let side = max(abs(dx), abs(dy))
                p = CGPoint(x: o.x + (dx < 0 ? -side : side), y: o.y + (dy < 0 ? -side : side))
            }
            switch handle {
            case .tl: minX = p.x; minY = p.y
            case .t: minY = p.y
            case .tr: maxX = p.x; minY = p.y
            case .r: maxX = p.x
            case .br: maxX = p.x; maxY = p.y
            case .b: maxY = p.y
            case .bl: minX = p.x; maxY = p.y
            case .l: minX = p.x
            default: break
            }
            let nr = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
            out.kind = with(rect: nr, kind: a.kind)
        }
        return out
    }

    /// Snaps `p` to the nearest 45° direction around `origin` when `on`.
    static func constrained(_ p: CGPoint, from origin: CGPoint, on: Bool) -> CGPoint {
        guard on else { return p }
        let dx = p.x - origin.x, dy = p.y - origin.y
        let len = hypot(dx, dy)
        let step = CGFloat.pi / 4
        let ang = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: origin.x + len * cos(ang), y: origin.y + len * sin(ang))
    }

    /// Square rect spanning `a`→`b` (grows toward `b`'s quadrant).
    static func squared(from a: CGPoint, to b: CGPoint) -> CGRect {
        let dx = b.x - a.x, dy = b.y - a.y
        let side = max(abs(dx), abs(dy))
        let end = CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
        return CGRect(x: min(a.x, end.x), y: min(a.y, end.y), width: side, height: side)
    }

    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Hit testing (image space, `tol` in image pixels)

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        guard l2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func hit(_ a: Annotation, at p: CGPoint, tol: CGFloat) -> Bool {
        let half = CGFloat(a.style.strokeWidth) / 2
        switch a.kind {
        case .arrow(let s, let e), .line(let s, let e):
            return distance(p, toSegment: s, e) <= max(half, 0) + tol + (a.kind.isArrow ? 6 : 0)
        case .pen(let pts), .highlighter(let pts):
            guard pts.count > 1 else { return pts.first.map { hypot(p.x - $0.x, p.y - $0.y) <= half + tol } ?? false }
            for i in 1..<pts.count where distance(p, toSegment: pts[i - 1], pts[i]) <= half + tol { return true }
            return false
        case .rectangle(let r):
            if a.style.fill != nil { return r.insetBy(dx: -tol - half, dy: -tol - half).contains(p) }
            let outer = r.insetBy(dx: -tol - half, dy: -tol - half)
            let inner = r.insetBy(dx: tol + half, dy: tol + half)
            return outer.contains(p) && (inner.width <= 0 || inner.height <= 0 || !inner.contains(p))
        case .ellipse(let r):
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (p.x - r.midX) / (r.width / 2), ny = (p.y - r.midY) / (r.height / 2)
            let d = hypot(nx, ny)
            if a.style.fill != nil, d <= 1 { return true }
            return abs(d - 1) * min(r.width, r.height) / 2 <= tol + half
        case .blur, .pixelate, .redact, .spotlight:
            return bounds(of: a).insetBy(dx: -tol, dy: -tol).contains(p)
        case .text, .counter, .emoji:
            return bounds(of: a).insetBy(dx: -tol, dy: -tol).contains(p)
        }
    }
}

extension AnnotationKind {
    var isArrow: Bool { if case .arrow = self { return true }; return false }
    var isText: Bool { if case .text = self { return true }; return false }
}
