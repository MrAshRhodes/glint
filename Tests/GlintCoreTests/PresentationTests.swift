import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

@Suite("Presentation model")
struct PresentationModelTests {
    private let frame = CGSize(width: 160, height: 90)

    @Test func zoomAmountEasesInHoldsAndEasesOut() {
        let zoom = ZoomSegment(start: 1, end: 3, rect: CGRect(x: 0, y: 0, width: 40, height: 22.5), ease: 0.4)
        #expect(zoom.amount(at: 0.99) == 0)
        #expect(zoom.amount(at: 1) == 0)
        #expect(abs(zoom.amount(at: 1.2) - 0.5) < 1e-9)
        #expect(zoom.amount(at: 1.4) == 1)
        #expect(zoom.amount(at: 2.5) == 1)
        #expect(abs(zoom.amount(at: 2.8) - 0.5) < 1e-9)
        #expect(zoom.amount(at: 3) == 0, "The end is exclusive like annotation ranges")
        #expect(zoom.amount(at: .nan) == 0)
        let short = ZoomSegment(start: 0, end: 0.2, rect: .zero, ease: 0.4)
        #expect(short.amount(at: 0.1) == 1, "Eases are capped at half the segment")
    }

    @Test func viewportKeepsTheFrameAspectAndStaysInside() throws {
        let zoom = ZoomSegment(start: 0, end: 4, rect: CGRect(x: 140, y: 80, width: 10, height: 40), ease: 0.5)
        let hold = try #require(zoom.viewport(at: 2, sourceSize: frame))
        #expect(abs(hold.width / hold.height - frame.width / frame.height) < 1e-6)
        #expect(hold.minX >= 0 && hold.minY >= 0 && hold.maxX <= frame.width + 1e-9 && hold.maxY <= frame.height + 1e-9)
        #expect(hold == ZoomSegment.fitted(zoom.rect, in: frame))
        #expect(zoom.viewport(at: 5, sourceSize: frame) == nil)
        #expect(zoom.viewport(at: 0, sourceSize: frame) == nil)
        let easing = try #require(zoom.viewport(at: 0.25, sourceSize: frame))
        #expect(easing.width < frame.width && easing.width > hold.width, "Mid-ease lies between full frame and area")
        #expect(abs(easing.width / easing.height - frame.width / frame.height) < 1e-6)
    }

    @Test func fittedAreaHasAMinimumSizeAndIsCentredOnTheRequest() {
        let tiny = ZoomSegment.fitted(CGRect(x: 79, y: 44, width: 2, height: 2), in: frame)
        #expect(abs(tiny.width - frame.width / 8) < 1e-9)
        #expect(abs(tiny.midX - 80) < 1e-9 && abs(tiny.midY - 45) < 1e-9)
        let huge = ZoomSegment.fitted(CGRect(x: -100, y: -100, width: 1000, height: 1000), in: frame)
        #expect(huge == CGRect(origin: .zero, size: frame))
        let flipped = ZoomSegment.fitted(CGRect(x: 100, y: 60, width: -40, height: -22.5), in: frame)
        #expect(flipped == CGRect(x: 60, y: 37.5, width: 40, height: 22.5))
    }

    @Test func laterOverlappingZoomWins() {
        let first = ZoomSegment(start: 0, end: 4, rect: CGRect(x: 0, y: 0, width: 40, height: 22.5), ease: 0)
        let second = ZoomSegment(start: 2, end: 3, rect: CGRect(x: 120, y: 67.5, width: 40, height: 22.5), ease: 0)
        let settings = PresentationSettings(zooms: [second, first])
        #expect(settings.viewport(at: 1, sourceSize: frame)?.minX == 0)
        #expect(settings.viewport(at: 2.5, sourceSize: frame)?.minX == 120)
        #expect(settings.viewport(at: 3.5, sourceSize: frame)?.minX == 0)
        #expect(settings.viewport(at: 4, sourceSize: frame) == nil)
    }

    @Test func pointerTrackCollapsesStillRunsAndInterpolates() {
        var track = PointerTrack()
        for (i, x) in [0.0, 10, 10, 10, 10, 20].enumerated() {
            track.append(PointerSample(time: Double(i), position: CGPoint(x: x, y: 5)))
        }
        track.append(PointerSample(time: 4, position: CGPoint(x: 99, y: 99)))
        #expect(track.samples.map(\.time) == [0, 1, 4, 5], "A still run keeps only its two ends; late samples drop")
        #expect(track.position(at: 0.5) == CGPoint(x: 5, y: 5))
        #expect(track.position(at: 2.5) == CGPoint(x: 10, y: 5))
        #expect(track.position(at: 4.5) == CGPoint(x: 15, y: 5))
        #expect(track.position(at: -1) == nil && track.position(at: 6) == nil)
    }

    @Test func presentationRoundTripsAndEncodesSamplesCompactly() throws {
        var track = PointerTrack()
        track.append(PointerSample(time: 0.5, position: CGPoint(x: 1, y: 2)))
        track.append(PointerSample(time: 0.75, position: CGPoint(x: 3, y: 4)))
        let click = ClickEvent(time: 0.6, position: CGPoint(x: 3, y: 4), button: .right)
        let presentation = Presentation(
            capture: PresentationCapture(pointer: track, clicks: [click], pointerIsBaked: false, pointerScale: 2),
            settings: PresentationSettings(
                clicks: ClickHighlightStyle(enabled: true, size: 60, duration: 1, removed: [click.id]),
                cursor: CursorEmphasis(scale: 2, hidden: true, halo: true, spotlight: true, radius: 80),
                zooms: [ZoomSegment(start: 1, end: 2, rect: CGRect(x: 1, y: 2, width: 30, height: 20), ease: 0.2)]))
        let data = try JSONEncoder().encode(presentation)
        #expect(try JSONDecoder().decode(Presentation.self, from: data) == presentation)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"pointer\":[[0.5,1,2],[0.75,3,4]]"))
    }

    @Test func legacyAndPartialPayloadsDecodeToInertDefaults() throws {
        let empty = try JSONDecoder().decode(Presentation.self, from: Data("{}".utf8))
        #expect(empty == Presentation())
        #expect(empty.isInert)
        let partial = try JSONDecoder().decode(Presentation.self, from: Data("""
        {"capture":{"pointer":[[0,1,2]]},"settings":{"zooms":[{"start":0,"end":1,"rect":[[0,0],[10,10]]}]}}
        """.utf8))
        #expect(partial.capture?.pointerIsBaked == true)
        #expect(partial.capture?.clicks == [])
        #expect(partial.settings.zooms.first?.ease == ZoomSegment.defaultEase)
        #expect(partial.settings.clicks == ClickHighlightStyle())
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ZoomSegment.self, from: Data("""
            {"start":2,"end":1,"rect":[[0,0],[10,10]]}
            """.utf8))
        }
        let legacyVideo = RecordedVideo(url: URL(fileURLWithPath: "/x.mp4"), duration: 1, pixelSize: frame)
        #expect(legacyVideo.presentation == nil)
    }

    @Test func defaultSettingsAreInertEvenWithRecordedData() {
        let capture = PresentationCapture(pointer: PointerTrack(samples: [PointerSample(time: 0, position: .zero)]),
                                          clicks: [ClickEvent(time: 0, position: .zero)])
        #expect(Presentation(capture: capture).isInert)
        var unbaked = capture
        unbaked.pointerIsBaked = false
        #expect(!Presentation(capture: unbaked).isInert, "An editable pointer is drawn by default")
        var hidden = Presentation(capture: unbaked)
        hidden.settings.cursor.hidden = true
        #expect(hidden.isInert)
    }
}

@Suite("Presentation rendering")
struct PresentationRenderingTests {
    private let settings = RenderSettings(padding: 0, inset: 0, cornerRadius: 0, shadow: .none,
                                          background: .solid(.white), autoBalance: false)
    private let red = RGBAColor(r: 1, g: 0, b: 0)

    private func capture(clicks: [ClickEvent] = [], pointer: CGPoint? = nil, baked: Bool = true) -> PresentationCapture {
        let samples = pointer.map { [PointerSample(time: 0, position: $0), PointerSample(time: 10, position: $0)] } ?? []
        return PresentationCapture(pointer: PointerTrack(samples: samples), clicks: clicks, pointerIsBaked: baked)
    }

    private func patterned() -> CGImage {
        let ctx = GlintBitmap.makeContext(width: 160, height: 90)!
        for x in stride(from: 0, to: 160, by: 10) {
            ctx.setFillColor(RGBAColor(r: Double(x) / 160, g: 0.4, b: 0.6).cgColor)
            ctx.fill(CGRect(x: x, y: 0, width: 10, height: 90))
        }
        return ctx.makeImage()!
    }

    @Test func defaultPresentationLeavesOutputBitIdentical() throws {
        let image = patterned()
        let styled = RenderSettings()
        let annotations = [Annotation(kind: .redact(CGRect(x: 10, y: 10, width: 20, height: 20)),
                                      style: AnnotationStyle(color: .black))]
        let reference = try #require(PixelBuffer(try Compositor.render(image: image, settings: styled,
                                                                        annotations: annotations, annotationTime: 1)))
        let recorded = capture(clicks: [ClickEvent(time: 1, position: CGPoint(x: 50, y: 50))],
                               pointer: CGPoint(x: 40, y: 40))
        for presentation in [Presentation(), Presentation(capture: recorded)] {
            let output = try Compositor.render(image: image, settings: styled, annotations: annotations,
                                               annotationTime: 1, presentation: presentation)
            #expect(try #require(PixelBuffer(output)).data == reference.data)
        }
        var active = Presentation(capture: recorded)
        active.settings.clicks.enabled = true
        active.settings.zooms = [ZoomSegment(start: 0, end: 5, rect: CGRect(x: 0, y: 0, width: 40, height: 22.5))]
        let screenshot = try Compositor.render(image: image, settings: styled, annotations: annotations,
                                               presentation: active)
        let plain = try Compositor.render(image: image, settings: styled, annotations: annotations)
        #expect(try #require(PixelBuffer(screenshot)).data == PixelBuffer(plain)?.data,
                "Without a recording time the presentation is ignored")
    }

    @Test func clickRipplesLandWhereTheClicksHappened() throws {
        let left = ClickEvent(time: 1, position: CGPoint(x: 50, y: 40), button: .left)
        let right = ClickEvent(time: 1, position: CGPoint(x: 120, y: 45), button: .right)
        var presentation = Presentation(capture: capture(clicks: [left, right]))
        presentation.settings.clicks = ClickHighlightStyle(enabled: true, leftColor: red, rightColor: red,
                                                           size: 40, duration: 0.6)
        let image = TestImages.solid(160, 90, .white)
        let result = try Compositor.renderDetailed(image: image, settings: settings, annotationTime: 1.3,
                                                   presentation: presentation)
        let origin = result.layout.contentRect.origin
        let pixels = try #require(PixelBuffer(result.image))
        func isRed(_ p: CGPoint) -> Bool {
            let v = pixels.pixel(Int(origin.x + p.x), Int(origin.y + p.y))
            return v.0 > 200 && v.1 < 180 && v.2 < 180
        }
        let radius = PresentationRenderer.rippleRadius(size: 40, progress: 0.5)
        let line = PresentationRenderer.rippleLineWidth(size: 40)
        #expect(isRed(CGPoint(x: 50 + radius, y: 40)))
        #expect(isRed(CGPoint(x: 50, y: 40 - radius)))
        #expect(!isRed(CGPoint(x: 50, y: 40)), "The ripple is a ring, not a disc")
        #expect(!isRed(CGPoint(x: 50 + radius - line * 2, y: 40)), "A left click has a single ring")
        #expect(isRed(CGPoint(x: 120 + radius, y: 45)))
        #expect(isRed(CGPoint(x: 120 + radius - line * 2, y: 45)), "A right click adds an inner ring")
        let after = try Compositor.render(image: image, settings: settings, annotationTime: 1.6,
                                          presentation: presentation)
        #expect(try #require(PixelBuffer(after)).data == PixelBuffer(image)?.data, "Ripples end after their duration")
        presentation.settings.clicks.removed = [left.id, right.id]
        let removed = try Compositor.render(image: image, settings: settings, annotationTime: 1.3,
                                            presentation: presentation)
        #expect(try #require(PixelBuffer(removed)).data == PixelBuffer(image)?.data)
    }

    @Test func redactionKeepsCoveringItsContentAtEveryZoom() throws {
        let ctx = GlintBitmap.makeContext(width: 160, height: 90)!
        ctx.setFillColor(RGBAColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        ctx.setFillColor(red.cgColor)
        ctx.fill(CGRect(x: 70, y: 40, width: 20, height: 10)) // y is bottom-up: top-left rect (70, 40, 20, 10)
        let image = ctx.makeImage()!
        let secret = CGRect(x: 66, y: 36, width: 28, height: 18)
        let redaction = Annotation(kind: .redact(secret), style: AnnotationStyle(color: .black))
        let plain = try Compositor.renderDetailed(image: image, settings: settings, annotations: [redaction])
        for magnification in [1.0, 2.0, 4.0] {
            let width = 160 / magnification
            let area = CGRect(x: 80 - width / 2, y: 45 - width * 9 / 32, width: width, height: width * 9 / 16)
            var presentation = Presentation()
            if magnification > 1 { presentation.settings.zooms = [ZoomSegment(start: 0, end: 2, rect: area)] }
            let result = try Compositor.renderDetailed(image: image, settings: settings,
                                                       annotations: [redaction], annotationTime: 1,
                                                       presentation: presentation)
            #expect(result.layout == plain.layout, "Zoom never changes the output size at \(magnification)×")
            if magnification > 1 { #expect(result.region == area) }
            let pixels = try #require(PixelBuffer(result.image))
            var black = 0
            for y in 0..<result.image.height {
                for x in 0..<result.image.width {
                    let p = pixels.pixel(x, y)
                    #expect(!(p.0 > 120 && p.1 < 90 && p.2 < 90), "Redacted red leaked at \(magnification)×: \(x),\(y)")
                    if p.0 < 20 && p.1 < 20 && p.2 < 20 { black += 1 }
                }
            }
            let content = result.layout.contentRect
            let expected = Double(secret.width * secret.height) * magnification * magnification
                * Double(content.width / 160) * Double(content.height / 90)
            #expect(Double(black) > expected * 0.8, "The redaction grows with the zoom at \(magnification)×")
        }
    }

    @Test func trackedRedactionsKeepCoveringMovingContentWhileZooming() throws {
        func secret(at time: Double) -> CGRect {
            CGRect(x: 60 + time * 20, y: 40, width: 16, height: 10)
        }
        let track = RedactionTrack(
            keyframes: [RedactionKeyframe(time: 0, rect: secret(at: 0), source: .manual),
                        RedactionKeyframe(time: 2, rect: secret(at: 2), source: .manual)],
            analyzedRange: AnnotationTiming(start: 0, end: 2), frameBounds: CGRect(x: 0, y: 0, width: 160, height: 90))
        let annotation = Annotation(kind: .redact(secret(at: 0)), style: AnnotationStyle(color: .black), track: track)
        let presentation = Presentation(settings: PresentationSettings(
            zooms: [ZoomSegment(start: 0, end: 2, rect: CGRect(x: 40, y: 22.5, width: 80, height: 45))]))
        for time in [0.0, 0.2, 0.8, 1.0, 1.8, 2.0] {
            let ctx = try #require(GlintBitmap.makeContext(width: 160, height: 90))
            ctx.setFillColor(RGBAColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
            ctx.setFillColor(red.cgColor)
            ctx.fill(secret(at: time))
            let image = try #require(ctx.makeImage())
            for effects in [Presentation(), presentation] {
                let result = try Compositor.render(image: image, settings: settings, annotations: [annotation],
                                                   annotationTime: time, presentation: effects)
                let pixels = try #require(PixelBuffer(result))
                let leaked = (0..<result.height).contains { y in
                    (0..<result.width).contains { x in
                        let pixel = pixels.pixel(x, y)
                        return pixel.0 > 120 && pixel.1 < 90 && pixel.2 < 90
                    }
                }
                #expect(!leaked, "Moving content must stay covered before and during zoom at \(time)")
            }
        }
    }

    @Test func editablePointerIsDrawnEnlargedOrHidden() throws {
        let image = TestImages.solid(160, 90, .white)
        var presentation = Presentation(capture: capture(pointer: CGPoint(x: 40, y: 20), baked: false))
        func dark(_ x: Int, _ y: Int) throws -> Bool {
            let result = try Compositor.renderDetailed(image: image, settings: settings, annotationTime: 1,
                                                       presentation: presentation)
            let p = try #require(PixelBuffer(result.image)).pixel(Int(result.layout.contentRect.minX) + x,
                                                                   Int(result.layout.contentRect.minY) + y)
            return p.0 < 60 && p.1 < 60 && p.2 < 60
        }
        #expect(try dark(42, 30))
        #expect(try !dark(42, 70))
        presentation.settings.cursor.scale = 3
        #expect(try dark(46, 60))
        presentation.settings.cursor.hidden = true
        #expect(try !dark(42, 30))
        presentation.capture?.pointerIsBaked = true
        presentation.settings.cursor.hidden = false
        #expect(try !dark(42, 30), "A baked pointer is never drawn twice")
    }

    @Test func haloAndSpotlightFollowThePointer() throws {
        let image = TestImages.solid(160, 90, .white)
        var presentation = Presentation(capture: capture(pointer: CGPoint(x: 120, y: 45)))
        presentation.settings.cursor.spotlight = true
        presentation.settings.cursor.radius = 20
        let result = try Compositor.renderDetailed(image: image, settings: settings, annotationTime: 1,
                                                   presentation: presentation)
        let pixels = try #require(PixelBuffer(result.image))
        let o = result.layout.contentRect.origin
        #expect(pixels.pixel(Int(o.x) + 10, Int(o.y) + 10).0 < 160, "Outside the spotlight is dimmed")
        #expect(pixels.pixel(Int(o.x) + 120, Int(o.y) + 45).0 == 255, "Inside stays untouched")
        presentation.settings.cursor = CursorEmphasis(halo: true, haloColor: red, radius: 20)
        let halo = try Compositor.renderDetailed(image: image, settings: settings, annotationTime: 1,
                                                 presentation: presentation)
        let h = try #require(PixelBuffer(halo.image)).pixel(Int(o.x) + 130, Int(o.y) + 45)
        #expect(h.0 > 200 && h.1 < 60)
        #expect(try #require(PixelBuffer(halo.image)).pixel(Int(o.x) + 10, Int(o.y) + 10).1 == 255)
    }

    @Test func orientedViewportFollowsRotationAndFlips() {
        let base = CGRect(x: 0, y: 0, width: 100, height: 50)
        let v = CGRect(x: 10, y: 5, width: 20, height: 10)
        #expect(PresentationRenderer.orientedViewport(v, base: base, rotation: .none, flipH: false, flipV: false) == v)
        #expect(PresentationRenderer.orientedViewport(v, base: base, rotation: .cw90, flipH: false, flipV: false)
                == CGRect(x: 35, y: 10, width: 10, height: 20))
        #expect(PresentationRenderer.orientedViewport(v, base: base, rotation: .cw180, flipH: false, flipV: false)
                == CGRect(x: 70, y: 35, width: 20, height: 10))
        #expect(PresentationRenderer.orientedViewport(v, base: base, rotation: .cw270, flipH: false, flipV: false)
                == CGRect(x: 5, y: 70, width: 10, height: 20))
        #expect(PresentationRenderer.orientedViewport(v, base: base, rotation: .none, flipH: true, flipV: true)
                == CGRect(x: 70, y: 35, width: 20, height: 10))
    }

    @Test func rotatedZoomShowsTheSameAreaAsUnrotated() throws {
        let image = patterned()
        let area = CGRect(x: 100, y: 20, width: 40, height: 22.5)
        let presentation = Presentation(settings: PresentationSettings(zooms: [ZoomSegment(start: 0, end: 2, rect: area,
                                                                                           ease: 0)]))
        let upright = try Compositor.render(image: image, settings: settings, annotationTime: 1,
                                            presentation: presentation)
        var rotated = settings
        rotated.rotation = .cw180
        let turned = try Compositor.render(image: image, settings: rotated, annotationTime: 1,
                                           presentation: presentation)
        let a = try #require(PixelBuffer(upright)), b = try #require(PixelBuffer(turned))
        let p = a.pixel(10, 10), q = b.pixel(upright.width - 11, upright.height - 11)
        #expect(abs(Int(p.0) - Int(q.0)) < 6 && abs(Int(p.2) - Int(q.2)) < 6)
    }
}
