import CoreGraphics
import Foundation

/// A finished screen recording handed from the capture layer to the recording editor.
///
/// `url` points at a uniquely named temporary `.mp4`. The capture layer owns the file until it
/// returns this value; from then on the recording editor owns it and deletes it when it closes.
///
/// A clip opened from a saved project lives inside the user's `.glint` package instead. It is created with
/// `deletesFileOnClose` false so closing the editor never removes the user's own file.
public struct RecordedVideo: Sendable, Equatable {
    public let url: URL
    public let duration: TimeInterval
    public let pixelSize: CGSize
    /// True for a temporary capture the editor must clean up; false for a file someone else owns.
    public let deletesFileOnClose: Bool

    public init(url: URL, duration: TimeInterval, pixelSize: CGSize, deletesFileOnClose: Bool = true) {
        self.url = url
        self.duration = duration
        self.pixelSize = pixelSize
        self.deletesFileOnClose = deletesFileOnClose
    }
}

/// Where a screen-recording session currently is, for menu and status reporting.
public enum RecordingPhase: Sendable, Equatable {
    case idle
    case selecting
    case ready
    case countdown(Int)
    case recording
    case finishing
}
