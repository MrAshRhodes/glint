import AppKit
import Testing
@testable import GlintCapture

@Suite("Recording chrome")
struct RecordingChromeStyleTests {
    private func resolve(glass: Bool, motion: Bool = false, transparency: Bool = false, contrast: Bool = false)
        -> RecordingChromeStyle {
        RecordingChromeStyle.resolve(
            supportsLiquidGlass: glass,
            options: RecordingDisplayOptions(reduceMotion: motion, reduceTransparency: transparency,
                                             increaseContrast: contrast))
    }

    @Test func glassWhereTheSystemHasItAndAMaterialElsewhere() {
        let glass = resolve(glass: true)
        #expect(glass.surface == .liquidGlass && glass.borderWidth == 0 && !glass.strongBorder)
        #expect(glass.forcedAppearance == nil)

        let material = resolve(glass: false)
        #expect(material.surface == .material && material.borderWidth == 0.5 && !material.strongBorder)
    }

    @Test func theDarkMaterialKeepsItsContentInTheDarkAppearance() {
        #expect(resolve(glass: false).forcedAppearance == .vibrantDark)
        #expect(resolve(glass: true).forcedAppearance == nil)
        #expect(resolve(glass: true, transparency: true).forcedAppearance == nil)
    }

    @Test func reduceTransparencyReplacesGlassAndMaterialWithASolidSurface() {
        for glass in [true, false] {
            let style = resolve(glass: glass, transparency: true)
            #expect(style.surface == .opaque)
            #expect(style.borderWidth == 0.5)
        }
    }

    @Test func increaseContrastDrawsAFullStrengthEdgeOnEverySurface() {
        for (glass, transparency) in [(true, false), (false, false), (true, true), (false, true)] {
            let style = resolve(glass: glass, transparency: transparency, contrast: true)
            #expect(style.strongBorder && style.borderWidth == 1)
        }
        #expect(resolve(glass: true, contrast: true).surface == .liquidGlass)
        #expect(resolve(glass: false, contrast: true).surface == .material)
        #expect(resolve(glass: false, contrast: true).borderColor.alphaComponent > resolve(glass: false).borderColor.alphaComponent)
    }

    @Test func reduceMotionDoesNotChangeTheSurface() {
        #expect(resolve(glass: true, motion: true) == resolve(glass: true))
        #expect(resolve(glass: false, motion: true) == resolve(glass: false))
    }

    @Test func glassIsAvailableOnlyOnMacOS26OrLater() {
        var expected = false
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { expected = true }
        #endif
        #expect(RecordingChromeEnvironment.systemSupportsLiquidGlass == expected)
    }

    @Test func buttonsUseTheGlassBezelOnlyWhereGlassExists() {
        #expect(RecordingButtonStyle.bezelStyle(supportsLiquidGlass: false) == .rounded)
        var expected = NSButton.BezelStyle.rounded
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { expected = .glass }
        #endif
        #expect(RecordingButtonStyle.bezelStyle(supportsLiquidGlass: true) == expected)
    }

    @Test func tokensFollowGlintsBarAndTheEightPointGrid() {
        let tokens = RecordingChromeTokens.self
        #expect(tokens.barHeight == 44)
        #expect(tokens.barCornerRadius == tokens.barHeight / 2)
        #expect(tokens.minimumHitTarget == 28)
        #expect(tokens.spacing.truncatingRemainder(dividingBy: 8) == 0)
        #expect(tokens.barInsets.top + tokens.barInsets.bottom + tokens.minimumHitTarget == tokens.barHeight)
    }

    @Test func announcementsDescribeEachPhase() {
        #expect(RecordingAnnouncement.countdown(3, isFirst: true) == "Recording starts in 3")
        #expect(RecordingAnnouncement.countdown(2, isFirst: false) == "2")
        #expect(RecordingAnnouncement.started == "Recording started")
        #expect(RecordingAnnouncement.finished(wasRecording: true) == "Recording stopped")
        #expect(RecordingAnnouncement.finished(wasRecording: false) == "Recording cancelled")
        #expect(RecordingAnnouncement.ready.contains("Return") && RecordingAnnouncement.ready.contains("Escape"))
    }
}

@Suite("Recording glass view")
@MainActor
struct RecordingGlassViewTests {
    private func style(_ surface: RecordingChromeStyle.Surface, strong: Bool = false) -> RecordingChromeStyle {
        RecordingChromeStyle(surface: surface, borderWidth: strong ? 1 : 0.5, strongBorder: strong)
    }

    @Test func eachSurfaceUsesItsOwnView() {
        let material = RecordingGlassView(cornerRadius: 22, style: style(.material))
        #expect(material.surfaceView is NSVisualEffectView)
        #expect((material.surfaceView as? NSVisualEffectView)?.material == .hudWindow)

        let opaque = RecordingGlassView(cornerRadius: 22, style: style(.opaque))
        #expect(type(of: opaque.surfaceView) == NSView.self)
        #expect(opaque.surfaceView.layer?.backgroundColor != nil)

        let glass = RecordingGlassView(cornerRadius: 22, style: style(.liquidGlass))
        if RecordingChromeEnvironment.systemSupportsLiquidGlass {
            #expect(String(describing: type(of: glass.surfaceView)).contains("GlassEffectView"))
        } else {
            #expect(glass.surfaceView is NSVisualEffectView)
        }
    }

    @Test func changingTheStyleSwapsTheSurfaceAndKeepsTheContent() throws {
        let view = RecordingGlassView(cornerRadius: 22, style: style(.material))
        let content = NSButton(title: "Content", target: nil, action: nil)
        view.contentView = content
        let before = view.surfaceView

        view.apply(style(.opaque))
        #expect(view.surfaceView !== before)
        #expect(type(of: view.surfaceView) == NSView.self)
        #expect(content.isDescendant(of: view))
        #expect(view.style.surface == .opaque)

        view.apply(style(.material))
        #expect(view.surfaceView is NSVisualEffectView)
        #expect(content.isDescendant(of: view))
    }

    @Test func aBorderOnlyChangeKeepsTheSurface() {
        let view = RecordingGlassView(cornerRadius: 22, style: style(.material))
        let before = view.surfaceView
        view.apply(style(.material, strong: true))
        #expect(view.surfaceView === before)
        #expect(view.style.strongBorder)
    }

    @Test func theDarkMaterialForcesTheDarkAppearanceAndTheOthersFollowTheSystem() {
        let view = RecordingGlassView(cornerRadius: 22, style: style(.material))
        #expect(view.appearance?.name == .vibrantDark)
        view.apply(style(.opaque))
        #expect(view.appearance == nil)
    }

    @Test func theEdgeLineNeverTakesClicks() throws {
        let view = RecordingGlassView(cornerRadius: 22, style: style(.material, strong: true))
        let content = NSView()
        view.contentView = content
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 44)
        view.layoutSubtreeIfNeeded()

        let hit = try #require(view.hitTest(NSPoint(x: 100, y: 22)))
        #expect(hit === content || hit.isDescendant(of: view) && hit !== view)
        #expect(String(describing: type(of: hit)) != "RecordingEdgeView")
    }

    @Test func environmentResolvesItsStyleFromTheCurrentOptions() {
        var options = RecordingDisplayOptions()
        let environment = RecordingChromeEnvironment(displayOptions: { options }, announce: { _ in },
                                                     supportsLiquidGlass: false)
        #expect(environment.style.surface == .material)
        options.reduceTransparency = true
        #expect(environment.style.surface == .opaque)
    }

    @Test func liveDisplayOptionsReadTheSystem() {
        let options = RecordingDisplayOptions.live
        let workspace = NSWorkspace.shared
        #expect(options.reduceMotion == workspace.accessibilityDisplayShouldReduceMotion)
        #expect(options.reduceTransparency == workspace.accessibilityDisplayShouldReduceTransparency)
        #expect(options.increaseContrast == workspace.accessibilityDisplayShouldIncreaseContrast)
    }
}
