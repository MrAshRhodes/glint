import AppKit
import Combine
import GlintCore

/// Text field used for inline editing of text annotations.
final class InlineTextView: NSTextView {
    var onCommit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if event.keyCode == 53 || (isReturn && event.modifierFlags.contains(.command)) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { DispatchQueue.main.async { [weak self] in self?.onCommit?() } }
        return ok
    }
}

/// Live preview + annotation editing surface. Handles are drawn in view space on top of the composited preview.
final class CanvasView: NSView, NSTextViewDelegate {
    let model: EditorModel
    private var bag = Set<AnyCancellable>()

    private enum Drag {
        case none
        case creating(id: UUID, start: CGPoint, tool: EditorTool)
        case clickTool(start: CGPoint)
        case moving(last: CGPoint)
        case handle(id: UUID, handle: HandleID)
    }
    private var drag = Drag.none
    private var didMove = false

    private var editor: InlineTextView?
    private var editingBaseID: UUID?

    private let margin: CGFloat = 28

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        model.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.needsDisplay = true; self?.window?.invalidateCursorRects(for: self!) } }
            .store(in: &bag)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Screenshot preview")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    private var displayRect: CGRect {
        guard let p = model.preview else { return .zero }
        let avail = bounds.insetBy(dx: margin, dy: margin)
        let cs = p.layout.canvasSize
        guard cs.width > 0, cs.height > 0, avail.width > 0, avail.height > 0 else { return .zero }
        let s = min(avail.width / cs.width, avail.height / cs.height, 2)
        let size = CGSize(width: cs.width * s, height: cs.height * s)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    private var viewScale: CGFloat {
        guard let p = model.preview, p.layout.canvasSize.width > 0 else { return 1 }
        return displayRect.width / p.layout.canvasSize.width
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        guard let m = model.preview?.mapper else { return p }
        let c = m.toCanvas(p), r = displayRect, s = viewScale
        return CGPoint(x: r.minX + c.x * s, y: r.minY + c.y * s)
    }

    private func toImage(_ v: CGPoint) -> CGPoint {
        guard let m = model.preview?.mapper else { return v }
        let r = displayRect, s = viewScale
        return m.toImage(CGPoint(x: (v.x - r.minX) / s, y: (v.y - r.minY) / s))
    }

    /// View points per image pixel.
    private var viewPerImage: CGFloat { viewScale * (model.preview?.mapper.scaleX ?? 1) }

    private func viewRect(_ r: CGRect) -> CGRect {
        let a = toView(CGPoint(x: r.minX, y: r.minY)), b = toView(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        model.updatePreviewTarget(CGSize(width: max(bounds.width - 2 * margin, 10) * scale,
                                         height: max(bounds.height - 2 * margin, 10) * scale))
        positionEditor()
    }

    override func resetCursorRects() {
        if model.tool != .select, model.isEditable { addCursorRect(displayRect, cursor: .crosshair) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let p = model.preview, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = displayRect
        if case .transparent = model.settings.background { drawChecker(in: r) }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(p.image, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()

        guard model.isEditable else {
            if !model.isDesigningPreset { drawHint("Reset rotation, flip and 3D tilt to edit annotations") }
            return
        }
        for a in model.selectedAnnotations where a.id != model.editingID { drawSelection(a, single: model.selection.count == 1) }
    }

    private func drawChecker(in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        NSColor(white: 0.92, alpha: 1).setFill(); rect.fill()
        NSColor(white: 0.8, alpha: 1).setFill()
        let s: CGFloat = 10
        var y = rect.minY, row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : s)
            while x < rect.maxX { CGRect(x: x, y: y, width: s, height: s).fill(); x += 2 * s }
            y += s; row += 1
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: "  \(text)  ", attributes: attrs)
        let size = s.size()
        let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 8, width: size.width, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        s.draw(at: CGPoint(x: rect.minX, y: rect.minY + 2))
    }

    private let accent = NSColor(srgbRed: 35 / 255, green: 103 / 255, blue: 251 / 255, alpha: 1)

    private func drawSelection(_ a: Annotation, single: Bool) {
        accent.setStroke()
        let box = viewRect(AnnotationGeometry.bounds(of: a)).insetBy(dx: -3, dy: -3)
        let path = NSBezierPath(rect: box)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        if AnnotationGeometry.handles(of: a).count != 2 || !single { path.stroke() }
        guard single else { return }
        for (_, pt) in AnnotationGeometry.handles(of: a) {
            let v = toView(pt)
            let h = CGRect(x: v.x - 4.5, y: v.y - 4.5, width: 9, height: 9)
            let hp = a.kind.isLineLike ? NSBezierPath(ovalIn: h) : NSBezierPath(roundedRect: h, xRadius: 2, yRadius: 2)
            NSColor.white.setFill(); hp.fill()
            accent.setStroke(); hp.lineWidth = 1.5; hp.stroke()
        }
    }

    // MARK: Hit testing

    private func handleHit(at v: CGPoint) -> (UUID, HandleID)? {
        guard model.selection.count == 1, let a = model.selectedAnnotations.first else { return nil }
        for (id, pt) in AnnotationGeometry.handles(of: a) {
            let hv = toView(pt)
            if hypot(hv.x - v.x, hv.y - v.y) <= 8 { return (a.id, id) }
        }
        return nil
    }

    private func annotation(at imagePoint: CGPoint) -> Annotation? {
        let tol = 6 / max(viewPerImage, 0.01)
        for a in model.annotations.sorted(by: { $0.z > $1.z }) where AnnotationGeometry.hit(a, at: imagePoint, tol: tol) { return a }
        return nil
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        endEditing()
        guard !model.isDesigningPreset else { return }
        guard model.isEditable, model.preview != nil, displayRect.contains(convert(event.locationInWindow, from: nil)) else {
            if model.tool == .select { model.selection = [] }
            return
        }
        let v = convert(event.locationInWindow, from: nil)
        let p = toImage(v)
        didMove = false

        if model.tool != .select {
            beginTool(at: p)
            return
        }
        if let (id, h) = handleHit(at: v) {
            model.beginInteraction()
            drag = .handle(id: id, handle: h)
            return
        }
        let shift = event.modifierFlags.contains(.shift)
        if let hit = annotation(at: p) {
            if event.clickCount == 2, hit.kind.isText { beginEditing(id: hit.id, isNew: false); return }
            if shift {
                if model.selection.contains(hit.id) { model.selection.remove(hit.id); drag = .none; return }
                model.selection.insert(hit.id)
            } else if !model.selection.contains(hit.id) {
                model.selection = [hit.id]
            }
            model.beginInteraction()
            drag = .moving(last: p)
        } else {
            if !shift { model.selection = [] }
            drag = .none
        }
    }

    private func beginTool(at p: CGPoint) {
        let tool = model.tool
        switch tool {
        case .text, .counter:
            drag = .clickTool(start: p)
        case .select:
            break
        default:
            model.beginInteraction()
            var a: Annotation
            switch tool {
            case .arrow:
                a = model.makeAnnotation(model.arrowIsLine ? .line(from: p, to: p) : .arrow(from: p, to: p))
            case .shape:
                switch model.shapeVariant {
                case .rectangle, .rounded: a = model.makeAnnotation(.rectangle(CGRect(origin: p, size: .zero)))
                case .ellipse: a = model.makeAnnotation(.ellipse(CGRect(origin: p, size: .zero)))
                case .line: a = model.makeAnnotation(.line(from: p, to: p))
                }
            case .redact:
                let r = CGRect(origin: p, size: .zero)
                switch model.redactStyle {
                case .solid: a = model.makeAnnotation(.redact(r))
                case .blur: a = model.makeAnnotation(.blur(r))
                case .pixelate: a = model.makeAnnotation(.pixelate(r))
                }
            case .pen: a = model.makeAnnotation(.pen([p]))
            default: a = model.makeAnnotation(.highlighter([p]))
            }
            model.append(a)
            model.selection = []
            drag = .creating(id: a.id, start: p, tool: tool)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)
        didMove = true
        switch drag {
        case .none, .clickTool: break
        case .moving(let last):
            let d = CGSize(width: p.x - last.x, height: p.y - last.y)
            model.updateLive(model.annotations.map { model.selection.contains($0.id) ? $0.translated(by: d) : $0 })
            drag = .moving(last: p)
        case .handle(let id, let h):
            guard let a = model.annotations.first(where: { $0.id == id }) else { return }
            model.replace(AnnotationGeometry.resized(a, handle: h, to: p, constrain: shift))
        case .creating(let id, let start, _):
            guard var a = model.annotations.first(where: { $0.id == id }) else { return }
            switch a.kind {
            case .arrow: a.kind = .arrow(from: start, to: AnnotationGeometry.constrained(p, from: start, on: shift))
            case .line: a.kind = .line(from: start, to: AnnotationGeometry.constrained(p, from: start, on: shift))
            case .rectangle, .ellipse, .blur, .pixelate, .redact:
                let r = shift ? AnnotationGeometry.squared(from: start, to: p) : AnnotationGeometry.rect(from: start, to: p)
                a.kind = AnnotationGeometry.with(rect: r, kind: a.kind)
            case .pen(var pts): pts.append(p); a.kind = .pen(pts)
            case .highlighter(var pts):
                if shift, let f = pts.first { pts = [f, AnnotationGeometry.constrained(p, from: f, on: true)] } else { pts.append(p) }
                a.kind = .highlighter(pts)
            default: break
            }
            model.replace(a)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = .none }
        switch drag {
        case .none: break
        case .clickTool(let start):
            if model.tool == .text {
                model.beginInteraction()
                let a = model.makeAnnotation(.text(origin: CGPoint(x: start.x, y: start.y - model.defaultStyle.fontSize / 2),
                                                   string: "", maxWidth: 0))
                model.append(a)
                model.selection = [a.id]
                beginEditing(id: a.id, isNew: true)
            } else {
                model.beginInteraction()
                let a = model.makeAnnotation(.counter(center: start, number: model.nextCounterNumber()))
                model.append(a)
                model.endInteraction(actionName: "Add Counter")
                model.selection = [a.id]
            }
        case .moving:
            model.endInteraction(actionName: "Move")
        case .handle:
            model.endInteraction(actionName: "Resize")
        case .creating(let id, _, let tool):
            guard let a = model.annotations.first(where: { $0.id == id }) else { model.cancelInteraction(); return }
            let minSize = 4 / max(viewPerImage, 0.01)
            let tooSmall: Bool
            switch a.kind {
            case .arrow(let s, let e), .line(let s, let e): tooSmall = hypot(e.x - s.x, e.y - s.y) < minSize
            case .pen(let pts), .highlighter(let pts): tooSmall = pts.count < 2
            default: let b = a.boundingBox; tooSmall = b.width < minSize || b.height < minSize
            }
            if tooSmall { model.cancelInteraction(); return }
            model.endInteraction(actionName: "Add \(tool.title)")
            if tool == .redact || tool == .pen || tool == .highlighter {
                model.selection = []
            } else {
                model.selection = [id]
                model.tool = .select
            }
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let big: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117: model.deleteSelected()
        case 123: model.nudge(dx: -big, dy: 0)
        case 124: model.nudge(dx: big, dy: 0)
        case 125: model.nudge(dx: 0, dy: big)
        case 126: model.nudge(dx: 0, dy: -big)
        case 53:
            if model.tool != .select { model.tool = .select } else { model.selection = [] }
        default: super.keyDown(with: event)
        }
    }

    // MARK: Inline text editing

    private func beginEditing(id: UUID, isNew: Bool) {
        guard let a = model.annotations.first(where: { $0.id == id }), case .text(_, let string, _) = a.kind else { return }
        endEditing()
        if !isNew { model.beginInteraction() }
        model.editingID = id
        editingBaseID = id
        let tv = InlineTextView(frame: .zero)
        tv.delegate = self
        tv.isRichText = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 10_000, height: 10_000)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.insertionPointColor = a.style.color.nsColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.string = string
        tv.wantsLayer = true
        tv.layer?.borderColor = accent.cgColor
        tv.layer?.borderWidth = 1
        tv.onCommit = { [weak self] in self?.endEditing() }
        addSubview(tv)
        editor = tv
        positionEditor()
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
    }

    private func positionEditor() {
        guard let tv = editor, let id = editingBaseID, let a = model.annotations.first(where: { $0.id == id }) else { return }
        var style = a.style
        style.fontSize = a.style.fontSize * Double(viewPerImage)
        tv.font = AnnotationGeometry.font(for: style)
        tv.textColor = a.style.color.nsColor.withAlphaComponent(CGFloat(a.style.opacity))
        guard case .text(let origin, _, _) = a.kind else { return }
        let o = toView(origin)
        let used = tv.layoutManager.map { lm -> CGSize in
            lm.ensureLayout(for: tv.textContainer!)
            return lm.usedRect(for: tv.textContainer!).size
        } ?? .zero
        tv.frame = CGRect(x: o.x - 2, y: o.y - 2, width: max(used.width + 16, 80), height: max(used.height + 4, style.fontSize * 1.3))
    }

    func textDidChange(_ notification: Notification) { positionEditor() }

    func endEditing() {
        guard let tv = editor, let id = editingBaseID else { return }
        editor = nil
        editingBaseID = nil
        let string = tv.string
        tv.onCommit = nil
        tv.removeFromSuperview()
        model.editingID = nil
        if var a = model.annotations.first(where: { $0.id == id }), case .text(let o, _, let w) = a.kind {
            if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.updateLive(model.annotations.filter { $0.id != id })
                model.selection = []
            } else {
                a.kind = .text(origin: o, string: string, maxWidth: w)
                model.replace(a)
            }
        }
        model.endInteraction(actionName: "Edit Text")
        window?.makeFirstResponder(self)
    }
}

extension AnnotationKind {
    var isLineLike: Bool {
        switch self {
        case .arrow, .line: return true
        default: return false
        }
    }
}
