import AppKit
import Combine
import GlintCore

/// Why a saved recording couldn't be opened in the editor.
public enum RecordingEditorOpenError: LocalizedError, Equatable {
    case invalidClip
    case notEnoughMemory

    public var errorDescription: String? {
        switch self {
        case .invalidClip: return "The recording's size or length in the project is invalid."
        case .notEnoughMemory: return "There isn't enough memory to open a recording this large."
        }
    }
}

/// Owns the temporary recording while the ordinary Glint editor styles, annotates and exports it.
@MainActor
public final class RecordingEditorWindowController: NSWindowController, NSWindowDelegate {
    public var onClose: (() -> Void)?

    let model: RecordingEditorModel
    let playback: RecordingPlayback
    let editor: EditorWindowController
    private let services: RecordingEditorServices
    private var refreshTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?
    private var sizeDirty = false
    private var subscriptions = Set<AnyCancellable>()
    private var isClosing = false

    public convenience init(recording: RecordedVideo) {
        self.init(recording: recording, preferences: AppPreferences(), presetStore: PresetStore())
    }

    public convenience init(recording: RecordedVideo, preferences: AppPreferences, presetStore: PresetStore) {
        self.init(recording: recording, services: RecordingEditorServices(), preferences: preferences, presetStore: presetStore)
    }

    /// Reopens a saved recording project. Its size comes from a file, so it is checked and the placeholder frame is
    /// allocated before anything is built; an unusable size or a failed allocation throws instead of trapping.
    public convenience init(recording: RecordedVideo, project: RecordingProjectState, projectName: String?,
                            preferences: AppPreferences, presetStore: PresetStore) throws {
        try self.init(recording: recording, services: RecordingEditorServices(), preferences: preferences,
                      presetStore: presetStore, project: project, projectName: projectName)
    }

    convenience init(recording: RecordedVideo, services: RecordingEditorServices,
                     preferences: AppPreferences = AppPreferences(), presetStore: PresetStore = PresetStore(),
                     project: RecordingProjectState, projectName: String?) throws {
        guard RecordingProjectState.isValid(duration: recording.duration, pixelSize: recording.pixelSize) else {
            throw RecordingEditorOpenError.invalidClip
        }
        guard let placeholder = Self.placeholderFrame(for: recording.pixelSize) else {
            throw RecordingEditorOpenError.notEnoughMemory
        }
        self.init(recording: recording, services: services, preferences: preferences, presetStore: presetStore,
                  project: project, projectName: projectName, placeholder: placeholder)
    }

    /// A black frame of the recording's size, shown until the first real frame is decoded. The size is clamped to
    /// `1...RecordingProjectState.maxPixelSide`; nil when it can't be allocated.
    static func placeholderFrame(for size: CGSize) -> CGImage? {
        func side(_ value: CGFloat) -> Int {
            guard value.isFinite else { return 1 }
            return Int(min(max(value.rounded(), 1), CGFloat(RecordingProjectState.maxPixelSide)))
        }
        let width = side(size.width), height = side(size.height)
        guard let bitmap = GlintBitmap.makeContext(width: width, height: height) else { return nil }
        bitmap.setFillColor(NSColor.black.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return bitmap.makeImage()
    }

    init(recording: RecordedVideo, services: RecordingEditorServices,
         preferences: AppPreferences = AppPreferences(), presetStore: PresetStore = PresetStore(),
         project: RecordingProjectState? = nil, projectName: String? = nil, placeholder: CGImage? = nil) {
        self.services = services
        model = RecordingEditorModel(recording: recording, services: services)
        if let project {
            model.trim = project.trim
            model.options = project.options
        }
        playback = RecordingPlayback(url: recording.url, duration: recording.duration)

        // The real first frame arrives asynchronously. This neutral placeholder keeps the source geometry; if it
        // can't be allocated, a 1×1 frame stands in until the first real frame replaces it.
        let frame = placeholder ?? Self.placeholderFrame(for: recording.pixelSize)
            ?? Self.placeholderFrame(for: CGSize(width: 1, height: 1))
        let restored = project.map {
            EditorRestoreState(settings: $0.settings, annotations: $0.annotations, projectName: projectName)
        }
        guard let frame else { preconditionFailure("Couldn't allocate a 1×1 placeholder frame") }
        let context = EditorContext(image: frame, backingScale: 1, rawURL: nil,
                                    source: "Recording", isRecording: true, restored: restored)
        let canvasModel = EditorModel(context: context, preferences: preferences, presetStore: presetStore)
        editor = EditorWindowController(model: canvasModel, title: projectName.map { "Glint — \($0)" } ?? "Glint — Recording",
                                        exportServices: services.editorExport, recording: model, playback: playback)
        super.init(window: editor.window)
        window?.delegate = self
        editor.makeProject = { [weak model, weak canvasModel] in
            guard let model, let canvasModel else { return nil }
            return GlintProject(state: .recording(model.projectState(settings: canvasModel.settings,
                                                                     annotations: canvasModel.annotations)),
                                source: .video(model.recording.url))
        }
        canvasModel.onBeginEditing = { [weak playback] in playback?.pause() }
        model.makeFrameRenderer = { [canvasModel] in canvasModel.recordingFrameRenderer() }
        playback.onFrame = { [weak self, weak canvasModel] frame, time in
            let changedSize = canvasModel?.image.pixelSize != frame.pixelSize
            canvasModel?.updateRecordingFrame(frame, at: time)
            if changedSize { self?.refreshOutputSize() }
        }
        var previousFrameProblem: String?
        playback.$frameProblem.sink { [weak canvasModel] problem in
            if problem != nil || canvasModel?.statusMessage == previousFrameProblem {
                canvasModel?.statusMessage = problem
            }
            previousFrameProblem = problem
        }.store(in: &subscriptions)
        model.$trim.sink { [weak playback] trim in
            playback?.apply(range: trim.range, sourceDuration: trim.sourceDuration)
        }.store(in: &subscriptions)
        canvasModel.$settings.dropFirst().sink { [weak self] _ in
            self?.model.invalidatePreparedFile()
            Task { @MainActor [weak self] in self?.refreshOutputSize() }
        }.store(in: &subscriptions)
        canvasModel.$annotations.dropFirst().sink { [weak self] _ in
            self?.model.invalidatePreparedFile()
            Task { @MainActor [weak self] in self?.refreshOutputSize() }
        }.store(in: &subscriptions)
        refreshOutputSize()
        refreshTask = Task { [weak self] in await self?.model.refreshDuration() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func showEditor() { editor.showEditor() }

    /// Called after the recording was saved as a project, with the package's location.
    public var onProjectSaved: ((URL) -> Void)? {
        get { editor.onProjectSaved }
        set { editor.onProjectSaved = newValue }
    }

    /// Called when a project save that was still running when the window closed fails.
    public var onProjectSaveFailed: ((URL, Error) -> Void)? {
        get { editor.onProjectSaveFailed }
        set { editor.onProjectSaveFailed = newValue }
    }

    /// Saves the recording, its trim, export settings, look and annotations as an editable `.glint` project.
    @objc public func saveAsProject(_ sender: Any?) {
        guard !isClosing else { return }
        editor.saveAsProject(sender)
    }

    func save() {
        guard !isClosing else { return }
        editor.saveOutput()
    }

    private func refreshOutputSize() {
        guard !isClosing else { return }
        sizeDirty = true
        guard sizeTask == nil else { return }
        sizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard let self else { return }
            while self.sizeDirty, !Task.isCancelled, !self.isClosing {
                self.sizeDirty = false
                let render = self.editor.model.recordingFrameRenderer()
                let frame = self.editor.model.image
                let time = self.editor.model.recordingTime
                let result = await Task.detached(priority: .utility) { Result { try render(frame, time).pixelSize } }.value
                guard !Task.isCancelled, !self.isClosing else { break }
                if !self.sizeDirty {
                    switch result {
                    case .success(let size): self.model.styledPixelSize = size
                    case .failure(let error): self.editor.model.statusMessage = error.localizedDescription
                    }
                }
            }
            self.sizeTask = nil
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        refreshTask?.cancel()
        sizeTask?.cancel()
        subscriptions.removeAll()
        editor.windowWillClose(notification)
        playback.shutdown()
        model.beginShutdown()
        // The clip must outlive any export or project save still reading it.
        if model.hasRunningTask || editor.isSavingProject {
            Task { @MainActor in
                await self.model.waitForExport()
                await self.editor.waitForProjectSave()
                self.finishClosing()
            }
        } else {
            finishClosing()
        }
    }

    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { editor.model.undoManager }

    private func finishClosing() {
        if model.recording.deletesFileOnClose { services.removeItem(model.recording.url) }
        let callback = onClose
        onClose = nil
        callback?()
    }
}

extension RecordingEditorWindowController: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(saveAsProject(_:)) { return !isClosing && model.sourceProblem == nil }
        return true
    }
}
