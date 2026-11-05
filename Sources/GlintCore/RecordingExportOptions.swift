import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// The container a recording is exported to.
public enum RecordingFileFormat: String, CaseIterable, Sendable, Equatable {
    case gif, mp4

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .gif: return "GIF"
        case .mp4: return "MP4"
        }
    }

    public var utType: UTType {
        switch self {
        case .gif: return .gif
        case .mp4: return .mpeg4Movie
        }
    }
}

/// Upper bound on a GIF's pixel width. Frames are never scaled up.
public enum GIFMaxWidth: String, CaseIterable, Sendable, Equatable {
    case w480, w640, w720, original

    public var displayName: String {
        switch self {
        case .w480: return "480 px"
        case .w640: return "640 px"
        case .w720: return "720 px"
        case .original: return "Original (max \(GIFLimits.originalWidthCap) px)"
        }
    }

    /// The widest the GIF may be, in pixels.
    public var pixelCap: Int {
        switch self {
        case .w480: return 480
        case .w640: return 640
        case .w720: return 720
        case .original: return GIFLimits.originalWidthCap
        }
    }

    /// Output size for a source of `size` pixels: aspect ratio kept, never larger than the source.
    public func outputSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 1, height: 1) }
        let width = min(CGFloat(pixelCap), size.width).rounded()
        let height = max((width * size.height / size.width).rounded(), 1)
        return CGSize(width: max(width, 1), height: height)
    }
}

public struct GIFExportOptions: Equatable, Sendable {
    public var framesPerSecond: Int
    public var maxWidth: GIFMaxWidth

    public init(framesPerSecond: Int = GIFLimits.defaultFrameRate, maxWidth: GIFMaxWidth = .w640) {
        self.framesPerSecond = framesPerSecond
        self.maxWidth = maxWidth
    }
}

public struct RecordingExportOptions: Equatable, Sendable {
    public var format: RecordingFileFormat
    public var gif: GIFExportOptions

    public init(format: RecordingFileFormat = .gif, gif: GIFExportOptions = GIFExportOptions()) {
        self.format = format
        self.gif = gif
    }
}

/// Why a trimmed range can't be exported as a GIF with the chosen options.
public struct GIFLimitIssue: Equatable, Sendable {
    public let duration: TimeInterval
    public let framesPerSecond: Int
    public let frameCount: Int
    public let maxDuration: TimeInterval

    /// Plain-language explanation that says what to change; shown inline and in export errors.
    public var message: String {
        let limit = GIFLimits.maxFrameCount
        return "This GIF would run \(GIFLimits.format(seconds: duration)) (\(frameCount) frames at \(framesPerSecond) fps), "
            + "but GIFs are limited to \(GIFLimits.format(seconds: maxDuration)) (\(limit) frames max) at \(framesPerSecond) fps. "
            + "Shorten the trim, lower the frame rate, or export MP4 instead."
    }
}

/// Hard limits that keep GIF exports small and the encoder's memory bounded. Nothing is truncated silently:
/// a range over the limit is reported as a `GIFLimitIssue` and the export is refused.
public enum GIFLimits {
    public static let frameRates = [10, 15, 20]
    public static let defaultFrameRate = 15
    public static let maxDuration: TimeInterval = 30
    public static let maxFrameCount = 450
    public static let originalWidthCap = 1280

    /// Rough bytes per pixel per frame of a GIF of screen content; only used for the size estimate.
    private static let estimatedBytesPerPixel = 0.08

    public static func isSupported(framesPerSecond: Int) -> Bool {
        frameRates.contains(framesPerSecond)
    }

    /// Frames a GIF of `duration` seconds gets at `framesPerSecond`; always at least one.
    public static func frameCount(duration: TimeInterval, framesPerSecond: Int) -> Int {
        guard duration.isFinite, duration > 0, framesPerSecond > 0 else { return 1 }
        return max(Int((duration * Double(framesPerSecond)).rounded()), 1)
    }

    /// The longest range that fits both the duration and the frame-count limits at `framesPerSecond`.
    public static func maxDuration(framesPerSecond: Int) -> TimeInterval {
        guard framesPerSecond > 0 else { return maxDuration }
        return min(maxDuration, Double(maxFrameCount) / Double(framesPerSecond))
    }

    /// Nil when `duration` can be exported with `options`.
    public static func issue(duration: TimeInterval, options: GIFExportOptions) -> GIFLimitIssue? {
        let limit = maxDuration(framesPerSecond: options.framesPerSecond)
        let frames = frameCount(duration: duration, framesPerSecond: options.framesPerSecond)
        guard duration > limit + 1e-6 || frames > maxFrameCount else { return nil }
        return GIFLimitIssue(duration: duration, framesPerSecond: options.framesPerSecond, frameCount: frames, maxDuration: limit)
    }

    /// Ballpark GIF size; real files vary a lot with how busy the screen is.
    public static func estimatedByteCount(duration: TimeInterval, options: GIFExportOptions, sourceSize: CGSize) -> Int {
        let size = options.maxWidth.outputSize(for: sourceSize)
        let frames = frameCount(duration: duration, framesPerSecond: options.framesPerSecond)
        return Int(Double(frames) * Double(size.width * size.height) * estimatedBytesPerPixel)
    }

    /// `12.3 s`, or `1:02.3` from a minute up.
    public static func format(seconds: TimeInterval) -> String {
        let value = max(seconds, 0)
        guard value >= 60 else { return String(format: "%.1f s", value) }
        let minutes = Int(value) / 60
        return String(format: "%d:%04.1f", minutes, value - Double(minutes * 60))
    }
}
