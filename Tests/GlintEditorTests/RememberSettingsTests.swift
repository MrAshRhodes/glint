import AppKit
import Testing
@testable import GlintCore
@testable import GlintEditor

@Suite("Remember settings")
@MainActor
struct RememberSettingsTests {
    /// A fresh `AppPreferences` and `PresetStore` over the same storage, as after restarting Glint.
    private func restarted(_ f: EditorFixture) throws -> (AppPreferences, PresetStore) {
        (AppPreferences(defaults: try #require(UserDefaults(suiteName: f.suite))), PresetStore(url: f.presets.url))
    }

    private func addDefaultPreset(_ f: EditorFixture, padding: Double) throws -> Preset {
        let preset = f.presets.add(name: "House style", settings: RenderSettings(padding: padding))
        f.presets.setDefault(id: preset.id)
        try f.presets.save()
        f.preferences.defaultPresetName = preset.name
        return preset
    }

    @Test func untilChosenItFollowsTheEarlierBehaviorThenTheChoicePersists() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        #expect(f.preferences.rememberSettings)
        f.preferences.defaultPresetName = "Clean"
        #expect(!f.preferences.rememberSettings)

        f.preferences.rememberSettings = true
        #expect(try restarted(f).0.rememberSettings)
        f.preferences.defaultPresetName = nil
        f.preferences.rememberSettings = false
        #expect(try !restarted(f).0.rememberSettings)

        f.preferences.resetToDefaults()
        #expect(f.preferences.defaults.object(forKey: AppPreferences.Key.rememberSettings) == nil)
        #expect(f.preferences.rememberSettings)
    }

    @Test func enabledRestoresLastUsedSettingsIncludingAfterRestart() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let preset = try addDefaultPreset(f, padding: 12)
        f.preferences.rememberSettings = true

        let model = f.model()
        model.settings.padding = 42
        model.settings.cornerRadius = 7
        #expect(f.model().settings.padding == 42)

        let (preferences, presets) = try restarted(f)
        #expect(preferences.rememberSettings)
        let restored = EditorModel(context: f.context, preferences: preferences, presetStore: presets)
        #expect(restored.settings.padding == 42 && restored.settings.cornerRadius == 7)
        #expect(presets.preset(named: preset.name)?.settings.padding == 12)
    }

    @Test func enabledWithNothingUsedYetStartsFromTheDefaultPreset() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.lastRenderSettings = nil
        _ = try addDefaultPreset(f, padding: 12)
        f.preferences.rememberSettings = true
        #expect(f.model().settings.padding == 12)
    }

    @Test func disabledStartsFromTheDefaultPresetIncludingAfterRestart() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.rememberSettings = false
        f.preferences.lastRenderSettings = RenderSettings(padding: 42)
        #expect(f.model().settings.padding == f.presets.defaultPreset?.settings.padding)

        _ = try addDefaultPreset(f, padding: 12)
        let model = f.model()
        #expect(model.settings.padding == 12)
        model.settings.padding = 55
        #expect(f.preferences.lastRenderSettings?.padding == 55)
        #expect(f.model().settings.padding == 12)

        let (preferences, presets) = try restarted(f)
        #expect(!preferences.rememberSettings)
        #expect(EditorModel(context: f.context, preferences: preferences, presetStore: presets).settings.padding == 12)
    }

    @Test func rememberingNeverOverwritesPresetsAndPresetsCanStillBeSaved() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let preset = try addDefaultPreset(f, padding: 12)
        f.preferences.rememberSettings = true
        let before = f.presets.presets

        let model = f.model()
        model.applyPreset(preset)
        model.settings.padding = 64
        #expect(f.presets.presets == before)
        #expect(PresetStore(url: f.presets.url).presets == before)

        model.savePreset(named: "Roomy")
        let reloaded = PresetStore(url: f.presets.url)
        #expect(reloaded.preset(named: "Roomy")?.settings.padding == 64)
        #expect(reloaded.preset(named: preset.name)?.settings.padding == 12)
    }

    struct Precedence: Sendable, CustomTestStringConvertible {
        enum DefaultPreset: Sendable {
            case named, missing, unnamed
        }

        let remember: Bool
        let saved: Bool
        let defaultPreset: DefaultPreset

        /// Saved settings are 31, the named default preset 12 and the store's default preset 7.
        var expectedPadding: Double {
            if remember && saved { return 31 }
            return defaultPreset == .named ? 12 : 7
        }

        var testDescription: String {
            "Remember settings \(remember ? "on" : "off"), \(saved ? "saved settings" : "nothing saved"), "
                + "default preset \(defaultPreset)"
        }

        static let all = [true, false].flatMap { remember in
            [true, false].flatMap { saved in
                [DefaultPreset.named, .missing, .unnamed].map { Precedence(remember: remember, saved: saved, defaultPreset: $0) }
            }
        }
    }

    @Test(arguments: Precedence.all)
    func initialSettingsPreferRememberedThenTheNamedDefaultThenTheStoreDefault(_ scenario: Precedence) throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let named = f.presets.add(name: "House style", settings: RenderSettings(padding: 12))
        let storeDefault = f.presets.add(name: "Store default", settings: RenderSettings(padding: 7))
        f.presets.setDefault(id: storeDefault.id)
        switch scenario.defaultPreset {
        case .named: f.preferences.defaultPresetName = named.name
        case .missing: f.preferences.defaultPresetName = "Deleted preset"
        case .unnamed: f.preferences.defaultPresetName = nil
        }
        f.preferences.rememberSettings = scenario.remember
        f.preferences.lastRenderSettings = scenario.saved ? RenderSettings(padding: 31) : nil

        let settings = EditorHeadless.initialSettings(preferences: f.preferences, presetStore: f.presets)
        #expect(settings.padding == scenario.expectedPadding)
        #expect(f.model().settings == settings)
    }

    @Test func withoutAPresetStoreItFallsBackToRememberedSettingsThenTheBuiltInDefault() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.rememberSettings = true
        f.preferences.lastRenderSettings = RenderSettings(padding: 31)
        #expect(EditorHeadless.initialSettings(preferences: f.preferences).padding == 31)

        f.preferences.lastRenderSettings = nil
        #expect(EditorHeadless.initialSettings(preferences: f.preferences).padding == RenderSettings.default.padding)
    }

    @Test(arguments: [true, false])
    func autoBalanceAlwaysFollowsPreferences(enabled: Bool) throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let preset = f.presets.add(name: "House style", settings: RenderSettings(padding: 12, autoBalance: !enabled))
        f.presets.setDefault(id: preset.id)
        f.preferences.autoBalance = enabled

        f.preferences.rememberSettings = false
        #expect(EditorHeadless.initialSettings(preferences: f.preferences, presetStore: f.presets).autoBalance == enabled)
        #expect(f.model().settings.autoBalance == enabled)

        f.preferences.rememberSettings = true
        f.preferences.lastRenderSettings = RenderSettings(padding: 31, autoBalance: !enabled)
        #expect(EditorHeadless.initialSettings(preferences: f.preferences, presetStore: f.presets).autoBalance == enabled)
        #expect(f.model().settings.autoBalance == enabled)
        #expect(EditorHeadless.initialSettings(preferences: f.preferences, presetStore: f.presets,
                                               presetName: preset.name).autoBalance == enabled)
    }

    @Test(arguments: [true, false])
    func anExplicitPresetOverridesRememberedSettingsAndAMissingOneFallsBack(remember: Bool) throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.presets.add(name: "Explicit", settings: RenderSettings(padding: 5))
        f.preferences.rememberSettings = remember
        f.preferences.lastRenderSettings = RenderSettings(padding: 31)

        let ordinary = EditorHeadless.initialSettings(preferences: f.preferences, presetStore: f.presets)
        #expect(ordinary.padding == (remember ? 31 : f.presets.defaultPreset?.settings.padding))
        #expect(EditorHeadless.initialSettings(preferences: f.preferences, presetStore: f.presets,
                                               presetName: "Explicit").padding == 5)
        #expect(EditorHeadless.initialSettings(preferences: f.preferences, presetStore: f.presets,
                                               presetName: "Deleted preset") == ordinary)
        #expect(EditorHeadless.initialSettings(preferences: f.preferences, presetName: "Explicit").padding
                == (remember ? 31 : RenderSettings.default.padding))
    }
}
