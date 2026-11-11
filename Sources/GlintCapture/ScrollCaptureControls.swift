import AppKit
import Carbon.HIToolbox
import GlintCore

// MARK: - Layout

enum ScrollCaptureLayout {
    static let gap: CGFloat = 16

    /// Right of the region when it fits on screen, else left of it, else inside it along the right edge.
    /// The controls never cover the region while there is room beside it, so they are never captured.
    static func hudFrame(size: CGSize, region: CGRect, usable: CGRect, gap: CGFloat = gap,
                         margin: CGFloat = RecordingLayout.margin) -> CGRect {
        let area = usable.insetBy(dx: margin, dy: margin)
        let width = min(size.width, area.width), height = min(size.height, area.height)
        let y = min(max(region.minY, area.minY), area.maxY - height)
        let right = region.maxX + gap
        if right + width <= area.maxX { return CGRect(x: right, y: y, width: width, height: height) }
        let left = region.minX - gap - width
        if left >= area.minX { return CGRect(x: left, y: y, width: width, height: height) }
        let inside = min(max(region.maxX - gap - width, area.minX), area.maxX - width)
        return CGRect(x: inside, y: y, width: width, height: height)
    }
}

// MARK: - Announcements

/// What VoiceOver says during a scrolling capture.
enum ScrollCaptureAnnouncement {
    static let started = "Scrolling capture started. Follow the pace indicator, then press Done."
    static let resumed = "Capturing resumed"

    static func paused(_ warning: ScrollStitchWarning) -> String { "Capture paused. " + warning.message }

    static func finished(wasCaptured: Bool) -> String {
        wasCaptured ? "Scrolling capture finished" : "Scrolling capture cancelled"
    }

    static func status(_ status: ScrollCaptureStatus) -> String {
        let frames = status.frames == 1 ? "1 frame" : "\(status.frames) frames"
        return "\(frames), \(status.height) pixels tall"
    }
}

// MARK: - Presenter

/// Shows the red frame around the region and the controls beside it, and relays the controls to the session.
///
/// Nothing here takes keyboard focus, so the app being scrolled keeps it. Esc cancels through a temporary global
/// shortcut; while the capture is paused Return finishes, Command-Z undoes and Command-R retries.
@MainActor
final class ScrollCaptureOverlayPresenter: ScrollCapturePresenting {
    private enum Key {
        static let cancel = "glint.scrolling.cancel"
        static let done = "glint.scrolling.done"
        static let undo = "glint.scrolling.undo"
        static let retry = "glint.scrolling.retry"
    }

    private let chrome: RecordingChromeEnvironment
    private let hotkeys: HotkeyCenter
    private var primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    private var region: RecordingRegion?
    private var actions: ScrollCaptureControlActions?
    private var status = ScrollCaptureStatus()
    private var hasCaptured = false
    private var framePanel: RecordingFramePanel?
    private var hudPanel: ScrollCaptureHUDPanel?
    private var pauseKeysRegistered = false

    init(chrome: RecordingChromeEnvironment = .live, hotkeys: HotkeyCenter? = nil) {
        self.chrome = chrome
        self.hotkeys = hotkeys ?? .shared
    }

    func show(region: RecordingRegion, actions: ScrollCaptureControlActions) {
        self.region = region
        self.actions = actions
        primaryHeight = NSScreen.screens.first?.frame.height ?? primaryHeight

        let frame = RecordingFramePanel(primaryHeight: primaryHeight, displayFrame: region.display.frame)
        frame.applyDisplayOptions(chrome.displayOptions())
        frame.setRegion(region.rect, mode: .recording)
        framePanel = frame

        let hud = ScrollCaptureHUDPanel(chrome: chrome)
        hud.hudView.onDone = { [weak self] in self?.actions?.done() }
        hud.hudView.onUndo = { [weak self] in self?.actions?.undo() }
        hud.hudView.onCancel = { [weak self] in self?.actions?.cancel() }
        hud.hudView.onResume = { [weak self] in self?.actions?.resume() }
        hud.hudView.onRetry = { [weak self] in self?.actions?.retry() }
        hud.apply(status, preview: nil)
        hudPanel = hud
        positionHUD()

        frame.orderFrontRegardless()
        hud.orderFrontRegardless()
        try? hotkeys.register(id: Key.cancel, keyCode: UInt32(kVK_Escape), modifiers: []) { [weak self] in
            self?.actions?.cancel()
        }
        chrome.announce(ScrollCaptureAnnouncement.started)
    }

    func update(_ status: ScrollCaptureStatus, preview: CGImage?) {
        let wasPaused = self.status.isPaused
        let previousMessage = self.status.pauseMessage
        let previousPace = self.status.pace
        let wasAutomatic = self.status.isAutomatic
        self.status = status
        hasCaptured = hasCaptured || status.frames > 0
        hudPanel?.apply(status, preview: preview)
        positionHUD()
        setPauseKeys(status.isPaused)
        if let message = status.pauseMessage, message != previousMessage {
            chrome.announce("Capture paused. " + message)
        } else if wasPaused, !status.isPaused {
            chrome.announce(ScrollCaptureAnnouncement.resumed)
        } else if status.isAutomatic, !wasAutomatic {
            chrome.announce("Scrolling automatically. Choose Done to finish or Escape to cancel.")
        } else if !status.isPaused, !status.isAutomatic, status.pace != previousPace,
                  status.pace == .tooFast || status.pace == .tooSlow {
            chrome.announce(status.pace.message)
        }
    }

    func dismiss() {
        if region != nil { chrome.announce(ScrollCaptureAnnouncement.finished(wasCaptured: hasCaptured)) }
        hotkeys.unregister(id: Key.cancel)
        setPauseKeys(false)
        for panel in [framePanel, hudPanel] as [NSPanel?] {
            panel?.orderOut(nil)
            panel?.close()
        }
        framePanel = nil
        hudPanel = nil
        region = nil
        actions = nil
    }

    private func setPauseKeys(_ paused: Bool) {
        guard paused != pauseKeysRegistered else { return }
        pauseKeysRegistered = paused
        guard paused else {
            for id in [Key.done, Key.undo, Key.retry] { hotkeys.unregister(id: id) }
            return
        }
        try? hotkeys.register(id: Key.done, keyCode: UInt32(kVK_Return), modifiers: []) { [weak self] in
            self?.actions?.done()
        }
        try? hotkeys.register(id: Key.undo, keyCode: UInt32(kVK_ANSI_Z), modifiers: .command) { [weak self] in
            guard self?.status.canUndo == true else { return }
            self?.actions?.undo()
        }
        try? hotkeys.register(id: Key.retry, keyCode: UInt32(kVK_ANSI_R), modifiers: .command) { [weak self] in
            guard self?.status.canRetry == true else { return }
            self?.actions?.retry()
        }
    }

    private func positionHUD() {
        guard let region, let hudPanel else { return }
        let screen = NSScreen.screens.first { WindowEnumerator.displayID(of: $0) == region.display.id }
        let usable = screen.map { CaptureGeometry.appKitToCG($0.visibleFrame, primaryHeight: primaryHeight) }
            ?? region.display.frame
        let target = ScrollCaptureLayout.hudFrame(size: hudPanel.frame.size, region: region.rect, usable: usable)
        hudPanel.setFrame(CaptureGeometry.cgToAppKit(target, primaryHeight: primaryHeight), display: true)
    }
}

// MARK: - Controls

/// The floating controls. Clicks reach the buttons without the panel taking keyboard focus.
final class ScrollCaptureHUDPanel: NSPanel {
    let hudView: ScrollCaptureHUDView

    init(chrome: RecordingChromeEnvironment = .live) {
        hudView = ScrollCaptureHUDView(chrome: chrome)
        super.init(contentRect: NSRect(x: 0, y: 0, width: ScrollCaptureHUDView.width, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        MainActor.assumeIsolated { configureOverlayPanel(self, levelOffset: 1) }
        hasShadow = true
        contentView = hudView
        setAccessibilityLabel("Scrolling capture controls")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func apply(_ status: ScrollCaptureStatus, preview: CGImage?) {
        hudView.apply(status, preview: preview)
        setContentSize(hudView.preferredSize)
    }
}

final class ScrollCaptureHUDView: NSView {
    static let width: CGFloat = 240
    static let previewHeight: CGFloat = 220

    var onDone: (() -> Void)?
    var onUndo: (() -> Void)?
    var onCancel: (() -> Void)?
    var onResume: (() -> Void)?
    var onRetry: (() -> Void)?

    let preview = ScrollPreviewView()
    let statusLabel = NSTextField(labelWithString: "Scroll to start")
    let paceLabel = NSTextField(wrappingLabelWithString: "")
    let warningLabel = NSTextField(wrappingLabelWithString: "")
    let progress = NSProgressIndicator()
    let doneButton: NSButton
    let undoButton: NSButton
    let cancelButton: NSButton
    let resumeButton: NSButton
    let retryButton: NSButton

    private let glass: RecordingGlassView
    private let root = NSStackView()

    init(chrome: RecordingChromeEnvironment) {
        let glassBezel = chrome.supportsLiquidGlass
        glass = RecordingGlassView(cornerRadius: RecordingChromeTokens.panelCornerRadius, style: chrome.style)
        doneButton = Self.button("Done", tip: "Finish and open the image (Return while paused)", glass: glassBezel,
                                 prominent: true)
        undoButton = Self.button("Undo", tip: "Remove the last part that was added (⌘Z while paused)", glass: glassBezel)
        cancelButton = Self.button("Cancel", tip: "Stop without keeping anything (Esc)", glass: glassBezel)
        resumeButton = Self.button("Resume", tip: "Keep what was captured and continue from what is on screen now",
                                   glass: glassBezel)
        retryButton = Self.button("Retry", tip: "Drop the last join and capture the screen again (⌘R while paused)",
                                  glass: glassBezel)
        super.init(frame: .zero)

        doneButton.target = self
        doneButton.action = #selector(doneTapped)
        undoButton.target = self
        undoButton.action = #selector(undoTapped)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        resumeButton.target = self
        resumeButton.action = #selector(resumeTapped)
        retryButton.target = self
        retryButton.action = #selector(retryTapped)

        statusLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        statusLabel.setAccessibilityLabel("Captured so far")
        warningLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warningLabel.textColor = .labelColor
        warningLabel.preferredMaxLayoutWidth = Self.width - 32
        paceLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        paceLabel.preferredMaxLayoutWidth = Self.width - 32
        paceLabel.setAccessibilityLabel("Scrolling pace")
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.setAccessibilityLabel("Height limit used")

        let pauseRow = Self.row([retryButton, resumeButton])
        let actionRow = Self.row([undoButton, cancelButton, doneButton])
        root.setViews([preview, statusLabel, paceLabel, progress, warningLabel, pauseRow, actionRow], in: .top)
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = RecordingChromeTokens.spacing
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            preview.widthAnchor.constraint(equalToConstant: Self.width - 32),
            preview.heightAnchor.constraint(equalToConstant: Self.previewHeight),
            progress.widthAnchor.constraint(equalToConstant: Self.width - 32),
            paceLabel.widthAnchor.constraint(equalToConstant: Self.width - 32),
            warningLabel.widthAnchor.constraint(equalToConstant: Self.width - 32)
        ])
        glass.contentView = root
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Scrolling capture controls")
        apply(ScrollCaptureStatus(), preview: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var preferredSize: NSSize { root.fittingSize }

    func apply(_ status: ScrollCaptureStatus, preview image: CGImage?) {
        preview.image = image ?? (status.frames == 0 ? nil : preview.image)
        preview.imageHeight = status.height
        if case .lowConfidence(let rows) = status.warning { preview.highlight = rows } else { preview.highlight = nil }
        statusLabel.stringValue = status.frames == 0
            ? "Scroll to start"
            : "\(status.frames) \(status.frames == 1 ? "frame" : "frames") · \(status.height) px"
        statusLabel.setAccessibilityValue(status.frames == 0 ? "Nothing yet" : ScrollCaptureAnnouncement.status(status))
        paceLabel.stringValue = status.isAutomatic ? "Scrolling automatically — capturing each step." : status.pace.message
        paceLabel.isHidden = status.isPaused
        paceLabel.textColor = status.isAutomatic || status.pace == .steady ? .systemGreen
            : (status.pace == .ready ? .secondaryLabelColor : .systemOrange)
        paceLabel.drawsBackground = !status.isAutomatic && (status.pace == .tooFast || status.pace == .tooSlow)
        paceLabel.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12)
        paceLabel.setAccessibilityValue(paceLabel.stringValue)
        progress.doubleValue = status.progress
        progress.isHidden = !status.isNearLimit
        warningLabel.stringValue = status.pauseMessage ?? ""
        warningLabel.isHidden = !status.isPaused
        resumeButton.isHidden = !status.isPaused || status.isAtLimit
        retryButton.isHidden = !status.canRetry
        resumeButton.superview?.isHidden = resumeButton.isHidden && retryButton.isHidden
        undoButton.isEnabled = status.canUndo
        doneButton.isEnabled = true
        doneButton.keyEquivalent = status.isPaused ? "\r" : ""
    }

    @objc private func doneTapped() { onDone?() }
    @objc private func undoTapped() { onUndo?() }
    @objc private func cancelTapped() { onCancel?() }
    @objc private func resumeTapped() { onResume?() }
    @objc private func retryTapped() { onRetry?() }

    private static func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = RecordingChromeTokens.spacing
        return stack
    }

    private static func button(_ title: String, tip: String, glass: Bool, prominent: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.toolTip = tip
        button.setAccessibilityHelp(tip)
        RecordingButtonStyle.configure(button, supportsLiquidGlass: glass)
        if prominent {
            button.bezelColor = .controlAccentColor
            button.contentTintColor = .white
        }
        return button
    }
}

/// The stitched image so far, scaled to fit, with the rows of a doubtful join tinted.
final class ScrollPreviewView: NSView {
    var image: CGImage? { didSet { needsDisplay = true; updateAccessibility() } }
    /// Height of the full stitched image the highlight rows refer to.
    var imageHeight = 0 { didSet { needsDisplay = true } }
    var highlight: Range<Int>? { didSet { needsDisplay = true; updateAccessibility() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Where the image is drawn in the view, aspect fit and centred horizontally, top-aligned.
    static func imageRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.minX + (bounds.width - size.width) / 2, y: bounds.minY, width: size.width,
                      height: size.height)
    }

    /// `rows` of an image `imageHeight` tall, inside `imageRect` (flipped, top-left origin).
    static func highlightRect(rows: Range<Int>, imageHeight: Int, imageRect: CGRect) -> CGRect {
        guard imageHeight > 0 else { return .zero }
        let scale = imageRect.height / CGFloat(imageHeight)
        let top = CGFloat(max(rows.lowerBound, 0)) * scale
        let height = max(CGFloat(min(rows.upperBound, imageHeight) - max(rows.lowerBound, 0)) * scale, 2)
        return CGRect(x: imageRect.minX, y: imageRect.minY + top, width: imageRect.width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = Self.imageRect(imageSize: CGSize(width: image.width, height: image.height), in: bounds)
        context.saveGState()
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .medium
        context.draw(image, in: rect)
        context.restoreGState()
        if let highlight {
            let band = Self.highlightRect(rows: highlight, imageHeight: imageHeight, imageRect: rect)
            NSColor.systemYellow.withAlphaComponent(0.35).setFill()
            band.fill(using: .sourceOver)
            NSColor.systemYellow.setStroke()
            NSBezierPath(rect: band).stroke()
        }
    }

    private func updateAccessibility() {
        setAccessibilityLabel(image == nil ? "Preview, empty" : "Preview of the stitched image")
        setAccessibilityHelp(highlight == nil ? nil : "The highlighted part may not line up")
    }
}
