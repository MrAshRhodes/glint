import Foundation

public enum RecordingExportError: LocalizedError, Equatable {
    case sourceMissing(String)
    case sourceUnreadable(String)
    case invalidRange(start: TimeInterval, end: TimeInterval, sourceDuration: TimeInterval)
    case rangeTooShort(minimum: TimeInterval)
    case unsupportedFrameRate(Int)
    case gifLimitExceeded(GIFLimitIssue)
    case frameUnavailable(time: TimeInterval, reason: String)
    case encodingFailed(String)
    case writeFailed(String)
    case exportSessionFailed(String)
    case pasteboardWriteFailed

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let name):
            return "The recording file “\(name)” is no longer available."
        case .sourceUnreadable(let reason):
            return "The recording can't be read: \(reason)"
        case .invalidRange(let start, let end, let duration):
            return "The selected range \(GIFLimits.format(seconds: start))–\(GIFLimits.format(seconds: end)) "
                + "doesn't fit inside the \(GIFLimits.format(seconds: duration)) recording."
        case .rangeTooShort(let minimum):
            return "The selected range is too short. Keep at least \(GIFLimits.format(seconds: minimum))."
        case .unsupportedFrameRate(let fps):
            return "\(fps) fps isn't a supported GIF frame rate. Choose \(GIFLimits.frameRates.map(String.init).joined(separator: ", ")) fps."
        case .gifLimitExceeded(let issue):
            return issue.message
        case .frameUnavailable(let time, let reason):
            return "Couldn't read the frame at \(GIFLimits.format(seconds: time)): \(reason)"
        case .encodingFailed(let reason):
            return "Couldn't encode the export: \(reason)"
        case .writeFailed(let reason):
            return "Couldn't write the file: \(reason)"
        case .exportSessionFailed(let reason):
            return "The video export failed: \(reason)"
        case .pasteboardWriteFailed:
            return "The clipboard didn't accept the recording."
        }
    }
}
