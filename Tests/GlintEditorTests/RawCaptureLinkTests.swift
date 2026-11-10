import Combine
import CoreGraphics
import Foundation
@testable import GlintCore
import Testing
@testable import GlintEditor

@Suite("Raw capture link")
@MainActor
struct RawCaptureLinkTests {
    private func rawFile(_ f: EditorFixture) -> URL { f.directory.appendingPathComponent("Raw/Glint-test.png") }

    @Test func anEditorOpenedBeforeTheRawFileExistsHasNoRawFileUntilItIsSaved() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        #expect(model.rawURL == nil)
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        model.rawFileSaved(rawFile(f))
        #expect(model.rawURL == rawFile(f))
        #expect(changes >= 1)
    }

    @Test func anEditorOpenedWithAnExistingRawFileKeepsIt() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let context = EditorContext(image: f.context.image, backingScale: 2, rawURL: rawFile(f), source: "test")
        let model = EditorModel(context: context, preferences: f.preferences, presetStore: f.presets)
        #expect(model.rawURL == rawFile(f))
    }

    @Test func theWindowPassesTheSavedRawFileToItsModel() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let controller = f.controller(services: EditorExportServices())
        #expect(controller.model.rawURL == nil)
        controller.rawFileSaved(rawFile(f))
        #expect(controller.model.rawURL == rawFile(f))
    }
}
