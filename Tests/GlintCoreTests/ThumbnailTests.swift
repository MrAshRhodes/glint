import CoreGraphics
import Testing
@testable import GlintCore

@Suite("Image thumbnails")
struct ThumbnailTests {
    @Test func shrinksTheLongerSideToTheLimitAndKeepsTheAspectRatio() {
        let wide = TestImages.solid(1000, 500, .white).glintThumbnail(maxPixelSide: 100)
        #expect(wide.width == 100 && wide.height == 50)
        let tall = TestImages.solid(300, 900, .white).glintThumbnail(maxPixelSide: 90)
        #expect(tall.width == 30 && tall.height == 90)
        let square = TestImages.solid(800, 800, .white).glintThumbnail(maxPixelSide: 64)
        #expect(square.width == 64 && square.height == 64)
    }

    @Test func neverEnlargesAnImageThatAlreadyFits() {
        let small = TestImages.solid(100, 40, .white)
        #expect(small.glintThumbnail(maxPixelSide: 440) === small)
        #expect(small.glintThumbnail(maxPixelSide: 100) === small)
    }

    @Test func ignoresALimitThatCannotBeUsed() {
        let image = TestImages.solid(100, 40, .white)
        #expect(image.glintThumbnail(maxPixelSide: 0) === image)
        #expect(image.glintThumbnail(maxPixelSide: -5) === image)
    }

    @Test func aVeryThinImageKeepsAtLeastOnePixelOnItsShortSide() {
        let thin = TestImages.solid(5000, 3, .white).glintThumbnail(maxPixelSide: 100)
        #expect(thin.width == 100 && thin.height == 1)
    }

    @Test func keepsTheColoursOfTheSource() {
        let red = TestImages.solid(1000, 500, RGBAColor(r: 1, g: 0, b: 0)).glintThumbnail(maxPixelSide: 100)
        let pixel = TestImages.pixel(red, 50, 25)
        #expect(pixel.r == 255 && pixel.g == 0 && pixel.b == 0 && pixel.a == 255)
    }

    @Test func keepsTransparency() {
        let clear = TestImages.solid(400, 400, .clear).glintThumbnail(maxPixelSide: 40)
        #expect(TestImages.pixel(clear, 20, 20).a == 0)
    }

    @Test func keepsAWideGamutColourSpace() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let context = try #require(CGContext(data: nil, width: 600, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: p3, bitmapInfo: info))
        context.setFillColor(CGColor(colorSpace: p3, components: [1, 0, 0, 1]) ?? CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
        let source = try #require(context.makeImage())
        let thumbnail = source.glintThumbnail(maxPixelSide: 60)
        #expect(thumbnail.width == 60 && thumbnail.height == 30)
        // Still Display P3, so its colours are shown as before instead of being clipped into sRGB.
        #expect(thumbnail.colorSpace?.name == CGColorSpace.displayP3)
    }

    @Test func fallsBackToSRGBForAColourSpaceItCannotDrawInto() throws {
        let gray = CGColorSpaceCreateDeviceGray()
        let context = try #require(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let source = try #require(context.makeImage())
        let thumbnail = source.glintThumbnail(maxPixelSide: 40)
        #expect(thumbnail.width == 40 && thumbnail.height == 20)
        #expect(thumbnail.colorSpace?.name == CGColorSpace.sRGB)
        let pixel = TestImages.pixel(thumbnail, 20, 10)
        #expect(abs(Int(pixel.r) - 128) <= 3 && pixel.r == pixel.g && pixel.g == pixel.b && pixel.a == 255)
    }

    @Test func aSharpEdgeStaysAnEdgeInsteadOfBlurringTheWholeImage() {
        // Left half white, right half black: downscaling must keep both halves clear of each other.
        let context = GlintBitmap.makeContext(width: 800, height: 400)!
        context.setFillColor(RGBAColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        context.setFillColor(RGBAColor.black.cgColor)
        context.fill(CGRect(x: 400, y: 0, width: 400, height: 400))
        let thumbnail = context.makeImage()!.glintThumbnail(maxPixelSide: 80)
        #expect(TestImages.pixel(thumbnail, 5, 20).r > 250)
        #expect(TestImages.pixel(thumbnail, 75, 20).r < 5)
    }
}
