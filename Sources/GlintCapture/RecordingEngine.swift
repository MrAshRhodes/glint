import CoreGraphics
import Foundation
import GlintCore

/// Everything the engine needs to capture one region.
struct RecordingTarget: Sendable {
    let displayID: CGDirectDisplayID
    let geometry: RecordingGeometry
    let showsCursor: Bool
    /// Where the `.mp4` is written; deleted again unless the recording completes.
    let outputURL: URL
}

/// Something that happens to a running engine without the session asking for it.
enum RecordingEngineEvent: Sendable {
    /// Capture or encoding failed. The partial file stays until `discard()`.
    case failed(Error)
    /// macOS ended the stream (for example from the menu bar's screen-recording indicator).
    /// The footage so far is intact and can still be finished.
    case stoppedBySystem
}

/// The capture back end behind a `ScreenRecordingSession`; tests substitute a synthetic one.
protocol RecordingEngine: AnyObject, Sendable {
    func setEventHandler(_ handler: @escaping @Sendable (RecordingEngineEvent) -> Void)
    /// Starts capturing. Throws `CaptureError` and leaves no file behind.
    func start() async throws
    /// Stops capturing and closes the file.
    func finish() async throws -> RecordedVideo
    /// Stops capturing and deletes the partial file. Safe to call at any time, also more than once.
    func discard() async
}
