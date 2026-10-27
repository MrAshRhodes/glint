import AppKit
import GlintCore
import GlintEditor

/// Small floating thumbnail at the screen corner: click to edit, drag out to drop the file, auto-dismisses.
@MainActor
final class QuickAccessPanel {
    private var panel: NSPanel?
    private var timer: Timer?

    /// Inset of the thumbnail inside the glass panel; the thumbnail's corners stay concentric with the panel's.
    static let thumbnailInset = GlintDesign.cardInset
    static let panelCornerRadius = GlintDesign.panelCornerRadius
    static var thumbnailCornerRadius: CGFloat { panelCornerRadius - thumbnailInset }
    /// Distance the panel slides in from (and back out to) the screen edge.
    private static let slideDistance: CGFloat = 16

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// `onDragOut` runs when a drag leaves the thumbnail. While a saved file is being dragged it counts as in use
    /// for Output cleanup.
    func show(image: CGImage, fileURL: URL?, activeFiles: OutputActiveFiles = .shared,
              onEdit: @escaping () -> Void, onDragOut: @escaping () -> Void = {}) {
        dismiss()
        guard let screen = NSScreen.main else { return }
        let maxSide: CGFloat = 220
        let ratio = CGFloat(image.width) / max(CGFloat(image.height), 1)
        let size = ratio >= 1 ? NSSize(width: maxSide, height: maxSide / ratio) : NSSize(width: maxSide * ratio, height: maxSide)
        let inset = Self.thumbnailInset
        let panelSize = NSSize(width: size.width + inset * 2, height: size.height + inset * 2)
        let margin: CGFloat = 20
        let frame = NSRect(x: screen.visibleFrame.maxX - panelSize.width - margin, y: screen.visibleFrame.minY + margin,
                           width: panelSize.width, height: panelSize.height)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let nsImage = NSImage(cgImage: image, size: size)
        let view = ThumbnailView(frame: NSRect(origin: .zero, size: size), image: nsImage, fileURL: fileURL,
                                 activeFiles: activeFiles, cornerRadius: Self.thumbnailCornerRadius)
        view.onClick = { [weak self] in self?.dismiss(); onEdit() }
        view.onClose = { [weak self] in self?.dismiss() }
        view.onHover = { [weak self] inside in inside ? self?.timer?.invalidate() : self?.scheduleDismiss() }
        view.onDragStart = { [weak self] in
            self?.timer?.invalidate()
            onDragOut()
        }

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
    var onDragStart: (() -> Void)?
    private let image: NSImage
    private let fileURL: URL?
    private let dragFile: ActiveDragFile
    private let closeButton = NSButton()
    private var downPoint: NSPoint = .zero
    private var dragged = false

    init(frame: NSRect, image: NSImage, fileURL: URL?, activeFiles: OutputActiveFiles, cornerRadius: CGFloat) {
        self.image = image
        self.fileURL = fileURL
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
        onDragStart?()
        dragFile.begin(fileURL)
        let writer: NSPasteboardWriting = fileURL.map { $0 as NSURL } ?? image
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
