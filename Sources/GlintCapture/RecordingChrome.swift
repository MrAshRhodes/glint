import AppKit

// The look of the recording overlay. It follows the rest of Glint's chrome (Sources/GlintEditor/GlassStyle.swift):
// Liquid Glass on macOS 26 and a material elsewhere, with a capsule bar for floating controls. GlintCapture cannot
// depend on GlintEditor, so the few numbers it needs are mirrored here. Keep in sync with GlassStyle.swift.

enum RecordingChromeTokens {
    /// `GlintDesign.barHeight`: height of floating toolbars and action bars.
    static let barHeight: CGFloat = 44
    /// `EditorChromeMetrics.iconButtonSize`: the smallest hit target of an icon-only control.
    static let minimumHitTarget: CGFloat = 28
    /// Space between controls, on the 8 pt grid.
    static let spacing: CGFloat = 8
    /// The bar's corner radius makes it a capsule.
    static let barCornerRadius: CGFloat = barHeight / 2
    /// Padding inside the capsule. The trailing and vertical padding match the control height, so the corners of
    /// the controls stay concentric with the bar's.
    static let barInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 8)
    /// Corner radius of a floating panel that is taller than one bar, such as the scrolling-capture controls.
    static let panelCornerRadius: CGFloat = 18
}

// MARK: - Display options

/// The accessibility display settings the overlay reacts to.
struct RecordingDisplayOptions: Equatable {
    var reduceMotion = false
    var reduceTransparency = false
    var increaseContrast = false

    @MainActor
    static var live: RecordingDisplayOptions {
        let workspace = NSWorkspace.shared
        return RecordingDisplayOptions(reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                                       reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                                       increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
    }
}

/// The system services the overlay talks to. Tests replace them to pick the settings and read the announcements.
struct RecordingChromeEnvironment {
    var displayOptions: @MainActor () -> RecordingDisplayOptions
    /// Speaks `text` through VoiceOver.
    var announce: @MainActor (String) -> Void
    var supportsLiquidGlass: Bool

    /// Mirrors `GlintDesign.supportsLiquidGlass`.
    static var systemSupportsLiquidGlass: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    static var live: RecordingChromeEnvironment {
        RecordingChromeEnvironment(
            displayOptions: { RecordingDisplayOptions.live },
            announce: { text in
                let element: Any = NSApp.keyWindow ?? NSApplication.shared
                NSAccessibility.post(element: element, notification: .announcementRequested,
                                     userInfo: [.announcement: text,
                                                .priority: NSAccessibilityPriorityLevel.high.rawValue])
            },
            supportsLiquidGlass: systemSupportsLiquidGlass)
    }

    @MainActor
    var style: RecordingChromeStyle {
        RecordingChromeStyle.resolve(supportsLiquidGlass: supportsLiquidGlass, options: displayOptions())
    }
}

// MARK: - Surface style

/// Which surface sits behind the overlay's controls and how its edge is drawn.
struct RecordingChromeStyle: Equatable {
    enum Surface: Equatable {
        /// `NSGlassEffectView`, macOS 26.
        case liquidGlass
        /// `NSVisualEffectView`, the fallback before macOS 26.
        case material
        /// A solid window background, for Reduce Transparency.
        case opaque
    }

    let surface: Surface
    /// Width of the edge line in points; 0 draws none.
    let borderWidth: CGFloat
    /// Increase Contrast: a full-strength edge instead of the hairline.
    let strongBorder: Bool

    static func resolve(supportsLiquidGlass: Bool, options: RecordingDisplayOptions) -> RecordingChromeStyle {
        let surface: Surface
        if options.reduceTransparency {
            surface = .opaque
        } else {
            surface = supportsLiquidGlass ? .liquidGlass : .material
        }
        if options.increaseContrast { return RecordingChromeStyle(surface: surface, borderWidth: 1, strongBorder: true) }
        let width: CGFloat = surface == .liquidGlass ? 0 : 0.5
        return RecordingChromeStyle(surface: surface, borderWidth: width, strongBorder: false)
    }

    /// The HUD material is dark whatever the system appearance, so its content is drawn in the dark appearance.
    /// Glass and the opaque surface follow the system appearance.
    var forcedAppearance: NSAppearance.Name? { surface == .material ? .vibrantDark : nil }

    var borderColor: NSColor {
        if strongBorder { return NSColor.labelColor.withAlphaComponent(0.55) }
        switch surface {
        case .material: return NSColor.white.withAlphaComponent(0.18)
        case .opaque: return .separatorColor
        case .liquidGlass: return .clear
        }
    }
}

// MARK: - Announcements

/// What VoiceOver says as the recording moves through its phases.
enum RecordingAnnouncement {
    static let ready = "Ready to record. Press Return to start or Escape to cancel."
    static let started = "Recording started"

    /// The first tick says what is happening, the later ones only count.
    static func countdown(_ remaining: Int, isFirst: Bool) -> String {
        isFirst ? "Recording starts in \(remaining)" : "\(remaining)"
    }

    static func finished(wasRecording: Bool) -> String {
        wasRecording ? "Recording stopped" : "Recording cancelled"
    }
}

// MARK: - Glass view

/// Hosts the overlay's content on a floating surface, rebuilt whenever the style changes: Liquid Glass on
/// macOS 26, a material before, a solid background under Reduce Transparency. Put the content in `contentView`.
@MainActor
final class RecordingGlassView: NSView {
    private(set) var style: RecordingChromeStyle
    private(set) var surfaceView: NSView
    private let cornerRadius: CGFloat
    private let host = NSView()
    private let border = RecordingEdgeView()

    var contentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let contentView else { return }
            contentView.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: host.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
        }
    }

    init(cornerRadius: CGFloat, style: RecordingChromeStyle) {
        self.cornerRadius = cornerRadius
        self.style = style
        surfaceView = Self.makeSurface(style.surface, cornerRadius: cornerRadius, host: host)
        super.init(frame: .zero)
        border.wantsLayer = true
        border.layer?.cornerCurve = .continuous
        Self.fill(self, with: border)
        install(surfaceView)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ newStyle: RecordingChromeStyle) {
        guard newStyle != style else { return }
        let surfaceChanged = newStyle.surface != style.surface
        style = newStyle
        if surfaceChanged {
            host.removeFromSuperview()
            surfaceView.removeFromSuperview()
            surfaceView = Self.makeSurface(newStyle.surface, cornerRadius: cornerRadius, host: host)
            install(surfaceView)
        }
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    /// Puts `surface` behind the edge line.
    private func install(_ surface: NSView) {
        addSubview(surface, positioned: .below, relativeTo: border)
        Self.fill(self, with: surface)
    }

    private static func fill(_ container: NSView, with view: NSView) {
        if view.superview == nil { container.addSubview(view) }
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func refresh() {
        appearance = style.forcedAppearance.flatMap { NSAppearance(named: $0) }
        border.layer?.cornerRadius = cornerRadius
        border.layer?.borderWidth = style.borderWidth
        effectiveAppearance.performAsCurrentDrawingAppearance {
            border.layer?.borderColor = style.borderColor.cgColor
            if style.surface == .opaque { surfaceView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        }
    }

    private static func makeSurface(_ surface: RecordingChromeStyle.Surface, cornerRadius: CGFloat,
                                    host: NSView) -> NSView {
        switch surface {
        case .liquidGlass:
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                host.translatesAutoresizingMaskIntoConstraints = true
                let glass = NSGlassEffectView()
                glass.cornerRadius = cornerRadius
                glass.contentView = host
                return glass
            }
            #endif
            return makeSurface(.material, cornerRadius: cornerRadius, host: host)
        case .material:
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            return rounded(effect, cornerRadius: cornerRadius, host: host)
        case .opaque:
            return rounded(NSView(), cornerRadius: cornerRadius, host: host)
        }
    }

    private static func rounded(_ view: NSView, cornerRadius: CGFloat, host: NSView) -> NSView {
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return view
    }
}

/// The edge line over the surface. It draws only and never takes clicks.
private final class RecordingEdgeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Buttons

enum RecordingButtonStyle {
    /// The glass bezel on macOS 26, the standard rounded push button before.
    static func bezelStyle(supportsLiquidGlass: Bool) -> NSButton.BezelStyle {
        #if compiler(>=6.2)
        if supportsLiquidGlass, #available(macOS 26.0, *) { return .glass }
        #endif
        return .rounded
    }

    /// Standard sizing and the overlay's bezel. `prominent` marks the one primary action (red, like Record in the
    /// Screenshot toolbar); an icon-only button is never smaller than the minimum hit target.
    @MainActor
    static func configure(_ button: NSButton, supportsLiquidGlass: Bool, prominent: Bool = false) {
        button.bezelStyle = bezelStyle(supportsLiquidGlass: supportsLiquidGlass)
        button.controlSize = .regular
        button.setButtonType(.momentaryPushIn)
        if prominent {
            button.bezelColor = .systemRed
            button.contentTintColor = .white
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: RecordingChromeTokens.minimumHitTarget).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: RecordingChromeTokens.minimumHitTarget).isActive = true
    }
}
