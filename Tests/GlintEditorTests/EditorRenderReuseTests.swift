import AppKit
import Combine
@testable import GlintCore
import Testing
@testable import GlintEditor

private let pureRed = RGBAColor(r: 1, g: 0, b: 0)
private let pureBlue = RGBAColor(r: 0, g: 0, b: 1)
private let framedLook = RenderSettings(padding: 20, inset: 0, cornerRadius: 0, shadow: .none,
                                        background: .solid(.black), autoBalance: false)
private let redaction = Annotation(kind: .redact(CGRect(x: 10, y: 10, width: 40, height: 30)),
                                   style: AnnotationStyle(color: .black))

@Suite("Editor render reuse")
@MainActor
struct EditorRenderReuseTests {
    private func writeImage(_ color: RGBAColor, to url: URL, modified: Date? = nil) throws {
        let bitmap = try #require(GlintBitmap.makeContext(width: 64, height: 48))
        bitmap.setFillColor(color.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        try Exporter.write(try #require(bitmap.makeImage()), to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func isRed(_ image: CGImage?) -> Bool {
        guard let image, let buffer = PixelBuffer(image) else { return false }
        let p = buffer.pixel(1, 1)
        return p == (255, 0, 0, 255)
    }

    private func isBlue(_ image: CGImage?) -> Bool {
        guard let image, let buffer = PixelBuffer(image) else { return false }
        let p = buffer.pixel(1, 1)
        return p == (0, 0, 255, 255)
    }

    @Test func aReplacedBackgroundFileShowsItsNewContent() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let file = f.directory.appendingPathComponent("background.png")
        try writeImage(pureRed, to: file)
        let model = f.model()
        var look = framedLook
        look.background = .image(path: file.path, fit: .fill)
        model.settings = look
        #expect(await eventually { isRed(model.preview?.image) })
        #expect(isRed(try model.renderFinal()))

        try writeImage(pureBlue, to: file, modified: Date().addingTimeInterval(120))
        model.settings.padding = 21
        #expect(await eventually { isBlue(model.preview?.image) })
        #expect(isBlue(try model.renderFinal()))
    }

    @Test func theFirstPreviewWaitsForTheWallpaperInsteadOfShowingTheFallback() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let file = f.directory.appendingPathComponent("wallpaper.png")
        try writeImage(pureRed, to: file)
        var look = framedLook
        look.usesDesktopWallpaper = true
        f.preferences.lastRenderSettings = look
        let model = EditorModel(context: f.context, preferences: f.preferences, presetStore: f.presets,
                                wallpaperURL: { file })
        var published: [CGImage] = []
        let sink = model.$preview.compactMap { $0?.image }.sink { published.append($0) }
        defer { sink.cancel() }
        #expect(await eventually { !published.isEmpty })
        #expect(published.allSatisfy { isRed($0) }, "no preview was composed with the black fallback")
        #expect(model.wallpaperProblem == nil)
    }

    @Test func anExportDecodesAPendingWallpaperInsteadOfFallingBack() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let file = f.directory.appendingPathComponent("wallpaper.png")
        try writeImage(pureRed, to: file)
        let model = EditorModel(context: f.context, preferences: f.preferences, presetStore: f.presets,
                                wallpaperURL: { file })
        var look = framedLook
        look.usesDesktopWallpaper = true
        model.settings = look
        // Nothing has run on the main actor since the toggle, so the off-main decode has not been delivered yet.
        let final = try model.renderFinal()
        #expect(isRed(final))
        #expect(await eventually {
            guard let preview = model.preview?.image else { return false }
            return PixelBuffer(preview)?.data == PixelBuffer(final)?.data
        })
    }

    @Test func aRenderTakenBeforeTheWallpaperLoadsDecodesItOffTheMainActor() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let file = f.directory.appendingPathComponent("wallpaper.png")
        try writeImage(pureRed, to: file)
        let model = EditorModel(context: f.context, preferences: f.preferences, presetStore: f.presets,
                                wallpaperURL: { file })
        var look = framedLook
        look.usesDesktopWallpaper = true
        model.settings = look
        // Nothing has run on the main actor since the toggle, so the wallpaper has not been delivered to the model yet.
        let render = model.finalRenderer()
        let final = try await Task.detached { try render() }.value
        #expect(isRed(final))
    }

    @Test func aWallpaperSwitchedOffBeforeItLoadsIsIgnored() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = EditorModel(context: f.context, preferences: f.preferences, presetStore: f.presets,
                                wallpaperURL: { nil })
        model.settings.usesDesktopWallpaper = true
        model.settings.usesDesktopWallpaper = false
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(model.wallpaperProblem == nil)

        model.settings.usesDesktopWallpaper = true
        #expect(await eventually { model.wallpaperProblem == DesktopWallpaperError.unavailable.localizedDescription })
    }

    @Test func previewsAndExportsShareOneRenderCache() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = f.model()
        model.undoManager.beginUndoGrouping()
        model.setAnnotations([redaction], actionName: "Add")
        model.undoManager.endUndoGrouping()
        model.settings = framedLook
        #expect(await eventually { model.preview != nil && model.renderCache.retainedBytes > 0 })
        let final = try model.renderFinal()
        let plain = try Compositor.render(image: f.context.image, settings: model.settings,
                                          annotations: model.annotations, backingScale: 2)
        try expectSamePixels(final, plain)
    }
}
