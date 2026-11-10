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
    public let isRecording: Bool
    /// The look and annotations of a reopened project. When set, the editor starts with exactly these:
    /// remembered settings and auto-redaction are not applied, and changes made in the session are not
    /// remembered for the next capture.
    public let restored: EditorRestoreState?

    public init(image: CGImage, backingScale: CGFloat, rawURL: URL?, source: String?, isComposed: Bool = false,
                isRecording: Bool = false, restored: EditorRestoreState? = nil) {
        self.image = image
        self.backingScale = backingScale
        self.rawURL = rawURL
        self.source = source
        self.isComposed = isComposed
        self.isRecording = isRecording
        self.restored = restored
    }

    var windowTitle: String {
        if isComposed { return "Glint — last image" }
        if let name = restored?.projectName { return "Glint — \(name)" }
        return source.map { "Glint — \($0)" } ?? "Glint"
    }
}

/// The editable state a project restores into the editor.
public struct EditorRestoreState: Equatable {
    public var settings: RenderSettings
    public var annotations: [Annotation]
    /// Shown in the window title, normally the project's file name without its extension.
    public var projectName: String?

    public init(settings: RenderSettings, annotations: [Annotation], projectName: String? = nil) {
        self.settings = settings
        self.annotations = annotations
        self.projectName = projectName
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
    /// Settings the editor would start with, and the ones an automatic export uses: a preset requested by name
    /// when it exists, otherwise the last-used settings when `rememberSettings` is on, otherwise (or when
    /// nothing has been used yet) the named default preset, then the store's default preset, then
    /// `RenderSettings.default`. Auto-balance always follows `preferences.autoBalance`.
    public static func initialSettings(preferences: AppPreferences, presetStore: PresetStore? = nil,
                                       presetName: String? = nil) -> RenderSettings {
        var settings: RenderSettings
        if let store = presetStore, let name = presetName, let preset = store.preset(named: name) {
            settings = preset.settings
        } else if preferences.rememberSettings, let last = preferences.lastRenderSettings {
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
        var settings: RenderSettings = context.isComposed ? .passThrough : initialSettings(preferences: preferences)
        if context.isRecording { settings.autoBalance = false }
        var wallpaper: CGImage?
        if settings.usesDesktopWallpaper {
            switch wallpaperProvider() {
            case .success(let image): wallpaper = image
            case .failure(let error): onWallpaperFailure(error)
            }
        }
        var annotations: [Annotation] = []
        if preferences.autoRedact, !context.isComposed, !context.isRecording, let lines = try? recognizeText(context.image) {
            var options = AutoRedactOptions(detector: preferences.autoRedactOptions, color: preferences.redactColor)
            options.padding = 3 * Double(context.backingScale)
            annotations = AutoRedact.annotations(for: lines, options: options, imageSize: context.image.pixelSize)
        }
        return try Compositor.render(image: context.image, settings: settings, annotations: annotations,
                                 backingScale: context.backingScale, wallpaper: wallpaper)
    }
}
