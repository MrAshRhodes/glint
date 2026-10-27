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
    case insetTL, insetTR, insetBR, insetBL
    case sourceTL, sourceTR, sourceBR, sourceBL
}

/// The two independently movable parts of a magnifier.
enum MagnifierPart: Equatable {
    case inset, source
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
        case .magnify(let m): return m.source.standardized.union(m.inset.standardized)
        default: return a.boundingBox
        }
    }

    // MARK: Magnifier

    static let magnificationRange: ClosedRange<Double> = 1.25...8

    static func clampedMagnification(_ m: Double) -> Double {
        guard m.isFinite else { return 2 }
        return min(max(m, magnificationRange.lowerBound), magnificationRange.upperBound)
    }

    /// `source` scaled by `magnification` about the centre of `inset`.
    static func inset(_ inset: CGRect, resizedFor source: CGRect, magnification: Double) -> CGRect {
        let m = CGFloat(magnification)
        let size = CGSize(width: source.width * m, height: source.height * m)
        return CGRect(x: inset.midX - size.width / 2, y: inset.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The magnifier part under `p`; the inset wins because it is drawn above its source.
    static func magnifierPart(_ a: Annotation, at p: CGPoint, tol: CGFloat) -> MagnifierPart? {
        guard case .magnify(let m) = a.kind else { return nil }
        let half = CGFloat(a.style.strokeWidth) / 2
        let inset = m.inset.standardized.insetBy(dx: -tol - half, dy: -tol - half)
        switch m.shape {
        case .rectangle where inset.contains(p): return .inset
        case .circle where inset.width > 0 && inset.height > 0:
            let nx = (p.x - inset.midX) / (inset.width / 2), ny = (p.y - inset.midY) / (inset.height / 2)
            if nx * nx + ny * ny <= 1 { return .inset }
        default: break
        }
        return m.source.standardized.insetBy(dx: -tol, dy: -tol).contains(p) ? .source : nil
    }

    /// Moves one part of a magnifier, or both when `part` is nil.
    static func moved(_ a: Annotation, part: MagnifierPart?, by d: CGSize) -> Annotation {
        guard let part, case .magnify(var m) = a.kind else { return a.translated(by: d) }
        var out = a
        switch part {
        case .inset: m.inset = m.inset.offsetBy(dx: d.width, dy: d.height)
        case .source: m.source = m.source.offsetBy(dx: d.width, dy: d.height)
        }
        out.kind = .magnify(m)
        return out
    }

    /// `current` with each annotation in `base` (keyed by id, as it was at mouse-down) moved by `d`; annotations
    /// added or changed independently since mouse-down are kept.
    static func moving(_ current: [Annotation], from base: [UUID: Annotation], part: MagnifierPart?, by d: CGSize) -> [Annotation] {
        current.map { a in base[a.id].map { moved($0, part: part, by: d) } ?? a }
    }

    /// Selection rect spanning `start`→`end`, optionally square, kept inside `bounds`.
    static func zoomSelection(from start: CGPoint, to end: CGPoint, square: Bool, in bounds: CGRect) -> CGRect {
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
        }
        let a = clamp(start), b = clamp(end)
        guard square else { return rect(from: a, to: b) }
        let dx = b.x - a.x, dy = b.y - a.y
        let side = min(max(abs(dx), abs(dy)),
                       dx < 0 ? a.x - bounds.minX : bounds.maxX - a.x,
                       dy < 0 ? a.y - bounds.minY : bounds.maxY - a.y)
        return squared(from: a, to: CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side)))
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
        case .magnify(let m):
            let i = m.inset.standardized, s = m.source.standardized
            return [(.insetTL, CGPoint(x: i.minX, y: i.minY)), (.insetTR, CGPoint(x: i.maxX, y: i.minY)),
                    (.insetBR, CGPoint(x: i.maxX, y: i.maxY)), (.insetBL, CGPoint(x: i.minX, y: i.maxY)),
                    (.sourceTL, CGPoint(x: s.minX, y: s.minY)), (.sourceTR, CGPoint(x: s.maxX, y: s.minY)),
                    (.sourceBR, CGPoint(x: s.maxX, y: s.maxY)), (.sourceBL, CGPoint(x: s.minX, y: s.maxY))]
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
        case .magnify(let m):
            out.kind = .magnify(resized(m, handle: handle, to: p, constrain: constrain))
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

    /// Inset corners scale the inset uniformly (changing magnification); source corners resize the selection and
    /// resize the inset about its centre so magnification stays the same.
    static func resized(_ m: Magnifier, handle: HandleID, to p: CGPoint, constrain: Bool) -> Magnifier {
        var out = m
        let source = m.source.standardized, inset = m.inset.standardized
        switch handle {
        case .insetTL, .insetTR, .insetBR, .insetBL:
            guard source.width > 0, source.height > 0 else { return m }
            let left = handle == .insetTL || handle == .insetBL, top = handle == .insetTL || handle == .insetTR
            let anchor = CGPoint(x: left ? inset.maxX : inset.minX, y: top ? inset.maxY : inset.minY)
            let aspect = source.width / source.height
            let wanted = max(abs(p.x - anchor.x), abs(p.y - anchor.y) * aspect)
            let magnification = clampedMagnification(Double(wanted / source.width))
            let w = source.width * CGFloat(magnification), h = source.height * CGFloat(magnification)
            out.inset = CGRect(x: left ? anchor.x - w : anchor.x, y: top ? anchor.y - h : anchor.y, width: w, height: h)
        case .sourceTL, .sourceTR, .sourceBR, .sourceBL:
            let left = handle == .sourceTL || handle == .sourceBL, top = handle == .sourceTL || handle == .sourceTR
            let anchor = CGPoint(x: left ? source.maxX : source.minX, y: top ? source.maxY : source.minY)
            let minSide: CGFloat = 2
            var dx = p.x - anchor.x, dy = p.y - anchor.y
            if constrain { let side = max(abs(dx), abs(dy)); dx = dx < 0 ? -side : side; dy = dy < 0 ? -side : side }
            let w = max(abs(dx), minSide), h = max(abs(dy), minSide)
            out.source = CGRect(x: dx < 0 ? anchor.x - w : anchor.x, y: dy < 0 ? anchor.y - h : anchor.y, width: w, height: h)
            out.inset = self.inset(inset, resizedFor: out.source, magnification: m.magnification)
        default:
            return m
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
        case .magnify:
            return magnifierPart(a, at: p, tol: tol) != nil
        }
    }
}

extension AnnotationKind {
    var isArrow: Bool { if case .arrow = self { return true }; return false }
    var isText: Bool { if case .text = self { return true }; return false }
}
