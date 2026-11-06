import AVFoundation
import Foundation
import GlintCore

/// Runs redaction tracking for one recording and helps review its frames. Tracking runs on this Mac only.
@MainActor
final class RedactionTrackingModel: ObservableObject {
    typealias Track = @Sendable (RedactionTrackingRequest, @escaping RedactionTracker.Progress) async throws
        -> RedactionTrack

    @Published private(set) var trackingID: UUID?
    @Published private(set) var progress: Double = 0
    @Published private(set) var message: String?
    /// Presentation times of every frame, for frame-by-frame review. Empty until loaded.
    @Published private(set) var frameTimes: [TimeInterval] = []

    private let url: URL
    private let runTracker: Track
    private var task: Task<Void, Never>?
    private var revision = 0

    init(url: URL, track: Track? = nil) {
        self.url = url
        runTracker = track ?? { request, progress in
            try await RedactionTracker(url: url).track(request, progress: progress)
        }
    }

    var isTracking: Bool { trackingID != nil }

    /// Tracks the redaction `id` from the frame on screen now, over its visible range.
    func track(_ id: UUID, editor: EditorModel, sourceDuration: TimeInterval) {
        guard !isTracking, editor.isRecording,
              let annotation = editor.annotations.first(where: { $0.id == id }) else { return }
        guard annotation.isTrackable else {
            message = "Only solid and pixelated redactions can be tracked. Blur can't hide content reliably."
            return
        }
        guard let rect = editor.editingView(annotation).redactionRect else { return }
        let visible = annotation.visibleRange ?? AnnotationTiming(start: 0, end: sourceDuration)
        let start = max(0, visible.start), end = min(sourceDuration, visible.end)
        guard end > start else {
            message = "Give the redaction a visible range inside the recording before tracking it."
            return
        }
        let anchorTime = min(max(editor.recordingTime, start), end)
        let request = RedactionTrackingRequest(anchorTime: anchorTime, anchorRect: rect, range: start...end)
        revision += 1
        let current = revision
        trackingID = id
        progress = 0
        message = "Tracking redaction…"
        let runTracker = runTracker
        task = Task { [weak self, weak editor] in
            let result: Result<RedactionTrack, Error>
            do {
                // A detached task doesn't inherit cancellation, so pass it on or the tracker keeps decoding.
                let worker = Task.detached(priority: .userInitiated) {
                    try await runTracker(request) { value in
                        Task { @MainActor [weak self] in
                            guard let self, self.revision == current else { return }
                            self.progress = max(self.progress, value)
                        }
                    }
                }
                let track = try await withTaskCancellationHandler { try await worker.value } onCancel: {
                    worker.cancel()
                }
                result = .success(track)
            } catch {
                result = .failure(error)
            }
            guard let self, self.revision == current else { return }
            self.trackingID = nil
            self.task = nil
            switch result {
            case .success(let track):
                guard !Task.isCancelled else { self.message = "Tracking cancelled."; return }
                editor?.applyTrack(track, to: id, anchorTime: anchorTime)
                let flagged = track.unresolvedIntervals(visibleRange: annotation.visibleRange,
                                                        sourceDuration: sourceDuration).count
                self.message = flagged == 0
                    ? "Tracked. Review the clip: you remain responsible for checking every frame."
                    : "Tracked with \(flagged) interval\(flagged == 1 ? "" : "s") to review before export."
            case .failure(is CancellationError):
                self.message = "Tracking cancelled."
            case .failure(let error):
                self.message = "Couldn't track the redaction: \(error.localizedDescription)"
            }
        }
    }

    /// Stops tracking; the redaction keeps whatever track it had before.
    func cancel() {
        guard isTracking else { return }
        revision += 1
        task?.cancel()
        task = nil
        trackingID = nil
        message = "Tracking cancelled."
    }

    func shutdown() {
        cancel()
        message = nil
    }

    // MARK: Review

    func loadFrameTimes() async {
        guard frameTimes.isEmpty else { return }
        let url = url
        let times = await Task.detached(priority: .utility) { (try? await Self.readFrameTimes(url)) ?? [] }.value
        frameTimes = times
    }

    /// The first frame after `time`, or nil at the end.
    func nextFrame(after time: TimeInterval) -> TimeInterval? {
        frameTimes.first { $0 > time + 1e-4 }
    }

    /// The last frame before `time`, or nil at the start.
    func previousFrame(before time: TimeInterval) -> TimeInterval? {
        frameTimes.last { $0 < time - 1e-4 }
    }

    /// The next flagged interval starting after `time`, wrapping to the first.
    static func nextFlagged(after time: TimeInterval,
                            in intervals: [UnresolvedRedactionInterval]) -> UnresolvedRedactionInterval? {
        intervals.first { $0.start > time + 1e-4 } ?? intervals.first
    }

    /// Reads presentation times without decoding frames.
    nonisolated static func readFrameTimes(_ url: URL) async throws -> [TimeInterval] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        defer { reader.cancelReading() }
        var times: [TimeInterval] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if time.isNumeric, CMSampleBufferGetNumSamples(sample) > 0 { times.append(time.seconds) }
        }
        return times.sorted()
    }
}
