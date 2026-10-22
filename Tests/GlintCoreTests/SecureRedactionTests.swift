import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

@Suite("Secure redactions")
struct SecureRedactionTests {
    private let primary = RGBAColor(red8: 180, green8: 30, blue8: 210, alpha8: 1)
    private let secondary = RGBAColor(red8: 20, green8: 220, blue8: 130, alpha8: 0)

    private func variants(_ rect: CGRect) -> [Annotation] {
        let plain = AnnotationStyle(color: primary, fill: .clear, opacity: 0, intensity: 8.5, cornerRadius: 100,
                                    redactionSecondaryColor: secondary)
        var checkerboard = plain
        checkerboard.redactionPattern = .checkerboard
        var accent = plain
        accent.pixelateHighlight = true
        return [
            Annotation(kind: .redact(rect), style: plain),
            Annotation(kind: .redact(rect), style: checkerboard),
            Annotation(kind: .pixelate(rect), style: plain),
            Annotation(kind: .pixelate(rect), style: accent),
        ]
    }

    private func secretImage(_ string: String, region: CGRect) throws -> CGImage {
        let ctx = try #require(GlintBitmap.makeContext(width: 240, height: 128))
        ctx.setFillColor(RGBAColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 128))
        ctx.translateBy(x: 0, y: 128)
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: region)
        let font = TextDrawing.font(name: "Helvetica", size: 16, bold: true)
        let lines = TextDrawing.lines(string, font: font, color: RGBAColor.black.cgColor, maxWidth: 0)
        TextDrawing.draw(lines, font: font, topLeft: CGPoint(x: region.minX + 2, y: region.minY + 2),
                         in: ctx, flipped: true)
        return try #require(ctx.makeImage())
    }

    private func render(_ source: CGImage, annotations: [Annotation], scale: CGFloat = 1,
                        offset: CGPoint = .zero, supplySource: Bool = true,
                        imageSize: CGSize? = nil) throws -> CGImage {
        let size = imageSize ?? source.pixelSize
        let ctx = try #require(GlintBitmap.makeContext(width: Int(ceil(size.width * scale)) + 4,
                                                     height: Int(ceil(size.height * scale)) + 4))
        ctx.translateBy(x: 0, y: CGFloat(ctx.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: offset.x, y: offset.y)
        ctx.scaleBy(x: scale, y: scale)
        ImageDrawing.drawFlipped(source, in: CGRect(origin: .zero, size: size), ctx: ctx)
        ctx.setAlpha(0.01)
        ctx.setBlendMode(.multiply)
        AnnotationRenderer.draw(in: ctx, annotations: annotations, imageSize: size,
                                source: supplySource ? source : nil)
        return try #require(ctx.makeImage())
    }

    @Test func classificationsDistinguishReplacementFromObfuscation() {
        for a in variants(CGRect(x: 1, y: 2, width: 3, height: 4)) {
            #expect(a.isRedaction)
            #expect(!a.isObfuscation)
        }
        let blur = Annotation(kind: .blur(CGRect(x: 1, y: 2, width: 3, height: 4)))
        #expect(blur.isObfuscation && !blur.isRedaction)
        #expect(!RedactionStyle.solid.isObfuscation)
        #expect(!RedactionStyle.pixelate.isObfuscation)
        #expect(RedactionStyle.blur.isObfuscation)
        #expect(!RedactionStyle.pixelate.displayName.contains("obfuscation"))
    }

    @Test func legacyStylesDecodeWithSafePlainDefaults() throws {
        let oldStyle = AnnotationStyle(color: primary, fill: .white, strokeWidth: 7, opacity: 0.2,
                                       fontName: "Helvetica", fontSize: 18, bold: false,
                                       intensity: 23, dashed: true, cornerRadius: 9)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(oldStyle)) as? [String: Any])
        for key in ["redactionPattern", "redactionSecondaryColor", "pixelateHighlight"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(AnnotationStyle.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == oldStyle)
        #expect(decoded.redactionPattern == .plain)
        #expect(!decoded.pixelateHighlight)
        #expect(decoded.redactionSecondaryColor == RGBAColor(r: 0.85, g: 0.85, b: 0.85))
        #expect(AnnotationStyle().redactionPattern == .plain)
    }

    @Test func styleAndAnnotationEncodingRetainEveryOption() throws {
        for annotation in variants(CGRect(x: -1.25, y: 3.75, width: 29.5, height: 20.25)) {
            let data = try JSONEncoder().encode(annotation)
            #expect(try JSONDecoder().decode(Annotation.self, from: data) == annotation)
        }
    }

    @Test func replacingSyntheticTextNumbersAndTokensIsSourceIndependent() throws {
        let region = CGRect(x: 12, y: 10, width: 216, height: 106)
        let first = try secretImage("Alice Example\n123-45-6789\nTEST-TOKEN-A1B2C3", region: region)
        let second = try secretImage("Bob Placeholder\n987-65-4321\nFAKE-KEY-Z9Y8X7", region: region)
        #expect(try #require(PixelBuffer(first)).data != #require(PixelBuffer(second)).data)
        for annotation in variants(region) {
            let a = try #require(AnnotationRenderer.bake(source: first, annotations: [annotation]))
            let b = try #require(AnnotationRenderer.bake(source: second, annotations: [annotation]))
            #expect(try #require(PixelBuffer(a)).data == #require(PixelBuffer(b)).data)
            let decodedA = try #require(GlintImageIO.load(data: Exporter.data(for: a, format: .plainPNG)))
            let decodedB = try #require(GlintImageIO.load(data: Exporter.data(for: b, format: .plainPNG)))
            #expect(try #require(PixelBuffer(decodedA)).data == #require(PixelBuffer(decodedB)).data)
        }
    }

    @Test func fractionalTinyAndOffImageRegionsCoverEveryTouchedDevicePixel() throws {
        let first = TestImages.solid(96, 64, RGBAColor(r: 1, g: 0, b: 0))
        let second = TestImages.solid(96, 64, RGBAColor(r: 0, g: 0, b: 1))
        let offset = CGPoint(x: 0.37, y: 0.61)
        let regions = [
            CGRect(x: 12.2, y: 9.7, width: 45.3, height: 31.8),
            CGRect(x: 10.99, y: 13.99, width: 0.02, height: 0.02),
            CGRect(x: -4.3, y: -3.8, width: 17.6, height: 16.4),
            CGRect(x: 88.7, y: 59.3, width: 20.2, height: 15.9),
            CGRect(x: 30.2, y: 29.8, width: -17.9, height: -20.1),
        ]
        for scale: CGFloat in [0.25, 0.75, 1, 1.5, 2, 4] {
            for region in regions {
                let clipped = region.standardized.intersection(CGRect(x: 0, y: 0, width: 96, height: 64))
                let device = CGRect(x: clipped.minX * scale + offset.x, y: clipped.minY * scale + offset.y,
                                    width: clipped.width * scale, height: clipped.height * scale).integral
                for annotation in variants(region) {
                    let a = try #require(PixelBuffer(render(first, annotations: [annotation], scale: scale, offset: offset)))
                    let b = try #require(PixelBuffer(render(second, annotations: [annotation], scale: scale, offset: offset)))
                    for y in Int(device.minY)..<Int(device.maxY) {
                        for x in Int(device.minX)..<Int(device.maxX) {
                            #expect(a.pixel(x, y) == b.pixel(x, y))
                            #expect(a.pixel(x, y).3 == 255)
                        }
                    }
                }
            }
        }
    }

    @Test func patternsAreOpaqueWithoutSourceAndOnTransparentImages() throws {
        let source = TestImages.solid(96, 64, .clear)
        for annotation in variants(CGRect(x: 5.3, y: 7.2, width: 80.4, height: 48.6)) {
            let supplied = try #require(PixelBuffer(render(source, annotations: [annotation])))
            let missing = try #require(PixelBuffer(render(source, annotations: [annotation], supplySource: false)))
            #expect(supplied.data == missing.data)
            for y in 7..<56 { for x in 5..<86 { #expect(supplied.pixel(x, y).3 == 255) } }
        }
    }

    @Test func checkerboardUsesOnlyTheTwoChosenOpaqueColors() throws {
        let source = TestImages.solid(96, 64, .clear)
        let annotation = variants(CGRect(x: 5.3, y: 7.2, width: 80.4, height: 48.6))[1]
        let pixels = try #require(PixelBuffer(render(source, annotations: [annotation])))
        var seen = Set<[UInt8]>()
        for y in 7..<56 { for x in 5..<86 {
            let p = pixels.pixel(x, y)
            seen.insert([p.0, p.1, p.2, p.3])
        } }
        #expect(seen == [[180, 30, 210, 255], [20, 220, 130, 255]])
    }

    @Test func pixelateHighlightAccentsButDoesNotReplaceTheMosaic() throws {
        let source = TestImages.solid(96, 64, .clear)
        let region = CGRect(x: 0, y: 0, width: 96, height: 64)
        var neutral = variants(region)[2]
        var ignoredColor = neutral
        ignoredColor.style.color = .white
        let plainPixels = try #require(PixelBuffer(render(source, annotations: [neutral])))
        #expect(plainPixels.data == (try #require(PixelBuffer(render(source, annotations: [ignoredColor])))).data)
        neutral.style.pixelateHighlight = true
        let highlighted = try #require(PixelBuffer(render(source, annotations: [neutral])))
        var accentCount = 0, neutralCount = 0
        var shades = Set<UInt8>()
        for y in 0..<64 { for x in 0..<96 {
            let p = highlighted.pixel(x, y)
            if p.0 == 180 && p.1 == 30 && p.2 == 210 { accentCount += 1 }
            else {
                #expect(p.0 == p.1 && p.1 == p.2)
                shades.insert(p.0)
                neutralCount += 1
            }
            #expect(p.3 == 255)
        } }
        #expect(accentCount > 0 && neutralCount > 0)
        #expect(shades.count > 1)
    }

    @Test func blurCannotRestoreOrSpreadCoveredSecretsAtAnyDrawOrder() throws {
        let region = CGRect(x: 20, y: 20, width: 200, height: 88)
        let first = try secretImage("1234567890\nSYNTHETIC-SECRET", region: region)
        let second = try secretImage("0987654321\nDIFFERENT-SECRET", region: region)
        for redaction in variants(region) {
            for z in [-2, 2] {
                let blur = Annotation(z: z, kind: .blur(CGRect(x: 0, y: 0, width: 240, height: 128)),
                                      style: AnnotationStyle(intensity: 10))
                let a = try #require(AnnotationRenderer.bake(source: first, annotations: [redaction, blur]))
                let b = try #require(AnnotationRenderer.bake(source: second, annotations: [redaction, blur]))
                #expect(try #require(PixelBuffer(a)).data == #require(PixelBuffer(b)).data)
            }
        }
    }

    @Test func blurSanitizationRespectsSourceToImageScale() throws {
        let region = CGRect(x: 20, y: 20, width: 200, height: 88)
        let first = try secretImage("TEST-123456\nPRIVATE-EXAMPLE", region: region)
        let second = try secretImage("TEST-987654\nCHANGED-EXAMPLE", region: region)
        let size = CGSize(width: 120, height: 64)
        let halfRegion = CGRect(x: 10, y: 10, width: 100, height: 44)
        for redaction in variants(halfRegion) {
            let blur = Annotation(z: 2, kind: .blur(CGRect(origin: .zero, size: size)))
            let a = try render(first, annotations: [redaction, blur], imageSize: size)
            let b = try render(second, annotations: [redaction, blur], imageSize: size)
            #expect(try #require(PixelBuffer(a)).data == #require(PixelBuffer(b)).data)
        }
    }

    @Test func nonfiniteTileSizesStillCoverTheSelection() throws {
        let source = TestImages.solid(96, 64, .clear)
        for intensity in [Double.nan, .infinity, -.infinity, -100, 0] {
            for var annotation in variants(CGRect(x: 0, y: 0, width: 96, height: 64)) {
                annotation.style.intensity = intensity
                let pixels = try #require(PixelBuffer(render(source, annotations: [annotation])))
                #expect(stride(from: 3, to: 96 * 4, by: 4).allSatisfy { pixels.data[$0] == 255 })
            }
        }
    }
}
