import AppKit
import GlintCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorExportServices {
    var copy: (CGImage) -> Bool = { Exporter.copyToClipboard($0) }
    var write: (CGImage, URL, ExportFormat, ExportScale, CGFloat) throws -> URL = {
        try Exporter.write($0, to: $1, format: $2, scale: $3, backingScale: $4)
    }
    var share: @MainActor (CGImage, NSView) -> Void = { image, content in
        let ns = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        let picker = NSSharingServicePicker(items: [ns])
        let anchor = CGRect(x: content.bounds.maxX - 200, y: 0, width: 80, height: 50)
        picker.show(relativeTo: anchor, of: content, preferredEdge: .minY)
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

@MainActor
public final class EditorWindowController: NSWindowController, NSWindowDelegate {
    public var onClose: (() -> Void)?
    public var onExported: ((URL?) -> Void)?

    let model: EditorModel
    private let exportServices: EditorExportServices
    let actions = EditorActions()
    private let canvas: CanvasView
    private var dragFiles: Set<URL> = []
    private var retryID: UUID?

    public convenience init(context: EditorContext, preferences: AppPreferences, presetStore: PresetStore) {
        self.init(context: context, preferences: preferences, presetStore: presetStore, exportServices: EditorExportServices())
    }

    init(context: EditorContext, preferences: AppPreferences, presetStore: PresetStore, exportServices: EditorExportServices) {
        let model = EditorModel(context: context, preferences: preferences, presetStore: presetStore)
        self.model = model
        self.exportServices = exportServices
        self.canvas = CanvasView(model: model)

        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1261, height: 704),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        window.title = context.source.map { "Glint — \($0)" } ?? "Glint"
        window.minSize = NSSize(width: 960, height: 560)
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
        actions.dragFileURL = { [weak self] in self?.prepareDragFile() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    private func buildUI(in window: NSWindow) {
        let root = NSView()
        window.contentView = root

        let toolbar = NSHostingView(rootView: ToolStripView(model: model))
        let inspector = NSHostingView(rootView: InspectorView(model: model))
        let bottom = NSHostingView(rootView: BottomBarView(model: model, actions: actions))
        for v in [toolbar, inspector, bottom, canvas] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            inspector.topAnchor.constraint(equalTo: root.topAnchor),
            inspector.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            inspector.widthAnchor.constraint(equalToConstant: 300),
            inspector.bottomAnchor.constraint(equalTo: bottom.topAnchor),

            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 50),

            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottom.topAnchor),
        ])
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
        exportServices.share(image, content)
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
                controller.model.statusMessage = "Drag the thumbnail again to export."
            }
        }
        guard let image = renderForExport(failure: "Drag export failed", retry: retry) else { return nil }
        let url = FileNaming.uniqueURL(directory: dir, baseName: name, ext: "png")
        do {
            _ = try exportServices.write(image, url, .plainPNG, model.preferences.exportScale, model.backingScale)
            dragFiles.insert(url)
            clearRetry()
            model.statusMessage = "Drag the thumbnail to export"
            return url
        } catch {
            offerRetry(failure: "Drag export failed: \(error.localizedDescription)", retry: retry)
            return nil
        }
    }

    // MARK: Shortcuts

    func handleShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
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
