import AppKit
import GlintCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorExportServices {
    var copy: (CGImage) -> Bool = { Exporter.copyToClipboard($0) }
    var write: (CGImage, URL, ExportFormat, ExportScale, CGFloat) throws -> URL = {
        try Exporter.write($0, to: $1, format: $2, scale: $3, backingScale: $4)
    }
    /// Shows the sharing picker for `image`, pointing at `anchor` (the Share button, or the window's content view).
    var share: @MainActor (CGImage, NSView) -> Void = { image, anchor in
        let ns = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        let picker = NSSharingServicePicker(items: [ns])
        if anchor === anchor.window?.contentView {
            let rect = CGRect(x: anchor.bounds.maxX - 200, y: 0, width: 80, height: 50)
            picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
        } else {
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .minY : .maxY)
        }
    }
    var beep: () -> Void = { NSSound.beep() }
    var dragDirectory: URL = (
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
    ).appendingPathComponent("Glint/Drag", isDirectory: true)
}

/// Window that routes editor shortcuts unless a text field is being edited.
final class EditorWindow: NSWindow {
    weak var controller: EditorWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if firstResponder is NSText { return super.performKeyEquivalent(with: event) }
        if let c = controller, MainActor.assumeIsolated({ c.handleShortcut(event) }) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Transparent strip over the titlebar row. The canvas extends under the transparent titlebar and handles its own
/// drags, so this keeps the titlebar area that isn't covered by controls moving the window like a normal titlebar.
private final class TitlebarDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount == 2 else {
            window.performDrag(with: event)
            return
        }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

/// How the editor handed out its composed image without saving it.
public enum EditorShareKind: Sendable {
    case copied, dragged
}

@MainActor
public final class EditorWindowController: NSWindowController, NSWindowDelegate {
    public var onClose: (() -> Void)?
    public var onExported: ((URL?) -> Void)?
    /// Called after the composed image was copied to the clipboard or prepared as a drag payload, with the exact
    /// image that was exported and its backing scale. Never called when rendering or exporting fails.
    public var onImageShared: ((CGImage, EditorShareKind, CGFloat) -> Void)?
    /// Preset designer only: called after the preset is saved and persisted, before the window closes.
    public var onPresetSaved: ((Preset) -> Void)?

    let model: EditorModel
    private let exportServices: EditorExportServices
    let actions = EditorActions()
    private let canvas: CanvasView
    private var dragFiles: Set<URL> = []
    private var retryID: UUID?
    private var presetSaved = false

    public convenience init(context: EditorContext, preferences: AppPreferences, presetStore: PresetStore) {
        self.init(context: context, preferences: preferences, presetStore: presetStore, exportServices: EditorExportServices())
    }

    /// Opens the editor purely to design a preset on a preview image; it exports nothing.
    public convenience init(design: PresetDesign, preferences: AppPreferences, presetStore: PresetStore) {
        self.init(design: design, preferences: preferences, presetStore: presetStore, exportServices: EditorExportServices())
    }

    convenience init(design: PresetDesign, preferences: AppPreferences, presetStore: PresetStore, exportServices: EditorExportServices) {
        let context = EditorContext(image: design.image, backingScale: design.backingScale, rawURL: nil, source: nil)
        let model = EditorModel(context: context, preferences: preferences, presetStore: presetStore, design: design)
        self.init(model: model, title: "Glint — \(model.designTitle)", exportServices: exportServices)
    }

    convenience init(context: EditorContext, preferences: AppPreferences, presetStore: PresetStore, exportServices: EditorExportServices) {
        self.init(model: EditorModel(context: context, preferences: preferences, presetStore: presetStore),
                  title: context.windowTitle, exportServices: exportServices)
    }

    private init(model: EditorModel, title: String, exportServices: EditorExportServices) {
        self.model = model
        self.exportServices = exportServices
        self.canvas = CanvasView(model: model)

        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1261, height: 704),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        // The title stays set for Mission Control, the Window menu and accessibility; it just isn't drawn.
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        // An empty unified toolbar gives the titlebar row its standard height, so the traffic lights line up
        // with the floating glass capsules drawn in it.
        let toolbar = NSToolbar(identifier: "GlintEditorToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 1000, height: 600)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("")
        super.init(window: window)
        window.controller = self
        window.delegate = self
        buildUI(in: window)

        actions.copy = { [weak self] in self?.copyAndMaybeClose() }
        actions.save = { [weak self] in self?.saveOutput() }
        actions.saveAs = { [weak self] in self?.saveAs() }
        actions.share = { [weak self] in self?.share() }
        actions.openRaw = { [weak self] in self?.openRaw() }
        actions.close = { [weak self] in self?.window?.close() }
        actions.savePreset = { [weak self] in self?.savePresetAndClose() }
        actions.dragFileURL = { [weak self] in self?.prepareDragFile() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    /// The canvas fills the whole window as the content layer; the toolbar, inspector and bottom bar float
    /// above it as glass, and the canvas centres the image in the area they leave free.
    private func buildUI(in window: NSWindow) {
        let root = NSView()
        window.contentView = root

        let metrics = EditorChromeMetrics.self
        let inset = GlintDesign.floatingInset
        let pad = metrics.shadowPadding
        let designing = model.isDesigningPreset

        let toolbar: NSView = designing
            ? Self.host(PresetDesignHeaderView(model: model), sizing: [.intrinsicContentSize])
            : Self.host(ToolStripView(model: model), sizing: [.intrinsicContentSize])
        toolbar.setContentHuggingPriority(.required, for: .horizontal)
        let bottom: NSView = designing
            ? Self.host(PresetDesignBarView(model: model, actions: actions), sizing: [])
            : Self.host(BottomBarView(model: model, actions: actions), sizing: [])

        let inspectorContent = Self.host(InspectorView(model: model), sizing: [])
        inspectorContent.wantsLayer = true
        inspectorContent.layer?.cornerRadius = GlintDesign.panelCornerRadius
        inspectorContent.layer?.cornerCurve = .continuous
        inspectorContent.layer?.masksToBounds = true
        let inspector = GlintGlassView(cornerRadius: GlintDesign.panelCornerRadius)
        inspector.contentView = inspectorContent

        let titlebarDrag = TitlebarDragView()

        for v in [canvas, titlebarDrag, inspector, bottom, toolbar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            titlebarDrag.topAnchor.constraint(equalTo: root.topAnchor),
            titlebarDrag.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titlebarDrag.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titlebarDrag.heightAnchor.constraint(equalToConstant: metrics.toolbarRowHeight),

            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: (metrics.toolbarRowHeight - metrics.toolbarHeight) / 2 - pad),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: metrics.toolbarLeading - pad),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -(inset - pad)),
            toolbar.heightAnchor.constraint(equalToConstant: metrics.toolbarHeight + 2 * pad),

            inspector.topAnchor.constraint(equalTo: root.topAnchor, constant: metrics.toolbarRowHeight),
            inspector.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            inspector.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
            inspector.widthAnchor.constraint(equalToConstant: metrics.inspectorWidth),

            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset - pad),
            bottom.trailingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: -(inset - pad)),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -(inset - pad)),
            bottom.heightAnchor.constraint(equalToConstant: metrics.bottomBarHeight + 2 * pad),
        ])
        canvas.contentInsets = NSEdgeInsets(top: metrics.toolbarRowHeight,
                                            left: inset,
                                            bottom: metrics.bottomBarHeight + 2 * inset,
                                            right: metrics.inspectorWidth + 2 * inset)
    }

    private static func host<V: View>(_ view: V, sizing: NSHostingSizingOptions) -> NSView {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = sizing
        return host
    }

    // MARK: Public API

    public func showEditor() {
        guard let window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    /// Copies the composed output (annotations burned in) to the clipboard.
    @discardableResult
    public func copyToClipboard() -> Bool {
        copyToClipboard(closeAfterSuccess: false)
    }

    private func copyToClipboard(closeAfterSuccess: Bool) -> Bool {
        canvas.endEditing()
        let retry: (EditorWindowController) -> Void = { _ = $0.copyToClipboard(closeAfterSuccess: closeAfterSuccess) }
        guard let image = renderForExport(failure: "Copy failed", retry: retry) else { return false }
        if exportServices.copy(image) {
            clearRetry()
            model.statusMessage = "Copied to clipboard"
            onExported?(nil)
            onImageShared?(image, .copied, model.backingScale)
            if closeAfterSuccess, model.preferences.closeAfterCopy { window?.close() }
            return true
        } else {
            offerRetry(failure: "Copy failed", retry: retry)
            return false
        }
    }

    /// Writes the composed output to the save directory and reports the URL through `onExported`.
    public func saveOutput() {
        let format = currentFormat()
        let url = model.preferences.outputPaths.saveURL(format: format)
        write(to: url, format: format)
    }

    // MARK: Actions

    /// Renders the final output, or reports the failure and returns nil so nothing unredacted is exported.
    private func renderForExport(failure: String, retry: @escaping (EditorWindowController) -> Void) -> CGImage? {
        guard !model.isDesigningPreset else { return nil }
        do {
            return try model.renderFinal()
        } catch {
            offerRetry(failure: "\(failure): \(error.localizedDescription)", retry: retry)
            return nil
        }
    }

    private func offerRetry(failure: String, retry: @escaping (EditorWindowController) -> Void) {
        model.statusMessage = failure
        let id = UUID()
        retryID = id
        actions.retryExport = { [weak self] in
            guard let self, self.retryID == id else { return }
            self.clearRetry()
            retry(self)
        }
        exportServices.beep()
    }

    private func clearRetry() {
        retryID = nil
        actions.retryExport = nil
    }

    private func currentFormat() -> ExportFormat {
        let p = model.preferences
        return p.compressToJPEG ? .jpeg(quality: p.jpegQuality) : p.exportFormat
    }

    func write(to url: URL, format: ExportFormat) {
        canvas.endEditing()
        let retry: (EditorWindowController) -> Void = { $0.write(to: url, format: format) }
        guard let image = renderForExport(failure: "Save failed", retry: retry) else { return }
        do {
            _ = try exportServices.write(image, url, format, model.preferences.exportScale, model.backingScale)
            clearRetry()
            model.statusMessage = "Saved \(url.lastPathComponent)"
            onExported?(url)
        } catch {
            offerRetry(failure: "Save failed: \(error.localizedDescription)", retry: retry)
        }
    }

    func copyAndMaybeClose() {
        _ = copyToClipboard(closeAfterSuccess: true)
    }

    private func saveAs() {
        let panel = NSSavePanel()
        let format = currentFormat()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.directoryURL = model.preferences.saveDirectory
        panel.nameFieldStringValue = model.preferences.outputPaths.saveURL(format: format).lastPathComponent
        panel.beginSheetModal(for: window ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            MainActor.assumeIsolated {
                let chosen: ExportFormat
                switch url.pathExtension.lowercased() {
                case "jpg", "jpeg": chosen = .jpeg(quality: self.model.preferences.jpegQuality)
                case "heic": chosen = .heic(quality: self.model.preferences.jpegQuality)
                case "tif", "tiff": chosen = .tiff
                default: chosen = .plainPNG
                }
                self.write(to: url, format: chosen)
            }
        }
    }

    private func share() {
        guard let content = window?.contentView else { return }
        canvas.endEditing()
        guard let image = renderForExport(failure: "Share failed", retry: { $0.share() }) else { return }
        clearRetry()
        model.statusMessage = "Choose where to share"
        exportServices.share(image, actions.shareAnchor.flatMap { $0.window === window ? $0 : nil } ?? content)
    }

    private func openRaw() {
        if let url = model.rawURL { NSWorkspace.shared.open(url) }
    }

    /// Renders the output to a cache file used as the drag-out payload.
    func prepareDragFile() -> URL? {
        canvas.endEditing()
        let dir = exportServices.dragDirectory
        let name = FileNaming.fileName(template: model.preferences.outputPaths.fileNameTemplate)
        let retry: (EditorWindowController) -> Void = { controller in
            if controller.prepareDragFile() != nil {
                controller.model.statusMessage = "Drag to share again."
            }
        }
        guard let image = renderForExport(failure: "Drag export failed", retry: retry) else { return nil }
        let url = FileNaming.uniqueURL(directory: dir, baseName: name, ext: "png")
        do {
            _ = try exportServices.write(image, url, .plainPNG, model.preferences.exportScale, model.backingScale)
            dragFiles.insert(url)
            clearRetry()
            model.statusMessage = "Dragging image to share"
            onImageShared?(image, .dragged, model.backingScale)
            return url
        } catch {
            offerRetry(failure: "Drag export failed: \(error.localizedDescription)", retry: retry)
            return nil
        }
    }

    // MARK: Preset designer

    /// Saves the designed preset, then reports it and closes; failures stay visible in the bar.
    func savePresetAndClose() {
        guard model.isDesigningPreset, !presetSaved else { return }
        guard model.canSaveDesign else { exportServices.beep(); return }
        do {
            let preset = try model.saveDesignedPreset()
            presetSaved = true
            model.statusMessage = nil
            onPresetSaved?(preset)
            window?.close()
        } catch {
            model.statusMessage = "Couldn't save the preset: \(error.localizedDescription)"
            exportServices.beep()
        }
    }

    private func handleDesignerShortcut(_ event: NSEvent, flags: NSEvent.ModifierFlags, key: String) -> Bool {
        if flags == .command {
            switch key {
            case "s": savePresetAndClose()
            case "z": model.undoManager.undo()
            case "w": window?.close()
            default: return false
            }
            return true
        }
        if flags == [.command, .shift], key == "z" { model.undoManager.redo(); return true }
        if flags.isEmpty {
            switch event.keyCode {
            case 36, 76: savePresetAndClose()
            case 53: window?.close()
            default: return false
            }
            return true
        }
        return false
    }

    // MARK: Shortcuts

    func handleShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if model.isDesigningPreset { return handleDesignerShortcut(event, flags: flags, key: key) }
        if flags == .command {
            switch key {
            case "c": copyAndMaybeClose()
            case "s": saveOutput()
            case "z": model.undoManager.undo()
            case "w": window?.close()
            case "d": model.duplicateSelected()
            case "a": model.selectAll()
            case "]": model.reorder(.forward)
            case "[": model.reorder(.backward)
            default: return false
            }
            return true
        }
        if flags == [.command, .shift] {
            switch key {
            case "z": model.undoManager.redo()
            case "s": saveAs()
            case "]", "}": model.reorder(.front)
            case "[", "{": model.reorder(.back)
            default: return false
            }
            return true
        }
        if flags.isEmpty {
            switch key {
            case "1": model.pressToolKey(.text)
            case "2": model.pressToolKey(.arrow)
            case "3": model.pressToolKey(.redact)
            case "4": model.pressToolKey(.shape)
            case "v": model.pressToolKey(.select)
            case "p": model.pressToolKey(.pen)
            case "h": model.pressToolKey(.highlighter)
            case "c": model.pressToolKey(.counter)
            default: return false
            }
            canvas.endEditing()
            return true
        }
        return false
    }

    // MARK: NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        clearRetry()
        canvas.endEditing()
        for url in dragFiles { try? FileManager.default.removeItem(at: url) }
        dragFiles.removeAll()
        onClose?()
    }

    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undoManager }
}
