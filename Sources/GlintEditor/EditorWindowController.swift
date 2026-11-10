import AppKit
import GlintCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorExportServices {
    /// Copies the finished image with the export scale and backing scale a saved copy would use.
    var copy: (CGImage, ExportScale, CGFloat) -> Bool = { Exporter.copyToClipboard($0, scale: $1, backingScale: $2) }
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
    /// Asks where to save a project, as a sheet on `window` when there is one. Calls back with nil on cancel.
    var chooseProjectDestination: @MainActor (NSWindow?, URL?, @escaping (URL?) -> Void) -> Void = { window, directory, completion in
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ProjectStore.contentType]
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.nameFieldStringValue = ProjectStore.defaultFileName()
        panel.message = "Save an editable copy you can reopen in Glint."
        panel.accessoryView = ProjectPrivacyNotice.makeView()
        let finish: (NSApplication.ModalResponse) -> Void = { completion($0 == .OK ? panel.url : nil) }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
    /// Where saves in flight are counted.
    var saveActivity: ProjectSaveActivity = .shared
    /// Writes a project package; runs off the main actor.
    var writeProject: @Sendable (GlintProject, URL) throws -> Void = { project, url in
        try ProjectStore.write(project, to: url, generator: ProjectPrivacyNotice.generator)
    }
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

/// Counts project saves in flight across every editor, so quitting can wait for them.
@MainActor
public final class ProjectSaveActivity {
    /// The app-wide counter every editor reports to unless a test gives it its own.
    public static let shared = ProjectSaveActivity()

    public private(set) var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isActive: Bool { count > 0 }

    func begin() { count += 1 }

    func end() {
        count = max(count - 1, 0)
        guard count == 0 else { return }
        resumeWaiters()
    }

    private func resumeWaiters() {
        let ready = waiters
        waiters.removeAll()
        ready.forEach { $0.resume() }
    }

    /// Waits until no project is being saved, or `timeout` passes. Returns true when nothing is being saved.
    public func waitUntilIdle(timeout: Duration) async -> Bool {
        guard isActive else { return true }
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resumeWaiters()
        }
        await withCheckedContinuation { waiters.append($0) }
        timer.cancel()
        return !isActive
    }
}

/// The warning shown wherever a project is saved: a project keeps the unedited capture.
enum ProjectPrivacyNotice {
    static let text = "Projects contain the original capture, including anything you redacted. "
        + "Share an exported image or clip instead."

    /// The app and version recorded in a project's manifest, for diagnostics only.
    static var generator: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "\(GlintInfo.name) \($0)" } ?? GlintInfo.name
    }

    @MainActor
    static func makeView() -> NSView {
        let view = NSHostingView(rootView: Label(text, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 420, alignment: .leading)
            .padding(12))
        view.setFrameSize(view.fittingSize)
        return view
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
    /// Called after a project package was written, with its location.
    public var onProjectSaved: ((URL) -> Void)?
    /// Called when a project save that was still running when the window closed fails, so the failure can be
    /// reported somewhere visible. While the window is open, failures are shown in the editor with Retry.
    public var onProjectSaveFailed: ((URL, Error) -> Void)?
    /// Builds the project to save. Screenshots save the model's own state; the recording editor supplies its clip.
    var makeProject: (() -> GlintProject?)?

    let model: EditorModel
    private let exportServices: EditorExportServices
    let actions = EditorActions()
    let recording: RecordingEditorModel?
    let playback: RecordingPlayback?
    let tracking: RedactionTrackingModel?
    private let canvas: CanvasView
    private weak var recordingControls: NSView?
    private var dragFiles: Set<URL> = []
    private var retryID: UUID?
    private var presetSaved = false
    private var projectSave: Task<Void, Never>?
    private var isClosed = false
    /// Copies and drags still rendering; each is kept in step with `finishExports`.
    private var exportTasks: [UUID: Task<Void, Never>] = [:]
    /// Counts the copies started in every editor, so a copy that a later one overtook does not replace the clipboard
    /// the later one filled, whichever editor it came from.
    private static var copyRequests = 0
    /// The cache files of drags whose file is still being made, in every editor, so two drags never share one.
    private static var dragFilesInFlight: Set<URL> = []

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

    init(model: EditorModel, title: String, exportServices: EditorExportServices = EditorExportServices(),
         recording: RecordingEditorModel? = nil, playback: RecordingPlayback? = nil) {
        self.model = model
        self.recording = recording
        self.playback = playback
        tracking = recording.map { RedactionTrackingModel(url: $0.recording.url) }
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

        actions.copy = { [weak self] in self?.startCopy(closeAfterSuccess: true) }
        actions.save = { [weak self] in self?.saveOutput() }
        actions.saveAs = { [weak self] in self?.saveAs() }
        actions.share = { [weak self] in self?.share() }
        actions.saveProject = { [weak self] in self?.saveAsProject(nil) }
        actions.openRaw = { [weak self] in self?.openRaw() }
        actions.close = { [weak self] in self?.window?.close() }
        actions.commitEditing = { [weak self] in self?.canvas.endEditing() }
        actions.savePreset = { [weak self] in self?.savePresetAndClose() }
        actions.dragPayload = { [weak self] in self?.dragPayload() }
        actions.selectTool = { [weak self] in self?.selectTool($0) }
        if let recording {
            actions.retryExport = { [weak recording] in recording?.retry() }
        }
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
            : Self.host(ToolStripView(model: model, actions: actions), sizing: [.intrinsicContentSize])
        toolbar.setContentHuggingPriority(.required, for: .horizontal)
        let bottom: NSView
        let bottomHeight: CGFloat
        if let recording, let playback, let tracking {
            bottom = Self.host(RecordingBarView(editor: model, recording: recording, playback: playback, actions: actions,
                                                tracking: tracking), sizing: [])
            recordingControls = bottom
            bottomHeight = RecordingBarView.contentHeight
        } else {
            bottom = designing
                ? Self.host(PresetDesignBarView(model: model, actions: actions), sizing: [])
                : Self.host(BottomBarView(model: model, actions: actions), sizing: [])
            bottomHeight = metrics.bottomBarHeight
        }

        let inspectorContent = Self.host(InspectorView(model: model, recording: recording, playback: playback,
                                                       tracking: tracking, presentation: recording?.presentation), sizing: [])
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
            bottom.heightAnchor.constraint(equalToConstant: bottomHeight + 2 * pad),
        ])
        canvas.contentInsets = NSEdgeInsets(top: metrics.toolbarRowHeight,
                                            left: inset,
                                            bottom: bottomHeight + 2 * inset,
                                            right: metrics.inspectorWidth + 2 * inset)
    }

    private static func host<V: View>(_ view: V, sizing: NSHostingSizingOptions) -> NSView {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = sizing
        // The chrome is laid out explicitly, including the toolbar under the transparent titlebar. Left on, the
        // titlebar's safe area pushes the toolbar's SwiftUI content down half a row, out of the hosting view's
        // bounds, so clicks on the lower half of every tool button miss it.
        host.safeAreaRegions = []
        return host
    }

    // MARK: Public API

    /// The unstyled capture was written after this editor opened (capture saves it in the background).
    public func rawFileSaved(_ url: URL) {
        model.rawFileSaved(url)
    }

    public func showEditor() {
        guard let window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    /// Copies the composed output (annotations burned in) to the clipboard. The image is rendered off the main actor,
    /// and the clipboard then takes it without waiting for it to be encoded.
    @discardableResult
    public func copyToClipboard() async -> Bool {
        guard let copy = beginCopy(closeAfterSuccess: false) else { return false }
        return await copy()
    }

    /// The copy behind ⌘C and the toolbar button: it also closes the window when that is the preference.
    func copyAndMaybeClose() async {
        guard let copy = beginCopy(closeAfterSuccess: true) else { return }
        _ = await copy()
    }

    /// Starts a copy nothing waits for, the way a shortcut, a button or a retry does. It holds the controller until it
    /// is done, so a copy still rendering when the window closes still reaches the clipboard.
    func startCopy(closeAfterSuccess: Bool) {
        guard let copy = beginCopy(closeAfterSuccess: closeAfterSuccess) else { return }
        track { _ = await copy() }
    }

    /// Does what a copy must do at once (commit the text being typed and take what the editor holds, so later edits
    /// cannot change the copy) and returns the rest: the render off the main actor, then the clipboard.
    /// Nil when there is nothing to copy.
    private func beginCopy(closeAfterSuccess: Bool) -> (() async -> Bool)? {
        canvas.endEditing()
        if let recording {
            playback?.pause()
            recording.copy()
            return nil // A recording export is asynchronous; never report a synchronous still-image success.
        }
        guard !model.isDesigningPreset else { return nil }
        let signpost = CaptureSignposts.begin("export.copy")
        Self.copyRequests += 1
        let request = Self.copyRequests
        let render = model.finalRenderer()
        let scale = model.preferences.exportScale, backingScale = model.backingScale
        let retry: (EditorWindowController) -> Void = { $0.startCopy(closeAfterSuccess: closeAfterSuccess) }
        return { [self] in
            var outcome = CaptureSignposts.Outcome.failed
            defer { CaptureSignposts.end(signpost, outcome) }
            let image: CGImage
            do {
                image = try await BlockingWork.run { _ in try render() }
            } catch {
                if request == Self.copyRequests { reportExportFailure("Copy failed: \(error.localizedDescription)", retry: retry) }
                return false
            }
            // A copy started while this one rendered is the one the clipboard should end up with.
            guard request == Self.copyRequests else {
                outcome = .cancelled
                return false
            }
            guard exportServices.copy(image, scale, backingScale) else {
                reportExportFailure("Copy failed", retry: retry)
                return false
            }
            outcome = .completed
            clearRetry()
            model.statusMessage = "Copied to clipboard"
            onExported?(nil)
            onImageShared?(image, .copied, backingScale)
            if closeAfterSuccess, !isClosed, model.preferences.closeAfterCopy { window?.close() }
            return true
        }
    }

    /// Writes the composed output to the save directory and reports the URL through `onExported`.
    public func saveOutput() {
        if let recording {
            canvas.endEditing()
            playback?.pause()
            recording.save(in: window)
            return
        }
        let format = currentFormat()
        let url = model.preferences.outputPaths.saveURL(format: format)
        write(to: url, format: format)
    }

    // MARK: Actions

    /// Renders the final output, or reports the failure and returns nil so nothing unredacted is exported.
    private func renderForExport(failure: String, retry: @escaping (EditorWindowController) -> Void) -> CGImage? {
        guard !model.isDesigningPreset, recording == nil else { return nil }
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

    /// Shows a failed export with a retry; once the window is gone there is nowhere to show it, so it only beeps.
    private func reportExportFailure(_ message: String, retry: @escaping (EditorWindowController) -> Void) {
        guard !isClosed else {
            exportServices.beep()
            return
        }
        offerRetry(failure: message, retry: retry)
    }

    // MARK: Exports in flight

    /// Runs `operation` as an export in flight, which `finishExports` waits for.
    private func track(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        exportTasks[id] = Task { [weak self] in
            await operation()
            self?.exportTasks[id] = nil
        }
    }

    /// Waits for every copy and drag still rendering, so that its outcome (status, retry, callbacks) is in place.
    func finishExports() async {
        while let task = exportTasks.values.first { await task.value }
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

    private func saveAs() {
        if recording != nil { saveOutput(); return }
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

    /// Saves the capture with its look and annotations as an editable `.glint` project.
    @objc public func saveAsProject(_ sender: Any?) {
        guard !model.isDesigningPreset else { return }
        canvas.endEditing()
        playback?.pause()
        let project: GlintProject
        if let makeProject {
            guard let made = makeProject() else { exportServices.beep(); return }
            project = made
        } else {
            project = GlintProject(state: .screenshot(model.screenshotProjectState()), source: .image(model.image))
        }
        exportServices.chooseProjectDestination(window, model.preferences.saveDirectory) { [weak self] url in
            guard let url else { return }
            MainActor.assumeIsolated { self?.writeProject(project, to: url) }
        }
    }

    /// True while a project is being written. The files it reads (a temporary recording, opened project
    /// assets) must stay in place until `waitForProjectSave()` returns.
    public var isSavingProject: Bool { projectSave != nil }

    /// Returns once no project save is running.
    public func waitForProjectSave() async {
        while let task = projectSave { await task.value; if projectSave == task { projectSave = nil } }
    }

    func writeProject(_ project: GlintProject, to url: URL) {
        // A panel answered after the window closed must not start reading files its owner is removing.
        guard !isClosed else { return }
        guard projectSave == nil else {
            model.statusMessage = "A project is still being saved."
            exportServices.beep()
            return
        }
        let write = exportServices.writeProject
        model.statusMessage = "Saving project…"
        let activity = exportServices.saveActivity
        activity.begin()
        // Holds the controller strongly so the outcome is always reported, even after the window closes.
        projectSave = Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try write(project, url) } }.value
            self.projectSave = nil
            activity.end()
            switch result {
            case .success:
                if !self.isClosed { self.clearRetry() }
                self.model.statusMessage = "Saved project \(url.deletingPathExtension().lastPathComponent)"
                self.onProjectSaved?(url)
            case .failure(let error):
                if self.isClosed {
                    self.onProjectSaveFailed?(url, error)
                    return
                }
                let failure = error is ProjectFormatError
                    ? error.localizedDescription : "Couldn't save the project: \(error.localizedDescription)"
                self.offerRetry(failure: failure) {
                    $0.writeProject(project, to: url)
                }
            }
        }
    }

    private func share() {
        guard let content = window?.contentView else { return }
        canvas.endEditing()
        if let recording {
            playback?.pause()
            recording.prepareFile { [weak self] url in
                guard let self, self.window?.isVisible == true else { return }
                let anchor = self.actions.shareAnchor ?? content
                let picker = NSSharingServicePicker(items: [url])
                picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            }
            return
        }
        guard let image = renderForExport(failure: "Share failed", retry: { $0.share() }) else { return }
        clearRetry()
        model.statusMessage = "Choose where to share"
        exportServices.share(image, actions.shareAnchor.flatMap { $0.window === window ? $0 : nil } ?? content)
    }

    private func openRaw() {
        if let url = model.rawURL { NSWorkspace.shared.open(url) }
    }

    /// What a drag out of the Share tile carries. The drag starts at once; the image is rendered and written in the
    /// background (see `EditorDragPayload`) and `dragRendered` reports how that went.
    func dragPayload() -> NSPasteboardWriting? {
        canvas.endEditing()
        if let recording {
            playback?.pause()
            return recording.prepareFile().map { $0 as NSURL }
        }
        return startDrag(successMessage: "Dragging image to share")
    }

    @discardableResult
    private func startDrag(successMessage: String) -> EditorDragPayload? {
        guard !model.isDesigningPreset, recording == nil else { return nil }
        let signpost = CaptureSignposts.begin("export.drag")
        let render = model.finalRenderer()
        let write = exportServices.write
        let scale = model.preferences.exportScale, backingScale = model.backingScale
        let url = reserveDragFile()
        let payload = EditorDragPayload(fileName: url.lastPathComponent) {
            let image = try render()
            _ = try write(image, url, .plainPNG, scale, backingScale)
            return EditorDragPayload.Delivery(url: url, image: image)
        }
        // Holds the controller until the file is made, so a window closed meanwhile still has it removed.
        track {
            self.dragRendered(await payload.delivery(), for: payload, url: url, backingScale: backingScale,
                              signpost: signpost, successMessage: successMessage)
        }
        return payload
    }

    /// The cache file a drag will write: not on disk, and not taken by a drag whose file is still being made, in this
    /// editor or any other.
    private func reserveDragFile() -> URL {
        let directory = exportServices.dragDirectory
        let name = FileNaming.fileName(template: model.preferences.outputPaths.fileNameTemplate)
        var url = FileNaming.uniqueURL(directory: directory, baseName: name, ext: "png")
        var n = 2
        while Self.dragFilesInFlight.contains(url) {
            url = FileNaming.uniqueURL(directory: directory, baseName: "\(name)-\(n)", ext: "png")
            n += 1
        }
        dragFiles.insert(url)
        Self.dragFilesInFlight.insert(url)
        return url
    }

    private func dragRendered(_ outcome: Result<EditorDragPayload.Delivery, Error>, for payload: EditorDragPayload,
                              url: URL, backingScale: CGFloat, signpost: CaptureSignposts.Interval?,
                              successMessage: String) {
        Self.dragFilesInFlight.remove(url)
        switch outcome {
        case .success(let delivery):
            CaptureSignposts.end(signpost, .completed)
            // The window's own clean-up ran before this file existed. A destination may still be about to read it,
            // so it goes when the drag lets go of the payload rather than now.
            guard !isClosed else {
                dragFiles.remove(url)
                payload.removeFileWhenReleased = url
                return
            }
            clearRetry()
            model.statusMessage = successMessage
            onImageShared?(delivery.image, .dragged, backingScale)
        case .failure(let error):
            CaptureSignposts.end(signpost, .failed)
            dragFiles.remove(url)
            try? FileManager.default.removeItem(at: url)
            reportExportFailure("Drag export failed: \(error.localizedDescription)") {
                $0.startDrag(successMessage: "Drag to share again.")
            }
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
            case "c": startCopy(closeAfterSuccess: true)
            case "s": saveOutput()
            case "z": model.undoManager.undo()
            case "w": window?.close()
            case "d": model.duplicateSelected()
            case "a": model.selectAll()
            case "]": model.reorder(.forward)
            case "[": model.reorder(.backward)
            case "0", "8", "9": model.canvasZoom = CanvasZoom(shortcutKey: key) ?? .fit
            default: return false
            }
            return true
        }
        if flags == [.command, .option], key == "s" {
            saveAsProject(nil)
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
        if flags == .shift, let recording, let playback, key == "n" {
            canvas.endEditing()
            playback.pause()
            guard let next = RedactionTrackingModel.nextFlagged(after: playback.currentTime,
                                                                in: recording.unresolvedRedactionIntervals) else { return false }
            model.selection = [next.annotationID]
            playback.seek(to: next.start)
            return true
        }
        if flags == .shift, let recording, let playback, key == "i" || key == "o" {
            guard !recording.isExporting, !model.selection.isEmpty else { return false }
            canvas.endEditing()
            playback.pause()
            model.setAnnotationBoundary(playback.currentTime, isStart: key == "i", ids: model.selection,
                                        sourceDuration: recording.trim.sourceDuration)
            return true
        }
        if flags.isEmpty {
            if let recording, let playback {
                if [123, 124].contains(event.keyCode), let controls = recordingControls,
                   let focused = window?.firstResponder as? NSView,
                   focused === controls || focused.isDescendant(of: controls) {
                    return false
                }
                switch event.keyCode {
                case 49: canvas.endEditing(); playback.togglePlayback(); return true
                case 123:
                    playback.pause()
                    let now = playback.currentTime
                    playback.seek(to: tracking?.previousFrame(before: now) ?? now - 1.0 / 30)
                    return true
                case 124:
                    playback.pause()
                    let now = playback.currentTime
                    playback.seek(to: tracking?.nextFrame(after: now) ?? now + 1.0 / 30)
                    return true
                default: break
                }
                if key == "i" { recording.setTrimStart(playback.currentTime); return true }
                if key == "o" { recording.setTrimEnd(playback.currentTime); return true }
            }
            guard let tool = EditorTool(shortcutKey: key) else { return false }
            selectTool(tool)
            return true
        }
        return false
    }

    /// Selects a tool; toolbar clicks and tool shortcuts both come through here so they behave identically.
    /// Choosing the current tool again cycles its variant, and any inline text edit is committed.
    func selectTool(_ tool: EditorTool) {
        playback?.pause()
        model.pressToolKey(tool)
        canvas.endEditing()
    }

    // MARK: NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        isClosed = true
        model.close()
        tracking?.shutdown()
        clearRetry()
        canvas.endEditing()
        for url in dragFiles { try? FileManager.default.removeItem(at: url) }
        dragFiles.removeAll()
        onClose?()
    }

    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undoManager }
}

extension EditorWindowController: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(saveAsProject(_:)) {
            return !model.isDesigningPreset && recording?.sourceProblem == nil
        }
        return true
    }
}
