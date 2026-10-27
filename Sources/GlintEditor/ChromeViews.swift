import AppKit
import GlintCore
import SwiftUI

/// Actions the SwiftUI chrome triggers on the window controller.
final class EditorActions: ObservableObject {
    @Published var retryExport: (() -> Void)?
    var copy: () -> Void = {}
    var save: () -> Void = {}
    var saveAs: () -> Void = {}
    var share: () -> Void = {}
    var openRaw: () -> Void = {}
    var close: () -> Void = {}
    var savePreset: () -> Void = {}
    var dragFileURL: () -> URL? = { nil }
    /// The Share button's frame in the bottom bar, so the sharing picker points at it.
    weak var shareAnchor: NSView?
}

extension RGBAColor {
    var swiftUI: Color { Color(nsColor: nsColor) }
    init(_ c: Color) { self.init(NSColor(c)) }
}

func colorBinding(_ get: @escaping () -> RGBAColor, _ set: @escaping (RGBAColor) -> Void) -> Binding<Color> {
    Binding(get: { get().swiftUI }, set: { set(RGBAColor($0)) })
}

// MARK: - Top tool strip

struct RedactionModePicker: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Picker("Redaction style", selection: Binding(get: { model.currentRedactStyle }, set: { model.setRedactStyle($0) })) {
            ForEach(RedactionStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("Redaction style")
        .accessibilityValue(model.currentRedactStyle.displayName)
        .help("Choose Solid, Blur, or Pixelate. Also changes selected redaction regions. Blur is unsafe for secrets.")
    }
}

/// Geometry shared by the floating editor chrome and the window layout.
enum EditorChromeMetrics {
    /// Height of the titlebar row (unified titlebar); the top capsules are centred on the traffic lights in it.
    static let toolbarRowHeight: CGFloat = 52
    /// Height of the floating top capsules.
    static let toolbarHeight: CGFloat = 36
    /// Leading edge of the first top capsule, clear of the traffic lights.
    static let toolbarLeading: CGFloat = 92
    /// Height of the floating bottom bar.
    static let bottomBarHeight: CGFloat = 48
    /// Corner radius of the bottom bar's grouped surfaces; concentric with the 10pt drag tile at a 6pt inset.
    static let bottomBarCornerRadius: CGFloat = 16
    /// Width of the floating inspector panel.
    static let inspectorWidth: CGFloat = 300
    /// Transparent margin around floating SwiftUI chrome so glass shadows aren't clipped by the hosting view.
    static let shadowPadding: CGFloat = 8
    /// Hit target of icon buttons in the top capsules.
    static let iconButtonSize: CGFloat = 28
}

/// Bezel-less icon button for glass toolbars: dims while pressed or disabled.
struct GlintToolbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolbarIconButton(configuration: configuration)
    }

    private struct ToolbarIconButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .frame(width: EditorChromeMetrics.iconButtonSize, height: EditorChromeMetrics.iconButtonSize)
                .background {
                    if configuration.isPressed { Capsule(style: .continuous).fill(Color.primary.opacity(0.1)) }
                }
                .contentShape(Capsule(style: .continuous))
                .opacity(isEnabled ? 1 : 0.35)
        }
    }
}

struct ToolStripView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 14) {
            GlintGlassContainer(spacing: 10) {
                HStack(spacing: 10) {
                    toolGroup
                    historyGroup
                    styleGroup
                }
            }
            Text(model.tool.tip)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
                .help(model.tool.tip)
        }
        .padding(EditorChromeMetrics.shadowPadding)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.tool)
    }

    /// Annotation tools; the selected tool gets an accent-tinted capsule rather than a filled bezel.
    private var toolGroup: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases, id: \.self) { tool in
                let selected = model.tool == tool
                Button {
                    model.pressToolKey(tool)
                } label: {
                    Image(systemName: tool.symbol)
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .frame(width: EditorChromeMetrics.iconButtonSize, height: EditorChromeMetrics.iconButtonSize)
                        .background {
                            if selected {
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor.opacity(0.2))
                                    .matchedGeometryEffect(id: "selected-tool", in: selection)
                            }
                        }
                }
                .buttonStyle(GlintToolbarIconButtonStyle())
                .help("\(tool.title) (\(tool.keyHint))")
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(height: EditorChromeMetrics.toolbarHeight)
        .glintGlass()
    }

    private var historyGroup: some View {
        HStack(spacing: 2) {
            Button { model.undoManager.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help("Undo (⌘Z)").accessibilityLabel("Undo")
            Button { model.undoManager.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help("Redo (⇧⌘Z)").accessibilityLabel("Redo")
        }
        .buttonStyle(GlintToolbarIconButtonStyle())
        .padding(4)
        .frame(height: EditorChromeMetrics.toolbarHeight)
        .glintGlass()
    }

    /// Colour, redaction style or tool variant for the current tool or selection.
    @ViewBuilder
    private var styleGroup: some View {
        let modes = model.activeRedactionModes
        let showsRedactionColor = modes.contains(.solid) || modes.contains(.pixelate)
        let showsRedactionPicker = model.tool == .redact || !modes.isEmpty
        let variant = showsRedactionPicker ? nil : model.variantDescription()
        if showsRedactionColor || modes.isEmpty || showsRedactionPicker || variant != nil {
            HStack(spacing: 10) {
                if showsRedactionColor {
                    ColorPicker("Redaction colour", selection: colorBinding({
                        let mode: RedactionStyle = modes.contains(.solid) ? .solid : .pixelate
                        return model.redactionAppearance(for: mode).color
                    }) { model.setRedactColor($0) }, supportsOpacity: false)
                        .labelsHidden()
                        .help("Redaction colour, used by Solid and highlighted Pixelate")
                } else if modes.isEmpty {
                    ColorPicker("Annotation colour", selection: colorBinding({ model.selectedAnnotations.first?.style.color ?? model.defaultStyle.color }) { c in
                        model.updateStyle(key: "color") { $0.color = c }
                    }, supportsOpacity: false)
                        .labelsHidden()
                        .help("Annotation colour")
                }
                if showsRedactionPicker {
                    RedactionModePicker(model: model)
                        .labelsHidden()
                        .fixedSize()
                } else if let variant {
                    Text(variant)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: EditorChromeMetrics.toolbarHeight)
            .glintGlass()
        }
    }
}

// MARK: - Bottom bar

struct BottomBarView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var actions: EditorActions

    private var status: String { model.statusMessage ?? "Ready to export" }

    var body: some View {
        GlintGlassContainer(spacing: 10) {
            HStack(spacing: 10) {
                exportStatus
                Spacer(minLength: 0)
                    .layoutPriority(-2)
                exportActions
            }
        }
        .padding(EditorChromeMetrics.shadowPadding)
    }

    /// Drag-out tile and export status, grouped on the leading side.
    private var exportStatus: some View {
        HStack(spacing: 10) {
            // The status truncates first; the tile drops its caption only when even that doesn't fit.
            ViewThatFits(in: .horizontal) {
                DragShareTile(model: model, actions: actions)
                DragShareTile(model: model, actions: actions, compact: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(status)
                    .foregroundStyle(.secondary)
                    .help(status)
                if actions.retryExport != nil {
                    Text("Edits kept while this window is open.")
                        .foregroundStyle(.tertiary)
                        .help("Your image and edits are kept while this window is open. Retry uses your current edits.")
                }
            }
            .font(.caption)
            .lineLimit(1)
            .padding(.trailing, 8)
            .layoutPriority(-1)
        }
        .padding(6)
        .frame(height: EditorChromeMetrics.bottomBarHeight)
        .glintGlass(in: RoundedRectangle(cornerRadius: EditorChromeMetrics.bottomBarCornerRadius, style: .continuous))
    }

    /// Export actions on the trailing side; only Copy, the primary action, is tinted.
    private var exportActions: some View {
        HStack(spacing: 8) {
            if actions.retryExport != nil {
                Button("Retry") { actions.retryExport?() }
                    .glintGlassButtonStyle()
                    .help("Retry the export using your current edits")
            }
            if model.rawURL != nil {
                Button("Open Raw") { actions.openRaw() }
                    .glintGlassButtonStyle()
                    .help("Open the original, unstyled capture")
            }
            Button { actions.share() } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
            }
                .glintGlassButtonStyle()
                .background(ShareAnchor(actions: actions))
                .help("Share")
                .accessibilityLabel("Share")
            Button("Save As…") { actions.saveAs() }
                .glintGlassButtonStyle()
                .help("Save As (⇧⌘S)")
            Button("Save") { actions.save() }
                .glintGlassButtonStyle()
                .help("Save (⌘S)")
            Button { actions.copy() } label: {
                HStack(spacing: 5) {
                    Text("Copy")
                    Text("⌘C")
                        .font(.caption)
                        .opacity(0.8)
                }
            }
                .keyboardShortcut(.defaultAction)
                .glintGlassButtonStyle(prominent: true)
                .help("Copy image (⌘C)")
                .accessibilityLabel("Copy image")
                .accessibilityHint("Keyboard shortcut Command-C")
            Button { actions.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
                .buttonStyle(.borderless)
                .glintGlass(in: Circle())
                .help("Close (⌘W)")
                .accessibilityLabel("Close")
        }
        .controlSize(.large)
        .fixedSize()
    }
}

/// Invisible marker behind the Share button that the sharing picker anchors to.
private struct ShareAnchor: NSViewRepresentable {
    let actions: EditorActions

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        actions.shareAnchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { actions.shareAnchor = view }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct DragShareTile: View {
    let model: EditorModel
    let actions: EditorActions
    /// Thumbnail only, for narrow windows.
    var compact = false

    private var height: CGFloat { EditorChromeMetrics.bottomBarHeight - 12 }

    var body: some View {
        if compact {
            DragThumbnail(model: model, actions: actions)
                .frame(width: DragSourceView.thumbnailWidth + 2 * DragSourceView.thumbnailInset, height: height)
                .help("Drag the image into another app or Finder")
        } else {
            fullTile
        }
    }

    private var fullTile: some View {
        ZStack {
            DragThumbnail(model: model, actions: actions)
            HStack(spacing: 8) {
                Color.clear.frame(width: DragSourceView.thumbnailWidth + DragSourceView.thumbnailInset)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Drag to share")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("To an app or Finder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "hand.draw")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.trailing, 10)
            .allowsHitTesting(false)
        }
        .frame(width: 184, height: height)
        .help("Drag the image into another app or Finder")
    }
}

struct DragThumbnail: NSViewRepresentable {
    let model: EditorModel
    let actions: EditorActions

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.previewImage = model.preview?.image
        view.fileProvider = actions.dragFileURL
        view.needsDisplay = true
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    static let cornerRadius: CGFloat = 10
    static let thumbnailInset: CGFloat = 4
    static let thumbnailWidth: CGFloat = 44
    /// Concentric with the tile's corners at `thumbnailInset`.
    static let thumbnailCornerRadius: CGFloat = 6

    var previewImage: CGImage?
    var fileProvider: () -> URL? = { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        updateLayerColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
        needsDisplay = true
    }

    /// Dynamic system colours must be resolved for the current appearance before going into the layer.
    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = Self.thumbnailInset
        let r = NSRect(x: inset, y: inset, width: Self.thumbnailWidth, height: max(bounds.height - 2 * inset, 1))
        let clip = NSBezierPath(roundedRect: r, xRadius: Self.thumbnailCornerRadius, yRadius: Self.thumbnailCornerRadius)
        NSColor.quaternaryLabelColor.setFill()
        clip.fill()
        guard let img = previewImage else { return }
        let ns = NSImage(cgImage: img, size: CGSize(width: img.width, height: img.height))
        // Aspect-fill the thumbnail slot, like Photos and Finder thumbnails.
        let aspect = CGFloat(img.width) / CGFloat(max(img.height, 1))
        var target = r
        if aspect > r.width / r.height { target.size.width = r.height * aspect } else { target.size.height = r.width / aspect }
        target.origin = CGPoint(x: r.midX - target.width / 2, y: r.midY - target.height / 2)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        ns.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        clip.lineWidth = 0.5
        clip.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let url = fileProvider() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let thumb = previewImage.map { NSImage(cgImage: $0, size: CGSize(width: 120, height: 120 * CGFloat($0.height) / CGFloat(max($0.width, 1)))) }
        item.setDraggingFrame(CGRect(x: 0, y: 0, width: 120, height: thumb?.size.height ?? 80), contents: thumb)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { "Drag to share. To an app or Finder." }
}
