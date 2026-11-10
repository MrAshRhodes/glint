import AppKit
@testable import GlintCore
@testable import GlintEditor
import Testing
@testable import Glint

@Suite("Direct export settings in the pipeline")
@MainActor
struct DirectExportCapturePipelineTests {
    /// What `defaultPresetName` and the preset store hold in a scenario.
    enum DefaultPreset: Sendable {
        case named, missing, unnamed, emptyStore
    }

    struct Scenario: Sendable, CustomTestStringConvertible {
        let remember: Bool
        let saved: Bool
        let defaultPreset: DefaultPreset

        var testDescription: String {
            "Remember settings \(remember ? "on" : "off"), \(saved ? "saved settings" : "nothing saved"), "
                + "default preset \(defaultPreset)"
        }

        static let all = [true, false].flatMap { remember in
            [true, false].flatMap { saved in
                [DefaultPreset.named, .missing, .unnamed, .emptyStore].map {
                    Scenario(remember: remember, saved: saved, defaultPreset: $0)
                }
            }
        }
    }

    private static let presetName = "Named"
    private static let remembered = RenderSettings(padding: 10, inset: 0, cornerRadius: 0, shadow: .none,
                                                   background: .solid(.black), autoBalance: true)
    private static let named = RenderSettings(padding: 6, inset: 0, cornerRadius: 0, shadow: .none,
                                              background: .solid(.red), autoBalance: true)

    /// Configures the preferences and the preset store for `scenario` and returns the settings an export must use:
    /// the remembered look, else the named default preset, else the store's default preset, else the built-in
    /// default, always with Auto-balance as set in Preferences.
    private func prepare(_ scenario: Scenario, _ f: CaptureFixture) throws -> RenderSettings {
        var expected = try #require(f.presets.defaultPreset).settings
        switch scenario.defaultPreset {
        case .named:
            f.presets.add(name: Self.presetName, settings: Self.named)
            f.preferences.defaultPresetName = Self.presetName
            expected = Self.named
        case .missing:
            f.preferences.defaultPresetName = "Deleted preset"
        case .unnamed:
            f.preferences.defaultPresetName = nil
        case .emptyStore:
            for preset in f.presets.presets { f.presets.delete(id: preset.id) }
            f.preferences.defaultPresetName = nil
            expected = .default
        }
        f.preferences.rememberSettings = scenario.remember
        f.preferences.lastRenderSettings = scenario.saved ? Self.remembered : nil
        if scenario.remember && scenario.saved { expected = Self.remembered }
        expected.autoBalance = f.preferences.autoBalance
        return expected
    }

    private func editor(_ f: CaptureFixture, image: CGImage? = nil) -> EditorModel {
        EditorModel(context: EditorContext(image: image ?? f.image, backingScale: 2, rawURL: nil, source: "test"),
                    preferences: f.preferences, presetStore: f.presets)
    }

    private func rendered(_ image: CGImage, _ settings: RenderSettings) throws -> CGImage {
        try Compositor.render(image: image, settings: settings, backingScale: 2, wallpaper: nil)
    }

    private func expectIdenticalPixels(_ actual: CGImage, _ expected: CGImage,
                                       sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(actual.width == expected.width && actual.height == expected.height, sourceLocation: sourceLocation)
        let a = try #require(PixelBuffer(actual), sourceLocation: sourceLocation)
        let e = try #require(PixelBuffer(expected), sourceLocation: sourceLocation)
        let firstDifference = zip(a.data, e.data).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        #expect(firstDifference == nil, "First differing byte: \(firstDifference ?? -1)", sourceLocation: sourceLocation)
    }

    /// A white screenshot with a 30 px white margin around a black block, which Auto-balance trims.
    private func framedImage() throws -> CGImage {
        let context = try #require(GlintBitmap.makeContext(width: 200, height: 100))
        context.setFillColor(RGBAColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        context.setFillColor(RGBAColor.black.cgColor)
        context.fill(CGRect(x: 30, y: 30, width: 140, height: 40))
        return try #require(context.makeImage())
    }

    @Test(arguments: Scenario.all)
    func automaticExportStartsFromTheSameLookAsTheEditor(_ scenario: Scenario) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.copyToClipboardAfterCapture = true
        let expected = try prepare(scenario, f)
        let storedLook = f.preferences.defaults.data(forKey: AppPreferences.Key.lastRenderSettings)

        #expect(f.pipeline().settings() == expected)
        await f.run()

        let exported = try #require(f.copiedImage)
        try expectIdenticalPixels(exported, rendered(f.image, expected))
        let model = editor(f)
        #expect(model.settings == expected)
        try expectIdenticalPixels(model.renderFinal(), exported)
        #expect(f.preferences.defaults.data(forKey: AppPreferences.Key.lastRenderSettings) == storedLook)
    }

    @Test func aLookChosenInTheEditorIsUsedByTheNextAutomaticExport() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.rememberSettings = true
        f.preferences.copyToClipboardAfterCapture = true
        let model = editor(f)
        model.settings.padding = 42
        model.settings.cornerRadius = 9
        model.settings.background = .solid(.red)

        await f.run()

        #expect(f.pipeline().settings() == model.settings)
        try expectIdenticalPixels(#require(f.copiedImage), model.renderFinal())
        #expect(editor(f).settings == model.settings)
    }

    @Test func clipboardOnlyCaptureUsesTheRememberedLookEvenWithTheEditorEnabled() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.preferences.openEditorAfterCapture = true
        f.preferences.rememberSettings = true
        f.preferences.lastRenderSettings = Self.remembered
        var expected = Self.remembered
        expected.autoBalance = f.preferences.autoBalance

        await f.run(clipboardOnly: true)

        #expect(f.copies == 1)
        try expectIdenticalPixels(#require(f.copiedImage), rendered(f.image, expected))
    }

    @Test(arguments: [true, false])
    func autoBalanceFollowsPreferencesNotTheRememberedLook(enabled: Bool) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        var look = Self.remembered
        look.autoBalance = !enabled
        f.preferences.rememberSettings = true
        f.preferences.lastRenderSettings = look
        f.preferences.autoBalance = enabled
        f.preferences.copyToClipboardAfterCapture = true
        let framed = try framedImage()
        var expected = look
        expected.autoBalance = enabled
        var unbalanced = look
        unbalanced.autoBalance = false

        let pipeline = f.pipeline()
        await pipeline.handle(image: framed, scale: 2, source: "test", rawURL: nil, saveRaw: false, clipboardOnly: false)
        await f.settle(pipeline)

        let exported = try #require(f.copiedImage)
        try expectIdenticalPixels(exported, rendered(framed, expected))
        try expectIdenticalPixels(editor(f, image: framed).renderFinal(), exported)
        let untrimmed = try rendered(framed, unbalanced)
        #expect((exported.width < untrimmed.width && exported.height < untrimmed.height) == enabled)
    }

    @Test(arguments: [true, false])
    func anExplicitPresetStillOverridesTheRememberedLook(remember: Bool) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        f.presets.add(name: Self.presetName, settings: Self.named)
        f.preferences.rememberSettings = remember
        f.preferences.lastRenderSettings = Self.remembered
        let pipeline = f.pipeline()
        var explicit = Self.named
        explicit.autoBalance = f.preferences.autoBalance
        var ordinary = remember ? Self.remembered : try #require(f.presets.defaultPreset).settings
        ordinary.autoBalance = f.preferences.autoBalance

        #expect(pipeline.settings(presetName: Self.presetName) == explicit)
        #expect(pipeline.settings() == ordinary)
        #expect(pipeline.settings(presetName: "Deleted preset") == ordinary)
    }
}
