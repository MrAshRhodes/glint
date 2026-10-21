import CoreGraphics
import Foundation

// MARK: - Aspect ratio

public enum AspectRatioPreset: Codable, Equatable, Hashable, Sendable {
    case auto
    case square, r4x3, r3x2, r16x9, r9x16, r4x5
    case twitterPost, twitterHeader, linkedInPost, instagramSquare, instagramPortrait
    case facebookPost, youTubeThumbnail, openGraph, pinterestPin, redditPost, snapchatStory
    case custom(width: Double, height: Double)

    public static let allBuiltIn: [AspectRatioPreset] = [
        .auto, .r4x3, .r3x2, .r16x9, .square, .r9x16, .r4x5,
        .twitterPost, .twitterHeader, .linkedInPost, .instagramSquare, .instagramPortrait,
        .facebookPost, .youTubeThumbnail, .openGraph, .pinterestPin, .redditPost, .snapchatStory,
    ]

    /// Recommended export size in pixels for social presets (informational).
    public var recommendedPixelSize: CGSize? {
        switch self {
        case .twitterPost: return CGSize(width: 1600, height: 900)
        case .twitterHeader: return CGSize(width: 1500, height: 500)
        case .linkedInPost: return CGSize(width: 1200, height: 627)
        case .instagramSquare: return CGSize(width: 1080, height: 1080)
        case .instagramPortrait: return CGSize(width: 1080, height: 1350)
        case .facebookPost: return CGSize(width: 1200, height: 630)
        case .youTubeThumbnail: return CGSize(width: 1280, height: 720)
        case .openGraph: return CGSize(width: 1200, height: 630)
        case .pinterestPin: return CGSize(width: 1000, height: 1500)
        case .redditPost: return CGSize(width: 1200, height: 628)
        case .snapchatStory: return CGSize(width: 1080, height: 1920)
        case .custom(let w, let h) where w > 0 && h > 0: return CGSize(width: w, height: h)
        default: return nil
        }
    }

    /// width / height, or nil for `.auto`.
    public var ratio: CGFloat? {
        switch self {
        case .auto: return nil
        case .square: return 1
        case .r4x3: return 4.0 / 3
        case .r3x2: return 3.0 / 2
        case .r16x9: return 16.0 / 9
        case .r9x16: return 9.0 / 16
        case .r4x5: return 4.0 / 5
        case .custom(let w, let h): return (w > 0 && h > 0) ? CGFloat(w / h) : nil
        default:
            guard let s = recommendedPixelSize else { return nil }
            return s.width / s.height
        }
    }

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .square: return "1:1"
        case .r4x3: return "4:3"
        case .r3x2: return "3:2"
        case .r16x9: return "16:9"
        case .r9x16: return "9:16"
        case .r4x5: return "4:5"
        case .twitterPost: return "Twitter / X Post"
        case .twitterHeader: return "Twitter / X Header"
        case .linkedInPost: return "LinkedIn"
        case .instagramSquare: return "Instagram Square"
        case .instagramPortrait: return "Instagram Portrait"
        case .facebookPost: return "Facebook"
        case .youTubeThumbnail: return "YouTube"
        case .openGraph: return "OG Image"
        case .pinterestPin: return "Pinterest"
        case .redditPost: return "Reddit"
        case .snapchatStory: return "Snapchat"
        case .custom(let w, let h): return "\(Int(w)):\(Int(h))"
        }
    }

    /// Parses `4:3`, `1200x630`, `1200×630` or a built-in display name / `auto`.
    public static func parse(_ text: String) -> AspectRatioPreset? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty || s == "auto" { return .auto }
        if let p = allBuiltIn.first(where: { $0.displayName.lowercased() == s }) { return p }
        let parts = s.split(whereSeparator: { ":x×/".contains($0) }).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return .custom(width: parts[0], height: parts[1])
    }
}

// MARK: - Shadow

public struct ShadowLayer: Codable, Equatable, Hashable, Sendable {
    public var opacity: Double
    /// CSS-style blur radius in points (Gaussian σ = blur / 2).
    public var blur: Double
    public var offsetX: Double
    /// Positive = downwards.
    public var offsetY: Double
    public init(opacity: Double, blur: Double, offsetX: Double = 0, offsetY: Double) {
        self.opacity = opacity; self.blur = blur; self.offsetX = offsetX; self.offsetY = offsetY
    }
}

public struct ShadowSettings: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    /// 0…100 slider. 50 is the default look (contact + ambient layer).
    public var strength: Double
    public var customLayers: [ShadowLayer]?
    public var color: RGBAColor

    public init(enabled: Bool = true, strength: Double = 50, customLayers: [ShadowLayer]? = nil,
                color: RGBAColor = .black) {
        self.enabled = enabled; self.strength = strength; self.customLayers = customLayers; self.color = color
    }

    public static let none = ShadowSettings(enabled: false, strength: 0)

    /// Two stacked layers: small sharp contact shadow + large offset ambient shadow, all scaling with `strength`.
    public var resolvedLayers: [ShadowLayer] {
        guard enabled else { return [] }
        if let customLayers { return customLayers }
        let k = max(0, min(strength, 100)) / 50
        guard k > 0 else { return [] }
        return [
            ShadowLayer(opacity: min(0.34 * k, 0.9), blur: 10 * k, offsetY: 6 * k),
            ShadowLayer(opacity: min(0.18 * k, 0.6), blur: 47 * k, offsetY: 43 * k),
        ]
    }
}

// MARK: - Misc render sub-settings

public struct BorderStyle: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var width: Double
    public var color: RGBAColor
    public init(enabled: Bool = false, width: Double = 1, color: RGBAColor = RGBAColor(r: 1, g: 1, b: 1, a: 0.3)) {
        self.enabled = enabled; self.width = width; self.color = color
    }
}

public enum WindowFrameKind: String, Codable, CaseIterable, Sendable { case none, macOS, browser }

public struct WindowFrameSettings: Codable, Equatable, Hashable, Sendable {
    public var style: WindowFrameKind
    public var dark: Bool
    public var title: String
    public init(style: WindowFrameKind = .none, dark: Bool = false, title: String = "") {
        self.style = style; self.dark = dark; self.title = title
    }
    /// Title bar height in points.
    public var barHeight: Double {
        switch style { case .none: return 0; case .macOS: return 28; case .browser: return 40 }
    }
}

/// 3D tilt in degrees (rotation about the X / Y axis). `.zero` = flat.
public struct Tilt: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double = 0, y: Double = 0) { self.x = x; self.y = y }
    /// 0…30 sliders where 15 is neutral.
    public init(uiX: Double, uiY: Double) { self.init(x: uiX - 15, y: uiY - 15) }
    public static let zero = Tilt()
    public var isFlat: Bool { abs(x) < 0.01 && abs(y) < 0.01 }
}

public enum Rotation: Int, Codable, CaseIterable, Sendable {
    case none = 0, cw90 = 90, cw180 = 180, cw270 = 270
    public var rotatedClockwise: Rotation { Rotation(rawValue: (rawValue + 90) % 360) ?? .none }
    public var rotatedCounterClockwise: Rotation { Rotation(rawValue: (rawValue + 270) % 360) ?? .none }
}

public enum WatermarkPosition: String, Codable, CaseIterable, Sendable {
    case topLeft, topCenter, topRight, centerLeft, center, centerRight, bottomLeft, bottomCenter, bottomRight
}

public enum WatermarkKind: String, Codable, Sendable { case text, image }

public struct WatermarkSettings: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var kind: WatermarkKind
    public var text: String
    public var imagePath: String?
    public var position: WatermarkPosition
    public var opacity: Double
    /// Font size in points (text) or image height in points (image).
    public var size: Double
    public var color: RGBAColor

    public init(enabled: Bool = false, kind: WatermarkKind = .text, text: String = "Screenshot by Glint",
                imagePath: String? = nil, position: WatermarkPosition = .bottomRight, opacity: Double = 0.8,
                size: Double = 12, color: RGBAColor = .white) {
        self.enabled = enabled; self.kind = kind; self.text = text; self.imagePath = imagePath
        self.position = position; self.opacity = opacity; self.size = size; self.color = color
    }
}

// MARK: - RenderSettings

public struct RenderSettings: Codable, Equatable, Sendable {
    /// Points per side; floored to an integer before scaling.
    public var padding: Double
    /// Inset band (detected border colour) thickness, points per side; floored.
    public var inset: Double
    /// Overrides the auto-detected inset colour when set.
    public var insetColor: RGBAColor?
    public var cornerRadius: Double
    public var shadow: ShadowSettings
    public var background: BackgroundStyle
    // Optional storage keeps older presets compatible and omits the key when disabled.
    private var desktopWallpaper: Bool?
    public var usesDesktopWallpaper: Bool {
        get { desktopWallpaper ?? false }
        set { desktopWallpaper = newValue ? true : nil }
    }
    public var aspectRatio: AspectRatioPreset
    public var border: BorderStyle
    public var windowFrame: WindowFrameSettings
    public var tilt: Tilt
    public var rotation: Rotation
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    public var watermark: WatermarkSettings
    public var autoBalance: Bool
    /// Extra multiplier applied to every pixel metric and to the content (1 = native).
    public var outputScale: Double

    public init(padding: Double = 48, inset: Double = 15, insetColor: RGBAColor? = nil, cornerRadius: Double = 20,
                shadow: ShadowSettings = ShadowSettings(), background: BackgroundStyle = BackgroundCatalog.defaultStyle,
                aspectRatio: AspectRatioPreset = .auto, border: BorderStyle = BorderStyle(),
                windowFrame: WindowFrameSettings = WindowFrameSettings(), tilt: Tilt = .zero,
                rotation: Rotation = .none, flipHorizontal: Bool = false, flipVertical: Bool = false,
                watermark: WatermarkSettings = WatermarkSettings(), autoBalance: Bool = true,
                outputScale: Double = 1, usesDesktopWallpaper: Bool = false) {
        self.padding = padding; self.inset = inset; self.insetColor = insetColor
        self.cornerRadius = cornerRadius; self.shadow = shadow; self.background = background
        self.aspectRatio = aspectRatio; self.border = border; self.windowFrame = windowFrame
        self.tilt = tilt; self.rotation = rotation; self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical; self.watermark = watermark; self.autoBalance = autoBalance
        self.outputScale = outputScale
        self.desktopWallpaper = usesDesktopWallpaper ? true : nil
    }

    public static let `default` = RenderSettings()
}
