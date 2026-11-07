import CoreGraphics
import Foundation

// Presentation tools for screen recordings (#81): pointer and click data recorded next to the video, and the
// editable effects drawn from it. Every time is in source-recording seconds, like `AnnotationTiming`, so trimming
// never rewrites the data; every position is in source video pixels with a top-left origin.

/// Where the pointer was at one moment of a recording.
public struct PointerSample: Codable, Equatable, Hashable, Sendable {
    public var time: TimeInterval
    public var position: CGPoint

    public init(time: TimeInterval, position: CGPoint) {
        self.time = time
        self.position = position
    }
}

/// The pointer's path through a recording, ordered by time.
///
/// Encoded as flat `[time, x, y]` triples because a ten-minute clip polled at 60 Hz holds tens of thousands of
/// samples; stationary runs are already collapsed to their two end points by `appending(_:)`.
public struct PointerTrack: Codable, Equatable, Sendable {
    public private(set) var samples: [PointerSample]

    public init(samples: [PointerSample] = []) {
        self.samples = samples.filter { $0.time.isFinite && $0.position.x.isFinite && $0.position.y.isFinite }
            .sorted { $0.time < $1.time }
    }

    public var isEmpty: Bool { samples.isEmpty }

    /// Adds a later sample. A sample that repeats the last two positions only moves the end of that still run
    /// forward, which keeps interpolation exact while storing a still pointer as two samples.
    public mutating func append(_ sample: PointerSample) {
        guard sample.time.isFinite, sample.position.x.isFinite, sample.position.y.isFinite else { return }
        if let last = samples.last, sample.time <= last.time { return }
        let count = samples.count
        if count >= 2, samples[count - 1].position == sample.position, samples[count - 2].position == sample.position {
            samples[count - 1].time = sample.time
        } else {
            samples.append(sample)
        }
    }

    /// The interpolated pointer position, or nil before the first or after the last sample (the pointer was not
    /// tracked then, so nothing is drawn rather than guessing).
    public func position(at time: TimeInterval) -> CGPoint? {
        guard time.isFinite, let first = samples.first, let last = samples.last,
              time >= first.time, time <= last.time else { return nil }
        var low = 0, high = samples.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if samples[mid].time <= time { low = mid } else { high = mid }
        }
        let a = samples[low], b = samples[high]
        guard b.time > a.time else { return a.position }
        let f = CGFloat((time - a.time) / (b.time - a.time))
        return CGPoint(x: a.position.x + (b.position.x - a.position.x) * f,
                       y: a.position.y + (b.position.y - a.position.y) * f)
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var samples: [PointerSample] = []
        while !container.isAtEnd {
            let triple = try container.decode([Double].self)
            guard triple.count == 3 else {
                throw DecodingError.dataCorruptedError(in: container,
                                                       debugDescription: "A pointer sample needs [time, x, y].")
            }
            samples.append(PointerSample(time: triple[0], position: CGPoint(x: triple[1], y: triple[2])))
        }
        self.init(samples: samples)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for sample in samples {
            try container.encode([sample.time, Double(sample.position.x), Double(sample.position.y)])
        }
    }
}

public enum PointerButton: String, Codable, Sendable, CaseIterable {
    case left, right
}

/// One mouse-button press seen during the recording.
public struct ClickEvent: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var time: TimeInterval
    public var position: CGPoint
    public var button: PointerButton

    public init(id: UUID = UUID(), time: TimeInterval, position: CGPoint, button: PointerButton = .left) {
        self.id = id
        self.time = time
        self.position = position
        self.button = button
    }

    private enum CodingKeys: String, CodingKey { case id, time, position, button }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  time: try c.decode(TimeInterval.self, forKey: .time),
                  position: try c.decode(CGPoint.self, forKey: .position),
                  button: try c.decodeIfPresent(PointerButton.self, forKey: .button) ?? .left)
    }
}

/// What Glint recorded about the pointer alongside a video. It stays in memory unless explicitly saved in
/// an editable project; nothing is written next to an exported clip.
public struct PresentationCapture: Codable, Equatable, Sendable {
    public var pointer: PointerTrack
    public var clicks: [ClickEvent]
    /// True when ScreenCaptureKit drew the system pointer into the frames (the default). Then the pointer can be
    /// emphasised but not enlarged or hidden, because it is part of the footage.
    public var pointerIsBaked: Bool
    /// Video pixels per screen point, so a drawn pointer matches the size of the real one.
    public var pointerScale: Double

    public init(pointer: PointerTrack = PointerTrack(), clicks: [ClickEvent] = [], pointerIsBaked: Bool = true,
                pointerScale: Double = 1) {
        self.pointer = pointer
        self.clicks = clicks.sorted { $0.time < $1.time }
        self.pointerIsBaked = pointerIsBaked
        self.pointerScale = pointerScale.isFinite && pointerScale > 0 ? pointerScale : 1
    }

    private enum CodingKeys: String, CodingKey { case pointer, clicks, pointerIsBaked, pointerScale }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(pointer: try c.decodeIfPresent(PointerTrack.self, forKey: .pointer) ?? PointerTrack(),
                  clicks: try c.decodeIfPresent([ClickEvent].self, forKey: .clicks) ?? [],
                  pointerIsBaked: try c.decodeIfPresent(Bool.self, forKey: .pointerIsBaked) ?? true,
                  pointerScale: try c.decodeIfPresent(Double.self, forKey: .pointerScale) ?? 1)
    }
}

/// How clicks are highlighted. Off by default.
public struct ClickHighlightStyle: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var leftColor: RGBAColor
    public var rightColor: RGBAColor
    /// Final ring radius in source video pixels.
    public var size: Double
    /// How long each ripple lasts, in seconds.
    public var duration: TimeInterval
    /// Clicks the user removed individually; kept as ids so the recorded data itself never changes.
    public var removed: Set<UUID>

    public static let defaultLeftColor = RGBAColor(r: 1, g: 0.78, b: 0.1)
    public static let defaultRightColor = RGBAColor(r: 0.36, g: 0.55, b: 1)
    public static let sizeRange: ClosedRange<Double> = 12...200
    public static let durationRange: ClosedRange<TimeInterval> = 0.2...2

    public init(enabled: Bool = false, leftColor: RGBAColor = ClickHighlightStyle.defaultLeftColor,
                rightColor: RGBAColor = ClickHighlightStyle.defaultRightColor, size: Double = 40,
                duration: TimeInterval = 0.6, removed: Set<UUID> = []) {
        self.enabled = enabled
        self.leftColor = leftColor
        self.rightColor = rightColor
        self.size = size.isFinite ? min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound) : 40
        self.duration = duration.isFinite
            ? min(max(duration, Self.durationRange.lowerBound), Self.durationRange.upperBound) : 0.6
        self.removed = removed
    }

    private enum CodingKeys: String, CodingKey { case enabled, leftColor, rightColor, size, duration, removed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
                  leftColor: try c.decodeIfPresent(RGBAColor.self, forKey: .leftColor) ?? Self.defaultLeftColor,
                  rightColor: try c.decodeIfPresent(RGBAColor.self, forKey: .rightColor) ?? Self.defaultRightColor,
                  size: try c.decodeIfPresent(Double.self, forKey: .size) ?? 40,
                  duration: try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0.6,
                  removed: try c.decodeIfPresent(Set<UUID>.self, forKey: .removed) ?? [])
    }
}

/// Pointer emphasis. The default draws nothing extra.
public struct CursorEmphasis: Codable, Equatable, Sendable {
    /// Size of a drawn (editable) pointer relative to the real one. Ignored for a baked pointer.
    public var scale: Double
    /// Hides a drawn pointer for the whole clip. Ignored for a baked pointer.
    public var hidden: Bool
    public var halo: Bool
    public var haloColor: RGBAColor
    public var spotlight: Bool
    /// Halo and spotlight radius in source video pixels.
    public var radius: Double

    public static let scaleRange: ClosedRange<Double> = 1...4
    public static let radiusRange: ClosedRange<Double> = 16...400
    public static let defaultHaloColor = RGBAColor(r: 1, g: 0.85, b: 0.1, a: 0.4)

    public init(scale: Double = 1, hidden: Bool = false, halo: Bool = false,
                haloColor: RGBAColor = CursorEmphasis.defaultHaloColor, spotlight: Bool = false, radius: Double = 48) {
        self.scale = scale.isFinite ? min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound) : 1
        self.hidden = hidden
        self.halo = halo
        self.haloColor = haloColor
        self.spotlight = spotlight
        self.radius = radius.isFinite
            ? min(max(radius, Self.radiusRange.lowerBound), Self.radiusRange.upperBound) : 48
    }

    private enum CodingKeys: String, CodingKey { case scale, hidden, halo, haloColor, spotlight, radius }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(scale: try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1,
                  hidden: try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false,
                  halo: try c.decodeIfPresent(Bool.self, forKey: .halo) ?? false,
                  haloColor: try c.decodeIfPresent(RGBAColor.self, forKey: .haloColor) ?? Self.defaultHaloColor,
                  spotlight: try c.decodeIfPresent(Bool.self, forKey: .spotlight) ?? false,
                  radius: try c.decodeIfPresent(Double.self, forKey: .radius) ?? 48)
    }
}

/// A timed full-frame zoom: the frame eases into `rect`, holds it and eases back out.
public struct ZoomSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    /// The area to fill the frame with, in source video pixels (top-left origin). Its aspect ratio is corrected
    /// to the frame's when drawn, so the picture is never stretched.
    public var rect: CGRect
    /// Length of each ease, capped at half the segment.
    public var ease: TimeInterval

    public static let defaultEase: TimeInterval = 0.4
    /// Shortest segment the editor creates or keeps.
    public static let minimumDuration: TimeInterval = 0.1
    /// Narrowest area as a fraction of the frame: at most 8× zoom.
    public static let minimumAreaFraction: CGFloat = 1.0 / 8

    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, rect: CGRect,
                ease: TimeInterval = ZoomSegment.defaultEase) {
        self.id = id
        self.start = start
        self.end = end
        self.rect = rect
        self.ease = ease.isFinite ? max(ease, 0) : Self.defaultEase
    }

    private enum CodingKeys: String, CodingKey { case id, start, end, rect, ease }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  start: try c.decode(TimeInterval.self, forKey: .start),
                  end: try c.decode(TimeInterval.self, forKey: .end),
                  rect: try c.decode(CGRect.self, forKey: .rect),
                  ease: try c.decodeIfPresent(TimeInterval.self, forKey: .ease) ?? Self.defaultEase)
        guard start.isFinite, end.isFinite, start >= 0, end > start else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "A zoom needs finite times with 0 <= start < end."))
        }
    }

    public func contains(_ time: TimeInterval) -> Bool { time >= start && time < end }

    /// 0 outside the segment, 1 while holding, smoothly in between. Trimming may start an export mid-ease; it then
    /// simply begins part way in.
    public func amount(at time: TimeInterval) -> Double {
        guard time.isFinite, contains(time) else { return 0 }
        let ramp = min(ease, (end - start) / 2)
        guard ramp > 0 else { return 1 }
        let progress = min((time - start) / ramp, (end - time) / ramp, 1)
        return progress * progress * (3 - 2 * progress)
    }

    /// The area actually shown at full zoom: `rect` grown to the frame's aspect ratio, at least
    /// `minimumAreaFraction` of the frame, and shifted inside it.
    public static func fitted(_ rect: CGRect, in frame: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return CGRect(origin: .zero, size: frame) }
        let r = rect.standardized
        let aspect = frame.width / frame.height
        var w = r.width.isFinite ? max(r.width, frame.width * minimumAreaFraction) : frame.width
        var h = r.height.isFinite ? max(r.height, frame.height * minimumAreaFraction) : frame.height
        if w / h < aspect { w = h * aspect } else { h = w / aspect }
        if w > frame.width { w = frame.width; h = w / aspect }
        if h > frame.height { h = frame.height; w = h * aspect }
        let cx = r.midX.isFinite ? r.midX : frame.width / 2, cy = r.midY.isFinite ? r.midY : frame.height / 2
        let x = min(max(cx - w / 2, 0), frame.width - w)
        let y = min(max(cy - h / 2, 0), frame.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The visible part of the frame at `time`, or nil when this segment does not zoom then.
    public func viewport(at time: TimeInterval, sourceSize: CGSize) -> CGRect? {
        let t = CGFloat(amount(at: time))
        guard t > 0, sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let full = CGRect(origin: .zero, size: sourceSize)
        let target = Self.fitted(rect, in: sourceSize)
        // Interpolating the scale geometrically keeps the zoom speed even; the centre follows linearly.
        let zoom = pow(sourceSize.width / target.width, t)
        let w = sourceSize.width / zoom, h = sourceSize.height / zoom
        let cx = full.midX + (target.midX - full.midX) * t, cy = full.midY + (target.midY - full.midY) * t
        let x = min(max(cx - w / 2, 0), sourceSize.width - w)
        let y = min(max(cy - h / 2, 0), sourceSize.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// The editable presentation effects of one recording. The default is inert: it changes no pixel.
public struct PresentationSettings: Codable, Equatable, Sendable {
    public var clicks: ClickHighlightStyle
    public var cursor: CursorEmphasis
    public var zooms: [ZoomSegment]

    public init(clicks: ClickHighlightStyle = ClickHighlightStyle(), cursor: CursorEmphasis = CursorEmphasis(),
                zooms: [ZoomSegment] = []) {
        self.clicks = clicks
        self.cursor = cursor
        self.zooms = zooms
    }

    private enum CodingKeys: String, CodingKey { case clicks, cursor, zooms }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(clicks: try c.decodeIfPresent(ClickHighlightStyle.self, forKey: .clicks) ?? ClickHighlightStyle(),
                  cursor: try c.decodeIfPresent(CursorEmphasis.self, forKey: .cursor) ?? CursorEmphasis(),
                  zooms: try c.decodeIfPresent([ZoomSegment].self, forKey: .zooms) ?? [])
    }

    /// The zoomed-in part of a `sourceSize` frame at `time`, or nil for the whole frame. Where segments overlap
    /// the one that started last wins.
    public func viewport(at time: TimeInterval, sourceSize: CGSize) -> CGRect? {
        zooms.filter { $0.contains(time) }.max { $0.start < $1.start }?
            .viewport(at: time, sourceSize: sourceSize)
    }
}

/// Everything the compositor needs to draw presentation effects for a recording frame.
public struct Presentation: Codable, Equatable, Sendable {
    /// Nil when nothing was recorded (an older recording, or pointer tracking was unavailable); zoom still works.
    public var capture: PresentationCapture?
    public var settings: PresentationSettings

    public init(capture: PresentationCapture? = nil, settings: PresentationSettings = PresentationSettings()) {
        self.capture = capture
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey { case capture, settings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(capture: try c.decodeIfPresent(PresentationCapture.self, forKey: .capture),
                  settings: try c.decodeIfPresent(PresentationSettings.self, forKey: .settings)
                    ?? PresentationSettings())
    }

    /// True when the pointer is not part of the footage and Glint draws it.
    public var drawsPointer: Bool {
        guard let capture, !capture.pointerIsBaked else { return false }
        return !settings.cursor.hidden
    }

    /// True when rendering with this presentation changes no pixel, so the compositor can skip it entirely.
    public var isInert: Bool {
        let tracked = !(capture?.pointer.isEmpty ?? true)
        let pointerEffects = tracked && (settings.cursor.halo || settings.cursor.spotlight || drawsPointer)
        let clickEffects = settings.clicks.enabled && !(capture?.clicks.isEmpty ?? true)
        return settings.zooms.isEmpty && !pointerEffects && !clickEffects
    }
}
