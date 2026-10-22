import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GlintCore

@Suite("Desktop wallpaper")
struct DesktopWallpaperTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-wallpaper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func settingsRemainCompatibleWithOlderPresets() throws {
        let original = RenderSettings(background: .solid(.red))
        let data = try JSONEncoder().encode(original)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["desktopWallpaper"] == nil)
        #expect(try JSONDecoder().decode(RenderSettings.self, from: data) == original)
        #expect(try !JSONDecoder().decode(RenderSettings.self, from: data).usesDesktopWallpaper)

        var enabled = original
        enabled.usesDesktopWallpaper = true
        let roundTrip = try JSONDecoder().decode(RenderSettings.self, from: JSONEncoder().encode(enabled))
        #expect(roundTrip == enabled && roundTrip.usesDesktopWallpaper)
        enabled.usesDesktopWallpaper = false
        #expect(enabled == original)
        #expect(RenderSettings(usesDesktopWallpaper: true).usesDesktopWallpaper)
    }

    @Test func missingOrRotatingWallpaperExplainsFallback() throws {
        #expect(throws: DesktopWallpaperError.unavailable) { try DesktopWallpaper.load(url: nil).get() }
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: DesktopWallpaperError.rotatingFolder) { try DesktopWallpaper.load(url: dir).get() }
        for error in [DesktopWallpaperError.unavailable, .rotatingFolder, .unreadable("wallpaper.heic")] {
            #expect(error.localizedDescription.contains("using your other background instead"))
        }
    }

    @Test func missingInvalidAndNonFileImagesFailClearly() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("invalid.png")
        #expect(throws: DesktopWallpaperError.unreadable("invalid.png")) { try DesktopWallpaper.load(url: url).get() }
        try Data("not an image".utf8).write(to: url)
        #expect(throws: DesktopWallpaperError.unreadable("invalid.png")) { try DesktopWallpaper.load(url: url).get() }
        let remote = try #require(URL(string: "https://example.invalid/wallpaper.png"))
        #expect(throws: DesktopWallpaperError.unreadable("wallpaper.png")) { try DesktopWallpaper.load(url: remote).get() }
    }

    @Test func loadsWallpaperPixelsWithoutImport() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("wallpaper.png")
        let original = TestImages.framed(width: 80, height: 60, margins: EdgeMargins(top: 5, left: 5, bottom: 5, right: 5))
        try Exporter.write(original, to: url)
        let wallpaper = try DesktopWallpaper.load(url: url).get()
        #expect(wallpaper.width == 80 && wallpaper.height == 60)
        #expect(PixelBuffer(wallpaper)?.data == PixelBuffer(original)?.data)
    }

    @Test func respectsWallpaperImageOrientation() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("portrait.tiff")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, TestImages.solid(80, 40, .red),
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let wallpaper = try DesktopWallpaper.load(url: url).get()
        #expect(wallpaper.width == 40 && wallpaper.height == 80)
    }

    @Test func wallpaperOverridesOnlyWhenEnabledAndAvailable() throws {
        let content = TestImages.solid(100, 50, .white)
        let wallpaper = TestImages.solid(200, 100, .red)
        var settings = RenderSettings(padding: 20, cornerRadius: 0, shadow: .none,
                                      background: .solid(.black), autoBalance: false, usesDesktopWallpaper: true)
        let enabled = try Compositor.render(image: content, settings: settings, wallpaper: wallpaper)
        #expect(TestImages.pixel(enabled, 1, 1) == TestImages.pixel(wallpaper, 1, 1))
        #expect(TestImages.pixel(enabled, 70, 45).g == 255)
        let unavailable = try Compositor.render(image: content, settings: settings)
        #expect(TestImages.pixel(unavailable, 1, 1).r == 0)
        settings.usesDesktopWallpaper = false
        let disabled = try Compositor.render(image: content, settings: settings, wallpaper: wallpaper)
        #expect(PixelBuffer(disabled)?.data == PixelBuffer(unavailable)?.data)
    }

    @Test(arguments: [false, true])
    func wallpaperPreservesStylingAndAspectFill(tilted: Bool) throws {
        let content = TestImages.solid(100, 70, .white)
        let wallpaper = TestImages.framed(width: 240, height: 80, margins: EdgeMargins(top: 8, left: 8, bottom: 8, right: 8))
        var settings = RenderSettings(padding: 40, inset: 5, insetColor: .red, cornerRadius: 18,
                                      background: .solid(.black), aspectRatio: .square,
                                      border: BorderStyle(enabled: true, width: 2),
                                      windowFrame: WindowFrameSettings(style: .browser, title: "Glint"),
                                      tilt: tilted ? Tilt(x: 5, y: 8) : .zero, rotation: .cw90,
                                      watermark: WatermarkSettings(enabled: true, text: "Example"),
                                      autoBalance: false, usesDesktopWallpaper: true)
        let annotations = [Annotation(kind: .redact(CGRect(x: 20, y: 20, width: 20, height: 10)))]
        let result = try Compositor.renderDetailed(image: content, settings: settings, annotations: annotations,
                                               backingScale: 2, wallpaper: wallpaper)
        settings.usesDesktopWallpaper = false
        settings.background = .image(path: "", fit: .fill)
        let baseline = try Compositor.renderDetailed(image: content, settings: settings, annotations: annotations,
                                                 backingScale: 2, backgroundImage: wallpaper)
        #expect(result.layout == baseline.layout)
        #expect(try #require(PixelBuffer(result.image)).data == #require(PixelBuffer(baseline.image)).data)
    }
}
