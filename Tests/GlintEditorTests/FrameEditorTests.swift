import CoreGraphics
import Testing
@testable import GlintCore
@testable import GlintEditor

@Suite("Editor frames")
@MainActor
struct FrameEditorTests {
    /// Frames with side or bottom chrome move the screenshot inside the card. Annotations must still land on
    /// the screenshot, and the preview must match the export.
    @Test(arguments: [WindowFrameKind.handheld, .phone, .filmStrip, .retro, .macOS])
    func annotationsLandOnTheScreenshotInPreviewAndExport(kind: WindowFrameKind) async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let bitmap = try #require(GlintBitmap.makeContext(width: 400, height: 300))
        bitmap.setFillColor(RGBAColor.white.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let context = EditorContext(image: try #require(bitmap.makeImage()), backingScale: 2, rawURL: nil, source: "test")
        let model = EditorModel(context: context, preferences: f.preferences, presetStore: f.presets)
        model.undoManager.groupsByEvent = false
        var s = model.settings
        s.autoBalance = false
        s.inset = 0
        s.windowFrame = WindowFrameSettings(style: kind, title: "Glint", screenEffects: false)
        model.settings = s
        // Both probes are more than 24 pt from the screenshot edges, where frames may not draw.
        let box = CGRect(x: 60, y: 60, width: 80, height: 60)
        model.updateLive([Annotation(kind: .redact(box), style: AnnotationStyle(color: .black))])

        let expected = Compositor.layout(contentSize: model.image.pixelSize, insetApplied: false, settings: s,
                                         backingScale: model.backingScale)
        let insets = kind.metrics.insets
        let k = model.backingScale
        #expect(expected.contentRect.origin == CGPoint(x: (CGFloat(insets.left) * k).rounded(),
                                                       y: (CGFloat(insets.top) * k).rounded()))
        for _ in 0..<300 where model.preview?.layout != expected { try await Task.sleep(nanoseconds: 10_000_000) }
        let preview = try #require(model.preview)
        #expect(preview.layout == expected)
        #expect(preview.mapper.contentRect == expected.contentRect)

        let final = try model.renderFinal()
        #expect(CGSize(width: final.width, height: final.height) == expected.canvasSize)
        let previewPixels = try #require(PixelBuffer(preview.image))
        let finalPixels = try #require(PixelBuffer(final))
        #expect(previewPixels.data == finalPixels.data, "\(kind) preview differs from the export")

        let inside = preview.mapper.toCanvas(CGPoint(x: box.midX, y: box.midY))
        let outside = preview.mapper.toCanvas(CGPoint(x: 300, y: 220))
        for pixels in [previewPixels, finalPixels] {
            #expect(pixels.pixel(Int(inside.x), Int(inside.y)) == (0, 0, 0, 255))
            #expect(pixels.pixel(Int(outside.x), Int(outside.y)) == (255, 255, 255, 255))
        }
    }
}
