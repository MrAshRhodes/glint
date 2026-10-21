import CoreGraphics
import Testing
@testable import GlintCore

@Suite("AutoBalance")
struct AutoBalanceTests {
    @Test func detectsUniformBorderAndMargins() throws {
        let img = TestImages.framed(width: 200, height: 100, margins: EdgeMargins(top: 30, left: 25, bottom: 20, right: 35))
        let info = try #require(AutoBalance.detectBorder(in: img))
        #expect(info.margins == EdgeMargins(top: 30, left: 25, bottom: 20, right: 35))
        #expect(info.perimeterFraction >= 0.99)
        #expect(info.color.hexString == "#FFFFFF")
    }

    @Test func balanceCropNormalisesMargins() throws {
        let img = TestImages.framed(width: 200, height: 100, margins: EdgeMargins(top: 30, left: 30, bottom: 30, right: 30))
        let info = try #require(AutoBalance.detectBorder(in: img))
        let rect = AutoBalance.balanceCropRect(imageSize: img.pixelSize, border: info)
        #expect(rect == CGRect(x: 20, y: 20, width: 159, height: 59))
        let result = try #require(AutoBalance.balance(img))
        #expect(result.image.width == 159 && result.image.height == 59)
        #expect(TestImages.pixel(result.image, 0, 0).r == 255) // margin kept
    }

    @Test func smallMarginsExtendedWithBorderColour() throws {
        let img = TestImages.framed(width: 100, height: 60, margins: EdgeMargins(top: 0, left: 5, bottom: 19, right: 5), border: .black)
        let info = BorderInfo(color: .black, perimeterFraction: 1, margins: EdgeMargins(top: 0, left: 5, bottom: 19, right: 5))
        let rect = AutoBalance.balanceCropRect(imageSize: img.pixelSize, border: info)
        #expect(rect.minY == -10) // 10 px added on top
        #expect(rect.height == 60.0)
        let cropped = try #require(AutoBalance.crop(img, to: rect, fill: info.color))
        #expect(cropped.height == Int(rect.height))
        #expect(TestImages.pixel(cropped, 50, 2).r == 0) // new margin filled with border colour
        #expect(TestImages.pixel(cropped, 50, 15).r != 0 || TestImages.pixel(cropped, 50, 16).r != 0) // content follows
    }

    @Test func noPrimaryBorderForBusyPerimeter() {
        let img = TestImages.framed(width: 100, height: 100, margins: EdgeMargins(top: 0, left: 0, bottom: 0, right: 0))
        #expect(AutoBalance.detectBorder(in: img) == nil)
        #expect(AutoBalance.balance(img) == nil)
    }

    @Test func hugeImagesAreSkipped() {
        let big = TestImages.solid(1000, 1000, .white) // 1,000,000 px > 910k guard
        #expect(AutoBalance.detectBorder(in: big) == nil)
        let ok = TestImages.framed(width: 900, height: 1000, margins: EdgeMargins(top: 20, left: 20, bottom: 20, right: 20))
        #expect(AutoBalance.detectBorder(in: ok) != nil) // 900k px
    }

    @Test func fullyUniformImageIsNotBalanced() {
        #expect(AutoBalance.detectBorder(in: TestImages.solid(50, 50, .white)) == nil)
    }

    @Test func axisTouchingEdgesIsUntouched() {
        let info = BorderInfo(color: .white, perimeterFraction: 1, margins: EdgeMargins(top: 0, left: 30, bottom: 0, right: 30))
        let rect = AutoBalance.balanceCropRect(imageSize: CGSize(width: 100, height: 100), border: info)
        #expect(rect.minY == 0 && rect.height == 100)
        #expect(rect.width == 59.0)
    }

    @Test func axisWithBothMarginsBelowTargetIsUntouched() {
        let info = BorderInfo(color: .white, perimeterFraction: 1, margins: EdgeMargins(top: 5, left: 3, bottom: 4, right: 8))
        #expect(AutoBalance.balanceCropRect(imageSize: CGSize(width: 100, height: 80), border: info) == CGRect(x: 0, y: 0, width: 100, height: 80))
    }
}
