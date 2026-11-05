import CoreGraphics
import Foundation

/// A finished screen recording handed from the capture layer to the recording editor.
///
/// `url` points at a uniquely named temporary `.mp4`. The capture layer owns the file until it
/// returns this value; from then on the recording editor owns it and deletes it when it closes.
public struct RecordedVideo: Sendable, Equatable {
    public let url: URL
    public let duration: TimeInterval
    public let pixelSize: CGSize

    public init(url: URL, duration: TimeInterval, pixelSize: CGSize) {
        self.url = url
        self.duration = duration
        self.pixelSize = pixelSize
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
