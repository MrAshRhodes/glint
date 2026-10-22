import Foundation

public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var settings: RenderSettings

    public init(id: UUID = UUID(), name: String, settings: RenderSettings) {
        self.id = id; self.name = name; self.settings = settings
    }

    /// Ships with the app so the preset list is never empty.
    public static let builtIn: [Preset] = [
        Preset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Default", settings: .default),
        Preset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Clean",
               settings: RenderSettings(padding: 32, cornerRadius: 12, shadow: ShadowSettings(strength: 30),
                                        background: .solid(.white))),
        Preset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Social 16:9",
               settings: RenderSettings(padding: 64, background: BackgroundCatalog.preset(id: "sunset")?.style ?? .transparent,
                                        aspectRatio: .r16x9)),
        Preset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, name: "Transparent",
               settings: RenderSettings(padding: 40, background: .transparent)),
    ]
}

struct PresetFile: Codable {
    var version: Int = 1
    var defaultPresetID: UUID?
    var presets: [Preset]
}

/// JSON-backed preset list. Not thread-safe; use from one actor (typically the main thread).
public final class PresetStore {
    public private(set) var presets: [Preset] = []
    public var defaultPresetID: UUID?
    public let url: URL

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Glint/presets.json")
    }

    /// Loads `url` if it exists, otherwise starts with `Preset.builtIn` (not yet written).
    public init(url: URL = PresetStore.defaultURL) {
        self.url = url
        if (try? load()) == nil { presets = Preset.builtIn; defaultPresetID = presets.first?.id }
    }

    public var defaultPreset: Preset? { presets.first { $0.id == defaultPresetID } ?? presets.first }

    public func preset(named name: String) -> Preset? { presets.first { $0.name == name } }

    /// `base`, or `base 2`, `base 3`, … — the first name no preset uses yet.
    public func uniqueName(_ base: String) -> String {
        var name = base, n = 2
        while preset(named: name) != nil { name = "\(base) \(n)"; n += 1 }
        return name
    }

    public func load() throws {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(PresetFile.self, from: data)
        presets = file.presets
        defaultPresetID = file.defaultPresetID
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }

    private func encoded(_ list: [Preset]? = nil) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(PresetFile(defaultPresetID: defaultPresetID, presets: list ?? presets))
    }

    /// Adds a preset; an existing preset with the same name is replaced (keeping its id).
    @discardableResult
    public func add(name: String, settings: RenderSettings) -> Preset {
        if let i = presets.firstIndex(where: { $0.name == name }) {
            presets[i].settings = settings
            return presets[i]
        }
        let p = Preset(name: name, settings: settings)
        presets.append(p)
        if defaultPresetID == nil { defaultPresetID = p.id }
        return p
    }

    public func update(_ preset: Preset) {
        if let i = presets.firstIndex(where: { $0.id == preset.id }) { presets[i] = preset }
    }

    public func rename(id: UUID, to name: String) {
        if let i = presets.firstIndex(where: { $0.id == id }) { presets[i].name = name }
    }

    public func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        if defaultPresetID == id { defaultPresetID = presets.first?.id }
    }

    public func setDefault(id: UUID) {
        if presets.contains(where: { $0.id == id }) { defaultPresetID = id }
    }

    /// Writes all presets (or only `ids`) to a standalone JSON file.
    public func exportPresets(to url: URL, ids: Set<UUID>? = nil) throws {
        let list = ids.map { set in presets.filter { set.contains($0.id) } } ?? presets
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded(list).write(to: url, options: .atomic)
    }

    /// Merges presets from a file. Name clashes get a numeric suffix. Returns the number imported.
    @discardableResult
    public func importPresets(from url: URL) throws -> Int {
        let file = try JSONDecoder().decode(PresetFile.self, from: Data(contentsOf: url))
        var count = 0
        for var p in file.presets {
            var name = p.name, n = 2
            while presets.contains(where: { $0.name == name }) { name = "\(p.name) \(n)"; n += 1 }
            p.name = name
            if presets.contains(where: { $0.id == p.id }) { p.id = UUID() }
            presets.append(p)
            count += 1
        }
        return count
    }
}
