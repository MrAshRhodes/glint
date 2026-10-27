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
    let snapToEdges: Bool
    var snappingEnabled: Bool { snapToEdges != command }
    var snapGuides: [SnapEdge] { drag?.guides ?? [] }
    var snappingHint: String {
        let action = command ? "Release" : "Hold"
        let nextState = snappingEnabled ? "off" : "on"
        return "Snap: \(snappingEnabled ? "on" : "off")  ·  \(action) ⌘: \(nextState)"
    }

    private var panels: [OverlayPanel] = []
    private var windows: [WindowInfo] = []
    private var displays: [DisplayInfo] = []
    private var targets: [CGDirectDisplayID: [SnapEdge]] = [:]

    /// Lets tests drive a session without `run()` enumerating real windows.
    func useDisplays(_ displays: [DisplayInfo]) {
        self.displays = displays
    }
    private var drag: SnappingSelection?
    private var dragDisplayID: CGDirectDisplayID?
    private var shift = false
    private var command = false
    private var continuation: CheckedContinuation<SelectionOutcome, Error>?
    private var firstDrawInterval: OSSignpostIntervalState?
    private let primaryHeight: CGFloat

    init(mode: OverlayStartMode, lastArea: CGRect?, snapToEdges: Bool = false) {
        self.mode = mode == .area ? .area : .window
        self.lastArea = lastArea
        self.snapToEdges = snapToEdges
        self.primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    }

    func run() async throws -> SelectionOutcome {
        firstDrawInterval = OverlayPerformance.begin("OverlayFirstDraw")
        let setup = OverlayPerformance.begin("OverlaySetup")
        let snapshot = OverlayPerformance.measure("WindowEnumeration") { WindowEnumerator.selectionSnapshot() }
        windows = snapshot.windows
        displays = WindowEnumerator.displays()
        targets = Dictionary(uniqueKeysWithValues: displays.map {
            ($0.id, SnapTargets.visibleEdges(in: $0.frame, windows: snapshot.snapWindows))
        })
        shift = NSEvent.modifierFlags.contains(.shift)
        command = NSEvent.modifierFlags.contains(.command)
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
            updateHover()
            if let w = hoverWindow { finish(.success(.window(w))) }
            return
        }
        guard let index = CaptureGeometry.index(containing: p, in: displays.map(\.frame)) else { return }
        let display = displays[index]
        dragDisplayID = display.id
        drag = SnappingSelection(anchor: p, bounds: display.frame, targets: targets[display.id] ?? [],
                                 snapToEdges: snapToEdges)
        drag?.setModifiers(shift: shift, command: command)
        updateSelection()
        refresh()
    }

    func mouseDragged(to p: CGPoint) {
        guard mode == .area, drag != nil else { return }
        drag?.move(to: p)
        updateSelection()
        refresh()
    }

    func mouseUp(at p: CGPoint) {
        guard mode == .area, let drag else { return }
        defer { self.drag = nil }
        guard drag.isValid, let sel = selection else {
            selection = nil; refresh(); return
        }
        finish(.success(.area(sel, displayID(for: sel))))
    }

    func toggleMode() {
        mode = mode == .area ? .window : .area
        drag = nil; selection = nil; dragDisplayID = nil
        updateHover(); refresh()
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        if drag != nil {
            drag?.nudge(dx: dx, dy: dy)
            updateSelection()
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

    func modifiersChanged(shift: Bool, command: Bool) {
        guard self.shift != shift || self.command != command else { return }
        self.shift = shift
        self.command = command
        drag?.setModifiers(shift: shift, command: command)
        updateSelection()
        refresh()
    }

    private func updateSelection() {
        guard let drag else { return }
        cursor = drag.rawCursor
        selection = drag.rectangle
    }

    private func displayID(for r: CGRect) -> CGDirectDisplayID {
        if let dragDisplayID { return dragDisplayID }
        let i = CaptureGeometry.index(containing: CGPoint(x: r.midX, y: r.midY), in: displays.map(\.frame))
        return i.map { displays[$0].id } ?? CGMainDisplayID()
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
        // Command is a selection modifier now; keep Command-drag on a background panel from sliding the overlay.
        isMovable = false
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
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: NSColor.white]
    private static let hintAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92)]

    /// HUD styling shared by every on-screen label: a dark translucent continuous capsule with a hairline
    /// and a soft drop shadow, like the system's macOS 26 HUDs. Colors are created once, not per draw.
    private enum HUD {
        static let paddingX: CGFloat = 10
        static let paddingY: CGFloat = 6
        static let fill = NSColor.black.withAlphaComponent(0.6).cgColor
        static let hairline = NSColor.white.withAlphaComponent(0.16).cgColor
        static let shadow = NSColor.black.withAlphaComponent(0.28).cgColor
        static let shadowBlur: CGFloat = 8
        static let shadowOffset = CGSize(width: 0, height: -1)
        /// How far the shadow can reach beyond the capsule (whole points); included in the label's damage.
        static let shadowReach: CGFloat = shadowBlur + 2
    }

    private struct BackgroundKey: Hashable {
        let width: Int
        let height: Int
    }

    /// Pre-rendered capsule + shadow per label size in backing pixels, so a redraw is one image blit
    /// instead of a Gaussian shadow pass. Only a handful of sizes occur (digit counts, hint texts).
    private var labelBackgrounds: [BackgroundKey: CGImage] = [:]

    private enum Palette {
        static let dim = NSColor.black.withAlphaComponent(0.38).cgColor
        static let selectionStroke = NSColor.white.cgColor
        /// Thin dark outline outside the selection keeps the white stroke visible on light content.
        static let selectionContrast = NSColor.black.withAlphaComponent(0.35).cgColor
        static let crosshair = NSColor.white.withAlphaComponent(0.55).cgColor
    }

    /// Corner radius of the window-picker highlight, close to the system window corner radius.
    private static let windowCornerRadius: CGFloat = 10
    private var hintLayouts: [String: TextLayout] = [:]

    private func hintLayout(_ text: String) -> TextLayout {
        if let cached = hintLayouts[text] { return cached }
        let layout = TextLayout(text, attributes: Self.hintAttributes)
        hintLayouts[text] = layout
        return layout
    }

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
        /// The capsule, snapped to backing pixels so its cached background and the text render crisply.
        let frame: NSRect

        init(layout: TextLayout, origin: NSPoint, scale: CGFloat) {
            let snapped = NSPoint(x: (origin.x * scale).rounded() / scale, y: (origin.y * scale).rounded() / scale)
            self.layout = layout
            self.origin = snapped
            frame = NSRect(x: snapped.x - HUD.paddingX, y: snapped.y - HUD.paddingY,
                           width: ceil((layout.size.width + 2 * HUD.paddingX) * scale) / scale,
                           height: ceil((layout.size.height + 2 * HUD.paddingY) * scale) / scale)
        }

        /// Everything the label paints, including its shadow.
        var damageFrame: NSRect { frame.insetBy(dx: -HUD.shadowReach, dy: -HUD.shadowReach) }

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
        var guides: [GuideLine] = []
    }

    private struct GuideLine: Equatable {
        let start: NSPoint
        let end: NSPoint

        var frame: NSRect {
            NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
                   width: abs(start.x - end.x), height: abs(start.y - end.y)).insetBy(dx: -2, dy: -2)
        }
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

    private func updateModifiers(_ e: NSEvent) {
        session.modifiersChanged(shift: e.modifierFlags.contains(.shift), command: e.modifierFlags.contains(.command))
    }

    // Hotkey chords include ⌘, so a release that happens before this panel is key would otherwise leave the hint stale.
    override func mouseMoved(with e: NSEvent) {
        OverlayPerformance.measure("MouseMoved") { updateModifiers(e); session.mouseMoved(to: toCG(e)) }
    }
    override func flagsChanged(with e: NSEvent) { updateModifiers(e) }
    override func mouseDown(with e: NSEvent) {
        OverlayPerformance.measure("MouseDown") { updateModifiers(e); session.mouseDown(at: toCG(e)) }
    }
    override func mouseDragged(with e: NSEvent) {
        OverlayPerformance.measure("MouseDragged") { updateModifiers(e); session.mouseDragged(to: toCG(e)) }
    }
    override func mouseUp(with e: NSEvent) {
        OverlayPerformance.measure("MouseUp") { updateModifiers(e); session.mouseUp(at: toCG(e)) }
    }
    override func rightMouseDown(with e: NSEvent) { session.cancel() }

    override func keyDown(with e: NSEvent) {
        let interval = OverlayPerformance.begin("KeyDown")
        defer { OverlayPerformance.end("KeyDown", interval) }
        updateModifiers(e)
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

        if session.mode == .area {
            snapshot.guides = session.snapGuides.map { guide in
                let start: CGPoint, end: CGPoint
                if guide.axis == .x {
                    start = CGPoint(x: guide.coordinate, y: guide.lower)
                    end = CGPoint(x: guide.coordinate, y: guide.upper)
                } else {
                    start = CGPoint(x: guide.lower, y: guide.coordinate)
                    end = CGPoint(x: guide.upper, y: guide.coordinate)
                }
                return GuideLine(
                    start: NSPoint(x: start.x - screenFrameCG.minX, y: bounds.height - (start.y - screenFrameCG.minY)),
                    end: NSPoint(x: end.x - screenFrameCG.minX, y: bounds.height - (end.y - screenFrameCG.minY)))
            }
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
            let text = session.mode == .area
                ? "Drag to select  ·  \(session.snappingHint)  ·  ⇧: square  ·  Space: window  ·  Esc: cancel"
                : "Click a window  ·  Space: area  ·  Esc: cancel"
            let layout = hintLayout(text)
            snapshot.hint = Label(layout: layout, origin: NSPoint(x: bounds.midX - layout.size.width / 2, y: 36),
                                  scale: scale)
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
        let margin: CGFloat = 4
        var origin = NSPoint(x: rect.minX + offset + HUD.paddingX,
                             y: rect.minY - layout.size.height - offset - HUD.paddingY)
        if origin.y - HUD.paddingY < margin { origin.y = rect.maxY + offset + HUD.paddingY }
        origin.x = min(max(origin.x, margin + HUD.paddingX), bounds.maxX - layout.size.width - HUD.paddingX - margin)
        return Label(layout: layout, origin: origin, scale: scale)
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
                    // Rounded window-highlight corners reach further into the hole than the border ring.
                    if next.windowHighlight {
                        damage += Self.cornerRects(of: hole, radius: Self.windowCornerRadius, margin: borderMargin)
                    }
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
        if previous.guides != next.guides {
            damage += (previous.guides + next.guides).map(\.frame)
        }
        for (old, new) in [(previous.detail, next.detail), (previous.hint, next.hint)] where old != new {
            damage += [old, new].compactMap { $0?.damageFrame.insetBy(dx: -1 / scale, dy: -1 / scale) }
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

    /// Squares covering the four rounded corners of `rect`, used to damage a continuous-corner outline.
    private static func cornerRects(of rect: NSRect, radius: CGFloat, margin: CGFloat) -> [NSRect] {
        let side = ContinuousCorners.extent(of: rect, radius: radius) + margin
        guard side > margin else { return [] }
        return [
            NSRect(x: rect.minX - margin, y: rect.minY - margin, width: side + margin, height: side + margin),
            NSRect(x: rect.maxX - side, y: rect.minY - margin, width: side + margin, height: side + margin),
            NSRect(x: rect.minX - margin, y: rect.maxY - side, width: side + margin, height: side + margin),
            NSRect(x: rect.maxX - side, y: rect.maxY - side, width: side + margin, height: side + margin)
        ]
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
        context.setFillColor(Palette.dim)
        context.fill(Self.subtract(bounds, excluding: snapshot.hole))

        if let hole = snapshot.hole {
            if snapshot.windowHighlight {
                let accent = NSColor.controlAccentColor
                let outline = ContinuousCorners.path(in: hole, radius: Self.windowCornerRadius)
                // Dim the corner slivers between the hole's rectangle and the rounded window outline.
                context.addRect(hole)
                context.addPath(outline)
                context.setFillColor(Palette.dim)
                context.fillPath(using: .evenOdd)
                context.addPath(outline)
                context.setFillColor(accent.withAlphaComponent(0.2).cgColor)
                context.fillPath()
                let border = ContinuousCorners.path(in: hole.insetBy(dx: 0.75, dy: 0.75),
                                                    radius: max(Self.windowCornerRadius - 0.75, 0))
                context.addPath(border)
                context.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
                context.setLineWidth(1.5)
                context.strokePath()
            } else {
                context.setLineWidth(1)
                context.setStrokeColor(Palette.selectionContrast)
                context.stroke(hole.insetBy(dx: -0.5, dy: -0.5))
                context.setStrokeColor(Palette.selectionStroke)
                context.stroke(hole.insetBy(dx: 0.5, dy: 0.5))
            }
            if let label = snapshot.detail { paintLabel(label, in: context) }
        }

        if !snapshot.guides.isEmpty {
            context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 3])
            for guide in snapshot.guides {
                context.move(to: guide.start)
                context.addLine(to: guide.end)
            }
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
        }

        if let c = snapshot.crosshair {
            context.setStrokeColor(Palette.crosshair)
            context.setLineWidth(0.5)
            context.move(to: NSPoint(x: 0, y: c.y))
            context.addLine(to: NSPoint(x: bounds.maxX, y: c.y))
            context.strokePath()
            context.move(to: NSPoint(x: c.x, y: 0))
            context.addLine(to: NSPoint(x: c.x, y: bounds.maxY))
            context.strokePath()
            if snapshot.hole == nil, let label = snapshot.detail { paintLabel(label, in: context) }
        }
        if let label = snapshot.hint { paintLabel(label, in: context) }
    }

    private func paintLabel(_ label: Label, in context: CGContext) {
        if let background = labelBackground(for: label.frame) {
            let pad = CGFloat(background.width - Int((label.frame.width * scale).rounded())) / 2 / scale
            context.saveGState()
            context.interpolationQuality = .none
            context.draw(background, in: label.frame.insetBy(dx: -pad, dy: -pad))
            context.restoreGState()
        }
        label.layout.attributedText.draw(at: label.origin)
    }

    private func labelBackground(for frame: NSRect) -> CGImage? {
        let key = BackgroundKey(width: Int((frame.width * scale).rounded()), height: Int((frame.height * scale).rounded()))
        if let cached = labelBackgrounds[key] { return cached }
        let pad = Int(ceil(HUD.shadowReach * scale))
        guard key.width > 0, key.height > 0,
              let bitmap = CGContext(data: nil, width: key.width + 2 * pad, height: key.height + 2 * pad,
                                     bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Drawn directly in backing pixels; shadow parameters are not affected by the CTM.
        let capsule = CGRect(x: CGFloat(pad), y: CGFloat(pad), width: CGFloat(key.width), height: CGFloat(key.height))
        let radius = capsule.height / 2
        bitmap.saveGState()
        bitmap.setShadow(offset: CGSize(width: HUD.shadowOffset.width * scale, height: HUD.shadowOffset.height * scale),
                         blur: HUD.shadowBlur * scale, color: HUD.shadow)
        bitmap.addPath(CGPath(roundedRect: capsule, cornerWidth: radius, cornerHeight: radius, transform: nil))
        bitmap.setFillColor(HUD.fill)
        bitmap.fillPath()
        bitmap.restoreGState()
        let hairline = 0.5 * scale
        let inner = capsule.insetBy(dx: hairline / 2, dy: hairline / 2)
        bitmap.addPath(CGPath(roundedRect: inner, cornerWidth: radius - hairline / 2, cornerHeight: radius - hairline / 2,
                              transform: nil))
        bitmap.setStrokeColor(HUD.hairline)
        bitmap.setLineWidth(hairline)
        bitmap.strokePath()
        guard let image = bitmap.makeImage() else { return nil }
        if labelBackgrounds.count >= 32 { labelBackgrounds.removeAll() }
        labelBackgrounds[key] = image
        return image
    }
}

/// Builds rounded rectangles with continuous ("squircle") corners: each corner is a single cubic whose
/// curvature ramps up from the straight edge, matching the look of `CALayerCornerCurve.continuous`.
enum ContinuousCorners {
    /// How far a continuous corner reaches along each edge, relative to the nominal radius.
    static let extentFactor: CGFloat = 1.528665
    /// Control-point distance from the corner, relative to the radius; keeps the corner's midpoint on the
    /// equivalent circular arc.
    private static let controlFactor: CGFloat = 0.2717

    /// Length each corner occupies along its edges for `rect`, after clamping to the rectangle's size.
    static func extent(of rect: CGRect, radius: CGFloat) -> CGFloat {
        min(radius * extentFactor, min(rect.width, rect.height) / 2)
    }

    static func path(in rect: CGRect, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let e = extent(of: rect, radius: radius)
        guard e > 0 else {
            path.addRect(rect)
            return path
        }
        let c = e / extentFactor * controlFactor
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        path.move(to: CGPoint(x: minX + e, y: minY))
        path.addLine(to: CGPoint(x: maxX - e, y: minY))
        path.addCurve(to: CGPoint(x: maxX, y: minY + e),
                      control1: CGPoint(x: maxX - c, y: minY), control2: CGPoint(x: maxX, y: minY + c))
        path.addLine(to: CGPoint(x: maxX, y: maxY - e))
        path.addCurve(to: CGPoint(x: maxX - e, y: maxY),
                      control1: CGPoint(x: maxX, y: maxY - c), control2: CGPoint(x: maxX - c, y: maxY))
        path.addLine(to: CGPoint(x: minX + e, y: maxY))
        path.addCurve(to: CGPoint(x: minX, y: maxY - e),
                      control1: CGPoint(x: minX + c, y: maxY), control2: CGPoint(x: minX, y: maxY - c))
        path.addLine(to: CGPoint(x: minX, y: minY + e))
        path.addCurve(to: CGPoint(x: minX + e, y: minY),
                      control1: CGPoint(x: minX, y: minY + c), control2: CGPoint(x: minX + c, y: minY))
        path.closeSubpath()
        return path
    }
}
