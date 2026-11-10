import AppKit
import CoreGraphics
import ImageIO
import Testing
@testable import GlintCore

@Suite("Screenshot colour policy")
struct ColourPolicyTests {
    private let patches: [[CGFloat]] = [
        [0, 0, 0, 1], [0.25, 0.25, 0.25, 1], [0.5, 0.5, 0.5, 1],
        [0.75, 0.75, 0.75, 1], [1, 1, 1, 1],
        [0.7, 0.2, 0.3, 1], [0.2, 0.7, 0.3, 1], [0.2, 0.3, 0.7, 1],
        [0.7, 0.6, 0.2, 1], [0.3, 0.6, 0.7, 1],
        [0.7, 0.2, 0.3, 0.5], [0, 0, 0, 0],
    ]

    private func context(width: Int, height: Int, space: CGColorSpace) throws -> CGContext {
        try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                  | CGBitmapInfo.byteOrder32Big.rawValue))
    }

    /// Both charts represent the same in-sRGB-gamut colours, not the same numeric RGB triplets.
    private func chart(in space: CGColorSpace) throws -> CGImage {
        let ctx = try context(width: patches.count * 32, height: 32, space: space)
        for (index, components) in patches.enumerated() {
            let source = try #require(CGColor(colorSpace: ColorSpaces.sRGB, components: components))
            let color = try #require(source.converted(to: space, intent: .relativeColorimetric, options: nil))
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: index * 32, y: 0, width: 32, height: 32))
        }
        return try #require(ctx.makeImage())
    }

    private func decode(_ data: Data) throws -> CGImage {
        // Inspect the encoded profile before GlintImageIO's intentional editor normalization.
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func expectPatches(_ image: CGImage, match reference: CGImage, tolerance: Int) {
        for index in patches.indices {
            let a = TestImages.pixel(image, index * 32 + 16, 16)
            let b = TestImages.pixel(reference, index * 32 + 16, 16)
            for (actual, expected) in [(a.r, b.r), (a.g, b.g), (a.b, b.b), (a.a, b.a)] {
                #expect(abs(Int(actual) - Int(expected)) <= tolerance,
                        "Patch \(index): \(actual) versus \(expected), tolerance \(tolerance)")
            }
        }
    }

    @Test func rawLosslessExportsKeepTheProvidedProfileAndAppearance() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let reference = try chart(in: ColorSpaces.sRGB)
        for space in [ColorSpaces.sRGB, p3] {
            let raw = try chart(in: space)
            for format in [ExportFormat.plainPNG, .tiff] {
                let saved = try decode(Exporter.data(for: raw, format: format))
                #expect(saved.colorSpace?.name == space.name)
                expectPatches(saved, match: reference, tolerance: 3)
            }
        }
    }

    @Test func compositionAndEncodedOutputsAgreeInSRGB() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let reference = try chart(in: ColorSpaces.sRGB)
        let raw = try chart(in: p3)
        let settings = RenderSettings(padding: 0, inset: 0, cornerRadius: 0, shadow: .none,
                                      background: .transparent, autoBalance: false)
        let composed = try Compositor.render(image: raw, settings: settings)
        #expect(composed.colorSpace?.name == CGColorSpace.sRGB)
        expectPatches(composed, match: reference, tolerance: 3)
        for format in [ExportFormat.plainPNG, .jpeg(quality: 1)] {
            let saved = try decode(Exporter.data(for: composed, format: format))
            #expect(saved.colorSpace?.name == CGColorSpace.sRGB)
            let expected = format.supportsAlpha ? reference : Exporter.flattened(reference)
            expectPatches(saved, match: expected, tolerance: format.supportsAlpha ? 3 : 5)
        }
        let png = try Exporter.data(for: composed)
        let loaded = try #require(GlintImageIO.load(data: png))
        try expectSamePixels(loaded, composed)
        #expect(loaded.glintSRGB() === loaded)
    }

    @Test func clipboardRepresentationsMatchTheEquivalentEncodedOutput() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let raw = try chart(in: p3)
        let pb = NSPasteboard(name: .init("glint.colour.tests.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        for image in [raw, raw.glintSRGB()] {
            #expect(Exporter.copyToClipboard(image, backingScale: 2, pasteboard: pb))
            for (type, format) in [(NSPasteboard.PasteboardType.png, ExportFormat.plainPNG), (.tiff, .tiff)] {
                let pasted = try decode(#require(pb.data(forType: type)))
                let saved = try decode(Exporter.data(for: image, format: format, backingScale: 2))
                #expect(pasted.colorSpace?.name == saved.colorSpace?.name)
                try expectSamePixels(pasted, saved)
            }
        }
    }

    @Test func resamplingConvertsOnlyWhenANewBitmapIsNeeded() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let raw = try chart(in: p3)
        let same = Exporter.resampled(raw, scale: .x2, backingScale: 2)
        #expect(same === raw)
        let scaled = Exporter.resampled(raw, scale: .x1, backingScale: 2)
        #expect(scaled.width == raw.width / 2)
        #expect(scaled.colorSpace?.name == CGColorSpace.sRGB)
        let actual = TestImages.pixel(scaled, 5 * 16 + 8, 8)
        let expected = TestImages.pixel(raw, 5 * 32 + 16, 16)
        #expect(abs(Int(actual.r) - Int(expected.r)) <= 1)
        #expect(abs(Int(actual.g) - Int(expected.g)) <= 1)
        #expect(abs(Int(actual.b) - Int(expected.b)) <= 1)
    }

    @Test func neutralGradientAndTransparentEdgesSurviveNormalization() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let ctx = try context(width: 256, height: 4, space: p3)
        for x in 0..<256 {
            let value = CGFloat(x) / 255
            ctx.setFillColor(try #require(CGColor(colorSpace: p3, components: [value, value, value, 1])))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: 4))
        }
        let converted = try #require(ctx.makeImage()).glintSRGB()
        for x in 0..<256 {
            let pixel = TestImages.pixel(converted, x, 2)
            #expect(abs(Int(pixel.r) - x) <= 1)
            #expect(abs(Int(pixel.g) - x) <= 1)
            #expect(abs(Int(pixel.b) - x) <= 1)
        }
        let alpha = try chart(in: p3).glintSRGB()
        #expect(abs(Int(TestImages.pixel(alpha, 10 * 32 + 16, 16).a) - 128) <= 1)
        let clear = TestImages.pixel(alpha, 11 * 32 + 16, 16)
        #expect(clear.r == 0 && clear.g == 0 && clear.b == 0 && clear.a == 0)
    }

    @Test func outOfSRGBGamutRawPatchesAreNotRetaggedAsSRGB() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let ctx = try context(width: 32, height: 32, space: p3)
        ctx.setFillColor(try #require(CGColor(colorSpace: p3, components: [1, 0, 0, 1])))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let raw = try #require(ctx.makeImage())
        let saved = try decode(Exporter.data(for: raw))
        #expect(saved.colorSpace?.name == CGColorSpace.displayP3)
        let normalized = saved.glintSRGB()
        #expect(normalized.colorSpace?.name == CGColorSpace.sRGB)
        #expect(normalized !== saved)
        let pixel = TestImages.pixel(normalized, 16, 16)
        #expect(pixel.r >= 254 && pixel.g <= 1 && pixel.b <= 1)
    }
}
