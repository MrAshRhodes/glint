import AppKit

enum SelectionOutcome {
    case area(CGRect, CGDirectDisplayID)
    case window(WindowInfo)
}

enum OverlayStartMode { case area, window }

/// Runs the interactive selection UI across all displays. All geometry is stored in global CG coordinates.
@MainActor
final class SelectionSession {
    enum Mode { case area, window }

    var mode: Mode
    var selection: CGRect?          // CG coords, in-progress drag rectangle
    var cursor: CGPoint = .zero     // CG coords
    var hoverWindow: WindowInfo?
    var lastArea: CGRect?

    private var panels: [OverlayPanel] = []
    private var windows: [WindowInfo] = []
    private var anchor: CGPoint?
    private var dragDisplay: CGRect?
    private var continuation: CheckedContinuation<SelectionOutcome, Error>?
    private let primaryHeight: CGFloat

    init(mode: OverlayStartMode, lastArea: CGRect?) {
        self.mode = mode == .area ? .area : .window
        self.lastArea = lastArea
        self.primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    }

    func run() async throws -> SelectionOutcome {
        windows = WindowEnumerator.onScreenWindows()
        cursor = CaptureGeometry.appKitToCG(NSEvent.mouseLocation, primaryHeight: primaryHeight)
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
            for screen in NSScreen.screens {
                let panel = OverlayPanel(screen: screen, session: self, level: level, primaryHeight: primaryHeight)
                panels.append(panel)
                panel.orderFrontRegardless()
            }
            NSApp.activate(ignoringOtherApps: true)
            panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKey()
            updateHover()
            refresh()
            NSCursor.crosshair.set()
        }
    }

    func refresh() { panels.forEach { $0.contentView?.needsDisplay = true } }

    private func updateHover() {
        hoverWindow = mode == .window ? WindowEnumerator.window(at: cursor, in: windows) : nil
    }

    // MARK: events (CG coords)

    func mouseMoved(to p: CGPoint) { cursor = p; updateHover(); refresh() }

    func mouseDown(at p: CGPoint) {
        cursor = p
        if mode == .window {
            if let w = hoverWindow { finish(.success(.window(w))) }
            return
        }
        anchor = p
        dragDisplay = displayFrame(containing: p)
        selection = CGRect(origin: p, size: .zero)
        refresh()
    }

    func mouseDragged(to p: CGPoint, shift: Bool) {
        guard mode == .area, let a = anchor else { return }
        let bounded = dragDisplay.map { CaptureGeometry.clamp(p, to: $0) } ?? p
        cursor = bounded
        selection = constrained(CaptureGeometry.rect(from: a, to: bounded, square: shift))
        refresh()
    }

    func mouseUp(at p: CGPoint) {
        guard mode == .area, anchor != nil else { return }
        defer { anchor = nil }
        guard let sel = selection, sel.width >= 3, sel.height >= 3 else {
            selection = nil; refresh(); return
        }
        finish(.success(.area(sel, displayID(for: sel))))
    }

    func toggleMode() {
        mode = mode == .area ? .window : .area
        anchor = nil; selection = nil
        updateHover(); refresh()
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        if var a = anchor, selection != nil {
            a.x += dx; a.y += dy
            anchor = a
            cursor.x += dx; cursor.y += dy
            selection = constrained(CaptureGeometry.rect(from: a, to: cursor, square: false))
        } else {
            cursor.x += dx; cursor.y += dy
            CGWarpMouseCursorPosition(cursor)
            updateHover()
        }
        refresh()
    }

    func confirm() {
        if mode == .window, let w = hoverWindow { finish(.success(.window(w))); return }
        if let sel = selection, sel.width >= 3, sel.height >= 3 { finish(.success(.area(sel, displayID(for: sel)))) }
    }

    func cancel() { finish(.failure(CaptureError.cancelled)) }

    private func constrained(_ r: CGRect) -> CGRect {
        dragDisplay.map { r.intersection($0) } ?? r
    }

    private func displayFrame(containing p: CGPoint) -> CGRect? {
        let frames = WindowEnumerator.displays().map(\.frame)
        return CaptureGeometry.index(containing: p, in: frames).map { frames[$0] }
    }

    private func displayID(for r: CGRect) -> CGDirectDisplayID {
        let ds = WindowEnumerator.displays()
        let i = CaptureGeometry.index(containing: CGPoint(x: r.midX, y: r.midY), in: ds.map(\.frame))
        return i.map { ds[$0].id } ?? CGMainDisplayID()
    }

    private func finish(_ result: Result<SelectionOutcome, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        NSCursor.arrow.set()
        c.resume(with: result)
    }
}

final class OverlayPanel: NSPanel {
    init(screen: NSScreen, session: SelectionSession, level: NSWindow.Level, primaryHeight: CGFloat) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        let v = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), session: session,
                            screenFrameCG: CaptureGeometry.appKitToCG(screen.frame, primaryHeight: primaryHeight),
                            scale: screen.backingScaleFactor)
        contentView = v
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: NSView {
    private unowned let session: SelectionSession
    private let screenFrameCG: CGRect
    private let scale: CGFloat

    init(frame: NSRect, session: SelectionSession, screenFrameCG: CGRect, scale: CGFloat) {
        self.session = session
        self.screenFrameCG = screenFrameCG
        self.scale = scale
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // global CG <-> view-local conversion
    private func toCG(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: screenFrameCG.minX + p.x, y: screenFrameCG.minY + (bounds.height - p.y))
    }

    private func toLocal(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX - screenFrameCG.minX, y: bounds.height - (r.maxY - screenFrameCG.minY),
               width: r.width, height: r.height)
    }

    override func mouseMoved(with e: NSEvent) { session.mouseMoved(to: toCG(e)) }
    override func mouseDown(with e: NSEvent) { session.mouseDown(at: toCG(e)) }
    override func mouseDragged(with e: NSEvent) {
        session.mouseDragged(to: toCG(e), shift: e.modifierFlags.contains(.shift))
    }
    override func mouseUp(with e: NSEvent) { session.mouseUp(at: toCG(e)) }
    override func rightMouseDown(with e: NSEvent) { session.cancel() }

    override func keyDown(with e: NSEvent) {
        let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
        switch e.keyCode {
        case 53: session.cancel()
        case 49: session.toggleMode()
        case 36, 76: session.confirm()
        case 123: session.nudge(dx: -step, dy: 0)
        case 124: session.nudge(dx: step, dy: 0)
        case 125: session.nudge(dx: 0, dy: step)
        case 126: session.nudge(dx: 0, dy: -step)
        default: break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.38)
        let highlight: CGRect? = session.mode == .window ? session.hoverWindow?.frame : session.selection
        let hole = highlight.flatMap { r -> NSRect? in
            let l = toLocal(r).intersection(bounds)
            return l.isNull || l.isEmpty ? nil : l
        }

        let path = NSBezierPath(rect: bounds)
        if let hole { path.append(NSBezierPath(rect: hole)); path.windingRule = .evenOdd }
        dim.setFill(); path.fill()

        if let hole {
            let accent = NSColor.controlAccentColor
            if session.mode == .window {
                accent.withAlphaComponent(0.18).setFill(); NSBezierPath(rect: hole).fill()
            }
            accent.setStroke()
            let b = NSBezierPath(rect: hole.insetBy(dx: 0.5, dy: 0.5)); b.lineWidth = 1.5; b.stroke()
            if let r = highlight { drawLabel(CaptureGeometry.dimensionLabel(r), near: hole) }
        }

        let c = NSPoint(x: session.cursor.x - screenFrameCG.minX, y: bounds.height - (session.cursor.y - screenFrameCG.minY))
        if session.mode == .area, bounds.contains(c) {
            NSColor.white.withAlphaComponent(0.55).setStroke()
            let h = NSBezierPath(); h.move(to: NSPoint(x: 0, y: c.y)); h.line(to: NSPoint(x: bounds.maxX, y: c.y))
            let v = NSBezierPath(); v.move(to: NSPoint(x: c.x, y: 0)); v.line(to: NSPoint(x: c.x, y: bounds.maxY))
            for p in [h, v] { p.lineWidth = 0.5; p.stroke() }
            if session.selection == nil {
                let pos = "\(Int(session.cursor.x)), \(Int(session.cursor.y))"
                drawLabel(pos, near: NSRect(x: c.x, y: c.y, width: 0, height: 0), offset: 18)
            }
        }

        if session.mode == .window || session.selection == nil {
            let hint = session.mode == .area ? "Drag to select  ·  Space: window  ·  Esc: cancel"
                                             : "Click a window  ·  Space: area  ·  Esc: cancel"
            drawLabel(hint, at: NSPoint(x: bounds.midX, y: 36), centered: true)
        }
    }

    private func drawLabel(_ text: String, near rect: NSRect, offset: CGFloat = 8) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        var origin = NSPoint(x: rect.minX + offset, y: rect.minY - size.height - offset - 6)
        if origin.y < 4 { origin.y = rect.maxY + offset }
        origin.x = min(max(origin.x, 4), bounds.maxX - size.width - 16)
        paintLabel(text, attrs: attrs, size: size, origin: origin)
    }

    private func drawLabel(_ text: String, at p: NSPoint, centered: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        paintLabel(text, attrs: attrs, size: size, origin: NSPoint(x: p.x - size.width / 2, y: p.y))
    }

    private func paintLabel(_ text: String, attrs: [NSAttributedString.Key: Any], size: NSSize, origin: NSPoint) {
        let pill = NSRect(x: origin.x - 6, y: origin.y - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }
}
