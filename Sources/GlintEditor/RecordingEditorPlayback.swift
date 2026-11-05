import AppKit
import AVFoundation
import Foundation

/// Plays the recording inside the trim range, on a loop, for the editor's preview.
///
/// Only the range between the trim handles plays: playback stops at the end handle and wraps to the start handle.
/// `shutdown()` must be called before the file is deleted.
@MainActor
final class RecordingPlayback: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var frameProblem: String?
    var onFrame: ((CGImage) -> Void)? {
        didSet { if onFrame != nil { requestFrame(at: currentTime) } }
    }

    private(set) var range: ClosedRange<TimeInterval>
    private let item: AVPlayerItem
    private var duration: TimeInterval
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isShutDown = false
    private let generator: AVAssetImageGenerator
    private var frameTask: Task<Void, Never>?
    private var pendingFrameTime: TimeInterval?
    private var seekRevision = 0

    init(url: URL, duration: TimeInterval) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        // A small forward tolerance supports variable-frame-rate recordings without showing an earlier frame.
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0 / 30, preferredTimescale: 600)
        item = AVPlayerItem(url: url)
        self.duration = duration
        range = 0...max(duration, 0)
        player.actionAtItemEnd = .pause
        player.replaceCurrentItem(with: item)
        applyEndTime()

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loop() }
        }
    }

    deinit {
        // `shutdown()` is the real teardown; this only keeps a forgotten player from leaking its observers.
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    /// Follows the trim handles. Moving the start handle shows the new first frame; moving the end handle shows the
    /// new last frame; anything else (a changed duration, say) just keeps the playhead inside the range.
    func apply(range newRange: ClosedRange<TimeInterval>, sourceDuration: TimeInterval) {
        guard !isShutDown, newRange != range || sourceDuration != duration else { return }
        let old = range
        range = newRange
        duration = sourceDuration
        applyEndTime()
        if newRange.lowerBound != old.lowerBound {
            seek(to: newRange.lowerBound)
        } else if newRange.upperBound != old.upperBound {
            seek(to: max(newRange.upperBound - 0.05, newRange.lowerBound))
        } else if !newRange.contains(currentTime) {
            seek(to: newRange.lowerBound)
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !isShutDown else { return }
        if currentTime < range.lowerBound || currentTime >= range.upperBound - 0.02 { seek(to: range.lowerBound) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// Moves the playhead to `seconds`, kept inside the trim range.
    func seek(to seconds: TimeInterval) {
        guard !isShutDown, seconds.isFinite else { return }
        let target = min(max(seconds, range.lowerBound), range.upperBound)
        seekRevision += 1
        currentTime = target
        requestFrame(at: target)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Stops playback and lets go of the file so it can be deleted.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        player.pause()
        isPlaying = false
        generator.cancelAllCGImageGeneration()
        frameTask?.cancel()
        frameTask = nil
        pendingFrameTime = nil
        onFrame = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    private func applyEndTime() {
        // Playing to the file's own end needs no limit, and a limit at the very end can make the last frame unreachable.
        item.forwardPlaybackEndTime = range.upperBound >= duration - 0.001
            ? .invalid
            : CMTime(seconds: range.upperBound, preferredTimescale: 600)
    }

    private func tick(_ seconds: TimeInterval) {
        guard !isShutDown, seconds.isFinite else { return }
        if isPlaying, seconds >= range.upperBound - 0.01 {
            loop()
        } else if player.rate != 0 || !isPlaying {
            currentTime = seconds
            requestFrame(at: seconds)
        }
    }

    private func loop() {
        guard !isShutDown, isPlaying else { return }
        seek(to: range.lowerBound)
        player.play()
    }

    /// There is only one extraction in flight. Playback replaces the pending time instead of queuing frames.
    private func requestFrame(at seconds: TimeInterval) {
        guard !isShutDown, onFrame != nil else { return }
        pendingFrameTime = min(max(0, seconds), max(0, duration - 1.0 / 600))
        guard frameTask == nil else { return }
        frameTask = Task { [weak self] in
            guard let self else { return }
            while let seconds = self.pendingFrameTime, !Task.isCancelled, !self.isShutDown {
                self.pendingFrameTime = nil
                let revision = self.seekRevision
                do {
                    let result = try await self.generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
                    guard !Task.isCancelled, !self.isShutDown else { break }
                    if revision == self.seekRevision {
                        self.frameProblem = nil
                        self.onFrame?(result.image)
                    }
                } catch {
                    guard !Task.isCancelled, !self.isShutDown else { break }
                    self.frameProblem = "Couldn't preview this recording: \(error.localizedDescription)"
                }
            }
            self.frameTask = nil
        }
    }
}
