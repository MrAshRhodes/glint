import CoreGraphics
import Testing
@testable import GlintCapture

@Suite("Capture geometry")
struct CaptureGeometryTests {
    @Test func globalCoordinateConversionIsReversibleAcrossDisplays() {
        let rect = CGRect(x: -1280, y: 1080, width: 640, height: 360)
        let converted = CaptureGeometry.appKitToCG(rect, primaryHeight: 1080)
        #expect(converted == CGRect(x: -1280, y: -360, width: 640, height: 360))
        #expect(CaptureGeometry.cgToAppKit(converted, primaryHeight: 1080) == rect)
        #expect(CaptureGeometry.appKitToCG(CGPoint(x: -50, y: 1200), primaryHeight: 1080) == CGPoint(x: -50, y: -120))
    }

    @Test func rectangleAndSquarePreserveAnchorInEveryQuadrant() {
        let anchor = CGPoint(x: 50, y: 50)
        for dx: CGFloat in [-30, 30] {
            for dy: CGFloat in [-10, 10] {
                let end = CGPoint(x: anchor.x + dx, y: anchor.y + dy)
                let rect = CaptureGeometry.rect(from: anchor, to: end, square: false)
                #expect(rect.width == 30 && rect.height == 10)
                let square = CaptureGeometry.rect(from: anchor, to: end, square: true)
                #expect(square == CGRect(x: dx < 0 ? 20 : 50, y: dy < 0 ? 20 : 50, width: 30, height: 30))
            }
        }
    }

    @Test func displayLocalClipsAndSnapsToRetinaPixels() {
        let display = CGRect(x: -100, y: -50, width: 100, height: 80)
        let rect = CGRect(x: -110, y: -39.7, width: 40.4, height: 25.6)
        let local = CaptureGeometry.displayLocal(rect, display: display, scale: 2)
        #expect(local == CGRect(x: 0, y: 10.5, width: 30.5, height: 25.5))
        #expect(local.minX >= 0 && local.maxX <= display.width && local.maxY <= display.height)
    }

    @Test func fullDisplayHasZeroLocalOriginAtAnyDisplayOffset() {
        let display = CGRect(x: 1920, y: -200, width: 1440, height: 900)
        #expect(CaptureGeometry.displayLocal(display, display: display, scale: 1) == CGRect(origin: .zero, size: display.size))
    }

    @Test func displaySelectionHandlesGapsAndEmptyDisplayList() {
        let frames = [CGRect(x: -100, y: 0, width: 100, height: 100), CGRect(x: 50, y: 0, width: 100, height: 100)]
        #expect(CaptureGeometry.index(containing: CGPoint(x: -20, y: 30), in: frames) == 0)
        #expect(CaptureGeometry.index(containing: CGPoint(x: 100, y: 30), in: frames) == 1)
        #expect(CaptureGeometry.index(containing: CGPoint(x: 40, y: 30), in: frames) == 1)
        #expect(CaptureGeometry.index(containing: .zero, in: []) == nil)
    }

    @Test func clampIncludesEdgesAndDimensionsRoundInPoints() {
        let bounds = CGRect(x: -100, y: -50, width: 80, height: 40)
        #expect(CaptureGeometry.clamp(CGPoint(x: 2, y: -100), to: bounds) == CGPoint(x: -20, y: -50))
        #expect(CaptureGeometry.clamp(CGPoint(x: -100, y: -10), to: bounds) == CGPoint(x: -100, y: -10))
        #expect(CaptureGeometry.dimensionLabel(CGRect(x: 0, y: 0, width: 10.4, height: 20.6)) == "10 × 21")
    }

    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func pixelCropSnapsLikeALiveGrab(scale: CGFloat) throws {
        let display = CGRect(x: 0, y: 0, width: 100, height: 80)
        let rect = CGRect(x: 10.3, y: 20.6, width: 30.4, height: 10.2)
        let crop = try #require(CaptureGeometry.pixelCrop(rect, display: display,
                                                          imageSize: CGSize(width: 100 * scale, height: 80 * scale)))
        #expect(crop.scale == scale)
        #expect(crop.pixels == (scale == 1 ? CGRect(x: 10, y: 21, width: 31, height: 10)
                                           : CGRect(x: 21, y: 41, width: 60, height: 21)))
        // Same pixel size as the ScreenCaptureKit configuration a live grab of `rect` uses.
        let local = CaptureGeometry.displayLocal(rect, display: display, scale: scale)
        #expect(crop.pixels.size == CGSize(width: (local.width * scale).rounded(),
                                           height: (local.height * scale).rounded()))
    }

    @Test func pixelCropIsRelativeToOffsetDisplays() {
        let left = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let leftCrop = CaptureGeometry.pixelCrop(CGRect(x: -100, y: -150, width: 50, height: 40), display: left,
                                                 imageSize: CGSize(width: 2880, height: 1800))
        #expect(leftCrop?.pixels == CGRect(x: 2680, y: 100, width: 100, height: 80))
        #expect(leftCrop?.scale == 2)
        let right = CGRect(x: 1920, y: -300, width: 1280, height: 720)
        let rightCrop = CaptureGeometry.pixelCrop(CGRect(x: 2000.4, y: -250.6, width: 100, height: 50), display: right,
                                                  imageSize: CGSize(width: 1280, height: 720))
        #expect(rightCrop?.pixels == CGRect(x: 80, y: 49, width: 100, height: 50))
    }

    @Test func pixelCropClipsToTheDisplayAndUsesTheImageResolution() {
        let display = CGRect(x: 1920, y: 0, width: 100, height: 100)
        let image = CGSize(width: 200, height: 200)
        #expect(CaptureGeometry.pixelCrop(CGRect(x: 1900, y: 90, width: 50, height: 50), display: display,
                                          imageSize: image)?.pixels == CGRect(x: 0, y: 180, width: 60, height: 20))
        #expect(CaptureGeometry.pixelCrop(CGRect(x: 1990, y: -40, width: 80, height: 60), display: display,
                                          imageSize: image)?.pixels == CGRect(x: 140, y: 0, width: 60, height: 40))
        #expect(CaptureGeometry.pixelCrop(CGRect(x: 0, y: 0, width: 50, height: 50), display: display,
                                          imageSize: image) == nil)
        #expect(CaptureGeometry.pixelCrop(CGRect(x: 1950, y: 50, width: 0.5, height: 10), display: display,
                                          imageSize: image) == nil)
        #expect(CaptureGeometry.pixelCrop(CGRect(x: 1950, y: 50, width: 10, height: 10), display: display,
                                          imageSize: .zero) == nil)
        // A fallback grab at another resolution still maps the same points.
        let fallback = CaptureGeometry.pixelCrop(CGRect(x: 1930, y: 20, width: 30, height: 10), display: display,
                                                 imageSize: CGSize(width: 150, height: 150))
        #expect(fallback?.scale == 1.5)
        #expect(fallback?.pixels == CGRect(x: 15, y: 30, width: 45, height: 15))
    }

    @Test func frozenDisplayCropsTheTopLeftOriginPixelsOfTheSelection() throws {
        // 200 × 160 pixels for a 100 × 80 point display at x = -100: the top 40 points are red, the rest blue.
        let context = try #require(CGContext(data: nil, width: 200, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 80))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 80, width: 200, height: 80))
        let display = DisplayInfo(id: 9, frame: CGRect(x: -100, y: -20, width: 100, height: 80), scale: 2,
                                  name: "Test", isMain: false)
        let frozen = FrozenDisplay(display: display, image: try #require(context.makeImage()))

        let top = try #require(frozen.crop(CGRect(x: -120, y: -30, width: 50, height: 30)))
        #expect(top.rect == CGRect(x: -100, y: -20, width: 30, height: 20))
        #expect(top.grab.scale == 2)
        #expect(top.grab.image.width == 60 && top.grab.image.height == 40)
        #expect(try firstPixel(top.grab.image) == [255, 0, 0, 255])
        let bottom = try #require(frozen.crop(CGRect(x: -50, y: 30, width: 20, height: 20)))
        #expect(bottom.grab.image.width == 40 && bottom.grab.image.height == 40)
        #expect(try firstPixel(bottom.grab.image) == [0, 0, 255, 255])
        #expect(frozen.crop(CGRect(x: 10, y: 10, width: 20, height: 20)) == nil)
    }

    private func firstPixel(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Draw so the image's top-left pixel lands on the only pixel.
        context.draw(image, in: CGRect(x: 0, y: 1 - CGFloat(image.height), width: CGFloat(image.width),
                                       height: CGFloat(image.height)))
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: 4))
    }
}
