import AppKit
import GlintCore
import SwiftUI
import UniformTypeIdentifiers

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

    private let model: EditorModel
    private let actions = EditorActions()
    private let canvas: CanvasView
    private var dragFile: URL?

    public init(context: EditorContext, preferences: AppPreferences, presetStore: PresetStore) {
        let model = EditorModel(context: context, preferences: preferences, presetStore: presetStore)
        self.model = model
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
    public func copyToClipboard() {
        canvas.endEditing()
        let image = model.renderFinal()
        if Exporter.copyToClipboard(image) {
            model.statusMessage = "Copied to clipboard"
            onExported?(nil)
        } else {
            model.statusMessage = "Copy failed"
            NSSound.beep()
        }
    }

    /// Writes the composed output to the save directory and reports the URL through `onExported`.
    public func saveOutput() {
        let format = currentFormat()
        let url = model.preferences.outputPaths.saveURL(format: format)
        write(to: url, format: format)
    }

    // MARK: Actions

    private func currentFormat() -> ExportFormat {
        let p = model.preferences
        return p.compressToJPEG ? .jpeg(quality: p.jpegQuality) : p.exportFormat
    }

    private func write(to url: URL, format: ExportFormat) {
        canvas.endEditing()
        let image = model.renderFinal()
        do {
            try Exporter.write(image, to: url, format: format, scale: model.preferences.exportScale, backingScale: model.backingScale)
            model.statusMessage = "Saved \(url.lastPathComponent)"
            onExported?(url)
        } catch {
            model.statusMessage = "Save failed: \(error.localizedDescription)"
            NSSound.beep()
        }
    }

    func copyAndMaybeClose() {
        copyToClipboard()
        if model.preferences.closeAfterCopy { window?.close() }
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
        let image = model.renderFinal()
        let ns = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        let picker = NSSharingServicePicker(items: [ns])
        let anchor = CGRect(x: content.bounds.maxX - 200, y: 0, width: 80, height: 50)
        picker.show(relativeTo: anchor, of: content, preferredEdge: .minY)
    }

    private func openRaw() {
        if let url = model.rawURL { NSWorkspace.shared.open(url) }
    }

    /// Renders the output to a cache file used as the drag-out payload.
    private func prepareDragFile() -> URL? {
        canvas.endEditing()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        let dir = caches.appendingPathComponent("Glint/Drag", isDirectory: true)
        let name = FileNaming.fileName(template: model.preferences.outputPaths.fileNameTemplate)
        let url = FileNaming.uniqueURL(directory: dir, baseName: name, ext: "png")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try Exporter.write(model.renderFinal(), to: url, format: .plainPNG, scale: model.preferences.exportScale,
                               backingScale: model.backingScale)
            dragFile = url
            return url
        } catch {
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
        canvas.endEditing()
        if let dragFile { try? FileManager.default.removeItem(at: dragFile) }
        onClose?()
    }

    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undoManager }
}
