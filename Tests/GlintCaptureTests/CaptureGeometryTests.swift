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
}
