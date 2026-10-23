import AppKit
import Testing
@testable import GlintCore
@testable import GlintEditor

private final class CallCounter: @unchecked Sendable { var count = 0 }

private let redaction = Annotation(kind: .redact(CGRect(x: 0, y: 0, width: 50, height: 40)),
                                   style: AnnotationStyle(color: .black))

/// Runs the real compositor but with an annotation baker that always fails.
private let failingBakeRenderer: EditorModel.Renderer = { image, settings, annotations, scale, background, wallpaper in
    try Compositor.renderDetailed(image: image, settings: settings, annotations: annotations, backingScale: scale,
                                  backgroundImage: background, wallpaper: wallpaper, bake: { _, _, _, _ in nil })
}

/// A look a normal capture remembers; nothing like the flat one a reopened image starts from.
private let rememberedLook = RenderSettings(padding: 40, cornerRadius: 12, shadow: ShadowSettings(),
                                            background: .solid(.black), autoBalance: true)

/// Looks like a finished screenshot: opaque, translucent and fully transparent pixels in an irregular pattern.
private func finishedImage(width: Int = 64, height: Int = 40) throws -> CGImage {
    let bitmap = try #require(GlintBitmap.makeContext(width: width, height: height))
    let bytes = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let alpha = [255, 255, 0, 128, 37, 255][(x * 7 + y * 3) % 6]
            let offset = y * bitmap.bytesPerRow + x * 4
            bytes[offset] = UInt8((x * 4 % 256) * alpha / 255)
            bytes[offset + 1] = UInt8((y * 6 % 256) * alpha / 255)
            bytes[offset + 2] = UInt8(((x + y) * 3 % 256) * alpha / 255)
            bytes[offset + 3] = UInt8(alpha)
        }
    }
    return try #require(bitmap.makeImage())
}

private func expectSamePixels(_ actual: CGImage, _ expected: CGImage, sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(actual.width == expected.width && actual.height == expected.height, sourceLocation: sourceLocation)
    let a = try #require(PixelBuffer(actual), sourceLocation: sourceLocation)
    let e = try #require(PixelBuffer(expected), sourceLocation: sourceLocation)
    let firstDifference = zip(a.data, e.data).enumerated().first { $0.element.0 != $0.element.1 }?.offset
    #expect(firstDifference == nil, "First differing byte: \(firstDifference ?? -1)", sourceLocation: sourceLocation)
}

@MainActor
private extension EditorFixture {
    /// A context for an image that is already a finished output, such as a reopened last image.
    func composed(_ image: CGImage? = nil, scale: CGFloat = 2, source: String? = nil) -> EditorContext {
        EditorContext(image: image ?? context.image, backingScale: scale, rawURL: nil, source: source, isComposed: true)
    }

    func composedController(_ context: EditorContext,
                            services: EditorExportServices = EditorExportServices()) -> EditorWindowController {
        _ = NSApplication.shared
        return EditorWindowController(context: context, preferences: preferences, presetStore: presets, exportServices: services)
    }

    /// Makes the preferences hold a look that a normal capture starts from.
    func rememberLook(_ look: RenderSettings = rememberedLook) {
        preferences.rememberSettings = true
        preferences.lastRenderSettings = look
        preferences.autoBalance = look.autoBalance
    }
}

@Suite("Reopened image")
@MainActor
struct ReopenedImageTests {
    @Test func contextsAreOnlyComposedWhenMarked() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let plain = EditorContext(image: f.context.image, backingScale: 2, rawURL: nil, source: "area")
        #expect(!plain.isComposed && !f.context.isComposed)
        #expect(f.composed().isComposed)
        #expect(!f.model().isComposed)
        #expect(f.model().settings.padding == 0)
    }

    @Test func sessionStartsFlatWhateverLookIsRemembered() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.rememberLook()
        let preset = f.presets.add(name: "House style", settings: RenderSettings(padding: 99))
        f.presets.setDefault(id: preset.id)
        f.preferences.defaultPresetName = preset.name

        let model = EditorModel(context: f.composed(), preferences: f.preferences, presetStore: f.presets)
        #expect(model.isComposed && model.isEditable && !model.isDesigningPreset)
        #expect(model.settings == .passThrough)
        let s = model.settings
        #expect(s.padding == 0 && s.inset == 0 && s.insetColor == nil && s.cornerRadius == 0)
        #expect(!s.shadow.enabled && s.shadow.resolvedLayers.isEmpty)
        #expect(s.background == .transparent && !s.usesDesktopWallpaper)
        #expect(s.aspectRatio == .auto && !s.border.enabled && s.windowFrame.style == .none)
        #expect(s.tilt.isFlat && s.rotation == .none && !s.flipHorizontal && !s.flipVertical)
        #expect(!s.watermark.enabled && !s.autoBalance && s.outputScale == 1)

        // The same preferences still style a normal capture.
        let capture = f.model()
        #expect(!capture.isComposed && capture.settings == rememberedLook)
    }

    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func renderingReproducesEveryPixel(scale: CGFloat) throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.rememberLook()
        let image = try finishedImage()
        let model = EditorModel(context: f.composed(image, scale: scale), preferences: f.preferences, presetStore: f.presets)

        let rendered = try model.renderFinal()
        try expectSamePixels(rendered, image)
        let encoded = try Exporter.data(for: rendered, format: .plainPNG, scale: .original, backingScale: scale)
        try expectSamePixels(try #require(GlintImageIO.load(data: encoded)), image)

        // The same preferences do frame a normal capture of that image.
        let capture = EditorModel(context: EditorContext(image: image, backingScale: scale, rawURL: nil, source: nil),
                                  preferences: f.preferences, presetStore: f.presets)
        #expect(try capture.renderFinal().width > image.width)
    }

    @Test func previewShowsTheImageUnframed() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.rememberLook()
        let image = try finishedImage()
        let model = EditorModel(context: f.composed(image), preferences: f.preferences, presetStore: f.presets)
        for _ in 0..<200 where model.preview == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let preview = try #require(model.preview)
        #expect(preview.layout.canvasSize == image.pixelSize)
        #expect(preview.layout.contentRect == CGRect(origin: .zero, size: image.pixelSize))
        try expectSamePixels(preview.image, image)
    }

    @Test func lookChangesAreNeverRemembered() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.rememberLook()
        let storedLook = f.preferences.defaults.data(forKey: AppPreferences.Key.lastRenderSettings)
        #expect(storedLook != nil && f.preferences.autoBalance)

        let model = EditorModel(context: f.composed(), preferences: f.preferences, presetStore: f.presets)
        model.settings.padding = 42
        model.settings.autoBalance = true
        model.settings.autoBalance = false
        model.chooseBackground(.solid(.white))
        model.rotate(clockwise: true)
        model.applyPreset(try #require(f.presets.preset(named: "Clean")))
        model.settings.cornerRadius = 7
        #expect(model.settings != .passThrough)

        #expect(f.preferences.defaults.data(forKey: AppPreferences.Key.lastRenderSettings) == storedLook)
        #expect(f.preferences.lastRenderSettings == rememberedLook)
        #expect(f.preferences.autoBalance)
        #expect(f.model().settings == rememberedLook)

        // A normal capture session still remembers its look.
        let capture = f.model()
        capture.settings.padding = 42
        capture.settings.autoBalance = false
        #expect(f.preferences.lastRenderSettings?.padding == 42)
        #expect(!f.preferences.autoBalance)
    }

    @Test func automaticRedactionIsSkippedButTheCommandStillWorks() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 20, width: 80, height: 40))]
        let reopenedScans = CallCounter()
        let reopened = EditorModel(context: f.composed(), preferences: f.preferences, presetStore: f.presets,
                                   recognizeText: { _ in reopenedScans.count += 1; return lines })
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(reopenedScans.count == 0 && reopened.annotations.isEmpty && reopened.lastRedactSummary == nil)

        // The same preference still redacts a new capture on its own.
        let captureScans = CallCounter()
        let capture = EditorModel(context: f.context, preferences: f.preferences, presetStore: f.presets,
                                  recognizeText: { _ in captureScans.count += 1; return lines })
        for _ in 0..<200 where capture.annotations.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(captureScans.count == 1 && capture.annotations.count == 1)

        await reopened.runAutoRedact()
        #expect(reopenedScans.count == 1 && reopened.annotations.count == 1)
    }

    @Test func annotationsStillBurnInAndFailClosed() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.closeAfterCopy = false
        f.rememberLook()
        var services = EditorExportServices()
        var copies: [CGImage] = []
        services.copy = { copies.append($0); return true }
        services.dragDirectory = f.directory.appendingPathComponent("Drag")
        services.beep = {}
        let controller = f.composedController(f.composed(), services: services)
        defer { controller.window?.close() }
        var shared: [(image: CGImage, kind: EditorShareKind, scale: CGFloat)] = []
        controller.onImageShared = { shared.append(($0, $1, $2)) }
        controller.model.updateLive([redaction])

        #expect(controller.copyToClipboard())
        let copied = try #require(shared.first)
        #expect(shared.count == 1 && copied.kind == .copied && copied.scale == 2 && copied.image === copies[0])
        #expect(copied.image.width == 100 && copied.image.height == 80)
        let pixels = try #require(PixelBuffer(copied.image))
        #expect(pixels.pixel(0, 0) == (0, 0, 0, 255) && pixels.pixel(49, 39) == (0, 0, 0, 255))
        #expect(pixels.pixel(50, 39) == (255, 255, 255, 255) && pixels.pixel(49, 40) == (255, 255, 255, 255))
        #expect(pixels.pixel(75, 60) == (255, 255, 255, 255))

        controller.model.renderer = failingBakeRenderer
        #expect(!controller.copyToClipboard())
        #expect(controller.prepareDragFile() == nil)
        controller.saveOutput()
        #expect(shared.count == 1 && copies.count == 1)
        #expect(controller.model.statusMessage == "Save failed: \(RenderError.annotationsNotApplied.localizedDescription)")
        for directory in [services.dragDirectory, f.preferences.saveDirectory] {
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty)
        }
    }

    @Test func windowTitleIdentifiesTheReopenedImage() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        for source in [nil, "file", "area"] as [String?] {
            let controller = f.composedController(f.composed(source: source))
            #expect(controller.window?.title == "Glint — last image")
            controller.window?.close()
        }

        let capture = f.controller(services: EditorExportServices())
        #expect(capture.window?.title == "Glint — test")
        capture.window?.close()
        let anonymous = EditorWindowController(
            context: EditorContext(image: f.context.image, backingScale: 2, rawURL: nil, source: nil),
            preferences: f.preferences, presetStore: f.presets)
        #expect(anonymous.window?.title == "Glint")
        anonymous.window?.close()
    }

    @Test func headlessRenderLeavesTheImageAlone() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.rememberLook()
        f.preferences.autoRedact = true
        let image = try finishedImage()
        let lines = [RecognizedLine(text: "test@example.com", box: CGRect(x: 4, y: 4, width: 40, height: 20))]
        let scans = CallCounter()

        let flat = try EditorHeadless.render(context: f.composed(image), preferences: f.preferences,
                                             recognizeText: { _ in scans.count += 1; return lines })
        try expectSamePixels(flat, image)
        #expect(scans.count == 0)

        let styled = try EditorHeadless.render(context: EditorContext(image: image, backingScale: 2, rawURL: nil, source: nil),
                                               preferences: f.preferences,
                                               recognizeText: { _ in scans.count += 1; return lines })
        #expect(styled.width > image.width && scans.count == 1)
    }
}
