import CoreGraphics
import Foundation
import Testing
@testable import GlintCore
@testable import GlintEditor

@Suite("Sample image and preset previews")
struct SampleImageTests {
    static let sample = SampleImage.make()

    private func aspect(_ image: CGImage) -> CGFloat { CGFloat(image.width) / CGFloat(image.height) }

    private func solid(_ color: RGBAColor, width: Int = 64, height: Int = 64) throws -> CGImage {
        let bitmap = try #require(GlintBitmap.makeContext(width: width, height: height))
        bitmap.setFillColor(color.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(bitmap.makeImage())
    }

    @Test func sampleHasExpectedPixelSizes() {
        #expect(SampleImage.pointSize == CGSize(width: 720, height: 450))
        #expect(SampleImage.make(scale: 1).pixelSize == CGSize(width: 720, height: 450))
        #expect(Self.sample.pixelSize == CGSize(width: 1440, height: 900))
    }

    @Test func sampleIsDetailedAndDeterministic() throws {
        let buf = try #require(PixelBuffer(SampleImage.make(scale: 1)))
        let sidebar = buf.pixel(100, 440), content = buf.pixel(600, 440), closeButton = buf.pixel(20, 20)
        #expect(sidebar != content)
        #expect(closeButton.0 > 200 && closeButton.1 < 150 && closeButton.3 == 255)
        var colors = Set<UInt32>()
        for i in stride(from: 0, to: buf.data.count, by: 4) {
            colors.insert(UInt32(buf.data[i]) << 16 | UInt32(buf.data[i + 1]) << 8 | UInt32(buf.data[i + 2]))
        }
        #expect(colors.count > 100)
        #expect(buf.data.indices.filter { $0 % 4 == 3 }.allSatisfy { buf.data[$0] == 255 })
        #expect(PixelBuffer(SampleImage.make(scale: 1))?.data == buf.data)
    }

    @Test func sampleRendersIdenticallyOffTheMainThread() async throws {
        let reference = try #require(PixelBuffer(SampleImage.make(scale: 1))).data
        let images = await withTaskGroup(of: CGImage.self) { group in
            for _ in 0..<4 { group.addTask { SampleImage.make(scale: 1) } }
            return await group.reduce(into: [CGImage]()) { $0.append($1) }
        }
        #expect(images.count == 4)
        for image in images { #expect(PixelBuffer(image)?.data == reference) }
    }

    @Test(arguments: [1.0, 2.0])
    func autoBalanceKeepsTheWholeSample(scale: Double) throws {
        let image = SampleImage.make(scale: CGFloat(scale))
        if let border = AutoBalance.detectBorder(in: image, maxPixels: .max) {
            let crop = AutoBalance.balanceCropRect(imageSize: image.pixelSize, border: border)
            #expect(abs(crop.minX) <= 4 && abs(crop.minY) <= 4)
            #expect(abs(crop.width - CGFloat(image.width)) <= 4 && abs(crop.height - CGFloat(image.height)) <= 4)
        }
        let settings = RenderSettings(padding: 0, inset: 0, cornerRadius: 0, shadow: .none, background: .transparent,
                                      autoBalance: true)
        let result = try Compositor.renderDetailed(image: image, settings: settings, backingScale: CGFloat(scale))
        #expect(result.layout.contentRect.size == image.pixelSize)
    }

    @Test(arguments: Preset.builtIn.map(\.name))
    func previewFitsForEveryBuiltInPreset(name: String) throws {
        let preset = try #require(Preset.builtIn.first { $0.name == name })
        let bounds = CGSize(width: 480, height: 320)
        let out = try #require(PresetPreview.render(settings: preset.settings, image: Self.sample, backingScale: 2,
                                                    fitting: bounds))
        #expect(out.width <= 480 && out.height <= 320)
        #expect(out.width >= 470 || out.height >= 310)
    }

    @Test func paddedPresetSurroundsTheContent() throws {
        let clean = try #require(Preset.builtIn.first { $0.name == "Clean" }).settings
        let out = try #require(PresetPreview.render(settings: clean, image: Self.sample, backingScale: 2,
                                                    fitting: CGSize(width: 4000, height: 4000)))
        let expected = Compositor.layout(contentSize: Self.sample.pixelSize, insetApplied: false, settings: clean,
                                         backingScale: 2).canvasSize
        #expect(out.pixelSize == expected)
        #expect(out.width > Self.sample.width && out.height > Self.sample.height)
        #expect(abs(aspect(out) - 1) < abs(aspect(Self.sample) - 1))
        #expect(try #require(PixelBuffer(out)).pixel(0, 0) == (255, 255, 255, 255))
    }

    @Test func socialPresetKeepsSixteenByNine() throws {
        let social = try #require(Preset.builtIn.first { $0.name == "Social 16:9" }).settings
        let out = try #require(PresetPreview.render(settings: social, image: Self.sample, backingScale: 2,
                                                    fitting: CGSize(width: 400, height: 400)))
        #expect(abs(aspect(out) - 16.0 / 9) < 0.02)
        #expect(out.width <= 400 && out.width >= 396)
    }

    @Test func tinyOrEmptyBounds() throws {
        let out = try #require(PresetPreview.render(settings: .default, image: Self.sample, backingScale: 2,
                                                    fitting: CGSize(width: 60, height: 40)))
        #expect(out.width <= 60 && out.height <= 40 && (out.width >= 58 || out.height >= 38))
        #expect(PresetPreview.render(settings: .default, image: Self.sample, backingScale: 2, fitting: .zero) == nil)
    }

    @Test func smallImagesAreNotUpscaled() throws {
        let image = SampleImage.make(scale: 0.25)
        let settings = RenderSettings(padding: 10, shadow: .none, background: .solid(.black))
        let out = try #require(PresetPreview.render(settings: settings, image: image, backingScale: 1,
                                                    fitting: CGSize(width: 2000, height: 2000)))
        #expect(out.pixelSize == CGSize(width: image.width + 20, height: image.height + 20))
    }

    @Test func wallpaperAndImageBackgroundsAreUsed() throws {
        var settings = RenderSettings(padding: 40, shadow: .none, background: .solid(.black))
        settings.usesDesktopWallpaper = true
        let bounds = CGSize(width: 300, height: 300)
        let red = try solid(RGBAColor(r: 1, g: 0, b: 0))
        let withWallpaper = try #require(PresetPreview.render(settings: settings, image: Self.sample, backingScale: 2,
                                                              fitting: bounds, wallpaper: red))
        #expect(try #require(PixelBuffer(withWallpaper)).pixel(1, 1) == (255, 0, 0, 255))
        let fallback = try #require(PresetPreview.render(settings: settings, image: Self.sample, backingScale: 2,
                                                         fitting: bounds))
        #expect(try #require(PixelBuffer(fallback)).pixel(1, 1) == (0, 0, 0, 255))

        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/TestFixtures/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("background.png")
        try Exporter.data(for: try solid(RGBAColor(r: 0, g: 0, b: 1)), format: .plainPNG).write(to: url)
        let fromDisk = try #require(PresetPreview.render(
            settings: RenderSettings(padding: 40, shadow: .none, background: .image(path: url.path, fit: .fill)),
            image: Self.sample, backingScale: 2, fitting: bounds))
        #expect(try #require(PixelBuffer(fromDisk)).pixel(1, 1) == (0, 0, 255, 255))
    }
}
