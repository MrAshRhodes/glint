import CoreGraphics
import Testing
@testable import GlintCore

@Suite("Annotations")
struct AnnotationTests {
    let noise = TestImages.framed(width: 120, height: 80, margins: EdgeMargins(top: 0, left: 0, bottom: 0, right: 0))
    func flat(_ anns: [Annotation], _ image: CGImage? = nil) -> CGImage {
        let s = RenderSettings(padding: 0, inset: 0, cornerRadius: 0, shadow: .none, background: .transparent, autoBalance: false)
        return Compositor.render(image: image ?? noise, settings: s, annotations: anns)
    }
    func sameRegion(_ a: CGImage, _ b: CGImage, _ r: CGRect) -> Bool {
        let pa = PixelBuffer(a)!, pb = PixelBuffer(b)!
        for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) where pa.pixel(x, y) != pb.pixel(x, y) { return false } }
        return true
    }

    @Test func solidRedactionDestroysPixelsEvenWithLowOpacity() {
        let region = CGRect(x: 20, y: 10, width: 50, height: 30)
        var style = AnnotationStyle(color: RGBAColor(hex: "#9C129E")!)
        style.opacity = 0.2
        let out = flat([Annotation(kind: .redact(region), style: style)])
        let p = PixelBuffer(out)!
        for y in 10..<40 { for x in 20..<70 {
            let px = p.pixel(x, y)
            #expect(px.0 == 0x9C && px.1 == 0x12 && px.2 == 0x9E && px.3 == 255)
        } }
        #expect(sameRegion(out, noise, CGRect(x: 80, y: 50, width: 30, height: 20))) // untouched elsewhere
    }

    @Test func blurChangesAndSmoothsRegion() {
        let region = CGRect(x: 20, y: 10, width: 60, height: 40)
        let out = flat([Annotation(kind: .blur(region), style: AnnotationStyle(intensity: 10))])
        #expect(!sameRegion(out, noise, region))
        func variance(_ img: CGImage) -> Double {
            let b = PixelBuffer(img)!
            var vals: [Double] = []
            for y in 15..<45 { for x in 30..<70 { vals.append(Double(b.pixel(x, y).0)) } }
            let mean = vals.reduce(0, +) / Double(vals.count)
            return vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(vals.count)
        }
        #expect(variance(out) < variance(noise) / 4)
        #expect(sameRegion(out, noise, CGRect(x: 90, y: 60, width: 20, height: 10)))
    }

    @Test func pixelateMakesBlocks() {
        let region = CGRect(x: 0, y: 0, width: 60, height: 60)
        let out = flat([Annotation(kind: .pixelate(region), style: AnnotationStyle(intensity: 20))])
        let b = PixelBuffer(out)!
        #expect(b.pixel(2, 2) == b.pixel(15, 15)) // same 20-px cell
        #expect(!sameRegion(out, noise, region))
    }

    @Test func redactionReadsSourceNotOtherAnnotations() {
        // blur over a text-like block must be derived from the source, then survive a later arrow elsewhere
        let anns = [Annotation(z: 1, kind: .blur(CGRect(x: 0, y: 0, width: 40, height: 40))),
                    Annotation(z: 2, kind: .arrow(from: CGPoint(x: 60, y: 60), to: CGPoint(x: 110, y: 70)))]
        let out = flat(anns)
        #expect(!sameRegion(out, noise, CGRect(x: 0, y: 0, width: 40, height: 40)))
        #expect(!sameRegion(out, noise, CGRect(x: 60, y: 58, width: 50, height: 14)))
    }

    @Test func redactionOnlyExportContainsNoOriginalPixels() throws {
        // end-to-end through the exporter: decode PNG and verify the secret area is flat
        let secret = TestImages.framed(width: 80, height: 40, margins: EdgeMargins(top: 0, left: 0, bottom: 0, right: 0))
        let out = flat([Annotation(kind: .redact(CGRect(x: 0, y: 0, width: 80, height: 40)), style: AnnotationStyle(color: .black))], secret)
        let data = try Exporter.data(for: out, format: .plainPNG)
        let decoded = try #require(GlintImageIO.load(data: data))
        let b = PixelBuffer(decoded)!
        var distinct = Set<UInt32>()
        for y in 0..<40 { for x in 0..<80 { let p = b.pixel(x, y); distinct.insert(UInt32(p.0) << 16 | UInt32(p.1) << 8 | UInt32(p.2)) } }
        #expect(distinct == [0])
    }

    @Test func shapesDrawOnlyInsideTheirBounds() {
        let white = TestImages.solid(100, 100, .white)
        let rect = Annotation(kind: .rectangle(CGRect(x: 20, y: 20, width: 60, height: 40)), style: AnnotationStyle(color: .black, strokeWidth: 4))
        let out = flat([rect], white)
        #expect(TestImages.pixel(out, 20, 40).r < 50) // left edge stroke
        #expect(TestImages.pixel(out, 50, 40).r == 255) // interior untouched (no fill)
        #expect(TestImages.pixel(out, 5, 5).r == 255)
        let filled = Annotation(kind: .ellipse(CGRect(x: 20, y: 20, width: 60, height: 60)), style: AnnotationStyle(color: .black, fill: RGBAColor(hex: "#00FF00")))
        let o2 = flat([filled], white)
        #expect(TestImages.pixel(o2, 50, 50).g == 255 && TestImages.pixel(o2, 50, 50).r == 0)
        #expect(TestImages.pixel(o2, 21, 21).g == 255 && TestImages.pixel(o2, 21, 21).r == 255) // outside ellipse corner
    }

    @Test func zOrderIsRespected() {
        let white = TestImages.solid(60, 60, .white)
        let big = CGRect(x: 10, y: 10, width: 40, height: 40)
        let red = Annotation(z: 2, kind: .rectangle(big), style: AnnotationStyle(color: .red, fill: .red))
        let blue = Annotation(z: 1, kind: .rectangle(big), style: AnnotationStyle(color: RGBAColor(hex: "#0000FF")!, fill: RGBAColor(hex: "#0000FF")))
        let out = flat([red, blue], white)
        let p = TestImages.pixel(out, 30, 30)
        #expect(p.r > 200 && p.b < 60) // z=2 on top regardless of array order
    }

    @Test func textAndCounterRender() {
        let white = TestImages.solid(200, 100, .white)
        let t = Annotation(kind: .text(origin: CGPoint(x: 10, y: 10), string: "Hello", maxWidth: 0), style: AnnotationStyle(color: .black, fontSize: 30))
        let c = Annotation(kind: .counter(center: CGPoint(x: 150, y: 50), number: 3))
        let out = flat([t, c], white)
        let b = PixelBuffer(out)!
        var dark = 0
        for y in 5..<50 { for x in 5..<120 where b.pixel(x, y).0 < 100 { dark += 1 } }
        #expect(dark > 40)
        #expect(b.pixel(150, 36).0 > 200 && b.pixel(150, 36).1 < 60) // badge fill (above the digit)
    }

    @Test func textIsUpright() {
        // glyph "T": top bar is wider than the stem → more dark pixels in the top rows than bottom rows
        let white = TestImages.solid(100, 100, .white)
        let t = Annotation(kind: .text(origin: CGPoint(x: 20, y: 20), string: "T", maxWidth: 0), style: AnnotationStyle(color: .black, fontSize: 60))
        let b = PixelBuffer(flat([t], white))!
        let rows = (0..<100).map { y in (0..<100).filter { b.pixel($0, y).0 < 128 }.count }
        let inked = rows.indices.filter { rows[$0] > 0 }
        let widest = rows.indices.max { rows[$0] < rows[$1] }!
        #expect(widest < (inked.first! + inked.last!) / 2) // the bar of the T is in the upper half
    }

    @Test func bakeSupportsRegionBeyondImage() throws {
        let src = TestImages.solid(10, 10, .white)
        let baked = try #require(AnnotationRenderer.bake(source: src, annotations: [], region: CGRect(x: -5, y: -5, width: 20, height: 20), fill: .black))
        #expect(baked.width == 20)
        #expect(TestImages.pixel(baked, 1, 1).r == 0)
        #expect(TestImages.pixel(baked, 10, 10).r == 255)
    }
}
