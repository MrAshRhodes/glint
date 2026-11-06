import CoreGraphics
import Testing
@testable import GlintEditor

@Suite("Canvas zoom and scrolling")
struct CanvasViewportTests {
    let tall = CGSize(width: 1000, height: 12_000)
    let available = CGSize(width: 800, height: 600)

    @Test func tallImagesOpenAtFitWidth() {
        #expect(CanvasZoom.initial(for: tall) == .fitWidth)
        #expect(CanvasZoom.initial(for: CGSize(width: 1600, height: 1000)) == .fit)
        #expect(CanvasZoom.initial(for: .zero) == .fit)
    }

    @Test func shortcutsFollowPreview() {
        #expect(CanvasZoom(shortcutKey: "9") == .fit)
        #expect(CanvasZoom(shortcutKey: "8") == .fitWidth)
        #expect(CanvasZoom(shortcutKey: "0") == .actualSize)
        #expect(CanvasZoom(shortcutKey: "7") == nil)
    }

    @Test func zoomSizes() {
        let fit = CanvasViewport.displaySize(.fit, canvasPixels: tall, available: available, pointsPerPixel: 0.5)
        #expect(fit == CGSize(width: 50, height: 600))
        let width = CanvasViewport.displaySize(.fitWidth, canvasPixels: tall, available: available, pointsPerPixel: 0.5)
        #expect(width == CGSize(width: 800, height: 9600))
        let actual = CanvasViewport.displaySize(.actualSize, canvasPixels: tall, available: available,
                                                pointsPerPixel: 0.5)
        #expect(actual == CGSize(width: 500, height: 6000))
        // A tiny image is never blown up past the limit.
        let tiny = CanvasViewport.displaySize(.fitWidth, canvasPixels: CGSize(width: 10, height: 40),
                                              available: available, pointsPerPixel: 0.5)
        #expect(tiny == CGSize(width: 20, height: 80))
    }

    @Test func scrollingIsClampedAndCentresWhatFits() {
        let area = CGRect(x: 28, y: 28, width: 800, height: 600)
        let size = CGSize(width: 500, height: 6000)
        #expect(CanvasViewport.maximumOffset(content: size, in: area) == CGPoint(x: 0, y: 5400))
        #expect(CanvasViewport.clamped(CGPoint(x: 40, y: -10), content: size, in: area) == .zero)
        #expect(CanvasViewport.clamped(CGPoint(x: 0, y: 9000), content: size, in: area) == CGPoint(x: 0, y: 5400))
        let frame = CanvasViewport.frame(content: size, in: area, offset: CGPoint(x: 0, y: 1000))
        #expect(frame == CGRect(x: 178, y: -972, width: 500, height: 6000))
    }
}
