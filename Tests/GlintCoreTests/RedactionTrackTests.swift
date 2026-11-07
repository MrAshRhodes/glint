import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

@Suite("Tracked redactions")
struct RedactionTrackTests {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func track(_ keyframes: [RedactionKeyframe], intervals: [RedactionUncertainInterval] = [],
                       analyzed: AnnotationTiming = AnnotationTiming(start: 0, end: 4)) -> RedactionTrack {
        RedactionTrack(keyframes: keyframes, uncertainIntervals: intervals, analyzedRange: analyzed, frameBounds: bounds)
    }

    private func rect(_ x: CGFloat, _ y: CGFloat = 50) -> CGRect { CGRect(x: x, y: y, width: 20, height: 10) }

    // MARK: Codable

    @Test func legacyAnnotationsDecodeUntrackedAndTracksRoundTrip() throws {
        let legacy = Annotation(kind: .redact(rect(10)), visibleRange: AnnotationTiming(start: 0, end: 1))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(json["track"] == nil, "untracked annotations keep the old encoding")
        json.removeValue(forKey: "track")
        let decoded = try JSONDecoder().decode(Annotation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.track == nil)
        #expect(decoded == legacy)

        let tracked = Annotation(kind: .pixelate(rect(10)), track: track(
            [RedactionKeyframe(time: 0, rect: rect(10), source: .tracked),
             RedactionKeyframe(time: 1, rect: rect(30), source: .manual)],
            intervals: [RedactionUncertainInterval(start: 2, end: 3, anchorTime: 1, anchorRect: rect(30),
                                                   resolution: .fixedCover)]))
        let data = try JSONEncoder().encode(tracked)
        #expect(try JSONDecoder().decode(Annotation.self, from: data) == tracked)
    }

    @Test func malformedTracksDecodeButFailClosed() throws {
        let json = #"{"analyzedRange":{"start":0,"end":2},"keyframes":[{"time":0.5,"rect":[[10,10],[5,5]]}]}"#
        let decoded = try JSONDecoder().decode(RedactionTrack.self, from: Data(json.utf8))
        #expect(decoded.keyframes.first?.source == .manual, "an unknown source is treated as a user keyframe")
        #expect(!decoded.isValid, "a track without frame bounds is not trusted")

        let empty = RedactionTrack(keyframes: [], analyzedRange: AnnotationTiming(start: 0, end: 2), frameBounds: bounds)
        let annotation = Annotation(kind: .redact(rect(10)), track: empty)
        #expect(annotation.resolved(at: 1).redactionRect == bounds, "an invalid track covers the whole frame")
        let gate = RedactionGate.unresolvedIntervals(in: [annotation], sourceDuration: 2)
        #expect(gate.map(\.reason) == [.invalidTrack])
        #expect(RedactionGate.blocksExport(gate, range: 0...2))
    }

    // MARK: Positions

    @Test func trackedSamplesHoldUntilTheNextFrameSoVariableFrameRatesStayCovered() {
        let t = track([RedactionKeyframe(time: 1, rect: rect(10), source: .tracked),
                       RedactionKeyframe(time: 2, rect: rect(200), source: .tracked)])
        // A held frame from t = 1 may still be on screen at 1.5, so its position must be covered.
        let cover = t.coverRect(at: 1.5)
        #expect(cover.contains(rect(10)))
        #expect(!cover.contains(rect(200)), "the next sample is not shown yet")
        // Within the preview's forward tolerance the next frame may already be shown.
        #expect(t.coverRect(at: 1.99).contains(rect(200)))
        #expect(t.coverRect(at: 1.99).contains(rect(10)))
    }

    @Test func manualKeyframesInterpolate() {
        let t = track([RedactionKeyframe(time: 0, rect: rect(0), source: .manual),
                       RedactionKeyframe(time: 2, rect: rect(200), source: .manual)])
        #expect(t.editingRect(at: 1) == rect(100))
        let cover = t.coverRect(at: 1)
        #expect(cover.contains(rect(100)))
        #expect(cover.width < 40, "interpolated, not the whole swept area: \(cover)")
        #expect(t.coverRect(at: -1).contains(rect(0)))
        #expect(t.coverRect(at: 3).contains(rect(200)))
    }

    @Test func coverAlwaysContainsTheEditingRect() {
        let t = track([RedactionKeyframe(time: 0, rect: rect(0), source: .tracked),
                       RedactionKeyframe(time: 0.5, rect: rect(40, 80), source: .manual),
                       RedactionKeyframe(time: 1.7, rect: rect(300, 20), source: .tracked)])
        for step in 0...80 {
            let time = Double(step) * 0.05 - 0.5
            #expect(t.coverRect(at: time).contains(t.editingRect(at: time)), "at \(time)")
        }
    }

    // MARK: Fail-safe

    @Test func failSafeCoverIsGenerousGrowsAndStaysInTheFrame() {
        let anchor = CGRect(x: 100, y: 100, width: 20, height: 10)
        let first = FailSafeCover.rect(anchor: anchor, elapsed: 0, bounds: bounds)
        #expect(first.contains(anchor.insetBy(dx: -anchor.width / 2, dy: -anchor.height / 2)))
        var previous = first
        for step in 1...20 {
            let next = FailSafeCover.rect(anchor: anchor, elapsed: Double(step) * 0.1, bounds: bounds)
            #expect(next.contains(previous))
            #expect(bounds.contains(next))
            previous = next
        }
        #expect(FailSafeCover.rect(anchor: anchor, elapsed: 60, bounds: bounds) == bounds)
        #expect(FailSafeCover.rect(anchor: anchor, elapsed: .infinity, bounds: bounds) == bounds)
    }

    @Test func uncertainIntervalsUseTheFailSafeCoverAndFixedCoverIsItsLargest() {
        let interval = RedactionUncertainInterval(start: 1, end: 2, anchorTime: 0.9, anchorRect: rect(100))
        var t = track([RedactionKeyframe(time: 0, rect: rect(50), source: .tracked),
                       RedactionKeyframe(time: 0.9, rect: rect(100), source: .tracked)], intervals: [interval])
        let inside = t.coverRect(at: 1.5)
        #expect(inside == FailSafeCover.rect(anchor: rect(100), elapsed: 0.6, bounds: bounds))
        // The frame flagged at 1.0 may already be on screen just before it in the preview.
        #expect(t.coverRect(at: 0.98).contains(FailSafeCover.rect(anchor: rect(100), elapsed: 1.0 - 0.9, bounds: bounds)))

        let changed1 = t.resolveInterval(containing: 1.5, as: .fixedCover, visibleRange: nil, sourceDuration: 4)
        #expect(changed1)
        let fixed = t.coverRect(at: 1.01)
        for step in 0..<10 {
            let time = 1 + Double(step) * 0.1
            #expect(fixed == t.coverRect(at: time))
            #expect(fixed.contains(FailSafeCover.rect(anchor: rect(100), elapsed: time - 0.9, bounds: bounds)))
        }
        let changed2 = t.reopenInterval(containing: 1.5)
        #expect(changed2)
        #expect(t.unresolvedIntervals(visibleRange: nil, sourceDuration: 4).count == 1)
    }

    @Test func resolvingWithKeyframesRequiresAManualKeyframeInside() {
        var t = track([RedactionKeyframe(time: 0, rect: rect(50), source: .tracked)],
                      intervals: [RedactionUncertainInterval(start: 1, end: 2, anchorTime: 0, anchorRect: rect(50))])
        let changed3 = t.resolveInterval(containing: 1.2, as: .keyframes, visibleRange: nil, sourceDuration: 4)
        #expect(!changed3)
        t.setManualKeyframe(at: 1.4, rect: rect(150))
        let changed4 = t.resolveInterval(containing: 1.2, as: .keyframes, visibleRange: nil, sourceDuration: 4)
        #expect(changed4)
        #expect(t.unresolvedIntervals(visibleRange: nil, sourceDuration: 4).isEmpty)
        #expect(t.coverRect(at: 1.4).contains(rect(150)), "a keyframe-resolved interval follows the keyframes")
        t.setManualKeyframe(at: 1.4, rect: rect(160))
        #expect(t.keyframes.filter { $0.time == 1.4 }.count == 1, "editing at the same time replaces the keyframe")
        let changed5 = t.removeKeyframe(near: 1.405)
        #expect(changed5)
        #expect(!t.keyframes.contains { $0.time == 1.4 })
    }

    @Test func visibleTimeOutsideTheTrackedRangeIsUncertain() {
        var t = track([RedactionKeyframe(time: 1, rect: rect(50), source: .tracked),
                       RedactionKeyframe(time: 2, rect: rect(60), source: .tracked)],
                      analyzed: AnnotationTiming(start: 1, end: 2))
        let gaps = t.unresolvedIntervals(visibleRange: AnnotationTiming(start: 0.5, end: 3), sourceDuration: 4)
        #expect(gaps.map(\.start) == [0.5, 2])
        #expect(gaps.map(\.end) == [1, 3])
        #expect(t.coverRect(at: 2.5) == FailSafeCover.rect(anchor: rect(60), elapsed: 0.5, bounds: bounds))
        let changed6 = t.resolveInterval(containing: 2.5, as: .fixedCover, visibleRange: AnnotationTiming(start: 0.5, end: 3),
                                  sourceDuration: 4)
        #expect(changed6)
        #expect(t.unresolvedIntervals(visibleRange: AnnotationTiming(start: 0.5, end: 3), sourceDuration: 4).count == 1)
        // Making the range longer again exposes new, unresolved time.
        #expect(t.unresolvedIntervals(visibleRange: nil, sourceDuration: 4).map(\.end) == [1, 4])
    }

    // MARK: Gate

    @Test func onlyIntervalsInsideTheTrimBlockExport() throws {
        let interval = RedactionUncertainInterval(start: 1, end: 2, anchorTime: 0.9, anchorRect: rect(100))
        let tracked = Annotation(kind: .redact(rect(10)), track: track(
            [RedactionKeyframe(time: 0, rect: rect(10), source: .tracked)], intervals: [interval]))
        let gate = RedactionGate.unresolvedIntervals(in: [tracked, Annotation(kind: .redact(rect(10)))], sourceDuration: 4)
        #expect(gate == [UnresolvedRedactionInterval(annotationID: tracked.id, start: 1, end: 2,
                                                     reason: .uncertainTracking)])
        #expect(!RedactionGate.blocksExport(gate, range: 0...1), "trimmed out before")
        #expect(!RedactionGate.blocksExport(gate, range: 2...4), "trimmed out after")
        #expect(RedactionGate.blocksExport(gate, range: 0...1.01))
        #expect(RedactionGate.blocksExport(gate, range: 1.99...4))

        var hidden = tracked
        hidden.visibleRange = AnnotationTiming(start: 2.5, end: 3)
        #expect(RedactionGate.unresolvedIntervals(in: [hidden], sourceDuration: 4).isEmpty,
                "an interval while the redaction is hidden needs no review")

        #expect(throws: RedactionGateError.unresolvedTracking) {
            try RedactionGate.validate([tracked], at: 1.5, sourceDuration: 4)
        }
        try RedactionGate.validate([tracked], at: 0.5, sourceDuration: 4)
    }

    @Test func blurCannotBeTracked() {
        let blur = Annotation(kind: .blur(rect(10)), track: track([RedactionKeyframe(time: 0, rect: rect(10), source: .tracked)]))
        #expect(!blur.isTrackable)
        #expect(Annotation(kind: .redact(rect(1))).isTrackable && Annotation(kind: .pixelate(rect(1))).isTrackable)
        #expect(RedactionGate.unresolvedIntervals(in: [blur], sourceDuration: 4).map(\.reason) == [.untrackableStyle])
    }

    // MARK: Rendering

    @Test func compositorDrawsTheTrackedPositionAtEachTime() throws {
        let settings = RenderSettings(padding: 0, inset: 0, cornerRadius: 0, shadow: .none,
                                      background: .solid(.white), autoBalance: false)
        let tracked = Annotation(kind: .redact(rect(10)), style: AnnotationStyle(color: .black), track: track(
            [RedactionKeyframe(time: 0, rect: rect(10), source: .manual),
             RedactionKeyframe(time: 2, rect: rect(310), source: .manual)]))
        let source = TestImages.solid(400, 300, .white)
        func isBlack(_ image: CGImage, _ x: Int, _ y: Int) -> Bool { TestImages.pixel(image, x, y).r < 40 }
        let start = try Compositor.render(image: source, settings: settings, annotations: [tracked], annotationTime: 0)
        let middle = try Compositor.render(image: source, settings: settings, annotations: [tracked], annotationTime: 1)
        #expect(isBlack(start, 20, 55) && !isBlack(start, 170, 55))
        #expect(isBlack(middle, 170, 55) && !isBlack(middle, 20, 55))
        let screenshot = try Compositor.render(image: source, settings: settings, annotations: [tracked])
        #expect(isBlack(screenshot, 20, 55), "screenshots ignore tracks")
    }

    // MARK: Vision helpers

    @Test func visionCoordinatesRoundTrip() {
        let size = CGSize(width: 640, height: 360)
        let r = CGRect(x: 40, y: 30, width: 100, height: 50)
        let normalized = VisionFrameTracker.normalized(r, in: size)
        #expect(abs(normalized.minY - (1 - 80.0 / 360)) < 1e-9, "Vision's origin is bottom-left")
        let back = VisionFrameTracker.denormalized(normalized, in: size)
        #expect(abs(back.minX - r.minX) < 1e-9 && abs(back.minY - r.minY) < 1e-9)
        #expect(abs(back.width - r.width) < 1e-9 && abs(back.height - r.height) < 1e-9)
    }

    @Test func lumaPatchCorrelationRejectsDifferentContent() throws {
        let frame = TrackingFrame(time: 0, luma: try #require(Self.grayPattern()), sourceSize: CGSize(width: 64, height: 64))
        let a = try #require(LumaPatch(frame: frame, rect: CGRect(x: 0, y: 0, width: 32, height: 32)))
        let same = try #require(LumaPatch(frame: frame, rect: CGRect(x: 0, y: 0, width: 32, height: 32)))
        let flat = try #require(LumaPatch(frame: frame, rect: CGRect(x: 32, y: 32, width: 32, height: 32)))
        #expect(a.correlation(with: same) > 0.99)
        #expect(a.correlation(with: flat) == 0)
        #expect(flat.correlation(with: flat) == 1)
        #expect(LumaPatch(frame: frame, rect: CGRect(x: 100, y: 100, width: 10, height: 10)) == nil)
    }

    /// Top-left quadrant striped, the rest flat grey.
    static func grayPattern() -> CGImage? {
        var bytes = [UInt8](repeating: 128, count: 64 * 64)
        for y in 0..<32 { for x in 0..<32 { bytes[y * 64 + x] = (x / 4 + y / 8) % 2 == 0 ? 20 : 230 } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 64,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
