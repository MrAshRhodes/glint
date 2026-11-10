import AppKit
import GlintCore
import GlintEditor

/// One screenshot offered in the quick-access panel.
struct QuickAccessItem {
    /// Names this screenshot when its file is written later, so a slow write never lands on a newer thumbnail.
    let id: UUID
    /// What the panel draws: already scaled down, so showing it never resamples the full-resolution capture.
    let thumbnail: CGImage
    /// The finished image: what a drag carries until the file exists.
    let image: CGImage
    /// The display the capture came from, where the panel appears.
    let displayID: CGDirectDisplayID?
    let onEdit: () -> Void
    /// Runs when a drag leaves the thumbnail, with the file being dragged (nil while only the image data leaves).
    let onDragOut: (URL?) -> Void
}

@MainActor
protocol QuickAccessPresenting: AnyObject {
    /// The longest side, in pixels, a thumbnail needs to look sharp on the display `displayID` names.
    func thumbnailPixelSide(for displayID: CGDirectDisplayID?) -> Int
    func show(_ item: QuickAccessItem)
    /// The file for the screenshot `id` now exists. Drags of it that start from here on carry the file.
    func fileSaved(_ url: URL, for id: UUID)
}

/// Small floating thumbnail at the screen corner: click to edit, drag out to drop the file, auto-dismisses.
@MainActor
final class QuickAccessPanel: QuickAccessPresenting {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("GlintQuickAccess")
    private var panel: NSPanel?
    private var timer: Timer?
    private var shownID: UUID?
    private weak var thumbnailView: ThumbnailView?
    private let activeFiles: OutputActiveFiles

    /// While a saved file is being dragged it counts as in use for Output cleanup.
    init(activeFiles: OutputActiveFiles = .shared) { self.activeFiles = activeFiles }

    /// Longest side of the thumbnail, in points.
    static let maxSide: CGFloat = 220

    /// Inset of the thumbnail inside the glass panel; the thumbnail's corners stay concentric with the panel's.
    static let thumbnailInset = GlintDesign.cardInset
    static let panelCornerRadius = GlintDesign.panelCornerRadius
    static var thumbnailCornerRadius: CGFloat { panelCornerRadius - thumbnailInset }
    /// Distance the panel slides in from (and back out to) the screen edge.
    private static let slideDistance: CGFloat = 16

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The screen showing the display `displayID` names, if it is among `screens`.
    static func screen(for displayID: CGDirectDisplayID?, among screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        guard let displayID else { return nil }
        return screens.first { Self.displayID(of: $0) == displayID }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    func thumbnailPixelSide(for displayID: CGDirectDisplayID?) -> Int {
        let scale = (Self.screen(for: displayID) ?? NSScreen.main)?.backingScaleFactor ?? 2
        return Int((Self.maxSide * scale).rounded(.up))
    }

    func fileSaved(_ url: URL, for id: UUID) {
        guard shownID == id else { return }
        thumbnailView?.fileURL = url
    }

    func show(_ item: QuickAccessItem) {
        let signpost = CaptureSignposts.begin("QuickAccessShown")
        defer { CaptureSignposts.end(signpost) }
        dismiss()
        guard let screen = Self.screen(for: item.displayID) ?? NSScreen.main else { return }
        let maxSide = Self.maxSide
        let ratio = CGFloat(item.image.width) / max(CGFloat(item.image.height), 1)
        let size = ratio >= 1 ? NSSize(width: maxSide, height: maxSide / ratio) : NSSize(width: maxSide * ratio, height: maxSide)
        let inset = Self.thumbnailInset
        let panelSize = NSSize(width: size.width + inset * 2, height: size.height + inset * 2)
        let margin: CGFloat = 20
        let frame = NSRect(x: screen.visibleFrame.maxX - panelSize.width - margin, y: screen.visibleFrame.minY + margin,
                           width: panelSize.width, height: panelSize.height)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.identifier = Self.windowIdentifier
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let nsImage = NSImage(cgImage: item.thumbnail, size: size)
        let view = ThumbnailView(frame: NSRect(origin: .zero, size: size), image: nsImage, dragImage: item.image,
                                 activeFiles: activeFiles, cornerRadius: Self.thumbnailCornerRadius)
        let onEdit = item.onEdit, onDragOut = item.onDragOut
        view.onClick = { [weak self] in self?.dismiss(); onEdit() }
        view.onClose = { [weak self] in self?.dismiss() }
        view.onHover = { [weak self] inside in inside ? self?.timer?.invalidate() : self?.scheduleDismiss() }
        view.onDragStart = { [weak self] file in
            self?.timer?.invalidate()
            onDragOut(file)
        }
        thumbnailView = view
        shownID = item.id

        let content = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
        ])
        let glass = GlintGlassView(cornerRadius: Self.panelCornerRadius)
        glass.contentView = content
        p.contentView = glass

        // Slide in from the screen edge like the system screenshot thumbnail; Reduce Motion only fades.
        let start = Self.reduceMotion ? frame : frame.offsetBy(dx: Self.slideDistance, dy: 0)
        p.setFrame(start, display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.reduceMotion ? 0.15 : 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            if start != frame { p.animator().setFrame(frame, display: true) }
        }
        panel = p
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    func dismiss() {
        timer?.invalidate()
        shownID = nil
        guard let p = panel else { return }
        panel = nil
        let reduceMotion = Self.reduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0.15 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
            if !reduceMotion { p.animator().setFrame(p.frame.offsetBy(dx: Self.slideDistance, dy: 0), display: true) }
        }, completionHandler: { p.orderOut(nil) })
    }
}

/// Keeps a file that is being dragged out away from Output cleanup until the drag ends.
final class ActiveDragFile {
    private let files: OutputActiveFiles
    private var url: URL?

    init(files: OutputActiveFiles = .shared) { self.files = files }

    func begin(_ url: URL?) {
        end()
        guard let url else { return }
        files.begin(url)
        self.url = url
    }

    func end() {
        guard let url else { return }
        files.end(url)
        self.url = nil
    }

    deinit { end() }
}

private final class ThumbnailView: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDragStart: ((URL?) -> Void)?
    private let image: NSImage
    private let dragImage: CGImage
    /// The saved file, once there is one. Until then a drag carries the image itself.
    var fileURL: URL?
    private let dragFile: ActiveDragFile
    private let closeButton = NSButton()
    private var downPoint: NSPoint = .zero
    private var dragged = false

    init(frame: NSRect, image: NSImage, dragImage: CGImage, activeFiles: OutputActiveFiles, cornerRadius: CGFloat) {
        self.image = image
        self.dragImage = dragImage
        dragFile = ActiveDragFile(files: activeFiles)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setUpCloseButton()

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Screenshot thumbnail")
        setAccessibilityHelp("Click to edit. Drag to drop the screenshot into another app.")
        toolTip = "Click to edit · Drag to share"
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Borderless HUD-style close control, revealed on hover like the system screenshot thumbnail.
    private func setUpCloseButton() {
        let symbol = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        closeButton.image = symbol
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        closeButton.layer?.cornerRadius = 10
        closeButton.layer?.borderWidth = 0.5
        closeButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "Dismiss"
        closeButton.setAccessibilityLabel("Dismiss screenshot thumbnail")
        closeButton.alphaValue = 0
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
        ])
    }

    @objc private func closeTapped() { onClose?() }

    private func setCloseButtonVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            closeButton.animator().alphaValue = visible ? 1 : 0
        }
    }

    override func draw(_ dirtyRect: NSRect) { image.draw(in: bounds) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { setCloseButtonVisible(true); onHover?(true) }
    override func mouseExited(with event: NSEvent) { setCloseButtonVisible(false); onHover?(false) }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, hypot(event.locationInWindow.x - downPoint.x, event.locationInWindow.y - downPoint.y) > 4 else { return }
        dragged = true
        let file = fileURL
        onDragStart?(file)
        dragFile.begin(file)
        let writer: NSPasteboardWriting = file.map { $0 as NSURL } ?? NSImage(cgImage: dragImage, size: bounds.size)
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { onClick?() }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragFile.end()
    }
}
