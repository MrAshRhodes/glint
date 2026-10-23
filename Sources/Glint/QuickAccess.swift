import AppKit
import GlintCore

/// Small floating thumbnail at the screen corner: click to edit, drag out to drop the file, auto-dismisses.
@MainActor
final class QuickAccessPanel {
    private var panel: NSPanel?
    private var timer: Timer?

    /// `onDragOut` runs when a drag leaves the thumbnail. While a saved file is being dragged it counts as in use
    /// for Output cleanup.
    func show(image: CGImage, fileURL: URL?, activeFiles: OutputActiveFiles = .shared,
              onEdit: @escaping () -> Void, onDragOut: @escaping () -> Void = {}) {
        dismiss()
        guard let screen = NSScreen.main else { return }
        let maxSide: CGFloat = 220
        let ratio = CGFloat(image.width) / max(CGFloat(image.height), 1)
        let size = ratio >= 1 ? NSSize(width: maxSide, height: maxSide / ratio) : NSSize(width: maxSide * ratio, height: maxSide)
        let margin: CGFloat = 20
        let frame = NSRect(x: screen.visibleFrame.maxX - size.width - margin, y: screen.visibleFrame.minY + margin,
                           width: size.width, height: size.height)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        let nsImage = NSImage(cgImage: image, size: size)
        let view = ThumbnailView(frame: NSRect(origin: .zero, size: size), image: nsImage, fileURL: fileURL,
                                 activeFiles: activeFiles)
        view.onClick = { [weak self] in self?.dismiss(); onEdit() }
        view.onHover = { [weak self] inside in inside ? self?.timer?.invalidate() : self?.scheduleDismiss() }
        view.onDragStart = { [weak self] in
            self?.timer?.invalidate()
            onDragOut()
        }
        p.contentView = view
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
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
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 },
                                             completionHandler: { p.orderOut(nil) })
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
    var onHover: ((Bool) -> Void)?
    var onDragStart: (() -> Void)?
    private let image: NSImage
    private let fileURL: URL?
    private let dragFile: ActiveDragFile
    private var downPoint: NSPoint = .zero
    private var dragged = false

    init(frame: NSRect, image: NSImage, fileURL: URL?, activeFiles: OutputActiveFiles) {
        self.image = image
        self.fileURL = fileURL
        dragFile = ActiveDragFile(files: activeFiles)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) { image.draw(in: bounds) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

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
