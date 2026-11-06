import CoreGraphics
import Foundation

// MARK: - Manifest

/// The header of a `.glint` project package, stored on its own in `manifest.json`.
///
/// It is decoded and checked before `project.json`, so a project written by a newer Glint is refused with a clear
/// message instead of being half-read and silently losing whatever this build doesn't understand.
///
/// Extending the format: prefer adding a defaulted (`decodeIfPresent`) field to the state types below; older builds
/// then ignore it and newer builds read older projects. When an older build would produce *wrong output* by ignoring
/// the new data (for example tracked redactions that would stop covering moving content), also register a feature
/// string in `ProjectFeatures` instead of bumping `currentFormatVersion`. Bump the version only for changes an older
/// build cannot even parse.
public struct ProjectManifest: Codable, Equatable, Sendable {
    /// Identifies the file as a Glint project. Also the exported uniform type identifier.
    public static let formatName = "io.github.mrashrhodes.glint.project"
    /// The newest layout this build reads and the one it writes.
    public static let currentFormatVersion = 1

    public var format: String
    public var formatVersion: Int
    /// Feature strings the project depends on; a build that doesn't know one of them must not open it.
    public var requiredFeatures: [String]
    /// The Glint version that wrote the project. Informational only.
    public var generator: String?

    public init(format: String = ProjectManifest.formatName, formatVersion: Int = ProjectManifest.currentFormatVersion,
                requiredFeatures: [String] = [], generator: String? = nil) {
        self.format = format
        self.formatVersion = formatVersion
        self.requiredFeatures = requiredFeatures
        self.generator = generator
    }

    private enum CodingKeys: String, CodingKey { case format, formatVersion, requiredFeatures, generator }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(format: try c.decode(String.self, forKey: .format),
                  formatVersion: try c.decode(Int.self, forKey: .formatVersion),
                  requiredFeatures: try c.decodeIfPresent([String].self, forKey: .requiredFeatures) ?? [],
                  generator: try c.decodeIfPresent(String.self, forKey: .generator))
    }

    /// Throws when this build can't faithfully open a project with this header.
    public func validate(supportedFeatures: Set<String> = ProjectFeatures.supported) throws {
        guard format == Self.formatName else { throw ProjectFormatError.notAProject }
        guard formatVersion >= 1 else { throw ProjectFormatError.damaged("unknown format version \(formatVersion)") }
        guard formatVersion <= Self.currentFormatVersion else { throw ProjectFormatError.newerVersion(formatVersion) }
        let unknown = Set(requiredFeatures).subtracting(supportedFeatures).sorted()
        guard unknown.isEmpty else { throw ProjectFormatError.unsupportedFeatures(unknown) }
    }
}

/// Optional capabilities a project can depend on, named by stable strings in `ProjectManifest.requiredFeatures`.
///
/// A feature that adds data older builds would ignore *safely* doesn't need an entry. One whose absence would change
/// the output adds its string to `supported` and returns it from `required(by:)` whenever a project uses it, for
/// example `"redactionTracks"` (#79) or `"presentation"` (#81). Never rename or reuse a string once released.
public enum ProjectFeatures {
    /// Every feature string this build understands.
    public static let supported: Set<String> = []

    /// The feature strings `state` relies on, written to the manifest so older builds refuse it.
    public static func required(by state: ProjectState) -> [String] {
        []
    }
}

// MARK: - State

/// Everything needed to reopen a screenshot editor with every element editable again.
public struct ScreenshotProjectState: Codable, Equatable, Sendable {
    /// Restored exactly; never replaced by the current preferences or default preset.
    public var settings: RenderSettings
    public var annotations: [Annotation]
    /// Device pixels per point of the capture, so stroke widths and padding keep their size.
    public var backingScale: Double
    /// Where the capture came from (`area`, `window`, `file`…), for the window title.
    public var source: String?

    public init(settings: RenderSettings, annotations: [Annotation], backingScale: Double, source: String? = nil) {
        self.settings = settings
        self.annotations = annotations
        self.backingScale = backingScale
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case settings, annotations, backingScale, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(settings: try c.decode(RenderSettings.self, forKey: .settings),
                  annotations: try c.decodeIfPresent([Annotation].self, forKey: .annotations) ?? [],
                  backingScale: try c.decodeIfPresent(Double.self, forKey: .backingScale) ?? 1,
                  source: try c.decodeIfPresent(String.self, forKey: .source))
        guard backingScale.isFinite, backingScale > 0, backingScale <= 16 else {
            throw DecodingError.dataCorruptedError(forKey: .backingScale, in: c,
                                                   debugDescription: "Backing scale must be between 0 and 16.")
        }
    }
}

/// Everything needed to reopen a recording editor: the look, the timed annotations, the trim and export settings.
public struct RecordingProjectState: Codable, Equatable, Sendable {
    public var settings: RenderSettings
    /// Annotations keep their `visibleRange` in source seconds, independent of the trim.
    public var annotations: [Annotation]
    public var trim: RecordingTrim
    public var options: RecordingExportOptions
    /// Duration and size of the stored clip, as the capture layer measured them.
    public var duration: TimeInterval
    public var pixelSize: CGSize

    public init(settings: RenderSettings, annotations: [Annotation], trim: RecordingTrim,
                options: RecordingExportOptions, duration: TimeInterval, pixelSize: CGSize) {
        self.settings = settings
        self.annotations = annotations
        self.trim = trim
        self.options = options
        self.duration = duration
        self.pixelSize = pixelSize
    }

    private enum CodingKeys: String, CodingKey { case settings, annotations, trim, options, duration, pixelSize }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(settings: try c.decode(RenderSettings.self, forKey: .settings),
                  annotations: try c.decodeIfPresent([Annotation].self, forKey: .annotations) ?? [],
                  trim: try c.decode(RecordingTrim.self, forKey: .trim),
                  options: try c.decodeIfPresent(RecordingExportOptions.self, forKey: .options) ?? RecordingExportOptions(),
                  duration: try c.decode(TimeInterval.self, forKey: .duration),
                  pixelSize: try c.decode(CGSize.self, forKey: .pixelSize))
        guard duration.isFinite, duration >= 0, pixelSize.width >= 1, pixelSize.height >= 1,
              pixelSize.width.isFinite, pixelSize.height.isFinite else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Recording duration or size is invalid."))
        }
    }
}

/// The editor state stored in `project.json`, tagged by `kind`.
public enum ProjectState: Equatable, Sendable {
    case screenshot(ScreenshotProjectState)
    case recording(RecordingProjectState)

    public var settings: RenderSettings {
        get {
            switch self {
            case .screenshot(let state): return state.settings
            case .recording(let state): return state.settings
            }
        }
        set {
            switch self {
            case .screenshot(var state): state.settings = newValue; self = .screenshot(state)
            case .recording(var state): state.settings = newValue; self = .recording(state)
            }
        }
    }

    public var annotations: [Annotation] {
        switch self {
        case .screenshot(let state): return state.annotations
        case .recording(let state): return state.annotations
        }
    }
}

extension ProjectState: Codable {
    private enum Kind: String, Codable { case screenshot, recording }
    private enum CodingKeys: String, CodingKey { case kind, screenshot, recording }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .screenshot: self = .screenshot(try c.decode(ScreenshotProjectState.self, forKey: .screenshot))
        case .recording: self = .recording(try c.decode(RecordingProjectState.self, forKey: .recording))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .screenshot(let state):
            try c.encode(Kind.screenshot, forKey: .kind)
            try c.encode(state, forKey: .screenshot)
        case .recording(let state):
            try c.encode(Kind.recording, forKey: .kind)
            try c.encode(state, forKey: .recording)
        }
    }
}

// MARK: - Project

/// The original, unredacted capture a project keeps so every edit stays changeable.
public enum ProjectSource {
    /// A screenshot's pixels, stored as `source/capture.png`.
    case image(CGImage)
    /// A recording, copied into the package as `source/recording.mp4` when saving.
    case video(URL)
}

/// An editable Glint project: the editor state plus the original capture it applies to.
///
/// Privacy: the source is the original capture, so anything redacted is still in the project. Only flattened
/// exports are ever shared; the UI says so when saving.
public struct GlintProject: @unchecked Sendable {
    // @unchecked: CGImage is immutable and safe to hand between threads.
    public var state: ProjectState
    public var source: ProjectSource

    public init(state: ProjectState, source: ProjectSource) {
        self.state = state
        self.source = source
    }
}

// MARK: - Errors

/// Why a project couldn't be opened or saved. Messages are shown to the user as they are.
public enum ProjectFormatError: LocalizedError, Equatable, Sendable {
    case notAProject
    case newerVersion(Int)
    case unsupportedFeatures([String])
    case missingMember(String)
    case unsafeMember(String)
    case memberTooLarge(String)
    case damaged(String)
    case mismatchedSource
    case unreadableAsset(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAProject:
            return "This isn't a Glint project."
        case .newerVersion:
            return "This project was saved by a newer version of Glint. Update Glint to open it."
        case .unsupportedFeatures(let features):
            return "This project uses features this version of Glint doesn't support "
                + "(\(features.joined(separator: ", "))). Update Glint to open it."
        case .missingMember(let name):
            return "The project is incomplete: \(name) is missing."
        case .unsafeMember(let name):
            return "The project contains an unexpected item at \(name), so Glint won't open it."
        case .memberTooLarge(let name):
            return "\(name) in the project is larger than Glint can open."
        case .damaged(let detail):
            return "The project is damaged and can't be opened (\(detail))."
        case .mismatchedSource:
            return "The project's original capture doesn't match its kind."
        case .unreadableAsset(let what):
            return "Couldn't read the \(what) image to include it in the project."
        case .writeFailed(let reason):
            return "Couldn't save the project: \(reason)"
        }
    }
}
