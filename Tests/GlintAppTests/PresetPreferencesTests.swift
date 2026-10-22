import AppKit
import GlintCore
import GlintEditor
import Testing
@testable import Glint

@Suite("Preferences preset starting points")
@MainActor
struct PresetPreferencesTests {
    @Test func offersLastUsedAndSavedLooksWithoutDuplicatingBuiltIns() {
        let lastUsed = RenderSettings(padding: 91)
        let custom = Preset(name: "My look", settings: RenderSettings(padding: 27))
        let saved = Preset.builtIn + [custom]
        let choices = PresetStartingPoint.choices(lastUsed: lastUsed, presets: saved)

        #expect(choices.count == saved.count + 1)
        #expect(choices.first?.id == "last-used")
        #expect(choices.first?.settings == lastUsed)
        #expect(choices.last?.name == custom.name)
        #expect(choices.last?.settings == custom.settings)
        #expect(Set(choices.map(\.id)).count == choices.count)
    }

    @Test func missingBuiltInsRemainAvailableWithoutChangingTheSavedList() {
        var renamed = Preset.builtIn[0]
        renamed.name = "Renamed look"
        renamed.settings.padding = 83
        let saved = [renamed]
        let choices = PresetStartingPoint.choices(lastUsed: nil, presets: saved)

        #expect(choices.count == Preset.builtIn.count)
        #expect(choices.first?.name == renamed.name)
        #expect(choices.first?.settings == renamed.settings)
        #expect(choices.filter { $0.detail == "Built-in" }.count == Preset.builtIn.count - 1)
        #expect(!choices.contains { $0.id == "last-used" })
        #expect(saved.count == 1)
    }

    @Test func emptyStoreStillOffersBuiltInStartingPoints() {
        let choices = PresetStartingPoint.choices(lastUsed: nil, presets: [])
        #expect(choices.map(\.settings) == Preset.builtIn.map(\.settings))
    }

    @Test func creatingFromPreferencesPersistsOnlyTheSelectedLook() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.prefs.lastRenderSettings = RenderSettings(padding: 91)
        let originalDefault = fixture.store.defaultPresetID
        let draft = NewPresetModel(prefs: fixture.prefs, store: fixture.store)
        let startingPoint = try #require(draft.choices.first { $0.name == "Clean" })
        draft.selectedID = startingPoint.id
        draft.name = "  Presentation  \n"

        let saved = try draft.add()

        #expect(saved.name == "Presentation")
        #expect(saved.settings == startingPoint.settings)
        #expect(PresetStore(url: fixture.store.url).preset(named: "Presentation") == saved)
        #expect(fixture.store.defaultPresetID == originalDefault)
        #expect(fixture.prefs.lastRenderSettings?.padding == 91)
        let data = try String(contentsOf: fixture.store.url, encoding: .utf8)
        #expect(!data.contains("Built-in sample"))
        #expect(!data.contains("imageName"))
    }

    @Test func preparingOrCancellingCustomizationDoesNotSaveAnything() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.prefs.lastRenderSettings = RenderSettings(padding: 91)
        let before = fixture.store.presets
        let draft = NewPresetModel(prefs: fixture.prefs, store: fixture.store)
        let design = try draft.design()

        #expect(design.settings.padding == 91)
        #expect(design.image.width > 0)
        #expect(design.editingID == nil)
        #expect(fixture.store.presets == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
        #expect(fixture.prefs.lastRenderSettings?.padding == 91)
    }

    @Test func invalidAndConflictingNamesNeverReplacePresets() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.store.add(name: "My preset", settings: .default)
        let before = fixture.store.presets
        let draft = NewPresetModel(prefs: fixture.prefs, store: fixture.store)
        #expect(draft.name == "My preset 2")

        for name in [" \n ", "  Clean  "] {
            draft.name = name
            #expect(draft.validationMessage != nil)
            #expect(throws: (any Error).self) { try draft.add() }
        }
        draft.name = "Added elsewhere"
        fixture.store.add(name: draft.name, settings: .default)
        #expect(throws: (any Error).self) { try draft.add() }
        #expect(Array(fixture.store.presets.dropLast()) == before)
    }

    @Test func failedPersistenceRollsBackTheNewPreset() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try Data("not a directory".utf8).write(to: fixture.directory)
        let before = fixture.store.presets
        let previousDefault = fixture.store.defaultPresetID
        let draft = NewPresetModel(prefs: fixture.prefs, store: fixture.store)

        #expect(throws: (any Error).self) { try draft.add() }
        #expect(fixture.store.presets == before)
        #expect(fixture.store.defaultPresetID == previousDefault)
    }

    @Test func userImageIsPreviewOnlyAndUnreadableImagesDoNotReplaceIt() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let url = fixture.directory.appendingPathComponent("preview.png")
        let image = SampleImage.make(scale: 1)
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: url)
        let draft = NewPresetModel(prefs: fixture.prefs, store: fixture.store)
        try draft.useImage(at: url)
        let revision = draft.imageRevision

        #expect(try draft.design().image.width == image.width)
        #expect(draft.imageName == "preview.png")
        #expect(throws: (any Error).self) { try draft.useImage(at: url.appendingPathExtension("missing")) }
        #expect(draft.imageRevision == revision)
        #expect(draft.imageName == "preview.png")

        let saved = try draft.add()
        let data = try String(contentsOf: fixture.store.url, encoding: .utf8)
        #expect(!data.contains("preview.png"))
        #expect(PresetStore(url: fixture.store.url).preset(named: saved.name) == saved)
    }

    private struct Fixture {
        let suite = "PresetPreferencesTests-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prefs: AppPreferences
        let store: PresetStore

        init() {
            prefs = AppPreferences(defaults: UserDefaults(suiteName: suite)!)
            store = PresetStore(url: directory.appendingPathComponent("presets.json"))
        }

        func cleanUp() {
            prefs.defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
