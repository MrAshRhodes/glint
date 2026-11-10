import CoreGraphics
import Testing
@testable import GlintCore

@Suite("ProvisionalFrame")
struct ProvisionalFrameTests {
    struct Look: Sendable, CustomTestStringConvertible {
        var name: String
        var settings: RenderSettings
        var backingScale: CGFloat = 1
        var testDescription: String { name }
    }

    static func base(_ edit: (inout RenderSettings) -> Void = { _ in }) -> RenderSettings {
        var settings = RenderSettings(padding: 0, inset: 0, cornerRadius: 0, shadow: .none,
                                      background: .solid(.black), autoBalance: false)
        edit(&settings)
        return settings
    }

    static let looks: [Look] = [
        Look(name: "plain", settings: base()),
        Look(name: "padded", settings: base { $0.padding = 24 }),
        Look(name: "inset band", settings: base { $0.padding = 24; $0.inset = 15; $0.insetColor = .red }),
        Look(name: "window frame", settings: base {
            $0.padding = 16
            $0.windowFrame = WindowFrameSettings(style: .macOS, screenEffects: false)
        }),
        Look(name: "16:9 canvas", settings: base { $0.padding = 20; $0.aspectRatio = .r16x9 }),
        Look(name: "rotated 90", settings: base { $0.padding = 12; $0.rotation = .cw90 }),
        Look(name: "rotated 180", settings: base { $0.padding = 12; $0.rotation = .cw180 }),
        Look(name: "rotated 270", settings: base { $0.padding = 12; $0.rotation = .cw270 }),
        Look(name: "flipped horizontally", settings: base { $0.padding = 12; $0.flipHorizontal = true }),
        Look(name: "flipped vertically", settings: base { $0.padding = 12; $0.flipVertical = true }),
        Look(name: "rotated and flipped", settings: base {
            $0.padding = 12; $0.rotation = .cw90; $0.flipHorizontal = true; $0.flipVertical = true
        }),
        Look(name: "half output scale", settings: base { $0.padding = 24; $0.outputScale = 0.5 }),
        Look(name: "double output scale", settings: base { $0.padding = 24; $0.outputScale = 2 }),
        Look(name: "Retina", settings: base { $0.padding = 24; $0.inset = 10; $0.insetColor = .white }, backingScale: 2),
    ]

    /// Red, green, blue and yellow quadrants (top-left, top-right, bottom-left, bottom-right), so any
    /// rotation, flip or misplacement shows.
    static func quadrants(_ width: Int = 40, _ height: Int = 30) -> CGImage {
        let ctx = GlintBitmap.makeContext(width: width, height: height)!
        func fill(_ color: RGBAColor, x: Int, y: Int) {
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: x, y: y, width: width / 2, height: height / 2))
        }
        fill(RGBAColor(r: 1, g: 0, b: 0), x: 0, y: height / 2)
        fill(RGBAColor(r: 0, g: 1, b: 0), x: width / 2, y: height / 2)
        fill(RGBAColor(r: 0, g: 0, b: 1), x: 0, y: 0)
        fill(RGBAColor(r: 1, g: 1, b: 0), x: width / 2, y: 0)
        return ctx.makeImage()!
    }

    /// The frame drawn the way the editor draws it, into a bitmap the size of the canvas.
    static func drawn(_ frame: ProvisionalFrame, _ image: CGImage, over backdrop: RGBAColor = .clear) throws -> CGImage {
        let ctx = try #require(GlintBitmap.makeContext(width: Int(frame.layout.canvasSize.width),
                                                       height: Int(frame.layout.canvasSize.height)))
        ctx.setFillColor(backdrop.cgColor)
        ctx.fill(CGRect(origin: .zero, size: frame.layout.canvasSize))
        ctx.interpolationQuality = .medium
        frame.draw(image, in: ctx, scale: 1)
        return try #require(ctx.makeImage())
    }

    /// The content rect's quadrant centres, top-left origin.
    static func samples(_ rect: CGRect) -> [(x: Int, y: Int)] {
        [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map {
            (Int(rect.minX + rect.width * $0.0), Int(rect.minY + rect.height * $0.1))
        }
    }

    /// Largest per-channel difference over the content rect, one pixel in from its edges.
    static func worstDifference(_ a: CGImage, _ b: CGImage, in rect: CGRect) throws -> Int {
        let first = try #require(PixelBuffer(a)), second = try #require(PixelBuffer(b))
        var worst = 0
        for y in Int(rect.minY) + 1..<Int(rect.maxY) - 1 {
            for x in Int(rect.minX) + 1..<Int(rect.maxX) - 1 {
                let p = first.pixel(x, y), q = second.pixel(x, y)
                worst = max(worst, abs(Int(p.0) - Int(q.0)), abs(Int(p.1) - Int(q.1)),
                            abs(Int(p.2) - Int(q.2)), abs(Int(p.3) - Int(q.3)))
            }
        }
        return worst
    }

    @Test(arguments: looks)
    func geometryMatchesTheComposedRender(_ look: Look) throws {
        let image = Self.quadrants()
        let frame = try #require(ProvisionalFrame(image: image, settings: look.settings, annotations: [],
                                                  backingScale: look.backingScale))
        let composed = try Compositor.renderDetailed(image: image, settings: look.settings,
                                                     backingScale: look.backingScale)
        #expect(frame.layout == composed.layout)
        #expect(frame.region == composed.region)
        #expect(frame.layout.canvasSize == CGSize(width: composed.image.width, height: composed.image.height))
    }

    @Test(arguments: looks)
    func contentLandsWhereTheComposedRenderPutsIt(_ look: Look) throws {
        let image = Self.quadrants()
        let frame = try #require(ProvisionalFrame(image: image, settings: look.settings, annotations: [],
                                                  backingScale: look.backingScale))
        let composed = try Compositor.render(image: image, settings: look.settings, backingScale: look.backingScale)
        let provisional = try Self.drawn(frame, image)
        for point in Self.samples(frame.layout.contentRect) {
            let expected = TestImages.pixel(composed, point.x, point.y)
            let actual = TestImages.pixel(provisional, point.x, point.y)
            #expect(actual == expected, "\(look.name) at \(point)")
        }
    }

    @Test func orientationPutsTheQuadrantsWhereTheRotationDoes() throws {
        // Clockwise 90° moves top-left to top-right: red, green, blue, yellow become blue, red, yellow, green.
        let image = Self.quadrants()
        let settings = Self.base { $0.rotation = .cw90 }
        let frame = try #require(ProvisionalFrame(image: image, settings: settings, annotations: [], backingScale: 1))
        let provisional = try Self.drawn(frame, image)
        let colours = Self.samples(frame.layout.contentRect).map { TestImages.pixel(provisional, $0.x, $0.y) }
        #expect(colours[0].b == 255 && colours[0].r == 0)
        #expect(colours[1].r == 255 && colours[1].g == 0 && colours[1].b == 0)
        #expect(colours[2].r == 255 && colours[2].g == 255)
        #expect(colours[3].g == 255 && colours[3].r == 0)
    }

    @Test(arguments: [
        EdgeMargins(top: 30, left: 30, bottom: 30, right: 30),
        EdgeMargins(top: 15, left: 15, bottom: 4, right: 4),
        EdgeMargins(top: 4, left: 40, bottom: 25, right: 3),
    ])
    func autoBalanceCropIsPredictedLikeTheRender(_ margins: EdgeMargins) throws {
        let image = TestImages.framed(width: 200, height: 100, margins: margins)
        let settings = Self.base { $0.padding = 20; $0.inset = 15; $0.autoBalance = true }
        let frame = try #require(ProvisionalFrame(image: image, settings: settings, annotations: [], backingScale: 1))
        let composed = try Compositor.renderDetailed(image: image, settings: settings, backingScale: 1)
        let border = try #require(composed.border)
        #expect(frame.layout == composed.layout)
        #expect(frame.region == composed.region)
        #expect(frame.region != CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(frame.fill == border.color)
        let provisional = try Self.drawn(frame, image)
        #expect(try Self.worstDifference(provisional, composed.image, in: frame.layout.contentRect) <= 2)
    }

    @Test func largeImagesSkipBorderDetectionJustLikeTheRender() throws {
        let ctx = try #require(GlintBitmap.makeContext(width: 1000, height: 1000))
        ctx.setFillColor(RGBAColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
        ctx.setFillColor(RGBAColor.red.cgColor)
        ctx.fill(CGRect(x: 300, y: 300, width: 400, height: 400))
        let image = try #require(ctx.makeImage())
        #expect(image.width * image.height > AutoBalance.maxPixels)
        let settings = Self.base { $0.padding = 20; $0.autoBalance = true }
        let frame = try #require(ProvisionalFrame(image: image, settings: settings, annotations: [], backingScale: 1))
        let composed = try Compositor.renderDetailed(image: image, settings: settings, backingScale: 1)
        #expect(composed.border == nil)
        #expect(frame.region == composed.region && frame.layout == composed.layout)
    }

    @Test func isUnavailableWhereTheRenderChangesTheCapture() throws {
        let image = Self.quadrants()
        #expect(ProvisionalFrame(image: image, settings: Self.base(), annotations: [], backingScale: 1) != nil)

        var tilted = Self.base()
        tilted.tilt = Tilt(x: 5, y: 0)
        #expect(ProvisionalFrame(image: image, settings: tilted, annotations: [], backingScale: 1) == nil)

        let redaction = Annotation(kind: .redact(CGRect(x: 2, y: 2, width: 10, height: 10)))
        #expect(ProvisionalFrame(image: image, settings: Self.base(), annotations: [redaction], backingScale: 1) == nil)

        // 40 × 30 = 1200 pixels.
        #expect(ProvisionalFrame(image: image, settings: Self.base(), annotations: [], backingScale: 1,
                                 maxPixels: 1199) == nil)
        #expect(ProvisionalFrame(image: image, settings: Self.base(), annotations: [], backingScale: 1,
                                 maxPixels: 1200) != nil)
    }

    @Test func drawingStaysInsideTheContentRect() throws {
        let image = Self.quadrants()
        let settings = Self.base { $0.padding = 20; $0.inset = 6; $0.insetColor = .red }
        let frame = try #require(ProvisionalFrame(image: image, settings: settings, annotations: [], backingScale: 1))
        let out = try Self.drawn(frame, image, over: RGBAColor(r: 0, g: 0, b: 1))
        let content = frame.layout.contentRect
        var strays = 0
        for y in 0..<out.height {
            for x in 0..<out.width where !content.contains(CGPoint(x: x, y: y)) {
                let p = TestImages.pixel(out, x, y)
                if p.r != 0 || p.g != 0 || p.b != 255 || p.a != 255 { strays += 1 }
            }
        }
        #expect(strays == 0)
        #expect(TestImages.pixel(out, Int(content.minX) + 2, Int(content.minY) + 2).r == 255)
    }

    @Test func scalingTheDrawingScalesTheFrame() throws {
        let image = Self.quadrants()
        let settings = Self.base { $0.padding = 20 }
        let frame = try #require(ProvisionalFrame(image: image, settings: settings, annotations: [], backingScale: 1))
        let half = try #require(GlintBitmap.makeContext(width: Int(frame.layout.canvasSize.width / 2),
                                                        height: Int(frame.layout.canvasSize.height / 2)))
        half.interpolationQuality = .medium
        frame.draw(image, in: half, scale: 0.5)
        let out = try #require(half.makeImage())
        let content = frame.layout.contentRect
        let red = TestImages.pixel(out, Int(content.minX / 2 + content.width / 8), Int(content.minY / 2 + content.height / 8))
        #expect(red.r == 255 && red.g == 0 && red.b == 0)
        #expect(TestImages.pixel(out, 1, 1).a == 0)
    }
}
