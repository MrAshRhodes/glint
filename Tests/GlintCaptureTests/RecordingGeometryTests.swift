import CoreGraphics
import Testing
@testable import GlintCapture

@Suite("Recording geometry")
struct RecordingGeometryTests {
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func retinaRegionCoversTwiceThePixels() throws {
        let geometry = try #require(RecordingGeometry(
            region: CGRect(x: 100, y: 120, width: 400, height: 300), display: display, scale: 2))
        #expect(geometry.sourceRect == CGRect(x: 100, y: 120, width: 400, height: 300))
        #expect(geometry.sourceWidth == 800 && geometry.sourceHeight == 600)
        #expect(geometry.outputSize == CGSize(width: 800, height: 600))
        #expect(!geometry.isDownscaled)
    }

    @Test func oddPixelCountsAreTrimmedToEven() throws {
        let retina = try #require(RecordingGeometry(
            region: CGRect(x: 10, y: 10, width: 100.5, height: 50.5), display: display, scale: 2))
        #expect(retina.sourceWidth == 200 && retina.sourceHeight == 100)
        #expect(retina.sourceRect.size == CGSize(width: 100, height: 50))

        let standard = try #require(RecordingGeometry(
            region: CGRect(x: 10, y: 10, width: 101, height: 77), display: display, scale: 1))
        #expect(standard.outputWidth == 100 && standard.outputHeight == 76)
        #expect(standard.outputWidth % 2 == 0 && standard.outputHeight % 2 == 0)
    }

    @Test func sourceRectIsLocalToTheDisplay() throws {
        let secondary = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        let geometry = try #require(RecordingGeometry(
            region: CGRect(x: 1500, y: -100, width: 640, height: 360), display: secondary, scale: 1))
        #expect(geometry.sourceRect == CGRect(x: 60, y: 100, width: 640, height: 360))
    }

    @Test func regionIsClippedToTheDisplay() throws {
        let geometry = try #require(RecordingGeometry(
            region: CGRect(x: 1400, y: 860, width: 200, height: 200), display: display, scale: 1))
        #expect(geometry.sourceRect == CGRect(x: 1400, y: 860, width: 40, height: 40))
        #expect(geometry.outputSize == CGSize(width: 40, height: 40))
    }

    @Test func unusableRegionsAreRejected() {
        #expect(RecordingGeometry(region: CGRect(x: 2000, y: 0, width: 100, height: 100), display: display, scale: 2) == nil)
        #expect(RecordingGeometry(region: .zero, display: display, scale: 2) == nil)
        #expect(RecordingGeometry(region: CGRect(x: 0, y: 0, width: 100, height: 100), display: display, scale: 0) == nil)
        #expect(RecordingGeometry(region: CGRect(x: 0, y: 0, width: 100, height: 100), display: .zero, scale: 2) == nil)
        #expect(RecordingGeometry(region: CGRect(x: 0, y: 0, width: 0.4, height: 0.4), display: display, scale: 1) == nil)
    }

    @Test func fiveKDisplayIsScaledDownToTheEncoderLimit() throws {
        let fiveK = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let geometry = try #require(RecordingGeometry(region: fiveK, display: fiveK, scale: 2))
        #expect(geometry.sourceWidth == 5120 && geometry.sourceHeight == 2880)
        #expect(geometry.outputWidth == 4096 && geometry.outputHeight == 2304)
        #expect(geometry.isDownscaled)
        #expect(geometry.sourceRect == CGRect(origin: .zero, size: fiveK.size))
    }

    @Test func downscalingKeepsTheAspectRatioAndEvenSides() {
        let sizes: [(Int, Int)] = [(6016, 3384), (7680, 4320), (5121, 2881), (3440, 1440), (4098, 4098)]
        for (width, height) in sizes {
            let (outWidth, outHeight) = RecordingGeometry.fitted(width: RecordingGeometry.even(width),
                                                                  height: RecordingGeometry.even(height))
            #expect(outWidth % 2 == 0 && outHeight % 2 == 0)
            #expect(outWidth * outHeight <= RecordingGeometry.maximumPixelArea)
            #expect(max(outWidth, outHeight) <= RecordingGeometry.maximumPixelSide)
            let sourceRatio = Double(width) / Double(height)
            let outputRatio = Double(outWidth) / Double(outHeight)
            #expect(abs(sourceRatio - outputRatio) / sourceRatio < 0.02)
        }
    }

    @Test func extremelyWideRegionsAreCappedToTheMaximumSide() {
        let (width, height) = RecordingGeometry.fitted(width: 10_000, height: 100)
        #expect(width == 8192 && height == 80)
    }

    @Test func regionsWithinTheLimitsAreNeverScaled() {
        #expect(RecordingGeometry.fitted(width: 4096, height: 2304) == (4096, 2304))
        #expect(RecordingGeometry.fitted(width: 1920, height: 1080) == (1920, 1080))
        #expect(RecordingGeometry.fitted(width: 2, height: 2) == (2, 2))
    }
}

@Suite("Region adjustment")
struct RegionAdjustmentTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func clampingGrowsSmallRegionsAndPullsThemOntoTheDisplay() {
        let grown = RegionAdjustment.clamped(CGRect(x: 10, y: 10, width: 20, height: 5), to: bounds)
        #expect(grown == CGRect(x: 10, y: 10, width: 64, height: 64))

        let shifted = RegionAdjustment.clamped(CGRect(x: 950, y: -30, width: 200, height: 100), to: bounds)
        #expect(shifted == CGRect(x: 800, y: 0, width: 200, height: 100))

        let oversized = RegionAdjustment.clamped(CGRect(x: -50, y: -50, width: 5000, height: 5000), to: bounds)
        #expect(oversized == bounds)
    }

    @Test func clampingSnapsToWholePoints() {
        let rect = RegionAdjustment.clamped(CGRect(x: 10.4, y: 20.6, width: 100.2, height: 90.7), to: bounds)
        #expect(rect == CGRect(x: 10, y: 21, width: 100, height: 91))
    }

    @Test func clampingHonoursAnOffsetDisplay() {
        let secondary = CGRect(x: -1280, y: 100, width: 1280, height: 720)
        let rect = RegionAdjustment.clamped(CGRect(x: -1300, y: 50, width: 300, height: 200), to: secondary)
        #expect(rect == CGRect(x: -1280, y: 100, width: 300, height: 200))
        #expect(secondary.contains(rect))
    }

    @Test func handleHitTestFindsCornersEdgesAndInterior() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
        let expectations: [(CGPoint, RegionHandle?)] = [
            (CGPoint(x: 100, y: 100), .topLeft),
            (CGPoint(x: 300, y: 100), .topRight),
            (CGPoint(x: 100, y: 250), .bottomLeft),
            (CGPoint(x: 300, y: 250), .bottomRight),
            (CGPoint(x: 200, y: 100), .top),
            (CGPoint(x: 200, y: 250), .bottom),
            (CGPoint(x: 100, y: 175), .left),
            (CGPoint(x: 300, y: 175), .right),
            (CGPoint(x: 200, y: 175), .move),
            (CGPoint(x: 95, y: 95), .topLeft),
            (CGPoint(x: 305, y: 255), .bottomRight),
            (CGPoint(x: 80, y: 175), nil),
            (CGPoint(x: 200, y: 300), nil)
        ]
        for (point, expected) in expectations {
            #expect(RegionAdjustment.handle(at: point, in: rect) == expected)
        }
    }

    @Test func movingKeepsTheSizeAndStaysOnTheDisplay() {
        let start = CGRect(x: 100, y: 100, width: 200, height: 150)
        let moved = RegionAdjustment.adjusted(start, handle: .move, by: CGSize(width: 40, height: -20), bounds: bounds)
        #expect(moved == CGRect(x: 140, y: 80, width: 200, height: 150))

        let pushedOut = RegionAdjustment.adjusted(start, handle: .move, by: CGSize(width: 5000, height: 5000), bounds: bounds)
        #expect(pushedOut == CGRect(x: 800, y: 650, width: 200, height: 150))

        let pulledOut = RegionAdjustment.adjusted(start, handle: .move, by: CGSize(width: -5000, height: -5000), bounds: bounds)
        #expect(pulledOut == CGRect(x: 0, y: 0, width: 200, height: 150))
    }

    @Test func resizingKeepsTheOppositeEdgesFixed() {
        let start = CGRect(x: 100, y: 100, width: 200, height: 150)
        let bottomRight = RegionAdjustment.adjusted(start, handle: .bottomRight, by: CGSize(width: 50, height: 30), bounds: bounds)
        #expect(bottomRight == CGRect(x: 100, y: 100, width: 250, height: 180))

        let topLeft = RegionAdjustment.adjusted(start, handle: .topLeft, by: CGSize(width: -30, height: -20), bounds: bounds)
        #expect(topLeft == CGRect(x: 70, y: 80, width: 230, height: 170))

        let top = RegionAdjustment.adjusted(start, handle: .top, by: CGSize(width: 999, height: 25), bounds: bounds)
        #expect(top == CGRect(x: 100, y: 125, width: 200, height: 125))

        let right = RegionAdjustment.adjusted(start, handle: .right, by: CGSize(width: -40, height: 999), bounds: bounds)
        #expect(right == CGRect(x: 100, y: 100, width: 160, height: 150))
    }

    @Test func resizingStopsAtTheMinimumSizeAndTheDisplayEdge() {
        let start = CGRect(x: 100, y: 100, width: 200, height: 150)
        let squeezed = RegionAdjustment.adjusted(start, handle: .bottomRight, by: CGSize(width: -500, height: -500), bounds: bounds)
        #expect(squeezed == CGRect(x: 100, y: 100, width: 64, height: 64))

        let squeezedFromTopLeft = RegionAdjustment.adjusted(start, handle: .topLeft, by: CGSize(width: 500, height: 500), bounds: bounds)
        #expect(squeezedFromTopLeft == CGRect(x: 236, y: 186, width: 64, height: 64))

        let stretched = RegionAdjustment.adjusted(start, handle: .bottomRight, by: CGSize(width: 5000, height: 5000), bounds: bounds)
        #expect(stretched == CGRect(x: 100, y: 100, width: 900, height: 700))

        let stretchedLeft = RegionAdjustment.adjusted(start, handle: .topLeft, by: CGSize(width: -5000, height: -5000), bounds: bounds)
        #expect(stretchedLeft == CGRect(x: 0, y: 0, width: 300, height: 250))
    }

    @Test func everyHandleProducesARegionInsideTheDisplay() {
        let start = CGRect(x: 50, y: 60, width: 120, height: 90)
        for handle in RegionHandle.allCases {
            for delta in [CGSize(width: -9999, height: -9999), CGSize(width: 9999, height: 9999),
                          CGSize(width: 13.4, height: -7.6), .zero] {
                let result = RegionAdjustment.adjusted(start, handle: handle, by: delta, bounds: bounds)
                #expect(bounds.contains(result))
                #expect(result.width >= RegionAdjustment.minimumSide && result.height >= RegionAdjustment.minimumSide)
                #expect(result == result.integral)
            }
        }
    }
}

@Suite("Recording layout")
struct RecordingLayoutTests {
    private let usable = CGRect(x: 0, y: 25, width: 1440, height: 875)
    private let barSize = CGSize(width: 400, height: 48)

    @Test func barSitsBelowTheRegionWhenThereIsRoom() {
        let region = CGRect(x: 500, y: 300, width: 400, height: 300)
        let frame = RecordingLayout.barFrame(size: barSize, region: region, usable: usable)
        #expect(frame == CGRect(x: 500, y: 620, width: 400, height: 48))
    }

    @Test func barMovesAboveWhenTheRegionReachesTheBottom() {
        let region = CGRect(x: 500, y: 700, width: 400, height: 150)
        let frame = RecordingLayout.barFrame(size: barSize, region: region, usable: usable)
        #expect(frame == CGRect(x: 500, y: 632, width: 400, height: 48))
        #expect(!frame.intersects(region))
    }

    @Test func barMovesInsideWhenTheRegionFillsTheDisplay() {
        let frame = RecordingLayout.barFrame(size: barSize, region: CGRect(x: 0, y: 0, width: 1440, height: 900), usable: usable)
        #expect(frame == CGRect(x: 520, y: 832, width: 400, height: 48))
        #expect(usable.contains(frame))
    }

    @Test func barStaysHorizontallyOnScreen() {
        let atLeft = RecordingLayout.barFrame(size: barSize, region: CGRect(x: 0, y: 100, width: 100, height: 100), usable: usable)
        #expect(atLeft.minX == RecordingLayout.margin)
        let atRight = RecordingLayout.barFrame(size: barSize, region: CGRect(x: 1340, y: 100, width: 100, height: 100), usable: usable)
        #expect(atRight.maxX == usable.maxX - RecordingLayout.margin)
    }

    @Test func barNeverExceedsTheUsableArea() {
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 30)
        let frame = RecordingLayout.barFrame(size: barSize, region: CGRect(x: 10, y: 10, width: 100, height: 100), usable: tiny)
        #expect(frame.width <= tiny.width && frame.height <= tiny.height)
    }

    @Test func keepingOnScreenMovesTheLeastDistance() {
        let outside = CGRect(x: -50, y: 10, width: 100, height: 40)
        #expect(RecordingLayout.keepingOnScreen(outside, in: usable) == CGRect(x: 8, y: 33, width: 100, height: 40))
        let inside = CGRect(x: 300, y: 300, width: 100, height: 40)
        #expect(RecordingLayout.keepingOnScreen(inside, in: usable) == inside)
        let farRight = CGRect(x: 1500, y: 880, width: 100, height: 40)
        #expect(RecordingLayout.keepingOnScreen(farRight, in: usable) == CGRect(x: 1332, y: 852, width: 100, height: 40))
    }
}

@Suite("Region nudging")
struct RegionNudgeTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let region = CGRect(x: 100, y: 100, width: 300, height: 200)

    @Test func arrowKeysMoveTheRegionAndOptionResizesIt() {
        #expect(RegionNudge(arrowKeyCode: 123, resize: false) == .moveLeft)
        #expect(RegionNudge(arrowKeyCode: 124, resize: false) == .moveRight)
        #expect(RegionNudge(arrowKeyCode: 126, resize: false) == .moveUp)
        #expect(RegionNudge(arrowKeyCode: 125, resize: false) == .moveDown)
        #expect(RegionNudge(arrowKeyCode: 123, resize: true) == .narrower)
        #expect(RegionNudge(arrowKeyCode: 124, resize: true) == .wider)
        #expect(RegionNudge(arrowKeyCode: 126, resize: true) == .shorter)
        #expect(RegionNudge(arrowKeyCode: 125, resize: true) == .taller)
        #expect(RegionNudge(arrowKeyCode: 36, resize: false) == nil)
    }

    @Test func movesKeepTheSizeAndFollowTheStep() {
        #expect(RegionAdjustment.nudged(region, .moveLeft, step: 1, bounds: bounds) == CGRect(x: 99, y: 100, width: 300, height: 200))
        #expect(RegionAdjustment.nudged(region, .moveRight, step: 10, bounds: bounds) == CGRect(x: 110, y: 100, width: 300, height: 200))
        #expect(RegionAdjustment.nudged(region, .moveUp, step: 10, bounds: bounds) == CGRect(x: 100, y: 90, width: 300, height: 200))
        #expect(RegionAdjustment.nudged(region, .moveDown, step: 1, bounds: bounds) == CGRect(x: 100, y: 101, width: 300, height: 200))
    }

    @Test func resizesKeepTheTopLeftCorner() {
        #expect(RegionAdjustment.nudged(region, .wider, step: 10, bounds: bounds) == CGRect(x: 100, y: 100, width: 310, height: 200))
        #expect(RegionAdjustment.nudged(region, .narrower, step: 1, bounds: bounds) == CGRect(x: 100, y: 100, width: 299, height: 200))
        #expect(RegionAdjustment.nudged(region, .taller, step: 10, bounds: bounds) == CGRect(x: 100, y: 100, width: 300, height: 210))
        #expect(RegionAdjustment.nudged(region, .shorter, step: 1, bounds: bounds) == CGRect(x: 100, y: 100, width: 300, height: 199))
    }

    @Test func nudgesStopAtTheDisplayEdgeAndTheMinimumSize() {
        let corner = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(RegionAdjustment.nudged(corner, .moveLeft, step: 10, bounds: bounds) == corner)
        #expect(RegionAdjustment.nudged(corner, .moveUp, step: 10, bounds: bounds) == corner)
        let right = CGRect(x: 700, y: 600, width: 300, height: 200)
        #expect(RegionAdjustment.nudged(right, .wider, step: 10, bounds: bounds) == right)
        #expect(RegionAdjustment.nudged(right, .taller, step: 10, bounds: bounds) == right)
        let smallest = CGRect(x: 100, y: 100, width: RegionAdjustment.minimumSide, height: RegionAdjustment.minimumSide)
        #expect(RegionAdjustment.nudged(smallest, .narrower, step: 10, bounds: bounds) == smallest)
        #expect(RegionAdjustment.nudged(smallest, .shorter, step: 10, bounds: bounds) == smallest)
    }

    @Test func everyNudgeHasAnActionName() {
        #expect(RegionNudge.allCases.count == 8)
        #expect(Set(RegionNudge.allCases.map(\.title)).count == 8)
        #expect(RegionNudge.allCases.allSatisfy { !$0.title.isEmpty })
    }
    @Test func globalPointsMapIntoVideoPixelsOnDisplaysLeftOfAndAboveTheMain() throws {
        let secondary = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let geometry = try #require(RecordingGeometry(
            region: CGRect(x: -1800, y: -200, width: 400, height: 300), display: secondary, scale: 2))
        #expect(geometry.displayOrigin == CGPoint(x: -1920, y: -300))
        #expect(geometry.videoPoint(forGlobal: CGPoint(x: -1800, y: -200)) == .zero)
        #expect(geometry.videoPoint(forGlobal: CGPoint(x: -1700, y: -50)) == CGPoint(x: 200, y: 300))
        #expect(geometry.videoPixelsPerPoint == 2)
    }

    @Test func globalPointsFollowADownscaledOutput() throws {
        let wide = CGRect(x: 0, y: 0, width: 6016, height: 3384)
        let geometry = try #require(RecordingGeometry(region: wide, display: wide, scale: 2))
        #expect(geometry.isDownscaled)
        let factor = CGFloat(geometry.outputWidth) / CGFloat(geometry.sourceWidth)
        let mapped = geometry.videoPoint(forGlobal: CGPoint(x: 3008, y: 1692))
        #expect(abs(mapped.x - 3008 * 2 * factor) < 0.001)
        #expect(abs(mapped.x - CGFloat(geometry.outputWidth) / 2) < 1)
        #expect(abs(mapped.y - CGFloat(geometry.outputHeight) / 2) < 1)
        #expect(abs(geometry.videoPixelsPerPoint - 2 * factor) < 0.0001)
    }
}
