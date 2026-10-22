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
}

extension RGBAColor {
    var swiftUI: Color { Color(nsColor: nsColor) }
    init(_ c: Color) { self.init(NSColor(c)) }
}

func colorBinding(_ get: @escaping () -> RGBAColor, _ set: @escaping (RGBAColor) -> Void) -> Binding<Color> {
    Binding(get: { get().swiftUI }, set: { set(RGBAColor($0)) })
}

// MARK: - Top tool strip

struct ToolStripView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(EditorTool.allCases, id: \.self) { tool in
                Button {
                    model.pressToolKey(tool)
                } label: {
                    Image(systemName: tool.symbol)
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.bordered)
                .tint(model.tool == tool ? .accentColor : nil)
                .controlSize(.regular)
                .help("\(tool.title) (\(tool.keyHint))")
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
            }
            Divider().frame(height: 18)
            Button { model.undoManager.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help("Undo (⌘Z)").accessibilityLabel("Undo")
            Button { model.undoManager.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help("Redo (⇧⌘Z)").accessibilityLabel("Redo")
            Divider().frame(height: 18)
            ColorPicker("Annotation colour", selection: colorBinding({ model.selectedAnnotations.first?.style.color ?? model.defaultStyle.color }) { c in
                model.updateStyle(key: "color") { $0.color = c }
            }, supportsOpacity: false)
                .labelsHidden()
                .help("Annotation colour")
            if let v = model.variantDescription() {
                Text(v).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }
            Spacer(minLength: 8)
            Text(model.tool.tip).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.bar)
    }
}

// MARK: - Bottom bar

struct BottomBarView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var actions: EditorActions

    private var status: String { model.statusMessage ?? "Drag the thumbnail to export" }

    var body: some View {
        HStack(spacing: 10) {
            DragThumbnail(model: model, actions: actions)
                .frame(width: 64, height: 36)
                .help("Drag the image into another app or Finder")
            VStack(alignment: .leading, spacing: 2) {
                Text(status)
                    .help(status)
                if actions.retryExport != nil {
                    Text("Edits kept while this window is open.")
                        .help("Your image and edits are kept while this window is open. Retry uses your current edits.")
                }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if actions.retryExport != nil {
                Button("Retry") { actions.retryExport?() }
                    .buttonStyle(.bordered)
                    .help("Retry the export using your current edits")
            }
            Spacer()
            if model.rawURL != nil {
                Button("Open Raw") { actions.openRaw() }
                    .help("Open the original, unstyled capture")
            }
            Button { actions.share() } label: { Label("Share", systemImage: "square.and.arrow.up") }
            Button("Save As…") { actions.saveAs() }
            Button("Save") { actions.save() }.help("Save (⌘S)")
            Button("Copy") { actions.copy() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .help("Copy image (⌘C)")
            Button { actions.close() } label: { Image(systemName: "xmark") }
                .help("Close (⌘W)").accessibilityLabel("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(.bar)
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
    var previewImage: CGImage?
    var fileProvider: () -> URL? = { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        guard let img = previewImage else { return }
        let ns = NSImage(cgImage: img, size: CGSize(width: img.width, height: img.height))
        let aspect = CGFloat(img.width) / CGFloat(max(img.height, 1))
        var target = r
        if aspect > r.width / r.height { target.size.height = r.width / aspect } else { target.size.width = r.height * aspect }
        target.origin = CGPoint(x: r.midX - target.width / 2, y: r.midY - target.height / 2)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: target, xRadius: 3, yRadius: 3).addClip()
        ns.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
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
    override func accessibilityLabel() -> String? { "Rendered image. Drag to export." }
}
