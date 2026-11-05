import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

private enum TimedAnnotations {
    static let kinds: [AnnotationKind] = [
        .arrow(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 70, y: 60)),
        .line(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 70, y: 60)),
        .rectangle(CGRect(x: 20, y: 20, width: 50, height: 40)),
        .ellipse(CGRect(x: 20, y: 20, width: 50, height: 40)),
        .pen([CGPoint(x: 20, y: 20), CGPoint(x: 40, y: 50), CGPoint(x: 70, y: 30)]),
        .highlighter([CGPoint(x: 20, y: 20), CGPoint(x: 70, y: 60)]),
        .text(origin: CGPoint(x: 20, y: 20), string: "Step", maxWidth: 100),
        .counter(center: CGPoint(x: 50, y: 50), number: 2),
        .blur(CGRect(x: 20, y: 20, width: 50, height: 40)),
        .pixelate(CGRect(x: 20, y: 20, width: 50, height: 40)),
        .redact(CGRect(x: 20, y: 20, width: 50, height: 40)),
        .spotlight(CGRect(x: 20, y: 20, width: 50, height: 40)),
        .emoji(center: CGPoint(x: 50, y: 50), string: "⭐"),
        .magnify(Magnifier(source: CGRect(x: 20, y: 20, width: 30, height: 30),
                           inset: CGRect(x: 90, y: 30, width: 50, height: 50))),
    ]
}

@Suite("Annotation timing")
struct AnnotationTimingTests {
    @Test(arguments: TimedAnnotations.kinds)
    func everyKindDefaultsToWholeClipAndDecodesLegacyData(kind: AnnotationKind) throws {
        let annotation = Annotation(kind: kind)
        #expect(annotation.visibleRange == nil)
        for time in [0.0, 0.1, 1000, .infinity, .nan] {
            #expect(annotation.isVisible(at: time))
        }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(annotation)) as? [String: Any])
        json.removeValue(forKey: "visibleRange")
        #expect(try JSONDecoder().decode(Annotation.self, from: JSONSerialization.data(withJSONObject: json)) == annotation)
        json["visibleRange"] = NSNull()
        #expect(try JSONDecoder().decode(Annotation.self, from: JSONSerialization.data(withJSONObject: json)) == annotation)
    }

    @Test(arguments: TimedAnnotations.kinds)
    func everyKindRoundTripsItsRangeAndUsesHalfOpenBoundaries(kind: AnnotationKind) throws {
        let timing = AnnotationTiming(start: 1.25, end: 2.5)
        let annotation = Annotation(z: 7, kind: kind, visibleRange: timing)
        #expect(timing.isValid)
        #expect(!annotation.isVisible(at: timing.start.nextDown))
        #expect(annotation.isVisible(at: timing.start))
        #expect(annotation.isVisible(at: timing.end.nextDown))
        #expect(!annotation.isVisible(at: timing.end))
        #expect(!annotation.isVisible(at: 3))
        #expect(try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(annotation)) == annotation)
        #expect(try JSONDecoder().decode(AnnotationTiming.self, from: JSONEncoder().encode(timing)) == timing)
        #expect(annotation.translated(by: CGSize(width: 4, height: 5)).visibleRange == timing)
        var wholeClip = annotation
        wholeClip.visibleRange = nil
        #expect(wholeClip != annotation)
        #expect(Set([annotation, wholeClip]).count == 2)
    }

    @Test(arguments: [
        AnnotationTiming(start: -1, end: 2), AnnotationTiming(start: 2, end: 2),
        AnnotationTiming(start: 3, end: 2), AnnotationTiming(start: .nan, end: 2),
        AnnotationTiming(start: 0, end: .nan), AnnotationTiming(start: .infinity, end: 2),
        AnnotationTiming(start: 0, end: .infinity), AnnotationTiming(start: -.infinity, end: 2),
    ])
    func invalidRangesRejectPersistenceAndKeepInMemoryRedactionsVisible(timing: AnnotationTiming) throws {
        let annotation = Annotation(kind: .redact(CGRect(x: 0, y: 0, width: 20, height: 20)), visibleRange: timing)
        #expect(!timing.isValid)
        for time in [0.0, 1, 10] { #expect(annotation.isVisible(at: time)) }
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let data = try encoder.encode(annotation)
        #expect(throws: DecodingError.self) { try decoder.decode(Annotation.self, from: data) }
    }

    @Test func nonfiniteFrameTimesKeepPrivacyAnnotationsVisible() {
        let annotation = Annotation(kind: .pixelate(.zero), visibleRange: AnnotationTiming(start: 1, end: 2))
        for time in [TimeInterval.nan, .infinity, -.infinity] {
            #expect(annotation.isVisible(at: time))
        }
    }

    @Test func missingOrMalformedBoundsRejectPersistence() {
        for json in ["{}", "{\"start\":0}", "{\"end\":1}", "{\"start\":null,\"end\":1}", "{\"start\":\"0\",\"end\":1}"] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(AnnotationTiming.self, from: Data(json.utf8))
            }
        }
    }
}

@Suite("Timed annotation rendering")
struct AnnotationTimingRenderTests {
    private let settings = RenderSettings(padding: 0, inset: 0, cornerRadius: 0, shadow: .none,
                                          background: .transparent, autoBalance: false)

    @Test(arguments: TimedAnnotations.kinds)
    func everyKindAppearsAndDisappearsAtItsBoundaries(kind: AnnotationKind) throws {
        let image = TestImages.framed(width: 160, height: 120, margins: EdgeMargins(top: 0, left: 0, bottom: 0, right: 0))
        let annotation = Annotation(kind: kind, style: AnnotationStyle(strokeWidth: 4),
                                    visibleRange: AnnotationTiming(start: 1, end: 2))
        let unannotated = try #require(PixelBuffer(Compositor.render(image: image, settings: settings)))
        let screenshot = try #require(PixelBuffer(Compositor.render(image: image, settings: settings, annotations: [annotation])))
        #expect(screenshot.data != unannotated.data)
        for time in [0.0, 1, 1.5, 2, 3] {
            let rendered = try Compositor.render(image: image, settings: settings, annotations: [annotation], annotationTime: time)
            let actual = try #require(PixelBuffer(rendered))
            #expect(actual.data == (time >= 1 && time < 2 ? screenshot.data : unannotated.data))
        }
    }

    @Test(arguments: [false, true])
    func hiddenMagnifiersReserveTheSameLayoutWithAndWithoutAutoBalance(autoBalance: Bool) throws {
        let image = TestImages.framed(width: 160, height: 120, margins: EdgeMargins(top: 20, left: 20, bottom: 20, right: 20))
        let magnifier = Annotation(kind: .magnify(Magnifier(source: CGRect(x: 30, y: 30, width: 20, height: 20),
                                                           inset: CGRect(x: -70, y: -50, width: 60, height: 60))),
                                   visibleRange: AnnotationTiming(start: 1, end: 2))
        var settings = settings
        settings.autoBalance = autoBalance
        settings.padding = 8
        let visible = try Compositor.renderDetailed(image: image, settings: settings, annotations: [magnifier], annotationTime: 1)
        let plain = try Compositor.renderDetailed(image: image, settings: settings)
        #expect(visible.layout.canvasSize.width > plain.layout.canvasSize.width)
        #expect(visible.layout.overflowRect != visible.layout.contentRect)
        for time in [0.0, 2, 3] {
            let hidden = try Compositor.renderDetailed(image: image, settings: settings, annotations: [magnifier], annotationTime: time)
            #expect(hidden.layout == visible.layout)
            #expect(hidden.region == visible.region)
            #expect(hidden.image.pixelSize == visible.image.pixelSize)
            #expect(try #require(PixelBuffer(hidden.image)).data != #require(PixelBuffer(visible.image)).data)
        }
    }

    @Test func magnifierSamplingRespectsRedactionTiming() throws {
        let image = TestImages.solid(160, 120, RGBAColor(r: 1, g: 0, b: 0))
        let source = CGRect(x: 20, y: 20, width: 30, height: 30)
        let magnifier = Annotation(z: 0, kind: .magnify(Magnifier(source: source,
                                                                inset: CGRect(x: 90, y: 30, width: 50, height: 50))))
        let redaction = Annotation(z: 1, kind: .redact(source), style: AnnotationStyle(color: .black),
                                    visibleRange: AnnotationTiming(start: 1, end: 2))
        for time in [0.0, 1, 2] {
            let rendered = try Compositor.render(image: image, settings: settings,
                                                 annotations: [magnifier, redaction], annotationTime: time)
            let sourcePixel = TestImages.pixel(rendered, 35, 35)
            let lensPixel = TestImages.pixel(rendered, 115, 55)
            if time == 1 {
                #expect(sourcePixel.r == 0 && lensPixel.r == 0)
            } else {
                #expect(sourcePixel.r == 255 && lensPixel.r == 255)
            }
        }
    }

    @Test func invalidTimingCannotExposeRedactedPixels() throws {
        let image = TestImages.solid(40, 40, .red)
        let redaction = Annotation(kind: .redact(CGRect(x: 0, y: 0, width: 40, height: 40)),
                                    style: AnnotationStyle(color: .black), visibleRange: AnnotationTiming(start: 2, end: 1))
        for time in [0.0, 1, 2, 10, .nan] {
            let rendered = try Compositor.render(image: image, settings: settings, annotations: [redaction], annotationTime: time)
            #expect(TestImages.pixel(rendered, 20, 20).r == 0)
        }
        #expect(throws: RenderError.annotationsNotApplied) {
            try Compositor.renderDetailed(image: image, settings: settings, annotations: [redaction],
                                          bake: { _, _, _, _ in nil }, annotationTime: 0)
        }
    }
}
