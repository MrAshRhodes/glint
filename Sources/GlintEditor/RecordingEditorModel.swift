import AppKit
import AVFoundation
import Foundation
import GlintCore

/// What the recording editor does with the machinery around it. The defaults are the real thing; tests swap pieces.
struct RecordingEditorServices {
    var readDuration: (URL) async throws -> TimeInterval = { url in
        try await RecordingExporter.readableDuration(of: AVURLAsset(url: url))
    }
    var export: (URL, ClosedRange<TimeInterval>, RecordingExportOptions, URL, @escaping RecordingExporter.ProgressHandler, RecordingExporter.FrameRenderer?) async throws -> URL = {
        source, range, options, directory, progress, renderer in
        try await RecordingExporter.export(source: source, range: range, options: options, outputDirectory: directory,
                                            progress: progress, frameRenderer: renderer)
    }
    var makeStagingDirectory: (URL?) throws -> URL = { try RecordingExportFiles.makeStagingDirectory(forDestination: $0) }
    var commit: (URL, URL) throws -> Void = { try RecordingExportFiles.commit($0, to: $1) }
    var copyToPasteboard: (URL, RecordingFileFormat) throws -> Void = { _ = try RecordingPasteboard.copy($0, format: $1) }
    var removeItem: (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }
    /// Asks where to save, as a sheet on `window` when there is one. Calls back with nil when the user cancels.
    var chooseDestination: @MainActor (NSWindow?, RecordingFileFormat, @escaping (URL?) -> Void) -> Void = { window, format, completion in
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = RecordingExportFiles.defaultFileName(format: format)
        let finish: (NSApplication.ModalResponse) -> Void = { completion($0 == .OK ? panel.url : nil) }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}

/// Something the user asked the editor to do with the trimmed recording.
enum RecordingExportAction: Equatable {
    case save(URL)
    case copy
    case prepare
}

enum RecordingExportState: Equatable {
    case idle
    case running(Double)
    case cancelled
    case failed(String)
    case done(String)
}

/// Editing state of one recording: the trim range, the export options, and the export in flight.
///
/// The model never deletes `recording.url`; whoever owns the window does that once the window is gone. A failed or
/// cancelled export leaves everything in place, so Retry and further edits keep working.
@MainActor
final class RecordingEditorModel: ObservableObject {
    let recording: RecordedVideo
    @Published var trim: RecordingTrim { didSet { invalidatePreparedFile() } }
    @Published var options = RecordingExportOptions() { didSet { invalidatePreparedFile() } }
    @Published var styledPixelSize: CGSize?
    /// Called once on the main actor when an export starts, never once per frame.
    var makeFrameRenderer: (() -> RecordingExporter.FrameRenderer)?
    @Published private(set) var exportState = RecordingExportState.idle
    /// Set when the file turns out not to be a readable video; every export is refused then.
    @Published private(set) var sourceProblem: String?
    /// The last action that was started, so Retry can repeat it.
    private(set) var lastAction: RecordingExportAction?

    private let services: RecordingEditorServices
    private var exportTask: Task<Void, Never>?
    private var isClosed = false
    private var preparedURL: URL?
    private var preparedDirectories: [URL] = []
    private var preparationRevision = 0
    private var preparedCompletion: ((URL) -> Void)?

    init(recording: RecordedVideo, services: RecordingEditorServices = RecordingEditorServices()) {
        self.recording = recording
        self.services = services
        trim = RecordingTrim(sourceDuration: recording.duration)
    }

    /// The editable state to save in a project, with the editor's current look and annotations.
    func projectState(settings: RenderSettings, annotations: [Annotation]) -> RecordingProjectState {
        RecordingProjectState(settings: settings, annotations: annotations, trim: trim, options: options,
                              duration: recording.duration, pixelSize: recording.pixelSize)
    }

    // MARK: Derived state

    var isExporting: Bool {
        if case .running = exportState { return true }
        return false
    }

    /// Present when the chosen range can't be exported as a GIF; never truncated silently.
    var gifLimitIssue: GIFLimitIssue? {
        guard options.format == .gif else { return nil }
        return GIFLimits.issue(duration: trim.duration, options: options.gif)
    }

    var canExport: Bool { !isClosed && !isExporting && sourceProblem == nil && gifLimitIssue == nil }

    var canRetry: Bool {
        if case .failed = exportState { return lastAction != nil && !isExporting }
        return false
    }

    var outputSize: CGSize {
        let size = styledPixelSize ?? recording.pixelSize
        if options.format == .gif { return options.gif.maxWidth.outputSize(for: size) }
        guard styledPixelSize != nil else { return size }
        return CGSize(width: ceil(size.width / 2) * 2, height: ceil(size.height / 2) * 2)
    }

    var outputSizeText: String {
        "\(Int(outputSize.width.rounded())) × \(Int(outputSize.height.rounded())) px"
    }

    /// A rough file size for GIFs; MP4 sizes depend too much on the content to estimate.
    var estimatedSizeText: String? {
        guard options.format == .gif else { return nil }
        let bytes = GIFLimits.estimatedByteCount(duration: trim.duration, options: options.gif, sourceSize: styledPixelSize ?? recording.pixelSize)
        return "about " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var statusText: String? {
        switch exportState {
        case .idle: return nil
        case .running(let fraction): return "Exporting… \(Int((fraction * 100).rounded()))%"
        case .cancelled: return "Export cancelled."
        case .failed(let message): return message
        case .done(let message): return message
        }
    }

    // MARK: Editing

    func setTrimStart(_ seconds: TimeInterval) {
        guard !isExporting else { return }
        trim.setStart(seconds)
    }

    func setTrimEnd(_ seconds: TimeInterval) {
        guard !isExporting else { return }
        trim.setEnd(seconds)
    }

    /// Shortens the end of the range to the longest a GIF can be at the chosen frame rate.
    func fitToGIFLimit() {
        guard !isExporting else { return }
        trim.limitDuration(to: GIFLimits.maxDuration(framesPerSecond: options.gif.framesPerSecond))
    }

    /// Aligns the trim range with the duration the file really has, which can differ slightly from the one the
    /// capture layer measured, and notes it when the file can't be read at all.
    func refreshDuration() async {
        do {
            let duration = try await services.readDuration(recording.url)
            if abs(duration - trim.sourceDuration) > 0.001, !isExporting { trim.setSourceDuration(duration) }
            sourceProblem = nil
        } catch is CancellationError {
            return
        } catch {
            sourceProblem = error.localizedDescription
        }
    }

    // MARK: Export

    /// Asks where to save, then exports there. Does nothing if the user cancels the panel.
    func save(in window: NSWindow?) {
        guard canExport else { return }
        services.chooseDestination(window, options.format) { [weak self] destination in
            guard let destination else { return }
            MainActor.assumeIsolated { self?.start(.save(destination)) }
        }
    }

    func copy() {
        start(.copy)
    }

    /// Share uses a completion; drag asks again after the visible preparation status reaches Ready.
    @discardableResult
    func prepareFile(completion: ((URL) -> Void)? = nil) -> URL? {
        guard !isClosed else { return nil }
        if let preparedURL {
            completion?(preparedURL)
            return preparedURL
        }
        guard canExport else { return nil }
        preparedCompletion = completion
        start(.prepare)
        return nil
    }

    func invalidatePreparedFile() {
        preparationRevision += 1
        preparedURL = nil
        // Keep already handed-out files alive for drag destinations and sharing services until the window closes.
    }

    func retry() {
        guard canRetry, let lastAction else { return }
        start(lastAction)
    }

    func start(_ action: RecordingExportAction) {
        guard canExport else { return }
        lastAction = action
        exportState = .running(0)
        let range = trim.range
        let options = options
        let renderer = makeFrameRenderer?()
        let revision = preparationRevision
        exportTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.perform(action, range: range, options: options, renderer: renderer, revision: revision)
            self.exportState = result
            self.exportTask = nil
        }
    }

    /// The window is going away: refuses new exports and cancels the one in flight.
    func beginShutdown() {
        isClosed = true
        exportTask?.cancel()
        preparedCompletion = nil
        for directory in preparedDirectories { services.removeItem(directory) }
        preparedDirectories.removeAll()
        preparedURL = nil
    }

    /// Stops a running export. The task removes its partial files and then reports `.cancelled`.
    func cancelExport() {
        exportTask?.cancel()
    }

    /// Returns once no export is running, after it has cleaned up after itself.
    func waitForExport() async {
        await exportTask?.value
    }

    var hasRunningTask: Bool { exportTask != nil }

    private func perform(_ action: RecordingExportAction, range: ClosedRange<TimeInterval>,
                         options: RecordingExportOptions, renderer: RecordingExporter.FrameRenderer?,
                         revision: Int) async -> RecordingExportState {
        var staging: URL?
        defer { if let staging { services.removeItem(staging) } }
        do {
            var destination: URL?
            if case .save(let url) = action { destination = url }
            let directory = try services.makeStagingDirectory(destination)
            staging = directory
            let exported = try await services.export(recording.url, range, options, directory, { [weak self] fraction in
                Task { @MainActor in self?.noteProgress(fraction) }
            }, renderer)
            try Task.checkCancellation()
            switch action {
            case .save(let url):
                try services.commit(exported, url)
                return .done("Saved \(url.lastPathComponent)")
            case .copy:
                try services.copyToPasteboard(exported, options.format)
                return .done("Copied to the clipboard")
            case .prepare:
                guard revision == preparationRevision else {
                    preparedCompletion = nil
                    return .done("Recording changed. Share or drag again to prepare the updated clip.")
                }
                preparedDirectories.append(directory)
                staging = nil
                preparedURL = exported
                let completion = preparedCompletion
                preparedCompletion = nil
                completion?(exported)
                return .done("Ready to share — drag again to export")
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func noteProgress(_ fraction: Double) {
        guard case .running(let current) = exportState else { return }
        exportState = .running(min(max(fraction, current, 0), 1))
    }
}
