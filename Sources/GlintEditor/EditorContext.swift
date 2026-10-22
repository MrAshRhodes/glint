import AppKit
import GlintCore

/// Everything the editor needs to open a capture.
public struct EditorContext {
    public let image: CGImage
    public let backingScale: CGFloat
    public let rawURL: URL?
    public let source: String?

    public init(image: CGImage, backingScale: CGFloat, rawURL: URL?, source: String?) {
        self.image = image
        self.backingScale = backingScale
        self.rawURL = rawURL
        self.source = source
    }
}

/// UI-free rendering with the same settings resolution the editor uses.
public enum EditorHeadless {
    /// Settings the editor would start with (last used, falling back to the default preset).
    public static func initialSettings(preferences: AppPreferences, presetStore: PresetStore? = nil) -> RenderSettings {
        var settings: RenderSettings
        if let store = presetStore, let name = preferences.defaultPresetName, let preset = store.preset(named: name) {
            settings = preset.settings
        } else if let last = preferences.lastRenderSettings {
            settings = last
        } else if let preset = presetStore?.defaultPreset {
            settings = preset.settings
        } else {
            settings = .default
        }
        settings.autoBalance = preferences.autoBalance
        return settings
    }

    /// Composes the capture with the current preferences (and auto-redaction when enabled).
    /// Throws (e.g. `RenderError.annotationsNotApplied`) rather than returning unredacted pixels.
    @MainActor
    public static func render(context: EditorContext, preferences: AppPreferences,
                              recognizeText: (CGImage) throws -> [RecognizedLine] = { try TextRecognizer.recognizeSync(in: $0) },
                              wallpaperProvider: @MainActor () -> Result<CGImage, DesktopWallpaperError> = { DesktopWallpaper.current() },
                              onWallpaperFailure: (DesktopWallpaperError) -> Void = {
                                  FileHandle.standardError.write(Data("warning: \($0.localizedDescription)\n".utf8))
                              }) throws -> CGImage {
        let settings = initialSettings(preferences: preferences)
        var wallpaper: CGImage?
        if settings.usesDesktopWallpaper {
            switch wallpaperProvider() {
            case .success(let image): wallpaper = image
            case .failure(let error): onWallpaperFailure(error)
            }
        }
        var annotations: [Annotation] = []
        if preferences.autoRedact, let lines = try? recognizeText(context.image) {
            var options = AutoRedactOptions(detector: preferences.autoRedactOptions, color: preferences.redactColor)
            options.padding = 3 * Double(context.backingScale)
            annotations = AutoRedact.annotations(for: lines, options: options, imageSize: context.image.pixelSize)
        }
        return try Compositor.render(image: context.image, settings: settings, annotations: annotations,
                                 backingScale: context.backingScale, wallpaper: wallpaper)
    }
}
