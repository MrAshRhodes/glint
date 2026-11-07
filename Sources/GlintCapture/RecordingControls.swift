import AppKit
import GlintCore

/// Every window of the recording UI is non-activating (the app being recorded keeps focus) and excluded from
/// screen capture, so none of it reaches the video; `ScreenRecorder` also leaves out the whole app.
@MainActor
func configureOverlayPanel(_ panel: NSPanel, levelOffset: Int) {
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + levelOffset)
    panel.sharingType = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
}

// MARK: - Presenter

/// Puts the region frame, control bar and countdown on screen and relays what the user does to the session.
/// It follows display changes and the accessibility display settings while it is up, and announces each phase
/// to VoiceOver.
@MainActor
final class RecordingOverlayPresenter: RecordingPresenting {
    private enum Phase: Equatable {
        case ready
        case countdown(Int)
        case recording
    }

    private let chrome: RecordingChromeEnvironment
    private var primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    private var region: RecordingRegion?
    private var actions: RecordingControlActions?
    private var phase = Phase.ready
    private var hasAnnouncedCountdown = false
    private var framePanel: RecordingFramePanel?
    private var barPanel: RecordingBarPanel?
    private var countdownPanel: RecordingCountdownPanel?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(chrome: RecordingChromeEnvironment = .live) {
        self.chrome = chrome
    }

    func showReady(region: RecordingRegion, actions: RecordingControlActions) {
        self.region = region
        self.actions = actions
        phase = .ready
        hasAnnouncedCountdown = false
        primaryHeight = NSScreen.screens.first?.frame.height ?? primaryHeight

        let frame = RecordingFramePanel(primaryHeight: primaryHeight, displayFrame: region.display.frame)
        frame.onRegionChange = { [weak self] in self?.regionChanged($0) }
        frame.onNudge = { [weak self] in self?.nudge($0, step: 10) }
        frame.applyDisplayOptions(chrome.displayOptions())
        frame.setRegion(region.rect, mode: .adjusting)
        framePanel = frame

        let bar = RecordingBarPanel(chrome: chrome)
        bar.onRecord = { [weak self] choice in
            guard let self, let region = self.region else { return }
            self.actions?.record(choice, region.rect)
        }
        bar.onStop = { [weak self] in self?.actions?.stop() }
        bar.onCancel = { [weak self] in self?.actions?.cancel() }
        bar.onNudge = { [weak self] in self?.nudge($0, step: $1) }
        bar.apply(.ready(sizeText: CaptureGeometry.dimensionLabel(region.rect)))
        barPanel = bar
        positionBar()

        frame.orderFrontRegardless()
        bar.orderFrontRegardless()
        OverlayFocus.makeKey(bar)
        observeSystemChanges()
        chrome.announce(RecordingAnnouncement.ready)
    }

    func showCountdown(_ remaining: Int) {
        guard let region else { return }
        guard remaining > 0 else {
            countdownPanel?.orderOut(nil)
            return
        }
        phase = .countdown(remaining)
        framePanel?.setRegion(region.rect, mode: .locked)
        barPanel?.apply(.countdown(remaining: remaining))
        positionBar()
        let panel = countdownPanel ?? RecordingCountdownPanel(chrome: chrome)
        countdownPanel = panel
        panel.show(remaining, over: region.rect, primaryHeight: primaryHeight)
        chrome.announce(RecordingAnnouncement.countdown(remaining, isFirst: !hasAnnouncedCountdown))
        hasAnnouncedCountdown = true
    }

    func showRecording(elapsed: TimeInterval) {
        guard let region else { return }
        phase = .recording
        countdownPanel?.orderOut(nil)
        framePanel?.setRegion(region.rect, mode: .recording)
        barPanel?.apply(.recording(elapsed: ElapsedTimeFormatter.string(from: elapsed),
                                   spoken: ElapsedTimeFormatter.spoken(from: elapsed)))
        positionBar()
        chrome.announce(RecordingAnnouncement.started)
    }

    func updateElapsed(_ elapsed: TimeInterval) {
        barPanel?.updateElapsed(ElapsedTimeFormatter.string(from: elapsed),
                                spoken: ElapsedTimeFormatter.spoken(from: elapsed))
    }

    func dismiss() {
        if region != nil { chrome.announce(RecordingAnnouncement.finished(wasRecording: phase == .recording)) }
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
        for panel in [framePanel, barPanel, countdownPanel] as [NSPanel?] {
            panel?.orderOut(nil)
            panel?.close()
        }
        framePanel = nil
        barPanel = nil
        countdownPanel = nil
        region = nil
        actions = nil
    }

    private func regionChanged(_ rect: CGRect) {
        guard let region else { return }
        self.region = RecordingRegion(rect: rect, display: region.display)
        framePanel?.setRegion(rect, mode: .adjusting)
        barPanel?.apply(.ready(sizeText: CaptureGeometry.dimensionLabel(rect)))
        positionBar()
    }

    private func nudge(_ nudge: RegionNudge, step: CGFloat) {
        guard phase == .ready, let region else { return }
        let rect = RegionAdjustment.nudged(region.rect, nudge, step: step, bounds: region.display.frame)
        if rect != region.rect { regionChanged(rect) }
    }

    private func positionBar() {
        guard let region, let barPanel else { return }
        barPanel.place(near: region.rect, usable: usableFrame(of: region.display), primaryHeight: primaryHeight)
    }

    /// The display without menu bar and Dock, in CG coordinates.
    private func usableFrame(of display: DisplayInfo) -> CGRect {
        let screen = NSScreen.screens.first { WindowEnumerator.displayID(of: $0) == display.id }
        guard let screen else { return display.frame }
        return CaptureGeometry.appKitToCG(screen.visibleFrame, primaryHeight: primaryHeight)
    }

    // MARK: System changes

    private func observeSystemChanges() {
        guard observers.isEmpty else { return }
        let screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let options = workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayOptionsChanged() }
        }
        observers = [(NotificationCenter.default, screens), (workspace, options)]
    }

    /// Displays came, went or moved: the overlay windows are positioned in global coordinates, so place them again.
    /// The captured rectangle never changes after Record, only the windows around it follow.
    func screensChanged() {
        primaryHeight = NSScreen.screens.first?.frame.height ?? primaryHeight
        guard let region,
              let display = WindowEnumerator.displays().first(where: { $0.id == region.display.id }) else { return }
        let rect = phase == .ready ? RegionAdjustment.clamped(region.rect, to: display.frame) : region.rect
        self.region = RecordingRegion(rect: rect, display: display)
        framePanel?.updateGeometry(primaryHeight: primaryHeight, displayFrame: display.frame)
        switch phase {
        case .ready:
            framePanel?.setRegion(rect, mode: .adjusting)
            barPanel?.apply(.ready(sizeText: CaptureGeometry.dimensionLabel(rect)))
        case .countdown(let remaining):
            framePanel?.setRegion(rect, mode: .locked)
            countdownPanel?.show(remaining, over: rect, primaryHeight: primaryHeight)
        case .recording:
            framePanel?.setRegion(rect, mode: .recording)
        }
        positionBar()
    }

    /// Reduce Motion, Reduce Transparency or Increase Contrast changed while the overlay is up.
    func displayOptionsChanged() {
        framePanel?.applyDisplayOptions(chrome.displayOptions())
        barPanel?.refreshChrome()
        countdownPanel?.refreshChrome()
    }
}

// MARK: - Region frame

/// A transparent frame around the region. Before recording it can be moved and resized; while recording it
/// ignores the mouse and its red outline lies entirely outside the captured pixels.
final class RecordingFramePanel: NSPanel {
    enum Mode { case adjusting, locked, recording }

    /// Room around the region for the resize handles.
    static let adjustingOutset: CGFloat = 14
    static let recordingOutset: CGFloat = 3

    var onRegionChange: ((CGRect) -> Void)? {
        get { frameView.onRegionChange }
        set { frameView.onRegionChange = newValue }
    }

    /// A move or resize asked for through VoiceOver instead of the mouse.
    var onNudge: ((RegionNudge) -> Void)? {
        get { frameView.onNudge }
        set { frameView.onNudge = newValue }
    }

    private let frameView: RecordingFrameView
    private var primaryHeight: CGFloat

    init(primaryHeight: CGFloat, displayFrame: CGRect) {
        self.primaryHeight = primaryHeight
        frameView = RecordingFrameView()
        frameView.displayFrame = displayFrame
        frameView.primaryHeight = primaryHeight
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        MainActor.assumeIsolated { configureOverlayPanel(self, levelOffset: 0) }
        isMovable = false
        acceptsMouseMovedEvents = true
        contentView = frameView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func updateGeometry(primaryHeight: CGFloat, displayFrame: CGRect) {
        self.primaryHeight = primaryHeight
        frameView.primaryHeight = primaryHeight
        frameView.displayFrame = displayFrame
    }

    func applyDisplayOptions(_ options: RecordingDisplayOptions) {
        frameView.increaseContrast = options.increaseContrast
        frameView.needsDisplay = true
    }

    /// `region` is in global CG coordinates.
    func setRegion(_ region: CGRect, mode: Mode) {
        let outset = mode == .recording ? Self.recordingOutset : Self.adjustingOutset
        frameView.region = region
        frameView.outset = outset
        frameView.mode = mode
        ignoresMouseEvents = mode != .adjusting
        setFrame(CaptureGeometry.cgToAppKit(region.insetBy(dx: -outset, dy: -outset), primaryHeight: primaryHeight),
                 display: true)
        frameView.needsDisplay = true
        frameView.refreshAccessibility()
    }
}

final class RecordingFrameView: NSView {
    var mode: RecordingFramePanel.Mode = .adjusting
    var outset: CGFloat = RecordingFramePanel.adjustingOutset
    /// Global CG coordinates.
    var region: CGRect = .zero
    var displayFrame: CGRect = .zero
    var primaryHeight: CGFloat = 0
    var increaseContrast = false
    var onRegionChange: ((CGRect) -> Void)?
    var onNudge: ((RegionNudge) -> Void)?

    private var drag: (handle: RegionHandle, startPoint: CGPoint, startRegion: CGRect)?
    private var lastSpokenValue: String?

    private enum Palette {
        /// Barely visible, but not clear: fully transparent pixels let clicks fall through to the window below.
        static let interior = NSColor.black.withAlphaComponent(0.02)
        static let stroke = NSColor.white
        static let recording = NSColor.systemRed

        /// White line with a dark one outside it, so the frame shows on light and dark content alike.
        static func contrast(increased: Bool) -> NSColor {
            NSColor.black.withAlphaComponent(increased ? 0.75 : 0.4)
        }
    }

    private static let handleSize: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Recording area")
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var regionRect: NSRect { bounds.insetBy(dx: outset, dy: outset) }

    private var mouseInCG: CGPoint {
        CaptureGeometry.appKitToCG(NSEvent.mouseLocation, primaryHeight: primaryHeight)
    }

    // MARK: Accessibility

    /// What VoiceOver reads for the frame: its size, and the actions that move it while it can still be adjusted.
    func refreshAccessibility() {
        let size = "\(Int(region.width.rounded())) by \(Int(region.height.rounded())) points"
        let value = mode == .recording ? "\(size), recording" : size
        setAccessibilityValue(value)
        if mode == .adjusting {
            setAccessibilityHelp("The area that will be recorded. Drag to move or resize it, or use the actions.")
            setAccessibilityCustomActions(RegionNudge.allCases.map { nudge in
                NSAccessibilityCustomAction(name: nudge.title) { [weak self] in
                    self?.onNudge?(nudge)
                    return true
                }
            })
        } else {
            setAccessibilityHelp(nil)
            setAccessibilityCustomActions([])
        }
        if let lastSpokenValue, lastSpokenValue != value {
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        lastSpokenValue = value
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard mode == .adjusting, let handle = RegionAdjustment.handle(at: mouseInCG, in: region) else { return }
        drag = (handle, mouseInCG, region)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = mouseInCG
        let delta = CGSize(width: point.x - drag.startPoint.x, height: point.y - drag.startPoint.y)
        let adjusted = RegionAdjustment.adjusted(drag.startRegion, handle: drag.handle, by: delta, bounds: displayFrame)
        if adjusted != region { onRegionChange?(adjusted) }
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        updateCursor()
    }

    override func mouseMoved(with event: NSEvent) { updateCursor() }
    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    private func updateCursor() {
        guard mode == .adjusting else { return }
        let handle = drag?.handle ?? RegionAdjustment.handle(at: mouseInCG, in: region)
        switch handle {
        case .left, .right: NSCursor.resizeLeftRight.set()
        case .top, .bottom: NSCursor.resizeUpDown.set()
        case .topLeft, .topRight, .bottomLeft, .bottomRight: NSCursor.crosshair.set()
        case .move: (drag == nil ? NSCursor.openHand : NSCursor.closedHand).set()
        case nil: NSCursor.arrow.set()
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        let rect = regionRect
        guard rect.width > 0, rect.height > 0 else { return }
        if mode == .recording {
            // The ring fills the panel's margin only, so none of it falls inside the recorded region.
            context.setFillColor(Palette.recording.cgColor)
            context.addRect(bounds)
            context.addRect(rect)
            context.fillPath(using: .evenOdd)
            return
        }
        let stroke = Palette.stroke.cgColor
        let contrast = Palette.contrast(increased: increaseContrast).cgColor
        context.setFillColor(Palette.interior.cgColor)
        context.fill(rect)
        context.setLineWidth(1)
        context.setStrokeColor(contrast)
        context.stroke(rect.insetBy(dx: -0.5, dy: -0.5))
        context.setLineWidth(increaseContrast ? 2 : 1)
        context.setStrokeColor(stroke)
        context.stroke(rect.insetBy(dx: increaseContrast ? 1 : 0.5, dy: increaseContrast ? 1 : 0.5))
        guard mode == .adjusting else { return }
        let size = Self.handleSize
        context.setLineWidth(1)
        for (row, y) in [rect.minY, rect.midY, rect.maxY].enumerated() {
            for (column, x) in [rect.minX, rect.midX, rect.maxX].enumerated() where !(row == 1 && column == 1) {
                let handle = CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
                context.setFillColor(stroke)
                context.fill(handle)
                context.setStrokeColor(contrast)
                context.stroke(handle.insetBy(dx: 0.5, dy: 0.5))
            }
        }
    }
}

// MARK: - Control bar and recording pill

/// One panel with three faces: the ready bar (Record, countdown choice, Cancel), the countdown bar and the
/// recording pill (red dot, elapsed time, Stop).
final class RecordingBarPanel: NSPanel, NSWindowDelegate {
    enum Content {
        case ready(sizeText: String)
        case countdown(remaining: Int)
        case recording(elapsed: String, spoken: String)
    }

    var onRecord: ((RecordingCountdownChoice) -> Void)? {
        get { barView.onRecord }
        set { barView.onRecord = newValue }
    }
    var onStop: (() -> Void)? {
        get { barView.onStop }
        set { barView.onStop = newValue }
    }
    var onCancel: (() -> Void)? {
        get { barView.onCancel }
        set { barView.onCancel = newValue }
    }
    /// An arrow key pressed on the ready bar: moves the region, or resizes it with Option; Shift steps by 10.
    var onNudge: ((RegionNudge, CGFloat) -> Void)?

    let barView: RecordingBarView
    private var isReadyContent = false
    private var isRecordingContent = false
    private var userMoved = false
    private var isRepositioning = false

    init(chrome: RecordingChromeEnvironment = .live) {
        barView = RecordingBarView(chrome: chrome)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: RecordingChromeTokens.barHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        MainActor.assumeIsolated { configureOverlayPanel(self, levelOffset: 1) }
        hasShadow = true
        isMovableByWindowBackground = true
        delegate = self
        contentView = barView
        setAccessibilityLabel("Screen recording controls")
    }

    // Takes keyboard focus for Esc and Return without activating the app that is being recorded.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if !isRecordingContent { onCancel?() }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard isReadyContent, flags.isDisjoint(with: [.command, .control]),
              let nudge = RegionNudge(arrowKeyCode: event.keyCode, resize: flags.contains(.option)) else {
            super.keyDown(with: event)
            return
        }
        onNudge?(nudge, flags.contains(.shift) ? 10 : 1)
    }

    func windowDidMove(_ notification: Notification) {
        if !isRepositioning { userMoved = true }
    }

    func apply(_ content: Content) {
        isReadyContent = false
        isRecordingContent = false
        switch content {
        case .ready(let sizeText):
            isReadyContent = true
            barView.showReady(sizeText: sizeText)
        case .countdown(let remaining):
            barView.showCountdown(remaining: remaining)
        case .recording(let elapsed, let spoken):
            isRecordingContent = true
            barView.showRecording(elapsed: elapsed, spoken: spoken)
        }
        setContentSize(barView.preferredSize)
    }

    func updateElapsed(_ text: String, spoken: String? = nil) {
        barView.updateElapsed(text, spoken: spoken)
    }

    func refreshChrome() {
        barView.refreshChrome()
    }

    /// Puts the bar next to the region (see `RecordingLayout.barFrame`), unless the user dragged it elsewhere;
    /// then it only stays centred on where they left it.
    func place(near region: CGRect, usable: CGRect, primaryHeight: CGFloat) {
        let size = frame.size
        let target: CGRect
        if userMoved {
            let current = CaptureGeometry.appKitToCG(frame, primaryHeight: primaryHeight)
            let centred = CGRect(x: current.midX - size.width / 2, y: current.midY - size.height / 2,
                                 width: size.width, height: size.height)
            target = RecordingLayout.keepingOnScreen(centred, in: usable)
        } else {
            target = RecordingLayout.barFrame(size: size, region: region, usable: usable)
        }
        isRepositioning = true
        setFrame(CaptureGeometry.cgToAppKit(target, primaryHeight: primaryHeight), display: true)
        isRepositioning = false
    }
}

/// The controls on the glass capsule. Return starts a recording, Escape cancels, Command-period stops one;
/// every control has an accessibility label and a tooltip.
final class RecordingBarView: NSView {
    var onRecord: ((RecordingCountdownChoice) -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    let recordButton: NSButton
    let cancelButton: NSButton
    let countdownCancelButton: NSButton
    let stopButton: NSButton
    let countdownControl = NSSegmentedControl(labels: RecordingCountdownChoice.allCases.map(\.title),
                                              trackingMode: .selectOne, target: nil, action: nil)
    let elapsedLabel = RecordingBarView.label(weight: .semibold)
    let dot: RecordingDotView

    private let chrome: RecordingChromeEnvironment
    private let glass: RecordingGlassView
    private let sizeLabel = RecordingBarView.label(weight: .medium)
    private let timerCaption = RecordingBarView.label(text: "Timer", weight: .regular, color: .secondaryLabelColor)
    private let countdownLabel = RecordingBarView.label(weight: .semibold)
    private let readyGroup = NSStackView()
    private let countdownGroup = NSStackView()
    private let recordingGroup = NSStackView()
    private let root = NSStackView()

    init(chrome: RecordingChromeEnvironment) {
        self.chrome = chrome
        let glassBezel = chrome.supportsLiquidGlass
        glass = RecordingGlassView(cornerRadius: RecordingChromeTokens.barCornerRadius, style: chrome.style)
        dot = RecordingDotView(reduceMotion: chrome.displayOptions().reduceMotion)
        recordButton = Self.button("Record", symbol: "record.circle.fill", prominent: true, glass: glassBezel)
        cancelButton = Self.button("Cancel", glass: glassBezel)
        countdownCancelButton = Self.button("Cancel", glass: glassBezel)
        stopButton = Self.button("Stop", symbol: "stop.fill", glass: glassBezel)
        super.init(frame: .zero)

        recordButton.keyEquivalent = "\r"
        recordButton.toolTip = "Start recording (Return)"
        recordButton.setAccessibilityLabel("Record")
        recordButton.setAccessibilityHelp("Starts recording the selected area")
        recordButton.target = self
        recordButton.action = #selector(recordTapped)

        for cancel in [cancelButton, countdownCancelButton] {
            cancel.keyEquivalent = "\u{1b}"
            cancel.toolTip = "Cancel (Esc)"
            cancel.setAccessibilityLabel("Cancel")
            cancel.setAccessibilityHelp("Closes the controls without recording")
            cancel.target = self
            cancel.action = #selector(cancelTapped)
        }
        countdownCancelButton.setAccessibilityHelp("Cancels the countdown without recording")

        stopButton.keyEquivalent = "."
        stopButton.keyEquivalentModifierMask = .command
        stopButton.toolTip = "Stop recording (⌘.)"
        stopButton.setAccessibilityLabel("Stop recording")
        stopButton.setAccessibilityHelp("Ends the recording")
        stopButton.target = self
        stopButton.action = #selector(stopTapped)

        countdownControl.selectedSegment = 0
        countdownControl.segmentStyle = .automatic
        countdownControl.controlSize = .regular
        countdownControl.setAccessibilityLabel("Countdown before recording")
        countdownControl.setAccessibilityHelp("Choose how long to wait before recording starts")
        for (index, choice) in RecordingCountdownChoice.allCases.enumerated() {
            countdownControl.setToolTip(choice.spokenTitle, forSegment: index)
        }
        timerCaption.setAccessibilityElement(false)
        sizeLabel.setAccessibilityLabel("Recording area size")
        sizeLabel.toolTip = "Size of the recording area in points"
        elapsedLabel.setAccessibilityLabel("Elapsed time")
        countdownLabel.setAccessibilityLabel("Countdown")

        Self.configure(readyGroup, [sizeLabel, timerCaption, countdownControl, cancelButton, recordButton])
        Self.configure(countdownGroup, [countdownLabel, countdownCancelButton])
        Self.configure(recordingGroup, [dot, elapsedLabel, stopButton])
        root.setViews([readyGroup, countdownGroup, recordingGroup], in: .center)
        root.orientation = .horizontal
        root.alignment = .centerY
        root.edgeInsets = RecordingChromeTokens.barInsets
        root.heightAnchor.constraint(equalToConstant: RecordingChromeTokens.barHeight).isActive = true
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
        setAccessibilityLabel("Screen recording controls")
    }

    convenience init() { self.init(chrome: .live) }

    required init?(coder: NSCoder) { fatalError() }

    var preferredSize: NSSize { root.fittingSize }

    /// The surface behind the controls, for tests and for the panel's own refresh.
    var chromeStyle: RecordingChromeStyle { glass.style }
    var surfaceView: NSView { glass.surfaceView }

    func showReady(sizeText: String) {
        sizeLabel.stringValue = sizeText
        sizeLabel.spokenValue = Self.spokenSize(sizeText)
        show(readyGroup)
    }

    func showCountdown(remaining: Int) {
        countdownLabel.stringValue = "Starts in \(remaining)…"
        countdownLabel.spokenValue = "Recording starts in \(remaining)"
        show(countdownGroup)
    }

    func showRecording(elapsed: String, spoken: String? = nil) {
        elapsedLabel.stringValue = elapsed
        elapsedLabel.spokenValue = spoken ?? elapsed
        show(recordingGroup)
    }

    func updateElapsed(_ text: String, spoken: String? = nil) {
        guard elapsedLabel.stringValue != text else { return }
        elapsedLabel.stringValue = text
        elapsedLabel.spokenValue = spoken ?? text
    }

    /// Re-reads the accessibility display settings: the surface, and whether the red dot pulses.
    func refreshChrome() {
        glass.apply(chrome.style)
        dot.apply(reduceMotion: chrome.displayOptions().reduceMotion)
    }

    private func show(_ group: NSStackView) {
        for candidate in [readyGroup, countdownGroup, recordingGroup] { candidate.isHidden = candidate !== group }
    }

    @objc private func recordTapped() {
        let index = max(countdownControl.selectedSegment, 0)
        onRecord?(RecordingCountdownChoice.allCases[index])
    }

    @objc private func stopTapped() { onStop?() }
    @objc private func cancelTapped() { onCancel?() }

    private static func configure(_ stack: NSStackView, _ views: [NSView]) {
        stack.setViews(views, in: .center)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = RecordingChromeTokens.spacing
    }

    /// "640 × 360" read as "640 by 360 points".
    private static func spokenSize(_ text: String) -> String {
        text.replacingOccurrences(of: " × ", with: " by ") + " points"
    }

    private static func label(text: String = "", weight: NSFont.Weight,
                              color: NSColor = .labelColor) -> RecordingReadoutLabel {
        let field = RecordingReadoutLabel(text: text)
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: weight)
        field.textColor = color
        return field
    }

    private static func button(_ title: String, symbol: String? = nil, prominent: Bool = false,
                               glass: Bool) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        if let symbol {
            // The title already names the button, so the symbol is decoration.
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        }
        RecordingButtonStyle.configure(button, supportsLiquidGlass: glass, prominent: prominent)
        return button
    }
}

/// A read-only label that VoiceOver reads as `spokenValue` ("1 minute, 5 seconds") instead of its on-screen
/// text ("01:05"). The accessibility value of a text field can't be overridden from outside.
final class RecordingReadoutLabel: NSTextField {
    var spokenValue: String?

    init(text: String) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byClipping
    }

    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityValue() -> String? { spokenValue ?? stringValue }
}

/// The red recording dot. It pulses, except under Reduce Motion.
final class RecordingDotView: NSView {
    static let diameter: CGFloat = 10
    static let pulseKey = "pulse"

    private var reduceMotion: Bool

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        wantsLayer = true
        layer?.cornerRadius = Self.diameter / 2
        setAccessibilityElement(false)
        updateColor()
        updatePulse()
    }

    convenience init() { self.init(reduceMotion: false) }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.diameter, height: Self.diameter) }

    var isPulsing: Bool { layer?.animation(forKey: Self.pulseKey) != nil }

    func apply(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        updatePulse()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePulse()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.systemRed.cgColor
        }
    }

    private func updatePulse() {
        guard !reduceMotion else {
            layer?.removeAnimation(forKey: Self.pulseKey)
            return
        }
        guard !isPulsing else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        layer?.add(pulse, forKey: Self.pulseKey)
    }
}

// MARK: - Countdown

/// The big number shown over the region while a countdown runs. It never takes clicks.
final class RecordingCountdownPanel: NSPanel {
    static let diameter: CGFloat = 160

    private let chrome: RecordingChromeEnvironment
    private let glass: RecordingGlassView
    private let numberLabel = NSTextField(labelWithString: "")

    init(chrome: RecordingChromeEnvironment = .live) {
        self.chrome = chrome
        glass = RecordingGlassView(cornerRadius: Self.diameter / 2, style: chrome.style)
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        MainActor.assumeIsolated { configureOverlayPanel(self, levelOffset: 2) }
        hasShadow = true
        ignoresMouseEvents = true

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 88, weight: .semibold)
        numberLabel.textColor = .labelColor
        numberLabel.alignment = .center
        numberLabel.setAccessibilityElement(false)
        let content = NSView()
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(numberLabel)
        NSLayoutConstraint.activate([
            numberLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        glass.contentView = content
        contentView = glass
        setAccessibilityLabel("Countdown")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var chromeStyle: RecordingChromeStyle { glass.style }

    func refreshChrome() {
        glass.apply(chrome.style)
    }

    /// `region` is in global CG coordinates.
    func show(_ number: Int, over region: CGRect, primaryHeight: CGFloat) {
        numberLabel.stringValue = "\(number)"
        setAccessibilityLabel("Countdown: \(number)")
        let centred = CGRect(x: region.midX - Self.diameter / 2, y: region.midY - Self.diameter / 2,
                             width: Self.diameter, height: Self.diameter)
        setFrame(CaptureGeometry.cgToAppKit(centred, primaryHeight: primaryHeight), display: true)
        orderFrontRegardless()
    }
}
