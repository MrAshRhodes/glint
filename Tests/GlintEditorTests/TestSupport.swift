import AppKit
import GlintCore
import Testing
@testable import GlintEditor

@MainActor
final class EditorFixture {
    let suite = "glint.editor.tests.\(UUID().uuidString)"
    let directory: URL
    let preferences: AppPreferences
    let presets: PresetStore
    let context: EditorContext

    init() throws {
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/TestFixtures/\(UUID().uuidString)")
        preferences = AppPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        preferences.autoRedact = false
        preferences.autoBalance = false
        preferences.saveDirectory = directory.appendingPathComponent("Manual")
        preferences.historyDirectory = directory.appendingPathComponent("History")
        preferences.lastRenderSettings = RenderSettings(padding: 0, cornerRadius: 0, shadow: .none, background: .transparent)
        presets = PresetStore(url: directory.appendingPathComponent("presets.json"))
        let bitmap = try #require(GlintBitmap.makeContext(width: 100, height: 80))
        bitmap.setFillColor(RGBAColor.white.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        context = EditorContext(image: try #require(bitmap.makeImage()), backingScale: 2, rawURL: nil, source: "test")
    }

    func model() -> EditorModel {
        let model = EditorModel(context: context, preferences: preferences, presetStore: presets)
        model.undoManager.groupsByEvent = false
        return model
    }

    func controller(services: EditorExportServices) -> EditorWindowController {
        _ = NSApplication.shared
        return EditorWindowController(context: context, preferences: preferences, presetStore: presets, exportServices: services)
    }

    func cleanUp() {
        preferences.defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
