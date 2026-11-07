import Foundation

/// The part of a recording that gets exported. Every mutation clamps, so the range is always valid:
/// within `0...sourceDuration` and at least `minimumDuration` long.
public struct RecordingTrim: Codable, Equatable, Sendable {
    /// Shortest range the editor allows. A recording shorter than this can only be exported whole.
    public static let minimumDuration: TimeInterval = 0.2

    public private(set) var sourceDuration: TimeInterval
    public private(set) var start: TimeInterval
    public private(set) var end: TimeInterval

    public init(sourceDuration: TimeInterval) {
        let duration = sourceDuration.isFinite ? max(sourceDuration, 0) : 0
        self.sourceDuration = duration
        start = 0
        end = duration
    }

    public var duration: TimeInterval { end - start }
    public var range: ClosedRange<TimeInterval> { start...end }
    public var isFullRange: Bool { start <= 0 && end >= sourceDuration }

    /// The effective lower bound on `duration` for this source.
    public var shortestDuration: TimeInterval { min(Self.minimumDuration, sourceDuration) }

    /// Moves the start handle; it can't pass the end handle minus the minimum duration.
    public mutating func setStart(_ value: TimeInterval) {
        guard value.isFinite else { return }
        start = min(max(value, 0), end - shortestDuration)
    }

    /// Moves the end handle; it can't pass the start handle plus the minimum duration.
    public mutating func setEnd(_ value: TimeInterval) {
        guard value.isFinite else { return }
        end = max(min(value, sourceDuration), start + shortestDuration)
    }

    /// Shortens the range from the end so it is at most `maxDuration` long. An explicit user action; never implicit.
    public mutating func limitDuration(to maxDuration: TimeInterval) {
        guard maxDuration.isFinite else { return }
        setEnd(min(end, start + max(maxDuration, shortestDuration)))
    }

    /// Adopts the duration measured from the file, keeping the current handles where they still fit.
    public mutating func setSourceDuration(_ value: TimeInterval) {
        guard value.isFinite, value > 0 else { return }
        let wasFull = isFullRange
        sourceDuration = value
        end = wasFull ? value : min(end, value)
        start = min(start, max(end - shortestDuration, 0))
    }

    private enum CodingKeys: String, CodingKey { case sourceDuration, start, end }

    /// Refuses a range the editor could never have produced instead of clamping it, so a damaged project is
    /// reported rather than silently exporting a different part of the clip.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let duration = try c.decode(TimeInterval.self, forKey: .sourceDuration)
        let start = try c.decode(TimeInterval.self, forKey: .start)
        let end = try c.decode(TimeInterval.self, forKey: .end)
        self.init(sourceDuration: duration)
        let tolerance = 1e-9
        // The ordering checks are exact; only the minimum length allows for rounding in the stored seconds.
        guard duration.isFinite, duration >= 0, start.isFinite, end.isFinite, 0 <= start, start <= end, end <= duration,
              end - start >= shortestDuration - tolerance else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Trim requires 0 <= start < end <= sourceDuration."))
        }
        self.start = start
        self.end = end
    }
}
