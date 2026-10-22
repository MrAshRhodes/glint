import AppKit
import os

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
    private var firstDrawInterval: OSSignpostIntervalState?
    private let primaryHeight: CGFloat

    init(mode: OverlayStartMode, lastArea: CGRect?) {
        self.mode = mode == .area ? .area : .window
        self.lastArea = lastArea
        self.primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    }

    func run() async throws -> SelectionOutcome {
        firstDrawInterval = OverlayPerformance.begin("OverlayFirstDraw")
        let setup = OverlayPerformance.begin("OverlaySetup")
        windows = OverlayPerformance.measure("WindowEnumeration") { WindowEnumerator.onScreenWindows() }
        cursor = CaptureGeometry.appKitToCG(NSEvent.mouseLocation, primaryHeight: primaryHeight)
        return try await withCheckedThrowingContinuation { cont in
            defer { OverlayPerformance.end("OverlaySetup", setup) }
            continuation = cont
            let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
            for screen in NSScreen.screens {
                let panel = OverlayPerformance.measure("PanelCreation") {
                    OverlayPanel(screen: screen, session: self, level: level, primaryHeight: primaryHeight)
                }
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

    func refresh() { panels.forEach { ($0.contentView as? OverlayView)?.refresh() } }

    fileprivate func didDraw() {
        OverlayPerformance.end("OverlayFirstDraw", firstDrawInterval)
        firstDrawInterval = nil
    }

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
        OverlayPerformance.end("OverlayFirstDraw", firstDrawInterval, cancelled: true)
        firstDrawInterval = nil
        panels.forEach {
            ($0.contentView as? OverlayView)?.cancelPendingDraw()
            $0.orderOut(nil)
            $0.close()
        }
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
    private var lastSnapshot: Snapshot?
    private var detailLayout: TextLayout?
    private var pendingDrawInterval: OSSignpostIntervalState?
    private var hasDrawn = false

    private static let detailAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white]
    private static let hintAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white]
    private static let areaHint = TextLayout("Drag to select  ·  Space: window  ·  Esc: cancel", attributes: hintAttributes)
    private static let windowHint = TextLayout("Click a window  ·  Space: area  ·  Esc: cancel", attributes: hintAttributes)

    private final class TextLayout {
        let text: String
        let attributedText: NSAttributedString
        let size: NSSize

        init(_ text: String, attributes: [NSAttributedString.Key: Any]) {
            self.text = text
            attributedText = NSAttributedString(string: text, attributes: attributes)
            size = attributedText.size()
        }
    }

    private struct Label: Equatable {
        let layout: TextLayout
        let origin: NSPoint

        var frame: NSRect {
            NSRect(x: origin.x - 6, y: origin.y - 3, width: layout.size.width + 12, height: layout.size.height + 6)
        }

        static func == (lhs: Label, rhs: Label) -> Bool {
            lhs.layout === rhs.layout && lhs.origin == rhs.origin
        }
    }

    private struct Snapshot {
        var hole: NSRect?
        var windowHighlight = false
        var crosshair: NSPoint?
        var detail: Label?
        var hint: Label?
    }

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

    override func mouseMoved(with e: NSEvent) {
        OverlayPerformance.measure("MouseMoved") { session.mouseMoved(to: toCG(e)) }
    }
    override func mouseDown(with e: NSEvent) {
        OverlayPerformance.measure("MouseDown") { session.mouseDown(at: toCG(e)) }
    }
    override func mouseDragged(with e: NSEvent) {
        OverlayPerformance.measure("MouseDragged") {
            session.mouseDragged(to: toCG(e), shift: e.modifierFlags.contains(.shift))
        }
    }
    override func mouseUp(with e: NSEvent) {
        OverlayPerformance.measure("MouseUp") { session.mouseUp(at: toCG(e)) }
    }
    override func rightMouseDown(with e: NSEvent) { session.cancel() }

    override func keyDown(with e: NSEvent) {
        let interval = OverlayPerformance.begin("KeyDown")
        defer { OverlayPerformance.end("KeyDown", interval) }
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

    private func makeSnapshot() -> Snapshot {
        var snapshot = Snapshot()
        let highlight: CGRect? = session.mode == .window ? session.hoverWindow?.frame : session.selection
        snapshot.hole = highlight.flatMap { r -> NSRect? in
            let l = toLocal(r).intersection(bounds)
            return l.isNull || l.isEmpty ? nil : l
        }
        snapshot.windowHighlight = session.mode == .window
        if let hole = snapshot.hole, let highlight {
            snapshot.detail = label(CaptureGeometry.dimensionLabel(highlight), near: hole)
        }

        let c = NSPoint(x: session.cursor.x - screenFrameCG.minX, y: bounds.height - (session.cursor.y - screenFrameCG.minY))
        if session.mode == .area, bounds.contains(c) {
            snapshot.crosshair = c
            if session.selection == nil {
                let pos = "\(Int(session.cursor.x)), \(Int(session.cursor.y))"
                snapshot.detail = label(pos, near: NSRect(origin: c, size: .zero), offset: 18)
            }
        }

        if session.mode == .window || session.selection == nil {
            let layout = session.mode == .area ? Self.areaHint : Self.windowHint
            snapshot.hint = Label(layout: layout, origin: NSPoint(x: bounds.midX - layout.size.width / 2, y: 36))
        }
        return snapshot
    }

    private func label(_ text: String, near rect: NSRect, offset: CGFloat = 8) -> Label {
        let layout: TextLayout
        if let cached = detailLayout, cached.text == text {
            layout = cached
        } else {
            layout = TextLayout(text, attributes: Self.detailAttributes)
            detailLayout = layout
        }
        var origin = NSPoint(x: rect.minX + offset, y: rect.minY - layout.size.height - offset - 6)
        if origin.y < 4 { origin.y = rect.maxY + offset }
        origin.x = min(max(origin.x, 4), bounds.maxX - layout.size.width - 16)
        return Label(layout: layout, origin: origin)
    }

    /// Keep damage as separate rectangles: unioning crosshair strips would dirty the entire display.
    /// AppKit accumulates these regions when several input events arrive before the next draw.
    @discardableResult
    func refresh() -> [NSRect] {
        let next = makeSnapshot()
        defer { lastSnapshot = next }
        guard let previous = lastSnapshot else {
            invalidate([bounds])
            return [bounds]
        }
        var damage: [NSRect] = []
        // Include the inset border's inner edge (0.5 + 1.5 / 2) and one backing pixel of antialiasing.
        let borderMargin: CGFloat = 1.25 + 1 / scale
        let crosshairMargin: CGFloat = 0.25 + 1 / scale
        if previous.hole != next.hole || previous.windowHighlight != next.windowHighlight {
            if previous.windowHighlight != next.windowHighlight {
                damage += [previous.hole, next.hole].compactMap { $0?.insetBy(dx: -borderMargin, dy: -borderMargin) }
            } else {
                for (hole, other) in [(previous.hole, next.hole), (next.hole, previous.hole)] {
                    guard let hole else { continue }
                    damage += Self.subtract(hole, excluding: other)
                    damage += Self.subtract(hole.insetBy(dx: -borderMargin, dy: -borderMargin),
                                            excluding: hole.insetBy(dx: borderMargin, dy: borderMargin))
                }
            }
        }
        if previous.crosshair?.x != next.crosshair?.x {
            for c in [previous.crosshair, next.crosshair].compactMap({ $0 }) {
                damage.append(NSRect(x: c.x - crosshairMargin, y: bounds.minY,
                                     width: 2 * crosshairMargin, height: bounds.height))
            }
        }
        if previous.crosshair?.y != next.crosshair?.y {
            for c in [previous.crosshair, next.crosshair].compactMap({ $0 }) {
                damage.append(NSRect(x: bounds.minX, y: c.y - crosshairMargin,
                                     width: bounds.width, height: 2 * crosshairMargin))
            }
        }
        for (old, new) in [(previous.detail, next.detail), (previous.hint, next.hint)] where old != new {
            damage += [old, new].compactMap { $0?.frame.insetBy(dx: -1 / scale, dy: -1 / scale) }
        }
        let rects = damage.compactMap { rect -> NSRect? in
            let x = floor(rect.minX * scale) / scale, y = floor(rect.minY * scale) / scale
            let aligned = NSRect(x: x, y: y, width: ceil(rect.maxX * scale) / scale - x,
                                 height: ceil(rect.maxY * scale) / scale - y).intersection(bounds)
            return aligned.isEmpty || aligned.isNull ? nil : aligned
        }
        invalidate(rects)
        return rects
    }

    private func invalidate(_ rects: [NSRect]) {
        guard !rects.isEmpty else { return }
        // Keep the oldest pending invalidation when AppKit coalesces several input events.
        if pendingDrawInterval == nil {
            pendingDrawInterval = OverlayPerformance.begin("InvalidationToDraw")
        }
        rects.forEach { setNeedsDisplay($0) }
    }

    fileprivate func cancelPendingDraw() {
        OverlayPerformance.end("InvalidationToDraw", pendingDrawInterval, cancelled: true)
        pendingDrawInterval = nil
    }

    private static func subtract(_ rect: NSRect, excluding other: NSRect?) -> [NSRect] {
        guard let other, !other.isEmpty else { return [rect] }
        let overlap = rect.intersection(other)
        guard !overlap.isEmpty, !overlap.isNull else { return [rect] }
        return [
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
            NSRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
            NSRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
            NSRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)
        ].filter { !$0.isEmpty }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let name: StaticString = hasDrawn ? "Draw" : "FirstDraw"
        let interval = OverlayPerformance.begin(name)
        defer {
            OverlayPerformance.end(name, interval)
            OverlayPerformance.end("InvalidationToDraw", pendingDrawInterval)
            pendingDrawInterval = nil
            hasDrawn = true
            session.didDraw()
        }
        let snapshot = makeSnapshot()
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: dirtyRect)
        // The panel is transparent. Repainting source-over without clearing would accumulate dimming
        // and leave old selection holes/crosshairs behind during partial or overlapping redraws.
        context.clear(dirtyRect)
        context.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
        context.fill(Self.subtract(bounds, excluding: snapshot.hole))

        if let hole = snapshot.hole {
            let accent = NSColor.controlAccentColor
            if snapshot.windowHighlight {
                context.setFillColor(accent.withAlphaComponent(0.18).cgColor)
                context.fill(hole)
            }
            context.setStrokeColor(accent.cgColor)
            context.setLineWidth(1.5)
            context.stroke(hole.insetBy(dx: 0.5, dy: 0.5))
            if let label = snapshot.detail { paintLabel(label) }
        }

        if let c = snapshot.crosshair {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
            context.setLineWidth(0.5)
            context.move(to: NSPoint(x: 0, y: c.y))
            context.addLine(to: NSPoint(x: bounds.maxX, y: c.y))
            context.strokePath()
            context.move(to: NSPoint(x: c.x, y: 0))
            context.addLine(to: NSPoint(x: c.x, y: bounds.maxY))
            context.strokePath()
            if snapshot.hole == nil, let label = snapshot.detail { paintLabel(label) }
        }
        if let label = snapshot.hint { paintLabel(label) }
    }

    private func paintLabel(_ label: Label) {
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: label.frame, xRadius: 6, yRadius: 6).fill()
        label.layout.attributedText.draw(at: label.origin)
    }
}
