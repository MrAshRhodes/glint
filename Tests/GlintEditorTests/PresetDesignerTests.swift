import AppKit
@testable import GlintCore
import Testing
@testable import GlintEditor

private func designerKey(_ characters: String, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                     characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}

private let designLook = RenderSettings(padding: 77, cornerRadius: 9, background: .solid(.white), autoBalance: true)

private final class CallCounter: @unchecked Sendable { var count = 0 }

@MainActor
private extension EditorFixture {
    func design(name: String = "My Look", editing id: UUID? = nil, settings: RenderSettings = designLook) -> PresetDesign {
        PresetDesign(image: context.image, backingScale: 2, settings: settings, name: name, editingID: id)
    }

    func designer(_ design: PresetDesign, store: PresetStore? = nil,
                  recognizeText: @escaping (CGImage) async throws -> [RecognizedLine] = { _ in [] }) -> EditorModel {
        EditorModel(context: context, preferences: preferences, presetStore: store ?? presets, design: design,
                    recognizeText: recognizeText)
    }

    func designController(_ design: PresetDesign, store: PresetStore? = nil,
                          services: EditorExportServices = EditorExportServices()) -> EditorWindowController {
        _ = NSApplication.shared
        return EditorWindowController(design: design, preferences: preferences, presetStore: store ?? presets, exportServices: services)
    }

    /// A store whose save always fails (its folder path runs through a regular file).
    func unwritableStore() throws -> PresetStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        return PresetStore(url: blocker.appendingPathComponent("presets.json"))
    }
}

@Suite("Preset designer")
@MainActor
struct PresetDesignerTests {
    @Test func designerStartsFromDesignAndNeverTouchesLastUsedLook() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let lastUsed = f.preferences.lastRenderSettings
        let ocr = CallCounter()
        let model = f.designer(f.design(), recognizeText: { _ in ocr.count += 1; return [] })
        #expect(model.isDesigningPreset && model.settings == designLook)
        #expect(model.designName == "My Look" && model.designTitle == "New Preset" && !model.designMakeDefault)

        model.settings.padding = 12
        model.settings.autoBalance = false
        model.settings.autoBalance = true
        model.applyPreset(try #require(f.presets.preset(named: "Clean")))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(f.preferences.lastRenderSettings == lastUsed)
        #expect(f.preferences.autoBalance == false)
        #expect(ocr.count == 0 && model.annotations.isEmpty)
    }

    @Test func captureEditorStillRemembersLastUsedLook() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        #expect(!model.isDesigningPreset)
        model.settings.padding = 33
        model.settings.autoBalance = true
        #expect(f.preferences.lastRenderSettings?.padding == 33)
        #expect(f.preferences.autoBalance)
    }

    @Test func newPresetGetsFreshIDIsPersistedAndCannotClobberAnotherPreset() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let clean = try #require(f.presets.preset(named: "Clean"))
        let model = f.designer(f.design(name: "Clean"))
        #expect(!model.canSaveDesign)
        #expect(model.designValidationMessage == "A preset with this name already exists.")
        #expect(throws: PresetDesignError.duplicateName) { try model.saveDesignedPreset() }
        #expect(f.presets.preset(named: "Clean") == clean)

        model.designName = "   "
        #expect(!model.canSaveDesign && model.designValidationMessage == nil)
        #expect(throws: PresetDesignError.emptyName) { try model.saveDesignedPreset() }

        model.designName = "  Mine \n"
        #expect(model.canSaveDesign && model.designValidationMessage == nil)
        model.settings.padding = 21
        let saved = try model.saveDesignedPreset()
        #expect(saved.name == "Mine" && saved.settings == model.settings)
        #expect(!Preset.builtIn.contains { $0.id == saved.id })
        #expect(f.presets.presets.count == Preset.builtIn.count + 1)
        #expect(model.presets.contains(saved))
        #expect(PresetStore(url: f.presets.url).preset(named: "Mine") == saved)
        #expect(f.presets.defaultPresetID == Preset.builtIn[0].id && f.preferences.defaultPresetName == nil)
    }

    @Test func editingKeepsIDRenamesAndFollowsDefaultPresetName() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.defaultPresetName = "Clean"
        let clean = try #require(f.presets.preset(named: "Clean"))
        let model = f.designer(f.design(name: clean.name, editing: clean.id, settings: clean.settings))
        #expect(model.designTitle == "Edit Preset “Clean”")
        #expect(model.designIsDefault && model.designMakeDefault)
        #expect(model.canSaveDesign)

        model.designMakeDefault = false
        model.designName = "Crisp"
        model.settings.padding = 90
        let saved = try model.saveDesignedPreset()
        #expect(saved.id == clean.id && saved.name == "Crisp" && saved.settings.padding == 90)
        #expect(f.presets.presets.count == Preset.builtIn.count && f.presets.preset(named: "Clean") == nil)
        #expect(f.preferences.defaultPresetName == "Crisp")
        #expect(f.presets.defaultPresetID == Preset.builtIn[0].id)
        #expect(PresetStore(url: f.presets.url).presets.first { $0.id == clean.id } == saved)
    }

    @Test func editingANonDefaultPresetLeavesDefaultsAlone() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let social = try #require(f.presets.preset(named: "Social 16:9"))
        let model = f.designer(f.design(name: social.name, editing: social.id, settings: social.settings))
        #expect(!model.designIsDefault && !model.designMakeDefault)
        model.designName = "Default"
        #expect(model.designValidationMessage == "A preset with this name already exists.")
        model.designName = "Social"
        let saved = try model.saveDesignedPreset()
        #expect(saved.id == social.id && saved.name == "Social")
        #expect(f.presets.defaultPresetID == Preset.builtIn[0].id && f.preferences.defaultPresetName == nil)
    }

    @Test func editingADeletedPresetCreatesANewOne() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let transparent = try #require(f.presets.preset(named: "Transparent"))
        let model = f.designer(f.design(name: transparent.name, editing: transparent.id, settings: transparent.settings))
        f.presets.delete(id: transparent.id)
        #expect(model.designEditingPreset == nil && model.designTitle == "New Preset")
        #expect(model.canSaveDesign)
        let saved = try model.saveDesignedPreset()
        #expect(saved.id != transparent.id && saved.name == "Transparent")
        #expect(f.presets.presets.count == Preset.builtIn.count)
    }

    @Test func makeDefaultSetsStoreDefaultAndPreferenceName() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.designer(f.design(name: "Hero"))
        model.designMakeDefault = true
        let saved = try model.saveDesignedPreset()
        #expect(f.presets.defaultPresetID == saved.id && f.preferences.defaultPresetName == "Hero")
        #expect(PresetStore(url: f.presets.url).defaultPresetID == saved.id)
        #expect(EditorHeadless.initialSettings(preferences: f.preferences, presetStore: f.presets).padding == designLook.padding)
    }

    @Test func failedSaveThrowsAndLeavesStoreAndPreferencesUnchanged() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let store = try f.unwritableStore()
        f.preferences.defaultPresetName = "Clean"
        let before = store.presets, defaultID = store.defaultPresetID
        let clean = try #require(store.preset(named: "Clean"))

        let editor = f.designer(f.design(name: "Renamed", editing: clean.id), store: store)
        #expect(throws: (any Error).self) { try editor.saveDesignedPreset() }
        let creator = f.designer(f.design(name: "Brand New"), store: store)
        creator.designMakeDefault = true
        #expect(throws: (any Error).self) { try creator.saveDesignedPreset() }

        #expect(store.presets == before && store.defaultPresetID == defaultID)
        #expect(f.preferences.defaultPresetName == "Clean")
        #expect(creator.canSaveDesign && editor.canSaveDesign)
    }

    @Test func controllerSavesReportsPresetThenCloses() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        _ = NSApplication.shared
        let controller = EditorWindowController(design: f.design(name: "Shortcut"), preferences: f.preferences, presetStore: f.presets)
        defer { controller.window?.close() }
        #expect(controller.window?.title == "Glint — New Preset")
        var events: [String] = []
        var saved: Preset?
        controller.onPresetSaved = { saved = $0; events.append("saved") }
        controller.onClose = { events.append("closed") }

        #expect(controller.handleShortcut(designerKey("s", modifiers: .command)))
        #expect(events == ["saved", "closed"])
        #expect(saved?.name == "Shortcut" && f.presets.preset(named: "Shortcut") == saved)
        controller.savePresetAndClose()
        #expect(events == ["saved", "closed"] && f.presets.presets.count == Preset.builtIn.count + 1)
    }

    @Test func controllerReturnSavesAndEscapeCancels() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let clean = try #require(f.presets.preset(named: "Clean"))
        let editor = f.designController(f.design(name: "Clean", editing: clean.id))
        defer { editor.window?.close() }
        #expect(editor.window?.title == "Glint — Edit Preset “Clean”")
        var saves = 0
        editor.onPresetSaved = { _ in saves += 1 }
        #expect(editor.handleShortcut(designerKey("\r", keyCode: 36)))
        #expect(saves == 1)

        let cancelled = f.designController(f.design(name: "Discard me"))
        var closes = 0
        cancelled.onPresetSaved = { _ in saves += 1 }
        cancelled.onClose = { closes += 1 }
        #expect(cancelled.handleShortcut(designerKey("\u{1b}", keyCode: 53)))
        #expect(closes == 1 && saves == 1 && f.presets.preset(named: "Discard me") == nil)
    }

    @Test func controllerRefusesInvalidNamesAndKeepsWindowOpen() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        var beeps = 0
        services.beep = { beeps += 1 }
        let controller = f.designController(f.design(name: "Clean"), services: services)
        defer { controller.window?.close() }
        var saves = 0, closes = 0
        controller.onPresetSaved = { _ in saves += 1 }
        controller.onClose = { closes += 1 }

        controller.actions.savePreset()
        controller.model.designName = " "
        #expect(controller.handleShortcut(designerKey("s", modifiers: .command)))
        #expect(saves == 0 && closes == 0 && beeps == 2)
    }

    @Test func designerHasNoAnnotationToolsOrExports() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        var copies = 0, writes = 0
        services.copy = { _ in copies += 1; return true }
        services.write = { _, url, _, _, _ in writes += 1; return url }
        let controller = f.designController(f.design(), services: services)
        defer { controller.window?.close() }
        var exports = 0
        controller.onExported = { _ in exports += 1 }

        for key in ["1", "2", "3", "4", "v", "p", "h", "c"] {
            #expect(!controller.handleShortcut(designerKey(key)))
        }
        for key in ["c", "d", "a", "]", "["] {
            #expect(!controller.handleShortcut(designerKey(key, modifiers: .command)))
        }
        #expect(controller.model.tool == .select)
        #expect(!controller.copyToClipboard())
        controller.saveOutput()
        #expect(controller.prepareDragFile() == nil)
        #expect(copies == 0 && writes == 0 && exports == 0)
    }

    @Test func controllerShowsSaveFailureAndStaysOpen() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var services = EditorExportServices()
        var beeps = 0
        services.beep = { beeps += 1 }
        let controller = f.designController(f.design(name: "Doomed"), store: try f.unwritableStore(), services: services)
        defer { controller.window?.close() }
        var saves = 0, closes = 0
        controller.onPresetSaved = { _ in saves += 1 }
        controller.onClose = { closes += 1 }
        controller.savePresetAndClose()
        #expect(saves == 0 && closes == 0 && beeps == 1)
        #expect(controller.model.statusMessage?.hasPrefix("Couldn't save the preset:") == true)
    }
}
