import AppKit
import Testing
@testable import GlintCore
@testable import GlintEditor

@Suite("Desktop wallpaper editor")
@MainActor
struct DesktopWallpaperEditorTests {
    private func solid(_ color: RGBAColor) throws -> CGImage {
        let bitmap = try #require(GlintBitmap.makeContext(width: 200, height: 100))
        bitmap.setFillColor(color.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        return try #require(bitmap.makeImage())
    }

    private func expectPreview(_ model: EditorModel, matches image: CGImage) async throws {
        let expected = try #require(PixelBuffer(image)).data
        for _ in 0..<200 {
            if let preview = model.preview, preview.image.width == image.width, preview.image.height == image.height,
               PixelBuffer(preview.image)?.data == expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Preview did not match the exported image")
    }

    @Test func previewAndExportUseOneSnapshotUntilRetoggled() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var calls = 0
        var wallpaper = try solid(RGBAColor(r: 1, g: 0, b: 0))
        let model = EditorModel(context: f.context, preferences: f.preferences, presetStore: f.presets,
                                wallpaperProvider: { calls += 1; return .success(wallpaper) })
        #expect(calls == 0)
        model.settings.padding = 20
        model.settings.usesDesktopWallpaper = true
        let first = try model.renderFinal()
        #expect(try #require(PixelBuffer(first)).pixel(1, 1) == (255, 0, 0, 255))
        try await expectPreview(model, matches: first)
        wallpaper = try solid(.black)
        model.settings.cornerRadius = 15
        model.settings.shadow = ShadowSettings(strength: 20)
        let styled = try model.renderFinal()
        try await expectPreview(model, matches: styled)
        #expect(calls == 1)
        #expect(try #require(PixelBuffer(styled)).pixel(1, 1).0 > 240)

        model.settings.usesDesktopWallpaper = false
        #expect(model.settings.background == .transparent && model.wallpaperProblem == nil)
        model.settings.usesDesktopWallpaper = true
        let refreshed = try model.renderFinal()
        #expect(calls == 2)
        #expect(try #require(PixelBuffer(refreshed)).pixel(1, 1).0 == 0)
        try await expectPreview(model, matches: refreshed)
        let encoded = try Exporter.data(for: refreshed, format: .plainPNG)
        let saved = try #require(GlintImageIO.load(data: encoded))
        #expect(PixelBuffer(saved)?.data == PixelBuffer(refreshed)?.data)
    }

    @Test func unavailableWallpaperShowsErrorAndAllowsNormalBackgrounds() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = EditorModel(context: f.context, preferences: f.preferences, presetStore: f.presets,
                                wallpaperProvider: { .failure(.unavailable) })
        model.chooseBackground(.solid(RGBAColor(r: 1, g: 0, b: 0)))
        model.settings.padding = 20
        model.settings.usesDesktopWallpaper = true
        #expect(model.wallpaperProblem == DesktopWallpaperError.unavailable.localizedDescription)
        let fallback = try model.renderFinal()
        #expect(try #require(PixelBuffer(fallback)).pixel(1, 1) == (255, 0, 0, 255))
        try await expectPreview(model, matches: fallback)
        model.chooseBackground(.solid(.black))
        #expect(!model.settings.usesDesktopWallpaper && model.wallpaperProblem == nil)
        #expect(f.preferences.lastRenderSettings?.usesDesktopWallpaper == false)
        #expect(try #require(PixelBuffer(try model.renderFinal())).pixel(1, 1) == (0, 0, 0, 255))
    }

    @Test func restoredSettingsAndPresetsResolveWallpaper() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let settings = RenderSettings(padding: 20, background: .solid(.black), autoBalance: false, usesDesktopWallpaper: true)
        f.preferences.lastRenderSettings = settings
        let wallpaper = try solid(RGBAColor(r: 1, g: 0, b: 0))
        var calls = 0
        let model = EditorModel(context: f.context, preferences: f.preferences, presetStore: f.presets,
                                wallpaperProvider: { calls += 1; return .success(wallpaper) })
        #expect(calls == 1 && model.settings.usesDesktopWallpaper)
        model.chooseBackground(.solid(.white))
        #expect(!model.settings.usesDesktopWallpaper)
        let preset = f.presets.add(name: "Wallpaper", settings: settings)
        try f.presets.save()
        let reloaded = PresetStore(url: f.presets.url)
        model.settings = try #require(reloaded.preset(named: preset.name)).settings
        #expect(calls == 2 && model.settings.usesDesktopWallpaper)
        #expect(model.settings.background == .solid(.black))
    }

    @Test func headlessRenderHonorsWallpaperAndReportsFallback() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.lastRenderSettings = RenderSettings(padding: 20, shadow: .none, background: .solid(.black),
                                                          autoBalance: false, usesDesktopWallpaper: true)
        let wallpaper = try solid(RGBAColor(r: 1, g: 0, b: 0))
        var errors: [DesktopWallpaperError] = []
        let rendered = try EditorHeadless.render(context: f.context, preferences: f.preferences,
                                              wallpaperProvider: { .success(wallpaper) }, onWallpaperFailure: { errors.append($0) })
        #expect(try #require(PixelBuffer(rendered)).pixel(1, 1) == (255, 0, 0, 255))
        #expect(errors.isEmpty)
        let fallback = try EditorHeadless.render(context: f.context, preferences: f.preferences,
                                              wallpaperProvider: { .failure(.rotatingFolder) }, onWallpaperFailure: { errors.append($0) })
        #expect(try #require(PixelBuffer(fallback)).pixel(1, 1) == (0, 0, 0, 255))
        #expect(errors == [.rotatingFolder])
    }
}
