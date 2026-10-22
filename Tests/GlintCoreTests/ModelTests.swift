import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

@Suite("Models")
struct ModelTests {
    @Test func catalog() {
        #expect(BackgroundCatalog.all.count >= 24)
        let gradients = BackgroundCatalog.all.filter { if case .linear = $0.style { return true } else { return false } }
        #expect(gradients.count >= 17)
        #expect(Set(BackgroundCatalog.all.map(\.id)).count == BackgroundCatalog.all.count)
        #expect(BackgroundCatalog.preset(id: BackgroundCatalog.defaultID) != nil)
    }

    @Test func colourHex() {
        #expect(RGBAColor(hex: "#FB00AD")?.hexString == "#FB00AD")
        #expect(RGBAColor(hex: "fff")?.hexString == "#FFFFFF")
        #expect(RGBAColor(hex: "#11223344")?.hexString == "#11223344")
        #expect(RGBAColor(hex: "zzz") == nil)
        let c = RGBAColor(hex: "#40A5D2")!
        #expect(RGBAColor(c.cgColor).hexString == "#40A5D2")
    }

    @Test func aspectRatios() {
        #expect(AspectRatioPreset.auto.ratio == nil)
        #expect(AspectRatioPreset.parse("4:3")?.ratio == 4.0 / 3)
        #expect(AspectRatioPreset.parse("1200x630") == .custom(width: 1200, height: 630))
        #expect(AspectRatioPreset.parse("garbage") == nil)
        #expect(AspectRatioPreset.parse("16:9")?.ratio == AspectRatioPreset.r16x9.ratio)
        #expect(AspectRatioPreset.openGraph.recommendedPixelSize == CGSize(width: 1200, height: 630))
        for p in AspectRatioPreset.allBuiltIn where p != .auto { #expect(p.ratio != nil) }
    }

    @Test func shadowScalesWithStrength() {
        let weak = ShadowSettings(strength: 20).resolvedLayers, strong = ShadowSettings(strength: 80).resolvedLayers
        #expect(weak.count == 2 && strong.count == 2)
        #expect(strong[1].offsetY > weak[1].offsetY && strong[0].opacity > weak[0].opacity)
        #expect(ShadowSettings(strength: 0).resolvedLayers.isEmpty)
        #expect(ShadowSettings.none.resolvedLayers.isEmpty)
    }

    @Test func tiltUIMapping() {
        #expect(Tilt(uiX: 15, uiY: 15).isFlat)
        #expect(Tilt(uiX: 30, uiY: 0) == Tilt(x: 15, y: -15))
    }

    @Test func renderSettingsRoundTrip() throws {
        var s = RenderSettings()
        s.background = .mesh(MeshGradient(base: .black, points: [MeshPoint(x: 0.1, y: 0.2, radius: 0.5, color: .red)]))
        s.aspectRatio = .custom(width: 3, height: 2)
        s.watermark = WatermarkSettings(enabled: true, text: "hi")
        s.windowFrame = WindowFrameSettings(style: .browser, dark: true, title: "x")
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(RenderSettings.self, from: data) == s)
    }

    @Test func presetStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("presets.json")
        let store = PresetStore(url: url)
        #expect(store.presets.count == Preset.builtIn.count)
        var custom = RenderSettings(); custom.padding = 77; custom.cornerRadius = 5
        let p = store.add(name: "Mine", settings: custom)
        store.setDefault(id: p.id)
        try store.save()

        let reloaded = PresetStore(url: url)
        #expect(reloaded.presets == store.presets)
        #expect(reloaded.defaultPreset?.name == "Mine")
        #expect(reloaded.preset(named: "Mine")?.settings.padding == 77)

        let exportURL = dir.appendingPathComponent("export.json")
        try reloaded.exportPresets(to: exportURL, ids: [p.id])
        let other = PresetStore(url: dir.appendingPathComponent("other.json"))
        let before = other.presets.count
        #expect(try other.importPresets(from: exportURL) == 1)
        #expect(other.presets.count == before + 1)
        #expect(try other.importPresets(from: exportURL) == 1)
        #expect(other.presets.map(\.name).contains("Mine 2"))

        reloaded.delete(id: p.id)
        #expect(reloaded.preset(named: "Mine") == nil)
        #expect(reloaded.defaultPresetID != p.id)
    }

    @Test func presetDefaultURL() {
        #expect(PresetStore.defaultURL.path.hasSuffix("Application Support/Glint/presets.json"))
    }

    @Test func presetUniqueName() {
        let store = PresetStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-test-\(UUID().uuidString)/presets.json"))
        #expect(store.uniqueName("Fresh") == "Fresh")
        #expect(store.uniqueName("Clean") == "Clean 2")
        store.add(name: "Clean 2", settings: .default)
        #expect(store.uniqueName("Clean") == "Clean 3")
    }

    @Test func annotationCodableAndGeometry() throws {
        let a = Annotation(z: 3, kind: .arrow(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 30, y: 40)))
        let decoded = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(a))
        #expect(decoded == a)
        let moved = a.translated(by: CGSize(width: 10, height: 10))
        #expect(moved.kind == .arrow(from: CGPoint(x: 11, y: 12), to: CGPoint(x: 40, y: 50)))
        #expect(!a.isRedaction && !a.isObfuscation)
        let region = CGRect(x: 0, y: 0, width: 5, height: 5)
        for kind in [AnnotationKind.redact(region), .pixelate(region)] {
            let redaction = Annotation(kind: kind)
            #expect(redaction.isRedaction && !redaction.isObfuscation)
            #expect(try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(redaction)) == redaction)
        }
        let obfuscation = Annotation(kind: .blur(region))
        #expect(!obfuscation.isRedaction && obfuscation.isObfuscation)
        #expect(try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(obfuscation)) == obfuscation)
    }
}
