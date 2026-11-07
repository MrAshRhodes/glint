import Foundation

/// A stretch of a recording where a tracked redaction still needs the user's review.
public struct UnresolvedRedactionInterval: Equatable, Hashable, Sendable {
    public enum Reason: String, Sendable {
        /// The tracker lost the content or was unsure about it.
        case uncertainTracking
        /// The redaction is visible where tracking never ran.
        case outsideTrackedRange
        /// The track's data can't be used, so its whole visible range is suspect.
        case invalidTrack
        /// A tracked annotation is not Solid or Pixelate.
        case untrackableStyle
    }

    public var annotationID: UUID
    /// Half-open, in source seconds.
    public var start: TimeInterval
    public var end: TimeInterval
    public var reason: Reason

    public init(annotationID: UUID, start: TimeInterval, end: TimeInterval, reason: Reason) {
        self.annotationID = annotationID; self.start = start; self.end = end; self.reason = reason
    }

    public func contains(_ time: TimeInterval) -> Bool { time >= start && time < end }

    /// Whether any frame exported for `range` falls inside. Exporters render times in `lower..<upper`.
    public func intersects(_ range: ClosedRange<TimeInterval>) -> Bool {
        start < range.upperBound && end > range.lowerBound
    }
}

/// Decides whether tracked redactions are safe to export. One unredacted frame is enough to leak a secret, so
/// anything uncertain inside the trimmed range blocks Copy, Save, Share and drag until the user resolves it.
public enum RedactionGate {
    public static func unresolvedIntervals(in annotations: [Annotation],
                                           sourceDuration: TimeInterval) -> [UnresolvedRedactionInterval] {
        let duration = sourceDuration.isFinite && sourceDuration > 0 ? sourceDuration : 0
        var result: [UnresolvedRedactionInterval] = []
        for annotation in annotations {
            guard let track = annotation.track else { continue }
            let visible = clamp(annotation.visibleRange, duration: duration)
            guard visible.end > visible.start else { continue }
            if !annotation.isTrackable || !track.isValid {
                result.append(UnresolvedRedactionInterval(
                    annotationID: annotation.id, start: visible.start, end: visible.end,
                    reason: annotation.isTrackable ? .invalidTrack : .untrackableStyle))
                continue
            }
            let visibleTiming = AnnotationTiming(start: visible.start, end: visible.end)
            for interval in track.unresolvedIntervals(visibleRange: visibleTiming, sourceDuration: duration) {
                let start = max(interval.start, visible.start), end = min(interval.end, visible.end)
                guard end > start else { continue }
                let inside = track.analyzedRange.start <= interval.start && interval.end <= track.analyzedRange.end
                result.append(UnresolvedRedactionInterval(annotationID: annotation.id, start: start, end: end,
                                                          reason: inside ? .uncertainTracking : .outsideTrackedRange))
            }
        }
        return result.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// True when any interval would reach an exported frame of `range`.
    public static func blocksExport(_ intervals: [UnresolvedRedactionInterval],
                                    range: ClosedRange<TimeInterval>) -> Bool {
        intervals.contains { $0.intersects(range) }
    }

    /// Fails closed for renderers: throws when an unresolved interval covers `time`.
    /// Without a source duration, time after the analysed range of an untimed redaction counts as unresolved.
    public static func validate(_ annotations: [Annotation], at time: TimeInterval,
                                sourceDuration: TimeInterval? = nil) throws {
        let intervals = unresolvedIntervals(in: annotations, sourceDuration: sourceDuration ?? .greatestFiniteMagnitude)
        if intervals.contains(where: { $0.contains(time) }) || (!time.isFinite && !intervals.isEmpty) {
            throw RedactionGateError.unresolvedTracking
        }
    }

    private static func clamp(_ range: AnnotationTiming?, duration: TimeInterval) -> (start: TimeInterval, end: TimeInterval) {
        guard let range, range.isValid else { return (0, duration) }
        return (max(range.start, 0), min(range.end, duration))
    }
}

public enum RedactionGateError: LocalizedError, Equatable {
    case unresolvedTracking

    public var errorDescription: String? {
        "A tracked redaction has frames that still need review, so the recording was not exported."
    }
}
