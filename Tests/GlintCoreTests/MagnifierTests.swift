import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

/// Synthetic 200×120 screenshot (plus optional uniform margins) with distinct details, in top-left coordinates
/// relative to the inner block: yellow lens area (30,30,40,40) holding a red (40,40,10,10) and a green
/// (55,55,10,10) square, and a blue square (150,100,10,10) elsewhere on dark grey.
private enum Scene {
    static let grey = RGBAColor(r: 0.2, g: 0.2, b: 0.2)
    static let yellow = RGBAColor(r: 1, g: 1, b: 0)
    static let red = RGBAColor(r: 1, g: 0, b: 0)
    static let green = RGBAColor(r: 0, g: 1, b: 0)
    static let blue = RGBAColor(r: 0, g: 0, b: 1)
    static let cyan = RGBAColor(r: 0, g: 1, b: 1)
    static let size = CGSize(width: 200, height: 120)
    static let lensSource = CGRect(x: 30, y: 30, width: 40, height: 40)
    static let redCenter = CGPoint(x: 45, y: 45)
    static let greenCenter = CGPoint(x: 60, y: 60)
    static let blueCenter = CGPoint(x: 155, y: 105)

    static func image(margins: EdgeMargins = EdgeMargins(top: 0, left: 0, bottom: 0, right: 0),
                      border: RGBAColor = .white, secret: RGBAColor = red) -> CGImage {
        let w = 200 + margins.left + margins.right, h = 120 + margins.top + margins.bottom
        let ctx = GlintBitmap.makeContext(width: w, height: h)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(border.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: CGFloat(margins.left), y: CGFloat(margins.top))
        func fill(_ c: RGBAColor, _ r: CGRect) { ctx.setFillColor(c.cgColor); ctx.fill(r) }
        fill(grey, CGRect(origin: .zero, size: size))
        fill(yellow, lensSource)
        fill(secret, CGRect(x: 40, y: 40, width: 10, height: 10))
        fill(green, CGRect(x: 55, y: 55, width: 10, height: 10))
        fill(blue, CGRect(x: 150, y: 100, width: 10, height: 10))
        return ctx.makeImage()!
    }

    static func magnifier(source: CGRect = lensSource, inset: CGRect, shape: MagnifierShape = .circle,
                          outline: Bool = true, connector: Bool = true, z: Int = 0) -> Annotation {
        Annotation(z: z, kind: .magnify(Magnifier(source: source, inset: inset, shape: shape,
                                                  showsSourceOutline: outline, showsConnector: connector)),
                   style: AnnotationStyle(color: cyan, strokeWidth: 4))
    }

    /// Where an image point lands in a lens that maps `source` onto `inset` (equal aspect).
    static func lensPoint(_ p: CGPoint, source: CGRect = lensSource, inset: CGRect) -> CGPoint {
        let m = inset.width / source.width
        return CGPoint(x: inset.minX + (p.x - source.minX) * m, y: inset.minY + (p.y - source.minY) * m)
    }
}

private typealias Pixel = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

private func px(_ image: CGImage, _ p: CGPoint) -> Pixel {
    TestImages.pixel(image, Int(floor(p.x)), Int(floor(p.y)))
}

private func isRed(_ p: Pixel) -> Bool { p.r > 200 && p.g < 60 && p.b < 60 }
private func isGreen(_ p: Pixel) -> Bool { p.g > 200 && p.r < 60 && p.b < 60 }
private func isBlue(_ p: Pixel) -> Bool { p.b > 200 && p.r < 60 && p.g < 60 }
private func isYellow(_ p: Pixel) -> Bool { p.r > 200 && p.g > 200 && p.b < 60 }
private func isCyan(_ p: Pixel) -> Bool { p.g > 200 && p.b > 200 && p.r < 60 }
private func isWhite(_ p: Pixel) -> Bool { p.r > 240 && p.g > 240 && p.b > 240 && p.a > 240 }
private func isBlack(_ p: Pixel) -> Bool { p.r < 30 && p.g < 30 && p.b < 30 && p.a > 240 }

@Suite("Magnifier model")
struct MagnifierModelTests {
    @Test func codableRoundTrip() throws {
        let m = Magnifier(source: CGRect(x: 1.5, y: 2, width: 30, height: 20), inset: CGRect(x: 250, y: -40, width: 75, height: 50),
                          shape: .rectangle, showsSourceOutline: false, showsConnector: false)
        let a = Annotation(z: 3, kind: .magnify(m), style: AnnotationStyle(color: Scene.blue, strokeWidth: 3, dashed: true))
        let data = try JSONEncoder().encode(a)
        #expect(try JSONDecoder().decode(Annotation.self, from: data) == a)
        #expect(try JSONDecoder().decode(Magnifier.self, from: JSONEncoder().encode(m)) == m)
        #expect(MagnifierShape.allCases == [.circle, .rectangle])
    }

    @Test func missingOptionalKeysDecodeToDefaults() throws {
        let m = Magnifier(source: CGRect(x: 0, y: 0, width: 10, height: 10), inset: CGRect(x: 20, y: 0, width: 20, height: 20),
                          shape: .rectangle, showsSourceOutline: false, showsConnector: false)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any])
        for key in ["shape", "showsSourceOutline", "showsConnector"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(Magnifier.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == Magnifier(source: m.source, inset: m.inset))
        #expect(decoded.shape == .circle && decoded.showsSourceOutline && decoded.showsConnector)

        // Nested inside an annotation as well.
        let a = Annotation(kind: .magnify(m))
        var root = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? [String: Any])
        var kind = try #require(root["kind"] as? [String: Any])
        var payload = try #require(kind["magnify"] as? [String: Any])
        var inner = try #require(payload["_0"] as? [String: Any])
        for key in ["shape", "showsSourceOutline", "showsConnector"] { inner.removeValue(forKey: key) }
        payload["_0"] = inner; kind["magnify"] = payload; root["kind"] = kind
        let decodedAnnotation = try JSONDecoder().decode(Annotation.self, from: JSONSerialization.data(withJSONObject: root))
        #expect(decodedAnnotation.kind == .magnify(Magnifier(source: m.source, inset: m.inset)))
    }

    @Test func missingRequiredKeysFail() throws {
        let json: [String: Any] = ["inset": [[0, 0], [10, 10]]]
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Magnifier.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func magnification() {
        #expect(Magnifier(source: CGRect(x: 0, y: 0, width: 40, height: 20),
                          inset: CGRect(x: 0, y: 0, width: 100, height: 50)).magnification == 2.5)
        #expect(Magnifier(source: CGRect(x: 0, y: 0, width: 0, height: 0),
                          inset: CGRect(x: 0, y: 0, width: 10, height: 10)).magnification.isFinite)
    }

    @Test func classificationBoundsAndTranslation() throws {
        let source = CGRect(x: 10, y: 20, width: 30, height: 30), inset = CGRect(x: 100, y: -50, width: 60, height: 60)
        let a = Annotation(kind: .magnify(Magnifier(source: source, inset: inset)), style: AnnotationStyle(strokeWidth: 6))
        #expect(a.isMagnifier && !a.isRedaction && !a.isObfuscation)
        #expect(!Annotation(kind: .rectangle(source)).isMagnifier)
        #expect(Annotation(kind: .rectangle(source)).magnifierRenderBounds == nil)

        let margin = 3 + Magnifier.shadowMargin(strokeWidth: 6)
        #expect(margin > 3)
        #expect(a.boundingBox == source.union(inset).insetBy(dx: -margin, dy: -margin))
        let bounds = try #require(a.magnifierRenderBounds)
        #expect(bounds.contains(inset.insetBy(dx: -margin, dy: -margin)))
        #expect(bounds.contains(source))

        let moved = a.translated(by: CGSize(width: 5, height: -7))
        guard case .magnify(let m) = moved.kind else { Issue.record("kind changed"); return }
        #expect(m.source == source.offsetBy(dx: 5, dy: -7))
        #expect(m.inset == inset.offsetBy(dx: 5, dy: -7))
        #expect(moved.id == a.id && moved.style == a.style)
    }

    @Test func renderBoundsCoverEverythingPainted() throws {
        for shape in MagnifierShape.allCases {
            var a = Scene.magnifier(source: CGRect(x: 150, y: 150, width: 20, height: 20),
                                    inset: CGRect(x: 60, y: 60, width: 80, height: 80), shape: shape)
            a.style.fill = .white
            let region = CGRect(x: 0, y: 0, width: 300, height: 300)
            let baked = try #require(AnnotationRenderer.bake(source: TestImages.solid(300, 300, .clear),
                                                             annotations: [a], region: region))
            let bounds = try #require(a.magnifierRenderBounds).insetBy(dx: -1, dy: -1)
            let pixels = try #require(PixelBuffer(baked))
            var painted = 0
            for y in 0..<300 { for x in 0..<300 where pixels.pixel(x, y).3 > 1 {
                painted += 1
                #expect(bounds.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)), "pixel \(x),\(y) outside bounds")
            } }
            #expect(painted > 80 * 80 / 2)
        }
    }
}

@Suite("Magnifier rendering")
struct MagnifierRenderTests {
    let inset = CGRect(x: 100, y: 10, width: 80, height: 80)

    @Test(arguments: MagnifierShape.allCases)
    func lensShowsEnlargedDetailAndKeepsOriginal(shape: MagnifierShape) throws {
        let image = Scene.image()
        let out = try #require(AnnotationRenderer.bake(source: image, annotations: [Scene.magnifier(inset: inset, shape: shape)]))
        #expect(isRed(px(out, Scene.lensPoint(Scene.redCenter, inset: inset))))
        #expect(isGreen(px(out, Scene.lensPoint(Scene.greenCenter, inset: inset))))
        // Not flipped: the mirrored red position shows yellow lens background instead.
        #expect(!isRed(px(out, CGPoint(x: 130, y: 70))))
        // The original stays visible.
        #expect(isRed(px(out, Scene.redCenter)))
        #expect(isGreen(px(out, Scene.greenCenter)))
        #expect(isBlue(px(out, Scene.blueCenter)))
        // Source outline and connector in the style colour.
        #expect(isCyan(px(out, CGPoint(x: 50, y: 30))))
        #expect(isCyan(px(out, CGPoint(x: 85, y: 50))))
    }

    @Test func rectangleFillsCornersCircleDoesNot() throws {
        let image = Scene.image()
        let corner = CGPoint(x: 104, y: 14) // lens shows image (32, 32): yellow
        let rect = try #require(AnnotationRenderer.bake(source: image, annotations: [Scene.magnifier(inset: inset, shape: .rectangle)]))
        let circle = try #require(AnnotationRenderer.bake(source: image, annotations: [Scene.magnifier(inset: inset, shape: .circle)]))
        #expect(isYellow(px(rect, corner)))
        #expect(!isYellow(px(circle, corner)))
        #expect(isYellow(px(circle, CGPoint(x: 140, y: 14)))) // top of the circle's interior
    }

    @Test func outlineAndConnectorCanBeHidden() throws {
        let out = try #require(AnnotationRenderer.bake(source: Scene.image(),
                                                       annotations: [Scene.magnifier(inset: inset, outline: false, connector: false)]))
        #expect(isYellow(px(out, CGPoint(x: 50, y: 30))))
        #expect(!isCyan(px(out, CGPoint(x: 85, y: 50))))
        // Overlapping inset and source: no connector.
        let overlapping = Scene.magnifier(inset: CGRect(x: 50, y: 50, width: 60, height: 60))
        let o = try #require(AnnotationRenderer.bake(source: Scene.image(), annotations: [overlapping]))
        #expect(!isCyan(px(o, CGPoint(x: 25, y: 25))))
    }

    @Test func lensRespectsSourcePixelScale() throws {
        let hiRes = try #require(GlintBitmap.makeContext(width: 400, height: 240))
        hiRes.interpolationQuality = .none
        hiRes.draw(Scene.image(), in: CGRect(x: 0, y: 0, width: 400, height: 240))
        let source = try #require(hiRes.makeImage())
        let out = try drawInImageSpace(source, annotations: [Scene.magnifier(inset: inset)], imageSize: Scene.size)
        #expect(isRed(px(out, Scene.lensPoint(Scene.redCenter, inset: inset))))
        #expect(isGreen(px(out, Scene.lensPoint(Scene.greenCenter, inset: inset))))
    }

    @Test func lensShowsEarlierAnnotationsButNotLaterOnes() throws {
        let below = Annotation(z: -1, kind: .rectangle(CGRect(x: 33, y: 33, width: 4, height: 4)),
                               style: AnnotationStyle(color: Scene.blue, fill: Scene.blue, strokeWidth: 1))
        let above = Annotation(z: 1, kind: .rectangle(CGRect(x: 63, y: 33, width: 4, height: 4)),
                               style: AnnotationStyle(color: Scene.blue, fill: Scene.blue, strokeWidth: 1))
        let out = try #require(AnnotationRenderer.bake(source: Scene.image(),
                                                       annotations: [Scene.magnifier(inset: inset, shape: .rectangle), below, above]))
        #expect(isBlue(px(out, Scene.lensPoint(CGPoint(x: 35, y: 35), inset: inset))))
        #expect(isYellow(px(out, Scene.lensPoint(CGPoint(x: 65, y: 35), inset: inset))))
    }

    @Test func lensAreasOutsideTheImageAreTransparent() throws {
        let m = Scene.magnifier(source: CGRect(x: -20, y: 30, width: 40, height: 40),
                                inset: CGRect(x: 300, y: 10, width: 80, height: 80), shape: .rectangle,
                                outline: false, connector: false)
        let out = try #require(AnnotationRenderer.bake(source: Scene.image(), annotations: [m],
                                                       region: CGRect(x: 0, y: 0, width: 400, height: 120)))
        #expect(px(out, CGPoint(x: 320, y: 50)).a == 0)      // image x -10: outside the image
        #expect(px(out, CGPoint(x: 360, y: 50)).a == 255)    // image x 10: grey
    }

    // MARK: Security

    private func redactions(_ rect: CGRect, z: Int) -> [Annotation] {
        let style = AnnotationStyle(color: RGBAColor(red8: 180, green8: 30, blue8: 210, alpha8: 1), opacity: 0.2, intensity: 6)
        var checker = style
        checker.redactionPattern = .checkerboard
        return [Annotation(z: z, kind: .redact(rect), style: style),
                Annotation(z: z, kind: .redact(rect), style: checker),
                Annotation(z: z, kind: .pixelate(rect), style: style)]
    }

    @Test(arguments: [-1, 1])
    func lensNeverRevealsRedactedPixels(redactionZ: Int) throws {
        let first = Scene.image(secret: Scene.red)
        let second = Scene.image(secret: RGBAColor(r: 1, g: 0.5, b: 0))
        let secretRect = CGRect(x: 38, y: 38, width: 14, height: 14)
        let blur = Annotation(z: 0, kind: .blur(CGRect(x: 20, y: 20, width: 60, height: 60)))
        let second2 = Scene.magnifier(source: inset, inset: CGRect(x: 0, y: 75, width: 60, height: 40), z: 2)
        for redaction in redactions(secretRect, z: redactionZ) {
            let stacks: [[Annotation]] = [
                [Scene.magnifier(inset: inset), redaction],
                [Scene.magnifier(inset: inset, shape: .rectangle), redaction, blur],
                [Scene.magnifier(inset: inset), redaction, second2],
            ]
            for annotations in stacks {
                let a = try #require(AnnotationRenderer.bake(source: first, annotations: annotations))
                let b = try #require(AnnotationRenderer.bake(source: second, annotations: annotations))
                #expect(try #require(PixelBuffer(a)).data == #require(PixelBuffer(b)).data)
                let pixels = try #require(PixelBuffer(a))
                for y in 0..<120 { for x in 0..<200 { #expect(!isRed(pixels.pixel(x, y) as Pixel)) } }
            }
        }
    }

    @Test func lensThroughCompositorNeverRevealsRedactedPixels() throws {
        let secretRect = CGRect(x: 38, y: 38, width: 14, height: 14)
        let outside = CGRect(x: 230, y: -30, width: 80, height: 80)
        let settings = RenderSettings(padding: 20, inset: 0, cornerRadius: 12, shadow: .none,
                                      background: .solid(.black), autoBalance: false)
        for redaction in redactions(secretRect, z: 5) {
            let annotations = [Scene.magnifier(inset: outside), redaction]
            let a = try Compositor.render(image: Scene.image(secret: Scene.red), settings: settings, annotations: annotations)
            let b = try Compositor.render(image: Scene.image(secret: RGBAColor(r: 1, g: 0.5, b: 0)), settings: settings,
                                          annotations: annotations)
            #expect(try #require(PixelBuffer(a)).data == #require(PixelBuffer(b)).data)
        }
    }

    @Test func higherRedactionStillMasksEarlierAnnotationsInTheLens() throws {
        let purple = RGBAColor(r: 0.7, g: 0.1, b: 0.8)
        let covered = CGRect(x: 38, y: 38, width: 14, height: 14)
        let shape = Annotation(z: 0, kind: .rectangle(covered),
                               style: AnnotationStyle(color: Scene.blue, fill: Scene.blue, strokeWidth: 1))
        let redaction = Annotation(z: 2, kind: .redact(covered), style: AnnotationStyle(color: purple))
        let lens = Scene.magnifier(inset: inset, shape: .rectangle, z: 1)
        let out = try #require(AnnotationRenderer.bake(source: Scene.image(), annotations: [shape, lens, redaction]))
        let p = px(out, Scene.lensPoint(Scene.redCenter, inset: inset))
        #expect(!isBlue(p))
        #expect(p.r > 150 && p.g < 60 && p.b > 160)
        #expect(!isBlue(px(out, Scene.redCenter)))
    }

    @Test func missingSourceFallsBackToSolidColour() throws {
        let out = try drawInImageSpace(Scene.image(), annotations: [Scene.magnifier(inset: inset)], imageSize: Scene.size,
                                       supplySource: false)
        #expect(isCyan(px(out, Scene.lensPoint(Scene.redCenter, inset: inset))))
        #expect(isCyan(px(out, Scene.lensPoint(Scene.greenCenter, inset: inset))))
        #expect(isRed(px(out, Scene.redCenter)))
    }

    private func drawInImageSpace(_ source: CGImage, annotations: [Annotation], imageSize: CGSize,
                                  supplySource: Bool = true) throws -> CGImage {
        let ctx = try #require(GlintBitmap.makeContext(width: Int(imageSize.width), height: Int(imageSize.height)))
        ctx.translateBy(x: 0, y: imageSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ImageDrawing.drawFlipped(source, in: CGRect(origin: .zero, size: imageSize), ctx: ctx)
        AnnotationRenderer.draw(in: ctx, annotations: annotations, imageSize: imageSize,
                                source: supplySource ? source : nil)
        return try #require(ctx.makeImage())
    }

    @Test func bakeFillRectLimitsTheFill() throws {
        let source = TestImages.solid(10, 10, Scene.red)
        let region = CGRect(x: -5, y: -5, width: 20, height: 20)
        let limited = try #require(AnnotationRenderer.bake(source: source, annotations: [], region: region, fill: .white,
                                                           fillRect: CGRect(x: -2, y: -2, width: 14, height: 14)))
        #expect(TestImages.pixel(limited, 0, 0).a == 0)
        #expect(isWhite(TestImages.pixel(limited, 4, 4)))
        #expect(isRed(TestImages.pixel(limited, 10, 10)))
        let full = try #require(AnnotationRenderer.bake(source: source, annotations: [], region: region, fill: .white))
        #expect(isWhite(TestImages.pixel(full, 0, 0)))
    }
}

@Suite("Magnifier canvas expansion")
struct MagnifierExpansionTests {
    func settings(padding: Double = 20, frame: WindowFrameKind = .none) -> RenderSettings {
        RenderSettings(padding: padding, inset: 15, cornerRadius: 0, shadow: .none, background: .solid(.black),
                       windowFrame: WindowFrameSettings(style: frame), autoBalance: false)
    }

    /// Output pixel of an image point for an unrotated render.
    func output(_ p: CGPoint, _ r: RenderResult) -> CGPoint {
        CGPoint(x: r.layout.contentRect.minX + p.x - r.region.minX, y: r.layout.contentRect.minY + p.y - r.region.minY)
    }

    func expectPaddingAroundEverything(_ r: RenderResult, padding: CGFloat = 20) {
        let used = r.layout.cardRect.union(r.layout.overflowRect)
        #expect(used.minX == padding && used.minY == padding)
        #expect(r.layout.canvasSize.width == used.maxX + padding)
        #expect(r.layout.canvasSize.height == used.maxY + padding)
        #expect(r.layout.overflowRect.contains(r.layout.contentRect))
    }

    @Test(arguments: [
        CGRect(x: 220, y: 10, width: 80, height: 80),    // fully outside, right
        CGRect(x: 170, y: 10, width: 80, height: 80),    // straddling the right edge
        CGRect(x: -120, y: -100, width: 80, height: 80), // above-left
        CGRect(x: 60, y: 100, width: 80, height: 80),    // below
    ])
    func insetOutsideGrowsTheCanvas(inset: CGRect) throws {
        let image = Scene.image()
        let s = settings()
        let baseline = try Compositor.renderDetailed(image: image, settings: s)
        let m = Scene.magnifier(inset: inset, shape: .rectangle)
        let r = try Compositor.renderDetailed(image: image, settings: s, annotations: [m])
        #expect(r.region == CGRect(origin: .zero, size: Scene.size))
        #expect(r.layout.contentRect.size == baseline.layout.contentRect.size)
        #expect(r.layout.cardRect.size == baseline.layout.cardRect.size)
        #expect(r.layout.canvasSize.width > baseline.layout.canvasSize.width
                || r.layout.canvasSize.height > baseline.layout.canvasSize.height)
        #expect(r.image.width == Int(r.layout.canvasSize.width) && r.image.height == Int(r.layout.canvasSize.height))
        expectPaddingAroundEverything(r)
        let bounds = try #require(m.magnifierRenderBounds)
        let expanded = CGRect(origin: .zero, size: Scene.size).union(bounds).integral
        #expect(r.layout.overflowRect.size == expanded.size)

        let redInLens = Scene.lensPoint(Scene.redCenter, inset: inset)
        #expect(isRed(px(r.image, output(redInLens, r))))
        #expect(isGreen(px(r.image, output(Scene.lensPoint(Scene.greenCenter, inset: inset), r))))
        #expect(isRed(px(r.image, output(Scene.redCenter, r))))
        #expect(isBlue(px(r.image, output(Scene.blueCenter, r))) || inset.contains(Scene.blueCenter))
        // The background stays visible next to the floating inset.
        let corner = output(CGPoint(x: expanded.minX + 2, y: expanded.minY + 2), r)
        if !r.layout.cardRect.contains(corner) && !bounds.insetBy(dx: 18, dy: 18).contains(corner) {
            #expect(isBlack(px(r.image, corner)))
        }
    }

    @Test func insetInsideKeepsLayoutAndPixels() throws {
        let image = Scene.image()
        let s = settings()
        // Inset plus stroke and shadow margin (2 + 15) stays within the 200×120 image.
        let m = Scene.magnifier(inset: CGRect(x: 110, y: 20, width: 70, height: 70))
        #expect(CGRect(origin: .zero, size: Scene.size).contains(try #require(m.magnifierRenderBounds)))
        let baseline = try Compositor.renderDetailed(image: image, settings: s)
        let r = try Compositor.renderDetailed(image: image, settings: s, annotations: [m])
        #expect(r.layout == baseline.layout)
        #expect(r.layout.overflowRect == r.layout.contentRect)
        let baked = try #require(AnnotationRenderer.bake(source: image, annotations: [m]))
        let reference = try Compositor.renderDetailed(image: baked, settings: s)
        #expect(try #require(PixelBuffer(r.image)).data == #require(PixelBuffer(reference.image)).data)
    }

    @Test(arguments: [WindowFrameKind.none, .macOS, .retro, .arcade, .terminal, .phone],
          MagnifierShape.allCases)
    func insetFloatsAboveFrameCornersEffectsAndBorder(frame: WindowFrameKind, shape: MagnifierShape) throws {
        var s = settings(frame: frame)
        s.border.enabled = true
        s.border.width = 12
        s.border.color = .white
        let inset = CGRect(x: -25, y: -25, width: 80, height: 80)
        let m = Scene.magnifier(source: CGRect(x: 40, y: 40, width: 10, height: 10),
                                inset: inset, shape: shape, outline: false, connector: false)
        let result = try Compositor.renderDetailed(image: Scene.image(), settings: s, annotations: [m])
        for p in [CGPoint(x: 1, y: 1), CGPoint(x: 5, y: -15), CGPoint(x: -15, y: 5)] {
            let pixel = px(result.image, output(p, result))
            #expect(pixel.r >= 250 && pixel.g <= 2 && pixel.b <= 2, "cut-in obscured at \(p), frame \(frame)")
        }
        #expect(isCyan(px(result.image, output(CGPoint(x: inset.minX + 1, y: inset.midY), result))))
    }

    @Test(arguments: [false, true])
    func screenEffectsDoNotCoverFlatOrTiltedInsets(tilted: Bool) throws {
        var s = settings(frame: .retro)
        s.border.enabled = true
        s.border.width = 12
        s.border.color = .white
        if tilted { s.tilt = Tilt(x: 10, y: -12) }
        let m = Scene.magnifier(source: CGRect(x: 40, y: 40, width: 10, height: 10),
                                inset: CGRect(x: 100, y: 20, width: 70, height: 70),
                                shape: .rectangle, outline: false, connector: false)
        let result = try Compositor.render(image: Scene.image(), settings: s, annotations: [m])
        let pixels = try #require(PixelBuffer(result))
        var pureRed = 0
        for y in 0..<result.height { for x in 0..<result.width {
            let (r, g, b, _) = pixels.pixel(x, y)
            if r >= 250 && g <= 2 && b <= 2 { pureRed += 1 }
        } }
        // The original red source is only 100 pixels; the undecorated lens supplies thousands more.
        #expect(pureRed > 2500)
    }

    @Test(arguments: [false, true])
    func annotationsKeepTheirOrderOverInset(above: Bool) throws {
        let inset = CGRect(x: 100, y: 20, width: 70, height: 70)
        let m = Scene.magnifier(source: CGRect(x: 40, y: 40, width: 10, height: 10),
                                inset: inset, shape: .rectangle, outline: false, connector: false, z: 1)
        let mark = Annotation(z: above ? 2 : 0, kind: .rectangle(CGRect(x: 120, y: 40, width: 30, height: 30)),
                              style: AnnotationStyle(color: Scene.blue, fill: Scene.blue, strokeWidth: 0))
        let result = try Compositor.renderDetailed(image: Scene.image(), settings: settings(frame: .retro),
                                                   annotations: [mark, m])
        let pixel = px(result.image, output(CGPoint(x: 135, y: 55), result))
        #expect(above ? isBlue(pixel) : isRed(pixel))
    }

    @Test(arguments: [false, true])
    func floatingLensNeverRestoresRedactedPixels(pixelate: Bool) throws {
        let source = CGRect(x: 40, y: 40, width: 10, height: 10)
        let m = Scene.magnifier(source: source, inset: CGRect(x: -25, y: -25, width: 80, height: 80),
                                shape: .rectangle, outline: false, connector: false)
        let mask = Annotation(z: 2, kind: pixelate ? .pixelate(source) : .redact(source),
                              style: AnnotationStyle(color: .black))
        var s = settings(frame: .phone)
        s.border.enabled = true
        s.border.width = 12
        let red = try Compositor.render(image: Scene.image(secret: Scene.red), settings: s, annotations: [m, mask])
        let green = try Compositor.render(image: Scene.image(secret: Scene.green), settings: s, annotations: [m, mask])
        #expect(try #require(PixelBuffer(red)).data == #require(PixelBuffer(green)).data)
    }

    @Test(arguments: [0.5, 1.0])
    func translucentAnnotationsOverTransparentInsetsAreDrawnOnce(opacity: Double) throws {
        var m = Scene.magnifier(source: CGRect(x: -20, y: 30, width: 40, height: 40),
                                inset: CGRect(x: 100, y: 20, width: 80, height: 80),
                                shape: .rectangle, outline: false, connector: false)
        m.style.opacity = opacity
        let mark = Annotation(z: 1, kind: .rectangle(CGRect(x: 105, y: 25, width: 70, height: 70)),
                              style: AnnotationStyle(color: Scene.blue, fill: Scene.blue, strokeWidth: 0, opacity: 0.5))
        let annotations = [m, mark]
        let source = Scene.image()
        let baked = try #require(AnnotationRenderer.bake(source: source, annotations: annotations))
        let result = try Compositor.renderDetailed(image: source, settings: settings(), annotations: annotations)
        for p in [CGPoint(x: 120, y: 55), CGPoint(x: 160, y: 55)] {
            #expect(px(result.image, output(p, result)) == px(baked, p))
        }
    }

    @Test func highlighterBlendsAgainstScreenshotAndInsetOnce() throws {
        let m = Scene.magnifier(source: CGRect(x: 40, y: 40, width: 10, height: 10),
                                inset: CGRect(x: 110, y: 20, width: 70, height: 70),
                                shape: .rectangle, outline: false, connector: false)
        let mark = Annotation(z: 1, kind: .highlighter([CGPoint(x: 80, y: 55), CGPoint(x: 165, y: 55)]),
                              style: AnnotationStyle(color: Scene.yellow, strokeWidth: 15))
        let annotations = [m, mark]
        let source = Scene.image()
        let baked = try #require(AnnotationRenderer.bake(source: source, annotations: annotations))
        let result = try Compositor.renderDetailed(image: source, settings: settings(), annotations: annotations)
        for p in [CGPoint(x: 90, y: 55), CGPoint(x: 145, y: 55)] {
            #expect(px(result.image, output(p, result)) == px(baked, p))
        }
    }

    @Test func redactionAboveInsetCoversEveryAntialiasedEdgePixel() throws {
        let inset = CGRect(x: 100, y: 10, width: 80, height: 80)
        var m = Scene.magnifier(source: CGRect(x: 40, y: 40, width: 10, height: 10),
                                inset: inset, outline: false, connector: false)
        m.style.strokeWidth = 0
        let mask = Annotation(z: 1, kind: .redact(inset.insetBy(dx: -2, dy: -2)),
                              style: AnnotationStyle(color: .black))
        let result = try Compositor.renderDetailed(image: Scene.image(), settings: settings(frame: .retro),
                                                   annotations: [m, mask])
        for y in 10..<90 { for x in 100..<180 {
            #expect(isBlack(px(result.image, output(CGPoint(x: x, y: y), result))))
        } }
    }

    @Test func higherAnnotationsCoverSourceOutlineAndConnector() throws {
        let m = Scene.magnifier(inset: CGRect(x: 110, y: 20, width: 70, height: 70))
        let mark = Annotation(z: 1, kind: .rectangle(CGRect(x: 20, y: 20, width: 85, height: 65)),
                              style: AnnotationStyle(color: Scene.blue, fill: Scene.blue, strokeWidth: 0))
        let source = Scene.image()
        let baked = try #require(AnnotationRenderer.bake(source: source, annotations: [m, mark]))
        let result = try Compositor.renderDetailed(image: source, settings: settings(frame: .retro),
                                                   annotations: [m, mark])
        for p in [CGPoint(x: 30, y: 50), CGPoint(x: 85, y: 52)] {
            #expect(isBlue(px(baked, p)))
            #expect(px(result.image, output(p, result)) == px(baked, p))
        }
    }

    @Test(arguments: [0.5, 1.5, 2.0])
    func floatingInsetUsesOutputScale(scale: Double) throws {
        var s = settings(frame: .phone)
        s.outputScale = scale
        let inset = CGRect(x: -25, y: -25, width: 80, height: 80)
        let m = Scene.magnifier(source: CGRect(x: 40, y: 40, width: 10, height: 10),
                                inset: inset, shape: .rectangle, outline: false, connector: false)
        let result = try Compositor.renderDetailed(image: Scene.image(), settings: s, annotations: [m])
        let center = CGPoint(x: result.layout.contentRect.minX + inset.midX * scale,
                             y: result.layout.contentRect.minY + inset.midY * scale)
        #expect(isRed(px(result.image, center)))
    }

    @Test func noMagnifiersKeepLegacyAnnotationPixels() throws {
        let annotations = [Annotation(kind: .rectangle(CGRect(x: 110, y: 20, width: 50, height: 50)),
                                      style: AnnotationStyle(color: Scene.blue, fill: Scene.blue, opacity: 0.5))]
        let source = Scene.image()
        let baked = try #require(AnnotationRenderer.bake(source: source, annotations: annotations))
        let s = settings(frame: .retro)
        let reference = try Compositor.render(image: baked, settings: s)
        let result = try Compositor.render(image: source, settings: s, annotations: annotations)
        #expect(try #require(PixelBuffer(result)).data == #require(PixelBuffer(reference)).data)
    }

    @Test func onlyMagnifiersExpand() throws {
        let image = Scene.image()
        let arrow = Annotation(kind: .arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 500, y: 300)))
        let baseline = try Compositor.renderDetailed(image: image, settings: settings())
        let r = try Compositor.renderDetailed(image: image, settings: settings(), annotations: [arrow])
        #expect(r.layout == baseline.layout)
    }

    @Test func layoutOverflowParameterDefaultsToNoOverflow() {
        let s = settings()
        let plain = Compositor.layout(contentSize: Scene.size, insetApplied: false, settings: s, backingScale: 2)
        let zero = Compositor.layout(contentSize: Scene.size, insetApplied: false, settings: s, backingScale: 2, overflow: .zero)
        #expect(plain == zero)
        #expect(plain.overflowRect == plain.contentRect)
        var scaled = s
        scaled.outputScale = 0.37
        let grown = Compositor.layout(contentSize: Scene.size, insetApplied: true, settings: scaled, backingScale: 2,
                                      overflow: FrameInsets(top: 11, left: 23, bottom: 0, right: 140))
        #expect(grown.overflowRect.contains(grown.contentRect))
        #expect(grown.overflowRect.width == ((200 + 23 + 140) * 0.37).rounded())
        #expect(grown.contentRect.size == Compositor.layout(contentSize: Scene.size, insetApplied: true, settings: scaled,
                                                            backingScale: 2).contentRect.size)
    }

    @Test func autoBalanceStillExpandsAndCropsTheBorder() throws {
        let margins = EdgeMargins(top: 30, left: 30, bottom: 30, right: 30)
        let image = Scene.image(margins: margins)
        var s = settings()
        s.autoBalance = true
        let offset = CGPoint(x: 30, y: 30)
        func shifted(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + offset.x, y: p.y + offset.y) }
        let source = Scene.lensSource.offsetBy(dx: 30, dy: 30)
        let inset = CGRect(x: 250, y: 40, width: 80, height: 80)
        let m = Scene.magnifier(source: source, inset: inset)
        let baseline = try Compositor.renderDetailed(image: image, settings: s)
        let r = try Compositor.renderDetailed(image: image, settings: s, annotations: [m])
        #expect(r.border != nil)
        #expect(r.region == CGRect(x: 20, y: 20, width: 219, height: 139))
        #expect(baseline.region == r.region)
        #expect(r.layout.contentRect.size == baseline.layout.contentRect.size)
        #expect(r.layout.canvasSize.width > baseline.layout.canvasSize.width)
        expectPaddingAroundEverything(r)
        #expect(isRed(px(r.image, output(Scene.lensPoint(shifted(Scene.redCenter), source: source, inset: inset), r))))
        #expect(isRed(px(r.image, output(shifted(Scene.redCenter), r))))
        // Image pixels the auto-balance crop removed stay hidden in the overflow area (beyond the 15 px card inset).
        #expect(isWhite(TestImages.pixel(image, 257, 150)))
        #expect(isBlack(px(r.image, output(CGPoint(x: 257, y: 150), r))))
    }

    @Test func autoBalanceFillOnlyCoversTheBaseRegion() throws {
        let image = Scene.image(margins: EdgeMargins(top: 30, left: 4, bottom: 30, right: 30))
        var s = settings()
        s.autoBalance = true
        let source = Scene.lensSource.offsetBy(dx: 4, dy: 30)
        let m = Scene.magnifier(source: source, inset: CGRect(x: 260, y: 40, width: 80, height: 80))
        let baseline = try Compositor.renderDetailed(image: image, settings: s)
        let r = try Compositor.renderDetailed(image: image, settings: s, annotations: [m])
        #expect(r.region.minX == -6)
        #expect(r.layout.canvasSize.width > baseline.layout.canvasSize.width)
        let fillPoint = CGPoint(x: -3, y: 60)
        #expect(isWhite(px(baseline.image, output(fillPoint, baseline))))
        #expect(isWhite(px(r.image, output(fillPoint, r))))
        // Beyond the 15 px card inset the overflow area shows the background, not the cropped border.
        #expect(isWhite(TestImages.pixel(image, Int(r.region.maxX) + 18, 150)))
        #expect(isBlack(px(r.image, output(CGPoint(x: r.region.maxX + 18, y: 150), r))))
    }

    /// Where a base-content point lands after rotation and flips, relative to the oriented base content.
    func orient(_ p: CGPoint, size: CGSize, rotation: Rotation, flipH: Bool, flipV: Bool) -> CGPoint {
        var q: CGPoint
        var s = size
        switch rotation {
        case .none: q = p
        case .cw90: q = CGPoint(x: size.height - p.y, y: p.x); s = CGSize(width: size.height, height: size.width)
        case .cw180: q = CGPoint(x: size.width - p.x, y: size.height - p.y)
        case .cw270: q = CGPoint(x: p.y, y: size.width - p.x); s = CGSize(width: size.height, height: size.width)
        }
        if flipH { q.x = s.width - q.x }
        if flipV { q.y = s.height - q.y }
        return q
    }

    struct Orientation: Sendable, CustomTestStringConvertible {
        var rotation: Rotation, flipH: Bool, flipV: Bool
        var testDescription: String { "\(rotation) h:\(flipH) v:\(flipV)" }
    }

    @Test(arguments: [
        Orientation(rotation: .none, flipH: false, flipV: false),
        Orientation(rotation: .cw90, flipH: false, flipV: false),
        Orientation(rotation: .cw180, flipH: false, flipV: false),
        Orientation(rotation: .cw270, flipH: false, flipV: false),
        Orientation(rotation: .none, flipH: true, flipV: false),
        Orientation(rotation: .none, flipH: false, flipV: true),
        Orientation(rotation: .cw90, flipH: true, flipV: false),
        Orientation(rotation: .cw270, flipH: false, flipV: true),
        Orientation(rotation: .cw180, flipH: true, flipV: true),
    ])
    func rotationAndFlipsKeepTheScreenshotInTheCard(o: Orientation) throws {
        let image = Scene.image()
        var s = settings()
        s.rotation = o.rotation; s.flipHorizontal = o.flipH; s.flipVertical = o.flipV
        let inset = CGRect(x: 220, y: -40, width: 80, height: 80)
        let baseline = try Compositor.renderDetailed(image: image, settings: s)
        let r = try Compositor.renderDetailed(image: image, settings: s, annotations: [Scene.magnifier(inset: inset)])
        #expect(r.layout.contentRect.size == baseline.layout.contentRect.size)
        #expect(r.layout.cardRect.size == baseline.layout.cardRect.size)
        expectPaddingAroundEverything(r)
        func out(_ p: CGPoint) -> CGPoint {
            let q = orient(p, size: Scene.size, rotation: o.rotation, flipH: o.flipH, flipV: o.flipV)
            return CGPoint(x: r.layout.contentRect.minX + q.x, y: r.layout.contentRect.minY + q.y)
        }
        #expect(r.layout.cardRect.contains(out(Scene.blueCenter)))
        #expect(isBlue(px(r.image, out(Scene.blueCenter))))
        #expect(isRed(px(r.image, out(Scene.redCenter))))
        let lensRed = out(Scene.lensPoint(Scene.redCenter, inset: inset))
        #expect(!r.layout.cardRect.contains(lensRed))
        #expect(isRed(px(r.image, lensRed)))
        #expect(isGreen(px(r.image, out(Scene.lensPoint(Scene.greenCenter, inset: inset)))))
    }

    @Test func windowFrameWrapsOnlyTheBaseContent() throws {
        let image = Scene.image()
        let s = settings(frame: .macOS)
        let inset = CGRect(x: 220, y: -60, width: 80, height: 80)
        let baseline = try Compositor.renderDetailed(image: image, settings: s)
        let r = try Compositor.renderDetailed(image: image, settings: s, annotations: [Scene.magnifier(inset: inset)])
        #expect(r.layout.barHeight == 28)
        #expect(r.layout.cardRect.size == baseline.layout.cardRect.size)
        #expect(r.layout.cardRect.width == r.layout.contentRect.width)
        #expect(r.layout.cardRect.height == r.layout.contentRect.height + 28)
        #expect(r.layout.contentRect.minY - r.layout.cardRect.minY == 28)
        #expect(!r.layout.cardRect.contains(r.layout.overflowRect))
        expectPaddingAroundEverything(r)
        let lensRed = output(Scene.lensPoint(Scene.redCenter, inset: inset), r)
        #expect(!r.layout.cardRect.contains(lensRed))
        #expect(isRed(px(r.image, lensRed)))
        #expect(isRed(px(r.image, output(Scene.redCenter, r))))
        // The title bar is still drawn above the content, under the overflow.
        let bar = CGPoint(x: r.layout.cardRect.minX + 100, y: r.layout.cardRect.minY + 14)
        #expect(!isBlack(px(r.image, bar)))
        #expect(px(baseline.image, CGPoint(x: baseline.layout.cardRect.minX + 100, y: baseline.layout.cardRect.minY + 14))
                == px(r.image, bar))
    }

    @Test func tiltedRenderKeepsTheExpandedCanvas() throws {
        let image = Scene.image()
        var s = settings()
        let m = Scene.magnifier(inset: CGRect(x: 220, y: 10, width: 80, height: 80))
        let flat = try Compositor.renderDetailed(image: image, settings: s, annotations: [m])
        s.tilt = Tilt(x: 10, y: -12)
        let tilted = try Compositor.renderDetailed(image: image, settings: s, annotations: [m])
        #expect(tilted.layout == flat.layout)
        #expect(tilted.image.width == flat.image.width)
    }

    @Test func failedBakeWithOverflowThrows() {
        let m = Scene.magnifier(inset: CGRect(x: 220, y: 10, width: 80, height: 80))
        #expect(throws: RenderError.annotationsNotApplied) {
            try Compositor.renderDetailed(image: Scene.image(), settings: settings(), annotations: [m],
                                          bake: { _, _, _, _ in nil })
        }
    }

    @Test func exportIncludesTheInset() throws {
        let image = Scene.image()
        let s = settings()
        let inset = CGRect(x: 220, y: 10, width: 80, height: 80)
        let m = Scene.magnifier(inset: inset)
        let detailed = try Compositor.renderDetailed(image: image, settings: s, annotations: [m])
        let rendered = try Compositor.render(image: image, settings: s, annotations: [m])
        #expect(try #require(PixelBuffer(rendered)).data == #require(PixelBuffer(detailed.image)).data)
        let decoded = try #require(GlintImageIO.load(data: Exporter.data(for: rendered, format: .plainPNG)))
        #expect(decoded.width == rendered.width && decoded.height == rendered.height)
        #expect(isRed(px(decoded, output(Scene.lensPoint(Scene.redCenter, inset: inset), detailed))))
        #expect(isGreen(px(decoded, output(Scene.lensPoint(Scene.greenCenter, inset: inset), detailed))))
    }

    @Test func largeEditorInsetIsNotClipped() throws {
        let image = TestImages.solid(1000, 800, Scene.red)
        let inset = CGRect(x: 1024, y: -100, width: 1250, height: 1000)
        let m = Scene.magnifier(source: CGRect(x: 0, y: 0, width: 1000, height: 800), inset: inset, shape: .rectangle)
        let bounds = try #require(m.magnifierRenderBounds)
        let base = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(Compositor.expandedRegion(base: base, annotations: [m]) == base.union(bounds).integral)
        let r = try Compositor.renderDetailed(image: image, settings: settings(), annotations: [m])
        #expect(r.layout.overflowRect.width >= bounds.maxX)
        #expect(isRed(px(r.image, output(CGPoint(x: inset.maxX - 10, y: inset.midY), r))))
        #expect(isRed(px(r.image, output(CGPoint(x: inset.midX, y: inset.minY + 10), r))))
    }

    @Test func absurdInsetIsLimitedToThePixelBudget() {
        let base = CGRect(x: 0, y: 0, width: 100, height: 80)
        let far = Scene.magnifier(source: CGRect(x: 0, y: 0, width: 10, height: 10),
                                  inset: CGRect(x: 1_000_000, y: 0, width: 20, height: 20))
        let r = Compositor.expandedRegion(base: base, annotations: [far])
        #expect(r.contains(base) && abs(r.width - Compositor.maxExpandedSide) <= 1 && r.height <= 200)
        let huge = Scene.magnifier(source: CGRect(x: 0, y: 0, width: 10, height: 10),
                                   inset: CGRect(x: -50_000, y: -50_000, width: 100_000, height: 100_000))
        let h = Compositor.expandedRegion(base: base, annotations: [huge])
        #expect(h.contains(base) && h.width <= Compositor.maxExpandedSide + 1)
        #expect((h.width - 1) * (h.height - 1) <= Compositor.maxExpandedArea)
    }

    @Test func overflowDoesNotRestoreSquareScreenshotCorners() throws {
        let image = TestImages.solid(200, 120, .white)
        let s = RenderSettings(padding: 20, inset: 0, cornerRadius: 20, shadow: .none, background: .solid(.black),
                               autoBalance: false)
        let m = Scene.magnifier(source: CGRect(x: 150, y: 50, width: 20, height: 20),
                                inset: CGRect(x: 400, y: 40, width: 40, height: 40), shape: .rectangle)
        let baseline = try Compositor.renderDetailed(image: image, settings: s)
        let r = try Compositor.renderDetailed(image: image, settings: s, annotations: [m])
        for result in [baseline, r] {
            let c = result.layout.contentRect
            #expect(isBlack(px(result.image, CGPoint(x: c.minX + 1, y: c.minY + 1))))
            #expect(isBlack(px(result.image, CGPoint(x: c.minX + 1, y: c.maxY - 2))))
            #expect(isWhite(px(result.image, CGPoint(x: c.midX, y: c.midY))))
        }
    }
}
