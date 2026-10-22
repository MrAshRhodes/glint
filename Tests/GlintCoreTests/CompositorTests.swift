import CoreGraphics
import Testing
@testable import GlintCore

@Suite("Compositor")
struct CompositorTests {
    func settings(padding: Double = 20, inset: Double = 15, insetColor: RGBAColor? = nil) -> RenderSettings {
        RenderSettings(padding: padding, inset: inset, insetColor: insetColor, cornerRadius: 0,
                       shadow: .none, background: .solid(.black), autoBalance: false)
    }

    @Test func paddingMath1x() throws {
        let out = try Compositor.render(image: TestImages.solid(100, 50, .white), settings: settings(), backingScale: 1)
        #expect(out.width == 140 && out.height == 90)
    }

    @Test func paddingFlooredAndScaled() throws {
        let out = try Compositor.render(image: TestImages.solid(200, 100, .white), settings: settings(padding: 20.9),
                                    backingScale: 2)
        #expect(out.width == 280 && out.height == 180) // floor(20.9)=20 pt × 2 × 2 sides + 200
    }

    @Test func insetBandOnlyWithColour() throws {
        let withColour = try Compositor.render(image: TestImages.solid(100, 50, .white),
                                           settings: settings(insetColor: .red), backingScale: 1)
        #expect(withColour.width == 100 + 2 * 35 && withColour.height == 50 + 2 * 35)
        let px = TestImages.pixel(withColour, 22, 45) // inside inset band, left of content
        #expect(px.r > 200 && px.g < 40)
    }

    @Test func autoBalanceAddsInsetFromDetectedBorder() throws {
        var s = settings()
        s.autoBalance = true
        let img = TestImages.framed(width: 200, height: 100, margins: EdgeMargins(top: 30, left: 30, bottom: 30, right: 30))
        let r = try Compositor.renderDetailed(image: img, settings: s, backingScale: 1)
        #expect(r.border != nil)
        // content 140×40 + 10/9 margins = 159×59, + 2*(20+15)
        #expect(r.image.width == 159 + 70 && r.image.height == 59 + 70)
    }

    @Test func aspectRatioFitting() throws {
        var s = settings()
        s.aspectRatio = .r16x9
        let out = try Compositor.render(image: TestImages.solid(100, 100, .white), settings: s)
        let ratio = Double(out.width) / Double(out.height)
        #expect(abs(ratio - 16.0 / 9) < 0.02)
        #expect(out.width >= 140 && out.height >= 140)
        s.aspectRatio = .square
        let sq = try Compositor.render(image: TestImages.solid(200, 100, .white), settings: s)
        #expect(sq.width == sq.height)
    }

    @Test func shadowPresentBelowCard() throws {
        var s = RenderSettings(padding: 60, cornerRadius: 0, background: .transparent, autoBalance: false)
        s.shadow = ShadowSettings(enabled: true, strength: 50)
        let img = TestImages.solid(100, 100, .white)
        let out = try Compositor.render(image: img, settings: s)
        #expect(out.width == 220)
        #expect(TestImages.pixel(out, 110, 165).a > 10) // below the card (card spans y 60…160)
        s.shadow = .none
        let flat = try Compositor.render(image: img, settings: s)
        #expect(TestImages.pixel(flat, 110, 165).a == 0)
        #expect(TestImages.pixel(flat, 110, 110).a == 255)
    }

    @Test func shadowIsAsymmetric() throws {
        let s = RenderSettings(padding: 80, cornerRadius: 0, shadow: ShadowSettings(strength: 50), background: .transparent, autoBalance: false)
        let out = try Compositor.render(image: TestImages.solid(100, 100, .white), settings: s)
        let below = TestImages.pixel(out, 130, 80 + 100 + 10).a
        let above = TestImages.pixel(out, 130, 80 - 10).a
        #expect(below > above)
    }

    @Test func roundedCornersClipContent() throws {
        let s = RenderSettings(padding: 10, cornerRadius: 30, shadow: .none, background: .transparent, autoBalance: false)
        let out = try Compositor.render(image: TestImages.solid(100, 100, .white), settings: s)
        #expect(TestImages.pixel(out, 10, 10).a == 0)
        #expect(TestImages.pixel(out, 60, 60).a == 255)
    }

    @Test func rotationSwapsDimensions() throws {
        var s = settings(padding: 0)
        s.rotation = .cw90
        let out = try Compositor.render(image: TestImages.solid(100, 50, .white), settings: s)
        #expect(out.width == 50 && out.height == 100)
    }

    @Test func rotationMovesPixelsClockwise() throws {
        // red on the top-left corner moves to top-right after 90° clockwise
        let ctx = GlintBitmap.makeContext(width: 40, height: 20)!
        ctx.setFillColor(RGBAColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        ctx.setFillColor(RGBAColor.red.cgColor); ctx.fill(CGRect(x: 0, y: 10, width: 10, height: 10)) // top-left
        var s = settings(padding: 0); s.rotation = .cw90
        let out = try Compositor.render(image: ctx.makeImage()!, settings: s)
        let p = TestImages.pixel(out, 15, 5)
        #expect(p.r > 200 && p.g < 60)
    }

    @Test func windowFrameAddsTitleBar() throws {
        var s = settings(padding: 0)
        s.windowFrame = WindowFrameSettings(style: .macOS, dark: false, title: "Glint")
        let out = try Compositor.render(image: TestImages.solid(100, 50, .white), settings: s)
        #expect(out.width == 100 && out.height == 50 + 28)
        s.windowFrame.style = .browser
        #expect(try Compositor.render(image: TestImages.solid(100, 50, .white), settings: s).height == 50 + 40)
    }

    @Test func tiltKeepsCanvasSizeAndRenders() throws {
        var s = settings()
        let flat = try Compositor.render(image: TestImages.solid(120, 80, .white), settings: s)
        s.tilt = Tilt(uiX: 25, uiY: 5)
        let tilted = try Compositor.render(image: TestImages.solid(120, 80, .white), settings: s)
        #expect(tilted.width == flat.width && tilted.height == flat.height)
        #expect(TestImages.pixel(tilted, tilted.width / 2, tilted.height / 2).r > 200)
    }

    @Test func watermarkDrawsPixels() throws {
        var s = settings(padding: 40)
        s.background = .solid(.black)
        let plain = try Compositor.render(image: TestImages.solid(200, 100, .white), settings: s)
        s.watermark = WatermarkSettings(enabled: true, text: "Screenshot by Glint", position: .bottomRight, opacity: 1, size: 14)
        let marked = try Compositor.render(image: TestImages.solid(200, 100, .white), settings: s)
        #expect(plain.width == marked.width)
        var diff = 0
        let a = PixelBuffer(plain)!, b = PixelBuffer(marked)!
        for y in (marked.height - 40)..<marked.height { for x in (marked.width - 200)..<marked.width where a.pixel(x, y) != b.pixel(x, y) { diff += 1 } }
        #expect(diff > 20)
    }

    @Test func deterministic() throws {
        let img = TestImages.framed(width: 120, height: 80, margins: EdgeMargins(top: 12, left: 12, bottom: 12, right: 12))
        let s = RenderSettings()
        let a = try PixelBuffer(Compositor.render(image: img, settings: s))!
        let b = try PixelBuffer(Compositor.render(image: img, settings: s))!
        #expect(a.data == b.data)
    }

    @Test func backgroundsRenderEveryCatalogEntry() throws {
        for preset in BackgroundCatalog.all {
            var s = settings(padding: 8)
            s.background = preset.style
            let out = try Compositor.render(image: TestImages.solid(20, 20, .white), settings: s)
            #expect(out.width == 36, "\(preset.id)")
            if preset.style != .transparent { #expect(TestImages.pixel(out, 1, 1).a == 255, "\(preset.id)") }
        }
    }

    @Test func linearGradientDirection() throws {
        var s = settings(padding: 50)
        s.background = .linear(LinearGradient(angle: 90, hexes: ["#000000", "#FFFFFF"]))
        let out = try Compositor.render(image: TestImages.solid(10, 10, .red), settings: s)
        #expect(TestImages.pixel(out, 1, 5).r < TestImages.pixel(out, out.width - 2, 5).r)
    }
}
