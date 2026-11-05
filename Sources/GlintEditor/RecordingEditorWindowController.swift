import AppKit
import Combine
import GlintCore

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

    init(recording: RecordedVideo, services: RecordingEditorServices,
         preferences: AppPreferences = AppPreferences(), presetStore: PresetStore = PresetStore()) {
        self.services = services
        model = RecordingEditorModel(recording: recording, services: services)
        playback = RecordingPlayback(url: recording.url, duration: recording.duration)

        // The real first frame arrives asynchronously. This neutral placeholder keeps the exact source geometry.
        let bitmap = GlintBitmap.makeContext(width: max(1, Int(recording.pixelSize.width)),
                                            height: max(1, Int(recording.pixelSize.height)))!
        bitmap.setFillColor(NSColor.black.cgColor)
        bitmap.fill(CGRect(origin: .zero, size: recording.pixelSize))
        let context = EditorContext(image: bitmap.makeImage()!, backingScale: 1, rawURL: nil,
                                    source: "Recording", isRecording: true)
        let canvasModel = EditorModel(context: context, preferences: preferences, presetStore: presetStore)
        editor = EditorWindowController(model: canvasModel, title: "Glint — Recording",
                                        recording: model, playback: playback)
        super.init(window: editor.window)
        window?.delegate = self
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
        if model.hasRunningTask {
            Task { @MainActor in
                await self.model.waitForExport()
                self.finishClosing()
            }
        } else {
            finishClosing()
        }
    }

    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { editor.model.undoManager }

    private func finishClosing() {
        services.removeItem(model.recording.url)
        let callback = onClose
        onClose = nil
        callback?()
    }
}
