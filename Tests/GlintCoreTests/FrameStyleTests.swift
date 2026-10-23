import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

@Suite("Frame styles")
struct FrameStyleTests {
    /// Styles added after None, macOS and Browser.
    static let newKinds: [WindowFrameKind] = [.ide, .terminal, .phone, .retro, .arcade, .handheld, .comic, .filmStrip, .photo]
    static let scales: [Double] = [1, 2]

    /// Transparent background, no padding, inset, shadow or corner radius: anything painted on the card is chrome
    /// or screenshot.
    func settings(_ frame: WindowFrameSettings, padding: Double = 0) -> RenderSettings {
        RenderSettings(padding: padding, inset: 0, cornerRadius: 0, shadow: .none, background: .transparent,
                       windowFrame: frame, autoBalance: false)
    }

    func px(_ points: Double, _ k: CGFloat) -> CGFloat { (CGFloat(points) * k).rounded() }

    /// Deterministic noisy 300×200 screenshot, so any shift or overpaint is visible.
    static let screenshot = TestImages.framed(width: 300, height: 200, margins: EdgeMargins(top: 0, left: 0, bottom: 0, right: 0))

    // MARK: Model

    @Test func rawValuesAreStable() throws {
        #expect(WindowFrameKind.allCases.map(\.rawValue) == [
            "none", "macOS", "browser", "ide", "terminal", "phone",
            "retro", "arcade", "handheld", "comic", "filmStrip", "photo",
        ])
        #expect(WindowFrameKind.allCases.filter { ![.none, .macOS, .browser].contains($0) } == Self.newKinds)
        for kind in WindowFrameKind.allCases {
            let data = try JSONEncoder().encode(kind)
            #expect(String(decoding: data, as: UTF8.self) == "\"\(kind.rawValue)\"")
            #expect(try JSONDecoder().decode(WindowFrameKind.self, from: data) == kind)
        }
    }

    @Test func everyFrameHasMenuMetadata() {
        #expect(WindowFrameKind.none.category == nil)
        for kind in WindowFrameKind.allCases where kind != .none {
            #expect(kind.category != nil, "\(kind) has no category")
            #expect(!kind.displayName.isEmpty)
            #expect(!kind.titlePlaceholder.isEmpty)
        }
        let names = WindowFrameKind.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
        #expect(WindowFrameCategory.allCases.map(\.displayName) == ["Windows", "Devices", "Playful"])
        // The inspector menu lists None, then every category's styles; each style appears exactly once.
        let menu = WindowFrameCategory.allCases.flatMap { c in WindowFrameKind.allCases.filter { $0.category == c } }
        #expect(menu.count == WindowFrameKind.allCases.count - 1)
        #expect(Set(menu) == Set(WindowFrameKind.allCases.filter { $0 != .none }))
        for category in WindowFrameCategory.allCases {
            #expect(WindowFrameKind.allCases.contains { $0.category == category }, "\(category) is empty")
        }
        #expect(WindowFrameKind.macOS.category == .window && WindowFrameKind.browser.category == .window)
    }

    @Test func existingFramesKeepTheirMetrics() {
        #expect(WindowFrameKind.none.metrics == FrameMetrics())
        #expect(WindowFrameKind.macOS.metrics == FrameMetrics(insets: FrameInsets(top: 28)))
        #expect(WindowFrameKind.browser.metrics == FrameMetrics(insets: FrameInsets(top: 40)))
        #expect(WindowFrameSettings(style: .macOS).barHeight == 28)
        #expect(WindowFrameSettings(style: .browser).barHeight == 40)
        #expect(WindowFrameSettings().insets == .zero)
    }

    @Test func newFramesHaveChrome() {
        for kind in Self.newKinds {
            let i = kind.metrics.insets
            #expect(i.top >= 0 && i.left >= 0 && i.bottom >= 0 && i.right >= 0, "\(kind) has a negative inset")
            #expect(i.top + i.left + i.bottom + i.right > 0, "\(kind) adds no chrome")
            #expect(WindowFrameSettings(style: kind).insets == i)
            #expect(WindowFrameSettings(style: kind).barHeight == i.top)
        }
    }

    @Test func cornerRules() {
        #expect(FrameCornerRule.user.resolve(0) == 0)
        #expect(FrameCornerRule.user.resolve(20) == 20)
        #expect(FrameCornerRule.atLeast(18).resolve(4) == 18)
        #expect(FrameCornerRule.atLeast(18).resolve(30) == 30)
        #expect(FrameCornerRule.fixed(0).resolve(20) == 0)
        #expect(FrameCornerRule.fixed(12).resolve(0) == 12)
        #expect(FrameCornerRule.fixed(12).resolve(50) == 12)
        #expect(FrameMetrics().corner == .user)
        #expect(WindowFrameKind.macOS.metrics.corner == .user && WindowFrameKind.browser.metrics.corner == .user)
    }

    // MARK: Persistence

    @Test func legacyFrameJSONDecodesWithScreenEffectsOn() throws {
        let json = #"{"style":"macOS","dark":true,"title":"x"}"#
        let frame = try JSONDecoder().decode(WindowFrameSettings.self, from: Data(json.utf8))
        #expect(frame == WindowFrameSettings(style: .macOS, dark: true, title: "x"))
        #expect(frame.screenEffects)
    }

    @Test func screenEffectsAreOnlyStoredWhenOff() throws {
        func keys(_ frame: WindowFrameSettings) throws -> Set<String> {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as? [String: Any]
            return Set(try #require(object).keys)
        }
        #expect(try keys(WindowFrameSettings()) == ["style", "dark", "title"])
        #expect(try keys(WindowFrameSettings(style: .retro, dark: true, title: "t")) == ["style", "dark", "title"])
        #expect(try keys(WindowFrameSettings(style: .arcade, screenEffects: false)).count == 4)

        var off = WindowFrameSettings(style: .arcade, title: "P1", screenEffects: false)
        let decoded = try JSONDecoder().decode(WindowFrameSettings.self, from: JSONEncoder().encode(off))
        #expect(decoded == off && !decoded.screenEffects)
        off.screenEffects = true
        #expect(off == WindowFrameSettings(style: .arcade, title: "P1"))

        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RenderSettings.default)) as? [String: Any]
        let frame = try #require(defaults?["windowFrame"] as? [String: Any])
        #expect(Set(frame.keys) == ["style", "dark", "title"])
    }

    @Test func presetsRoundTripEveryFrame() throws {
        let presets = WindowFrameKind.allCases.enumerated().map { i, kind in
            var s = RenderSettings.default
            s.windowFrame = WindowFrameSettings(style: kind, dark: i.isMultiple(of: 2),
                                                title: i.isMultiple(of: 3) ? "" : "Glint — \(kind.displayName)",
                                                screenEffects: !i.isMultiple(of: 4))
            return Preset(name: kind.displayName, settings: s)
        }
        // Same format as `PresetStore.save()`.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(PresetFile(defaultPresetID: presets[3].id, presets: presets))
        let file = try JSONDecoder().decode(PresetFile.self, from: data)
        #expect(file.presets == presets)
        #expect(file.presets.map(\.settings.windowFrame.style) == WindowFrameKind.allCases)
        #expect(file.presets.map(\.settings.windowFrame.screenEffects) == presets.map(\.settings.windowFrame.screenEffects))
        #expect(file.defaultPresetID == presets[3].id)
    }

    // MARK: Layout

    @Test(arguments: WindowFrameKind.allCases, FrameStyleTests.scales)
    func layoutAddsFrameInsets(kind: WindowFrameKind, scale: Double) {
        let k = CGFloat(scale)
        let i = kind.metrics.insets
        let top = px(i.top, k), left = px(i.left, k), bottom = px(i.bottom, k), right = px(i.right, k)
        let content = CGSize(width: 300, height: 200)
        let l = Compositor.layout(contentSize: content, insetApplied: false, settings: settings(WindowFrameSettings(style: kind)),
                                  backingScale: k)
        #expect(l.canvasSize == CGSize(width: 300 + left + right, height: 200 + top + bottom))
        #expect(l.cardRect == CGRect(origin: .zero, size: l.canvasSize))
        #expect(l.contentRect == CGRect(x: left, y: top, width: 300, height: 200))
        #expect(l.screenRect == l.contentRect)
        #expect(l.barHeight == top)
        #expect(l.factor == k)

        // With an inset band the screen grows by the band; chrome still surrounds it.
        var banded = settings(WindowFrameSettings(style: kind), padding: 10)
        banded.inset = 15
        let b = Compositor.layout(contentSize: content, insetApplied: true, settings: banded, backingScale: k)
        let pad = px(10, k), band = px(15, k)
        #expect(b.cardRect.size == CGSize(width: 300 + 2 * band + left + right, height: 200 + 2 * band + top + bottom))
        #expect(b.screenRect == b.contentRect.insetBy(dx: -band, dy: -band))
        #expect(b.screenRect.minX == b.cardRect.minX + left && b.screenRect.minY == b.cardRect.minY + top)
        #expect(b.cardRect.maxX - b.screenRect.maxX == right && b.cardRect.maxY - b.screenRect.maxY == bottom)
        #expect(b.canvasSize == CGSize(width: b.cardRect.width + 2 * pad, height: b.cardRect.height + 2 * pad))
    }

    @Test(arguments: FrameStyleTests.scales)
    func existingFrameLayoutsAreUnchanged(scale: Double) {
        let k = CGFloat(scale)
        let content = CGSize(width: 100, height: 50)
        func layout(_ kind: WindowFrameKind) -> RenderLayout {
            Compositor.layout(contentSize: content, insetApplied: false, settings: settings(WindowFrameSettings(style: kind)),
                              backingScale: k)
        }
        #expect(layout(.none).canvasSize == content)
        #expect(layout(.none).contentRect == CGRect(origin: .zero, size: content))
        #expect(layout(.macOS).canvasSize == CGSize(width: 100, height: 50 + 28 * k))
        #expect(layout(.macOS).contentRect == CGRect(x: 0, y: 28 * k, width: 100, height: 50))
        #expect(layout(.browser).canvasSize == CGSize(width: 100, height: 50 + 40 * k))
        #expect(layout(.browser).contentRect == CGRect(x: 0, y: 40 * k, width: 100, height: 50))
    }

    @Test func canvasBandsPartitionTheCard() throws {
        let ctx = try #require(GlintBitmap.makeContext(width: 4, height: 4))
        let card = CGRect(x: 10, y: 20, width: 400, height: 300)
        let screen = CGRect(x: 40, y: 60, width: 300, height: 200)
        let c = FrameCanvas(ctx: ctx, card: card, screen: screen, bar: card.maxY - screen.maxY, k: 1, radius: 0,
                            frame: WindowFrameSettings(style: .handheld))
        #expect(c.topBand == CGRect(x: 10, y: 260, width: 400, height: 60))
        #expect(c.bottomBand == CGRect(x: 10, y: 20, width: 400, height: 40))
        #expect(c.leftBand == CGRect(x: 10, y: 60, width: 30, height: 200))
        #expect(c.rightBand == CGRect(x: 340, y: 60, width: 70, height: 200))
        let area = [c.topBand, c.bottomBand, c.leftBand, c.rightBand, screen].map { $0.width * $0.height }.reduce(0, +)
        #expect(area == card.width * card.height)
    }

    // MARK: Rendering

    /// Frame, border and gradient background render identically every time. The drop shadow is left out: in busy
    /// parallel test runs CoreGraphics' shadow blur occasionally differs slightly outside the card, whatever the frame.
    @Test(arguments: WindowFrameKind.allCases)
    func renderingIsDeterministic(kind: WindowFrameKind) throws {
        for dark in [false, true] {
            var s = RenderSettings()
            s.shadow = .none
            s.windowFrame = WindowFrameSettings(style: kind, dark: dark, title: dark ? "Glint — notes.md" : "")
            s.border.enabled = true
            let a = try #require(PixelBuffer(Compositor.render(image: Self.screenshot, settings: s, backingScale: 2)))
            let b = try #require(PixelBuffer(Compositor.render(image: Self.screenshot, settings: s, backingScale: 2)))
            try #require(a.width == b.width && a.height == b.height)
            // Count differences rather than comparing the arrays, so a failure doesn't print megabytes of bytes.
            var differing = 0
            for y in 0..<a.height { for x in 0..<a.width where a.pixel(x, y) != b.pixel(x, y) { differing += 1 } }
            #expect(differing == 0, "\(kind) dark: \(dark) renders \(differing) pixels differently the second time")
        }
    }

    /// Everything more than 24 pt from the screen edges must be the untouched screenshot.
    @Test(arguments: WindowFrameKind.allCases, FrameStyleTests.scales)
    func screenshotCentreIsUntouched(kind: WindowFrameKind, scale: Double) throws {
        let k = CGFloat(scale)
        let source = try #require(PixelBuffer(Self.screenshot))
        for dark in [false, true] {
            let frame = WindowFrameSettings(style: kind, dark: dark, title: "Glint — notes.md", screenEffects: false)
            let r = try Compositor.renderDetailed(image: Self.screenshot, settings: settings(frame), backingScale: k)
            let out = try #require(PixelBuffer(r.image))
            let content = r.layout.contentRect
            let margin = Int((25 * k).rounded(.up))
            var mismatches = 0
            for y in margin..<(source.height - margin) {
                for x in margin..<(source.width - margin)
                where out.pixel(Int(content.minX) + x, Int(content.minY) + y) != source.pixel(x, y) {
                    mismatches += 1
                }
            }
            #expect(mismatches == 0, "\(kind) dark: \(dark) at \(scale)x changes \(mismatches) central screenshot pixels")
        }
    }

    /// Optional screen effects stay subtle enough to keep the screenshot legible.
    @Test(arguments: WindowFrameKind.allCases.filter { $0.metrics.supportsScreenEffects })
    func screenEffectsAreSubtle(kind: WindowFrameKind) throws {
        let source = try #require(PixelBuffer(Self.screenshot))
        let r = try Compositor.renderDetailed(image: Self.screenshot, settings: settings(WindowFrameSettings(style: kind)),
                                              backingScale: 2)
        let out = try #require(PixelBuffer(r.image))
        let content = r.layout.contentRect
        var worst = 0, translucent = 0
        for y in 50..<(source.height - 50) {
            for x in 50..<(source.width - 50) {
                let a = out.pixel(Int(content.minX) + x, Int(content.minY) + y), b = source.pixel(x, y)
                worst = max(worst, abs(Int(a.0) - Int(b.0)), abs(Int(a.1) - Int(b.1)), abs(Int(a.2) - Int(b.2)))
                if a.3 != 255 { translucent += 1 }
            }
        }
        #expect(worst <= 40, "\(kind) screen effects change a channel by \(worst)")
        #expect(translucent == 0)
    }

    /// Each chrome band of the new styles is painted (outside the rounded card corners).
    @Test(arguments: FrameStyleTests.newKinds, FrameStyleTests.scales)
    func chromeBandsArePainted(kind: WindowFrameKind, scale: Double) throws {
        let k = CGFloat(scale)
        for dark in [false, true] {
            let frame = WindowFrameSettings(style: kind, dark: dark, title: "Glint")
            let r = try Compositor.renderDetailed(image: Self.screenshot, settings: settings(frame), backingScale: k)
            let out = try #require(PixelBuffer(r.image))
            let card = r.layout.cardRect, screen = r.layout.screenRect
            let radius = min(CGFloat(kind.metrics.corner.resolve(0)) * k, min(card.width, card.height) / 2).rounded(.up)
            let bands: [(String, CGRect)] = [
                ("top", CGRect(x: card.minX + radius, y: card.minY, width: card.width - 2 * radius, height: screen.minY - card.minY)),
                ("bottom", CGRect(x: card.minX + radius, y: screen.maxY, width: card.width - 2 * radius, height: card.maxY - screen.maxY)),
                ("left", CGRect(x: card.minX, y: screen.minY, width: screen.minX - card.minX, height: screen.height)
                    .intersection(card.insetBy(dx: 0, dy: radius))),
                ("right", CGRect(x: screen.maxX, y: screen.minY, width: card.maxX - screen.maxX, height: screen.height)
                    .intersection(card.insetBy(dx: 0, dy: radius))),
            ]
            for (name, band) in bands where !band.isNull && band.width >= 1 && band.height >= 1 {
                var painted = 0, total = 0
                for y in Int(band.minY)..<Int(band.maxY) {
                    for x in Int(band.minX)..<Int(band.maxX) {
                        total += 1
                        if out.pixel(x, y).3 > 0 { painted += 1 }
                    }
                }
                #expect(painted * 4 >= total, "\(kind) dark: \(dark) at \(scale)x paints \(painted)/\(total) of its \(name) band")
            }
        }
    }

    @Test(arguments: WindowFrameKind.allCases)
    func tinyAndLargeScreenshotsRender(kind: WindowFrameKind) throws {
        let long = String(repeating: "A very long title that never fits ", count: 8)
        for (image, scale) in [(TestImages.solid(40, 20, .white), 1.0), (TestImages.solid(100, 50, .white), 2.0),
                               (TestImages.solid(1600, 1000, .white), 2.0)] {
            for title in ["", long] {
                let s = RenderSettings(windowFrame: WindowFrameSettings(style: kind, dark: title.isEmpty, title: title),
                                       autoBalance: false)
                let r = try Compositor.renderDetailed(image: image, settings: s, backingScale: CGFloat(scale))
                #expect(CGFloat(r.image.width) == r.layout.canvasSize.width)
                #expect(CGFloat(r.image.height) == r.layout.canvasSize.height)
            }
        }
    }
}
