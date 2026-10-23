import AppKit
import GlintCore

/// Everything the editor needs to open a capture.
public struct EditorContext {
    public let image: CGImage
    public let backingScale: CGFloat
    public let rawURL: URL?
    public let source: String?
    /// True when `image` is already a finished output (such as a reopened last image). The editor shows it
    /// flattened: no frame, background, padding or shadow is applied again, it is not auto-redacted a second
    /// time, and look changes made in the session are not remembered for the next capture.
    public let isComposed: Bool

    public init(image: CGImage, backingScale: CGFloat, rawURL: URL?, source: String?, isComposed: Bool = false) {
        self.image = image
        self.backingScale = backingScale
        self.rawURL = rawURL
        self.source = source
        self.isComposed = isComposed
    }

    var windowTitle: String {
        if isComposed { return "Glint — last image" }
        return source.map { "Glint — \($0)" } ?? "Glint"
    }
}

extension RenderSettings {
    /// Renders an already-composed image unchanged: nothing is added around it, cropped or restyled.
    static let passThrough = RenderSettings(
        padding: 0, inset: 0, cornerRadius: 0, shadow: .none, background: .transparent, aspectRatio: .auto,
        border: BorderStyle(), windowFrame: WindowFrameSettings(), tilt: .zero, rotation: .none,
        flipHorizontal: false, flipVertical: false, watermark: WatermarkSettings(), autoBalance: false,
        outputScale: 1, usesDesktopWallpaper: false)
}

/// UI-free rendering with the same settings resolution the editor uses.
public enum EditorHeadless {
    /// Settings the editor would start with: the last-used settings when `rememberSettings` is on,
    /// otherwise (or when nothing has been used yet) the default preset.
    public static func initialSettings(preferences: AppPreferences, presetStore: PresetStore? = nil) -> RenderSettings {
        var settings: RenderSettings
        if preferences.rememberSettings, let last = preferences.lastRenderSettings {
            settings = last
        } else if let store = presetStore, let name = preferences.defaultPresetName, let preset = store.preset(named: name) {
            settings = preset.settings
        } else if let preset = presetStore?.defaultPreset {
            settings = preset.settings
        } else {
            settings = .default
        }
        settings.autoBalance = preferences.autoBalance
        return settings
    }

    /// Composes the capture with the current preferences (and auto-redaction when enabled). An already-composed
    /// image is returned as it is: it is neither styled nor auto-redacted a second time.
    /// Throws (e.g. `RenderError.annotationsNotApplied`) rather than returning unredacted pixels.
    @MainActor
    public static func render(context: EditorContext, preferences: AppPreferences,
                              recognizeText: (CGImage) throws -> [RecognizedLine] = { try TextRecognizer.recognizeSync(in: $0) },
                              wallpaperProvider: @MainActor () -> Result<CGImage, DesktopWallpaperError> = { DesktopWallpaper.current() },
                              onWallpaperFailure: (DesktopWallpaperError) -> Void = {
                                  FileHandle.standardError.write(Data("warning: \($0.localizedDescription)\n".utf8))
                              }) throws -> CGImage {
        let settings: RenderSettings = context.isComposed ? .passThrough : initialSettings(preferences: preferences)
        var wallpaper: CGImage?
        if settings.usesDesktopWallpaper {
            switch wallpaperProvider() {
            case .success(let image): wallpaper = image
            case .failure(let error): onWallpaperFailure(error)
            }
        }
        var annotations: [Annotation] = []
        if preferences.autoRedact, !context.isComposed, let lines = try? recognizeText(context.image) {
            var options = AutoRedactOptions(detector: preferences.autoRedactOptions, color: preferences.redactColor)
            options.padding = 3 * Double(context.backingScale)
            annotations = AutoRedact.annotations(for: lines, options: options, imageSize: context.image.pixelSize)
        }
        return try Compositor.render(image: context.image, settings: settings, annotations: annotations,
                                 backingScale: context.backingScale, wallpaper: wallpaper)
    }
}
