import CoreGraphics
import Foundation

/// A redaction position at one moment of a recording, in oriented source pixels with a top-left origin.
public struct RedactionKeyframe: Codable, Equatable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Found by the tracker on a decoded frame. Its time is that frame's presentation time, and the frame stays
        /// on screen until the next one, so the rect is held rather than interpolated away.
        case tracked
        /// Placed by the user at the playhead; positions between manual keyframes are interpolated.
        case manual
    }

    public var time: TimeInterval
    public var rect: CGRect
    public var source: Source

    public init(time: TimeInterval, rect: CGRect, source: Source) {
        self.time = time
        self.rect = rect.standardized
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case time, rect, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(time: try c.decode(TimeInterval.self, forKey: .time),
                  rect: try c.decode(CGRect.self, forKey: .rect),
                  source: try c.decodeIfPresent(Source.self, forKey: .source) ?? .manual)
    }

    var isValid: Bool { time.isFinite && rect.isFiniteRect }
}

/// Part of a tracked redaction's range where tracking was lost or unsure. Half-open, in source seconds.
public struct RedactionUncertainInterval: Codable, Equatable, Hashable, Sendable {
    public enum Resolution: String, Codable, Sendable {
        /// The user accepted the generous fail-safe cover for the whole interval.
        case fixedCover
        /// The user placed manual keyframes inside the interval and reviewed it.
        case keyframes
    }

    public var start: TimeInterval
    public var end: TimeInterval
    /// The last position the tracker was sure of, which the fail-safe cover grows from.
    public var anchorTime: TimeInterval
    public var anchorRect: CGRect
    /// `nil` while unresolved: the clip can't be exported while an unresolved interval is inside the trim.
    public var resolution: Resolution?

    public init(start: TimeInterval, end: TimeInterval, anchorTime: TimeInterval, anchorRect: CGRect,
                resolution: Resolution? = nil) {
        self.start = start; self.end = end
        self.anchorTime = anchorTime; self.anchorRect = anchorRect.standardized
        self.resolution = resolution
    }

    private enum CodingKeys: String, CodingKey { case start, end, anchorTime, anchorRect, resolution }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(start: try c.decode(TimeInterval.self, forKey: .start),
                  end: try c.decode(TimeInterval.self, forKey: .end),
                  anchorTime: try c.decode(TimeInterval.self, forKey: .anchorTime),
                  anchorRect: try c.decode(CGRect.self, forKey: .anchorRect),
                  resolution: try c.decodeIfPresent(Resolution.self, forKey: .resolution))
    }

    public var isResolved: Bool { resolution != nil }

    public func contains(_ time: TimeInterval) -> Bool { time >= start && time < end }

    var isValid: Bool {
        start.isFinite && end.isFinite && end > start && anchorTime.isFinite && anchorRect.isFiniteRect
    }
}

/// How a redaction follows moving content: keyframes, the intervals tracking was unsure about, and the range that
/// was analysed. Times are source-recording seconds, independent of the trim.
///
/// Rendering always errs towards covering too much. Between keyframes it covers every position the content could
/// occupy on the frame actually shown (see `coverRect(at:)`), and inside an uncertain interval or outside the
/// analysed range it falls back to `FailSafeCover`. A redaction is never missing from a frame in its range.
public struct RedactionTrack: Codable, Equatable, Hashable, Sendable {
    /// Sorted by time.
    public private(set) var keyframes: [RedactionKeyframe]
    /// Sorted by start; never overlapping.
    public private(set) var uncertainIntervals: [RedactionUncertainInterval]
    /// The source seconds the tracker examined. Visible time outside it counts as uncertain.
    public var analyzedRange: AnnotationTiming
    /// The oriented source frame, used to clamp fail-safe covers.
    public var frameBounds: CGRect

    /// How far a displayed frame can be from the time it is rendered for: the editor preview accepts a frame up to
    /// 1/30 s after the requested time, and every exporter is exact. A little extra absorbs timestamp rounding.
    public static let frameTolerance: TimeInterval = 1.0 / 30 + 0.002
    /// Extra pixels around every tracked position.
    public static let padding: CGFloat = 2
    /// Most keyframes a track read from a project may hold. A 10-minute recording at 30 fps yields about 18,000, so
    /// this leaves room for any real clip while keeping a damaged or hostile project from flooding the timeline.
    public static let maxKeyframes = 100_000
    /// Most uncertain intervals a track read from a project may hold. Tracking stops at its first loss in each
    /// direction and the user resolves what lies outside the analysed range, so real tracks hold only a handful.
    public static let maxUncertainIntervals = 1_000

    public init(keyframes: [RedactionKeyframe], uncertainIntervals: [RedactionUncertainInterval] = [],
                analyzedRange: AnnotationTiming, frameBounds: CGRect) {
        self.keyframes = keyframes.sorted { $0.time < $1.time }
        self.uncertainIntervals = uncertainIntervals.sorted { $0.start < $1.start }
        self.analyzedRange = analyzedRange
        self.frameBounds = frameBounds.standardized
    }

    private enum CodingKeys: String, CodingKey { case keyframes, uncertainIntervals, analyzedRange, frameBounds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let keyframes = try c.decodeIfPresent([RedactionKeyframe].self, forKey: .keyframes) ?? []
        let intervals = try c.decodeIfPresent([RedactionUncertainInterval].self, forKey: .uncertainIntervals) ?? []
        // Oversized tracks are refused outright. Merely malformed ones still decode, and `isValid` then fails
        // closed (whole-frame cover, export blocked) so the user can see and repair them.
        guard keyframes.count <= Self.maxKeyframes, intervals.count <= Self.maxUncertainIntervals else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "A redaction track has too many entries."))
        }
        self.init(keyframes: keyframes, uncertainIntervals: intervals,
                  analyzedRange: try c.decode(AnnotationTiming.self, forKey: .analyzedRange),
                  frameBounds: try c.decodeIfPresent(CGRect.self, forKey: .frameBounds) ?? .null)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keyframes, forKey: .keyframes)
        try c.encode(uncertainIntervals, forKey: .uncertainIntervals)
        try c.encode(analyzedRange, forKey: .analyzedRange)
        // A track that lost its bounds holds `.null`, which JSON can't represent. It is invalid and blocks export;
        // leaving the bounds out keeps it saveable, and it decodes back to that same blocked state.
        if frameBounds.isFiniteRect { try c.encode(frameBounds, forKey: .frameBounds) }
    }

    /// False when the data can't be trusted to place the redaction; such tracks block export.
    public var isValid: Bool {
        guard !keyframes.isEmpty, keyframes.allSatisfy(\.isValid), analyzedRange.isValid,
              frameBounds.isFiniteRect, frameBounds.width > 0, frameBounds.height > 0,
              uncertainIntervals.allSatisfy(\.isValid) else { return false }
        return zip(uncertainIntervals, uncertainIntervals.dropFirst()).allSatisfy { $0.end <= $1.start }
    }

    // MARK: Positions

    /// The plain interpolated position at `time`, without any safety margin. The canvas edits this rect.
    public func editingRect(at time: TimeInterval) -> CGRect {
        interpolated(at: time)
    }

    /// The area to cover at `time`. Always contains `editingRect(at:)` for the frames that can be on screen.
    public func coverRect(at time: TimeInterval) -> CGRect {
        guard isValid, time.isFinite else { return frameBounds.isFiniteRect ? frameBounds : .null }
        var cover = baseCover(at: time)
        // The preview may show a frame up to `frameTolerance` later, which can already be inside the next interval.
        let ahead = time + Self.frameTolerance
        for interval in intervals(visibleRange: nil, sourceDuration: nil) where interval.start > time && interval.start <= ahead {
            cover = cover.union(baseCover(at: interval.start))
        }
        return cover
    }

    private func baseCover(at time: TimeInterval) -> CGRect {
        if let interval = interval(containing: time) {
            switch interval.resolution {
            case nil:
                return FailSafeCover.rect(anchor: interval.anchorRect, elapsed: abs(time - interval.anchorTime),
                                          bounds: frameBounds)
            case .fixedCover?:
                return FailSafeCover.fixedRect(for: interval, bounds: frameBounds)
            case .keyframes?:
                break
            }
        }
        return keyframeCover(at: time)
    }

    /// Covers every position from the frame that may still be held on screen (the last tracked sample) up to the
    /// latest frame the preview may show instead, so VFR holds and preview tolerance never expose content.
    private func keyframeCover(at time: TimeInterval) -> CGRect {
        var lower = time - Self.frameTolerance
        let upper = time + Self.frameTolerance
        if let previous = keyframes.last(where: { $0.time <= time }), previous.source == .tracked {
            lower = min(lower, previous.time)
        }
        var cover = interpolated(at: lower).union(interpolated(at: upper))
        for keyframe in keyframes where keyframe.time >= lower && keyframe.time <= upper {
            cover = cover.union(keyframe.rect)
        }
        return cover.insetBy(dx: -Self.padding, dy: -Self.padding)
    }

    private func interpolated(at time: TimeInterval) -> CGRect {
        guard let first = keyframes.first, let last = keyframes.last else { return .null }
        if time <= first.time { return first.rect }
        if time >= last.time { return last.rect }
        guard let index = keyframes.firstIndex(where: { $0.time > time }), index > 0 else { return last.rect }
        let a = keyframes[index - 1], b = keyframes[index]
        let span = b.time - a.time
        guard span > 0 else { return b.rect }
        let u = CGFloat((time - a.time) / span)
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * u }
        return CGRect(x: mix(a.rect.minX, b.rect.minX), y: mix(a.rect.minY, b.rect.minY),
                      width: mix(a.rect.width, b.rect.width), height: mix(a.rect.height, b.rect.height))
    }

    // MARK: Intervals

    /// The explicit or implied interval `time` falls in, if any.
    public func interval(containing time: TimeInterval) -> RedactionUncertainInterval? {
        intervals(visibleRange: nil, sourceDuration: nil).first { $0.contains(time) }
    }

    /// Explicit uncertain intervals plus the implied ones where the visible range reaches outside `analyzedRange`.
    /// Without a visible range, the implied intervals extend without limit on either side.
    public func intervals(visibleRange: AnnotationTiming?, sourceDuration: TimeInterval?) -> [RedactionUncertainInterval] {
        let lower = visibleRange?.start ?? (sourceDuration == nil ? -.greatestFiniteMagnitude : 0)
        let upper = visibleRange?.end ?? sourceDuration ?? .greatestFiniteMagnitude
        var implied: [RedactionUncertainInterval] = []
        if let first = keyframes.first, lower < analyzedRange.start {
            implied.append(RedactionUncertainInterval(start: lower, end: min(upper, analyzedRange.start),
                                                      anchorTime: first.time, anchorRect: first.rect))
        }
        if let last = keyframes.last, upper > analyzedRange.end {
            implied.append(RedactionUncertainInterval(start: max(lower, analyzedRange.end), end: upper,
                                                      anchorTime: last.time, anchorRect: last.rect))
        }
        let gaps = implied.filter { $0.end > $0.start }.flatMap { subtracting(uncertainIntervals, from: $0) }
        return (uncertainIntervals + gaps).sorted { $0.start < $1.start }
    }

    private func subtracting(_ taken: [RedactionUncertainInterval],
                             from interval: RedactionUncertainInterval) -> [RedactionUncertainInterval] {
        var pieces = [interval]
        for used in taken {
            pieces = pieces.flatMap { piece -> [RedactionUncertainInterval] in
                guard used.start < piece.end, used.end > piece.start else { return [piece] }
                var result: [RedactionUncertainInterval] = []
                if piece.start < used.start { var left = piece; left.end = used.start; result.append(left) }
                if used.end < piece.end { var right = piece; right.start = used.end; result.append(right) }
                return result
            }
        }
        return pieces
    }

    /// Unresolved intervals overlapping the visible range.
    public func unresolvedIntervals(visibleRange: AnnotationTiming?, sourceDuration: TimeInterval) -> [RedactionUncertainInterval] {
        intervals(visibleRange: visibleRange, sourceDuration: sourceDuration).filter { !$0.isResolved }
    }

    // MARK: Editing

    /// Adds or replaces the manual keyframe at `time`. Only the user's position counts at that moment.
    public mutating func setManualKeyframe(at time: TimeInterval, rect: CGRect) {
        guard time.isFinite, rect.isFiniteRect else { return }
        keyframes.removeAll { abs($0.time - time) < Self.keyframeMergeDistance }
        keyframes.append(RedactionKeyframe(time: time, rect: rect, source: .manual))
        keyframes.sort { $0.time < $1.time }
    }

    /// Removes the keyframe nearest `time` within half a frame, keeping at least one.
    @discardableResult
    public mutating func removeKeyframe(near time: TimeInterval) -> Bool {
        guard keyframes.count > 1,
              let index = keyframes.indices.min(by: { abs(keyframes[$0].time - time) < abs(keyframes[$1].time - time) }),
              abs(keyframes[index].time - time) <= Self.frameTolerance / 2 else { return false }
        keyframes.remove(at: index)
        return true
    }

    static let keyframeMergeDistance: TimeInterval = 0.0005

    /// Manual keyframes inside `interval`.
    public func manualKeyframes(in interval: RedactionUncertainInterval) -> [RedactionKeyframe] {
        keyframes.filter { $0.source == .manual && interval.contains($0.time) }
    }

    /// Resolves the interval containing `time`. `.keyframes` requires at least one manual keyframe inside it, so a
    /// lost track can't be waved through without the user placing the redaction themselves.
    @discardableResult
    public mutating func resolveInterval(containing time: TimeInterval, as resolution: RedactionUncertainInterval.Resolution,
                                         visibleRange: AnnotationTiming?, sourceDuration: TimeInterval) -> Bool {
        guard var interval = intervals(visibleRange: visibleRange, sourceDuration: sourceDuration)
            .first(where: { $0.contains(time) }) else { return false }
        if resolution == .keyframes, manualKeyframes(in: interval).isEmpty { return false }
        interval.resolution = resolution
        if let index = uncertainIntervals.firstIndex(where: { $0.start == interval.start && $0.end == interval.end }) {
            uncertainIntervals[index] = interval
        } else {
            uncertainIntervals.append(interval)
            uncertainIntervals.sort { $0.start < $1.start }
        }
        return true
    }

    /// Marks the interval containing `time` unresolved again.
    @discardableResult
    public mutating func reopenInterval(containing time: TimeInterval) -> Bool {
        guard let index = uncertainIntervals.firstIndex(where: { $0.contains(time) }),
              uncertainIntervals[index].isResolved else { return false }
        if analyzedRange.start <= uncertainIntervals[index].start && uncertainIntervals[index].end <= analyzedRange.end {
            uncertainIntervals[index].resolution = nil
        } else {
            // An implied interval outside the analysed range returns to being implied.
            uncertainIntervals.remove(at: index)
        }
        return true
    }
}

/// The generous area covered while tracking is unsure: twice the last known rect, plus padding that grows the longer
/// the content may have been moving, clamped to the frame. It never shrinks over an interval.
public enum FailSafeCover {
    /// Base padding in pixels around the doubled rect.
    public static let basePadding: CGFloat = 8
    /// Extra padding per second, as a multiple of the rect's longer side.
    public static let growthPerSecond: CGFloat = 1
    /// Minimum extra padding per second, as a fraction of the frame's longer side, so small rects
    /// still outgrow content moving quickly across the screen.
    public static let minimumFrameGrowthPerSecond: CGFloat = 0.3

    public static func rect(anchor: CGRect, elapsed: TimeInterval, bounds: CGRect) -> CGRect {
        let a = anchor.standardized
        guard a.isFiniteRect, elapsed.isFinite else { return bounds.isFiniteRect ? bounds : a }
        let side = max(a.width, a.height, 1)
        let frameSide = bounds.isFiniteRect ? max(bounds.width, bounds.height) : 0
        let speed = max(side * growthPerSecond, frameSide * minimumFrameGrowthPerSecond)
        let grow = basePadding + speed * CGFloat(max(elapsed, 0))
        guard grow.isFinite, grow < 1e7 else { return bounds.isFiniteRect && !bounds.isEmpty ? bounds : a }
        let cover = a.insetBy(dx: -a.width / 2 - grow, dy: -a.height / 2 - grow)
        guard bounds.isFiniteRect, !bounds.isEmpty else { return cover }
        let clamped = cover.intersection(bounds)
        return clamped.isNull || clamped.isEmpty ? cover : clamped
    }

    /// The largest cover reached anywhere in `interval`; used when the user accepts a fixed cover.
    public static func fixedRect(for interval: RedactionUncertainInterval, bounds: CGRect) -> CGRect {
        let elapsed = max(abs(interval.start - interval.anchorTime), abs(interval.end - interval.anchorTime))
        return rect(anchor: interval.anchorRect, elapsed: elapsed, bounds: bounds)
    }
}

extension CGRect {
    var isFiniteRect: Bool {
        !isNull && origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
            && size.width >= 0 && size.height >= 0
    }
}

extension Annotation {
    /// Only opaque redactions can follow content. Blur derives from the source pixels and is not a safe redaction.
    public var isTrackable: Bool { isRedaction }

    /// The rect of a redaction-style annotation.
    public var redactionRect: CGRect? {
        switch kind {
        case .redact(let r), .pixelate(let r), .blur(let r): return r
        default: return nil
        }
    }

    /// The annotation as drawn at `time`: a tracked redaction moves to its cover rect, everything else is unchanged.
    /// An invalid track or timestamp covers the whole frame instead of risking a gap.
    public func resolved(at time: TimeInterval) -> Annotation {
        guard let track, let rect = redactionRect else { return self }
        var cover = track.coverRect(at: time)
        if cover.isNull || !cover.isFiniteRect { cover = rect }
        return withRedactionRect(cover)
    }

    /// The annotation positioned for editing at `time`, without the safety margin added for rendering.
    public func editingView(at time: TimeInterval) -> Annotation {
        guard let track, track.isValid, redactionRect != nil else { return self }
        return withRedactionRect(track.editingRect(at: time))
    }

    /// A copy with the redaction rect replaced; other annotations are returned unchanged.
    public func withRedactionRect(_ rect: CGRect) -> Annotation {
        var copy = self
        switch kind {
        case .redact: copy.kind = .redact(rect)
        case .pixelate: copy.kind = .pixelate(rect)
        case .blur: copy.kind = .blur(rect)
        default: break
        }
        return copy
    }
}
