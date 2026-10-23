import CoreGraphics
import CryptoKit
import Foundation

/// How long Glint keeps the Output files it manages before moving them to the Trash.
public enum OutputRetentionPeriod: Int, CaseIterable, Sendable, Identifiable {
    case forever = 0, oneDay = 1, sevenDays = 7, thirtyDays = 30, ninetyDays = 90

    /// Reads a stored day count. Unknown or negative values fail safe to `.forever`.
    public init(storedDays: Int) { self = OutputRetentionPeriod(rawValue: storedDays) ?? .forever }

    /// Number of days, or nil when nothing is ever removed.
    public var days: Int? { self == .forever ? nil : rawValue }

    public var displayName: String {
        switch self {
        case .forever: return "Forever"
        case .oneDay: return "1 day"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .ninetyDays: return "90 days"
        }
    }

    public var id: Int { rawValue }
}

/// How a managed Output file came about.
public enum OutputRetentionSource: String, Codable, Sendable { case copied, dragged, saved }

/// A managed file in the Output folder.
public struct RetainedOutput: Equatable, Sendable {
    public let url: URL
    /// When the file was written or last reused; cleanup ages it from here.
    public let date: Date
    public let source: OutputRetentionSource
    /// Pixels per point of the stored file, for opening it again at the right size.
    public let backingScale: CGFloat
    /// Whether an unchanged earlier file was reused instead of writing another.
    public let reused: Bool

    public init(url: URL, date: Date, source: OutputRetentionSource, backingScale: CGFloat, reused: Bool = false) {
        self.url = url; self.date = date; self.source = source; self.backingScale = backingScale; self.reused = reused
    }
}

/// What one `OutputRetention.cleanUp()` run did.
public struct OutputCleanupReport: Equatable, Sendable {
    /// Files moved to the Trash.
    public var removed: [URL]
    /// Expired files left alone because they are in use, e.g. by a drag.
    public var skippedActive: [URL]
    /// Files no longer tracked because they changed after Glint wrote them. They are never deleted.
    public var untracked: [URL]
    /// Descriptions of the files that could not be moved to the Trash. Those files stay tracked.
    public var failures: [String]

    public init(removed: [URL] = [], skippedActive: [URL] = [], untracked: [URL] = [], failures: [String] = []) {
        self.removed = removed; self.skippedActive = skippedActive; self.untracked = untracked; self.failures = failures
    }

    public var isEmpty: Bool { removed.isEmpty && skippedActive.isEmpty && untracked.isEmpty && failures.isEmpty }
}

public enum OutputRetentionError: Error, Equatable, LocalizedError {
    /// Keeping copied images is off, or history is. Also thrown when either is turned off, or the Output folder
    /// changes, while an image is still being stored; nothing is written then.
    case disabled
    case encodingFailed
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .disabled: return "Keeping copied screenshots is turned off."
        case .encodingFailed: return "The screenshot could not be encoded."
        case .writeFailed(let reason): return reason
        }
    }
}

/// Output files that cleanup must leave alone right now, e.g. while one is being dragged.
public final class OutputActiveFiles: @unchecked Sendable {
    public static let shared = OutputActiveFiles()

    private let condition = NSCondition()
    private var counts: [String: Int] = [:]
    /// Files cleanup is moving to the Trash right now.
    private var removing: Set<String> = []

    public init() {}

    /// Marks `url` as in use. Calls nest: the file stays active until every `begin` has an `end`.
    /// If cleanup is moving that file to the Trash at this moment, this waits for the move to finish, so on return
    /// the file is either safe until `end` or already gone. Other files are never held up.
    public func begin(_ url: URL) {
        let key = OutputRetention.normalizedPath(url)
        condition.withLock {
            while removing.contains(key) { condition.wait() }
            counts[key, default: 0] += 1
        }
    }

    public func end(_ url: URL) {
        let key = OutputRetention.normalizedPath(url)
        condition.withLock {
            guard let count = counts[key] else { return }
            counts[key] = count > 1 ? count - 1 : nil
        }
    }

    public func contains(_ url: URL) -> Bool {
        let key = OutputRetention.normalizedPath(url)
        return condition.withLock { counts[key] != nil }
    }

    /// Runs `remove` unless `url` is in use, and holds back any `begin` for it until `remove` has finished, so a
    /// drag cannot claim the file between the check and the removal. Returns whether `remove` ran.
    func removeUnlessActive(_ url: URL, _ remove: () throws -> Void) rethrows -> Bool {
        let key = OutputRetention.normalizedPath(url)
        let claimed = condition.withLock {
            while removing.contains(key) { condition.wait() }
            guard counts[key] == nil else { return false }
            removing.insert(key)
            return true
        }
        guard claimed else { return false }
        defer {
            condition.withLock {
                removing.remove(key)
                condition.broadcast()
            }
        }
        try remove()
        return true
    }
}

/// Keeps copied, dragged and auto-saved screenshots reopenable, and expires the ones Glint wrote itself.
///
/// Everything is opt-in and needs `AppPreferences.saveHistory`. The files are tracked by a hidden index,
/// `.glint-output-index.json`, inside the Output folder. Only files listed there are reopened or cleaned up, so
/// manual saves, `Raw/` captures and files that existed before the user opted in are never touched. A missing,
/// corrupt or newer-versioned index reads as empty and is never used to delete anything.
///
/// Calls hit the disk (and `retain` encodes an image), so make them off the main thread when you can.
/// Every method is thread-safe; the index is guarded by one lock shared by all instances in the process.
public final class OutputRetention: @unchecked Sendable {
    static let indexFileName = ".glint-output-index.json"
    static let indexVersion = 1
    /// Guards every index. Tests hold it to stop a call at a known point.
    static let lock = NSRecursiveLock()

    private let preferences: AppPreferences
    private let now: @Sendable () -> Date
    private let moveToTrash: @Sendable (URL) throws -> Void
    private let activeFiles: OutputActiveFiles
    private let encode: @Sendable (CGImage, ExportFormat, ExportScale, CGFloat) throws -> Data

    public convenience init(preferences: AppPreferences, now: @escaping @Sendable () -> Date = { Date() },
                            moveToTrash: @escaping @Sendable (URL) throws -> Void = { try OutputRetention.moveToSystemTrash($0) },
                            activeFiles: OutputActiveFiles = .shared) {
        self.init(preferences: preferences, now: now, moveToTrash: moveToTrash, activeFiles: activeFiles,
                  encode: { try Exporter.data(for: $0, format: $1, scale: $2, backingScale: $3) })
    }

    /// The same, with the image encoder replaceable by tests.
    init(preferences: AppPreferences, now: @escaping @Sendable () -> Date,
         moveToTrash: @escaping @Sendable (URL) throws -> Void, activeFiles: OutputActiveFiles,
         encode: @escaping @Sendable (CGImage, ExportFormat, ExportScale, CGFloat) throws -> Data) {
        self.preferences = preferences
        self.now = now
        self.moveToTrash = moveToTrash
        self.activeFiles = activeFiles
        self.encode = encode
    }

    /// Copied and dragged images are kept.
    public var retainsCopies: Bool { preferences.saveHistory && preferences.keepCopiedImages }
    /// Files auto-saved to the Output folder are tracked, so they can be reopened or expire.
    public var tracksSavedOutputs: Bool {
        preferences.saveHistory && (preferences.keepCopiedImages || preferences.outputRetention != .forever)
    }
    /// Expired files are moved to the Trash.
    public var cleansUp: Bool { preferences.saveHistory && preferences.outputRetention != .forever }

    // MARK: - Tracking

    /// Writes `image` to the Output folder in the user's export format and scale, and tracks it. An image with
    /// the same pixels as an unchanged tracked file reuses that file and refreshes its date instead.
    /// Throws `.disabled` and writes nothing if keeping copies is turned off, or the Output folder changes, before
    /// the image is stored.
    /// - Parameter backingScale: the scale of `image`; the stored file's own scale follows the export scale.
    public func retain(_ image: CGImage, source: OutputRetentionSource, backingScale: CGFloat) throws -> RetainedOutput {
        guard retainsCopies else { throw OutputRetentionError.disabled }
        let paths = preferences.outputPaths
        guard let directory = paths.outputDirectory else { throw OutputRetentionError.disabled }
        let format = preferences.exportFormat
        let exportScale = preferences.exportScale
        guard let digest = Self.digest(of: image) else { throw OutputRetentionError.encodingFailed }

        if let existing = try whileKeeping(in: directory, { try reuse(digest: digest, in: directory) }) { return existing }

        let data: Data
        do {
            data = try encode(image, format, exportScale, backingScale)
        } catch {
            throw OutputRetentionError.encodingFailed
        }

        return try whileKeeping(in: directory) {
            // Another thread may have retained the same image while this one was encoding.
            if let existing = try reuse(digest: digest, in: directory) { return existing }
            let date = now()
            let url = try Self.writeNewFile(data) { paths.outputURL(date: date, format: format) }
            let entry: Entry
            do {
                guard case .present(let stamp) = Self.probe(url), stamp.isRegularFile,
                      Self.isBareFileName(url.lastPathComponent) else {
                    throw OutputRetentionError.writeFailed("The screenshot could not be stored in the Output folder.")
                }
                entry = Entry(fileName: url.lastPathComponent, date: date, digest: digest, source: source, size: stamp.size,
                              modified: stamp.modified,
                              backingScale: Self.storedScale(exportScale, backingScale: backingScale))
                var index = Self.readIndex(in: directory)
                index.entries.removeAll { $0.fileName == entry.fileName }
                index.entries.append(entry)
                try Self.writeIndex(index, in: directory)
            } catch {
                // An untracked file could never be reopened or expire, so don't leave one behind.
                try? FileManager.default.removeItem(at: url)
                if let error = error as? OutputRetentionError { throw error }
                throw OutputRetentionError.writeFailed(error.localizedDescription)
            }
            return Self.output(for: entry, in: directory, reused: false)
        }
    }

    /// Tracks a file the pipeline already saved to the Output folder, so a later copy of the same `image` reuses it.
    /// Does nothing unless `tracksSavedOutputs` and `url` is a regular file directly inside the Output folder, and
    /// the same must still hold when the file is about to be tracked. The file itself is never touched.
    /// - Parameter backingScale: the scale of `image`, as passed to the exporter that wrote `url`.
    public func register(savedFile url: URL, image: CGImage, backingScale: CGFloat) {
        register(savedFile: url, image: image, backingScale: backingScale, exportScale: preferences.exportScale)
    }

    /// Tracks an already-saved file using the export scale captured when it was written, even if preferences
    /// changed before registration ran. All other eligibility checks still use the live preferences.
    public func register(savedFile url: URL, image: CGImage, backingScale: CGFloat, exportScale: ExportScale) {
        guard tracksSavedOutputs, let directory = preferences.outputPaths.outputDirectory,
              Self.isDirectChild(url, of: directory), Self.isBareFileName(url.lastPathComponent),
              let digest = Self.digest(of: image) else { return }
        let scale = Self.storedScale(exportScale, backingScale: backingScale)
        Self.lock.withLock {
            // Hashing takes a while, so tracking may have been turned off or the Output folder changed since.
            guard tracksSavedOutputs, isOutputFolder(directory),
                  case .present(let stamp) = Self.probe(url), stamp.isRegularFile else { return }
            var index = Self.readIndex(in: directory)
            index.entries.removeAll { $0.fileName == url.lastPathComponent }
            index.entries.append(Entry(fileName: url.lastPathComponent, date: now(), digest: digest, source: .saved,
                                       size: stamp.size, modified: stamp.modified, backingScale: scale))
            try? Self.writeIndex(index, in: directory)
        }
    }

    /// The newest tracked file that still exists in the current Output folder, ignoring symlinks and anything
    /// that is not a regular file. Entries whose file is gone are dropped from the index.
    public func latest() -> RetainedOutput? {
        guard let directory = preferences.outputPaths.outputDirectory else { return nil }
        return Self.lock.withLock {
            var index = Self.readIndex(in: directory)
            var missing = Set<String>()
            var found: Entry?
            for entry in Self.newestFirst(index.entries) {
                switch Self.probe(Self.fileURL(entry.fileName, in: directory)) {
                case .missing: missing.insert(entry.fileName)
                case .present(let stamp) where stamp.isRegularFile: found = entry
                case .present, .unavailable: break
                }
                if found != nil { break }
            }
            if !missing.isEmpty {
                index.entries.removeAll { missing.contains($0.fileName) }
                try? Self.writeIndex(index, in: directory)
            }
            return found.map { Self.output(for: $0, in: directory, reused: false) }
        }
    }

    /// Whether the index in `url`'s folder tracks it.
    public func isManaged(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        return Self.lock.withLock { Self.readIndex(in: directory).entries.contains { $0.fileName == name } }
    }

    /// Stops tracking `url`. The file itself is left alone.
    public func discard(_ url: URL) {
        guard url.isFileURL else { return }
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        Self.lock.withLock {
            var index = Self.readIndex(in: directory)
            let count = index.entries.count
            index.entries.removeAll { $0.fileName == name }
            if index.entries.count != count { try? Self.writeIndex(index, in: directory) }
        }
    }

    // MARK: - Cleanup

    /// Moves expired tracked files to the Trash. A file expires when its date is before now minus the retention
    /// period, so one exactly at the cutoff is kept. Only tracked regular files directly inside the current Output
    /// folder are considered. Files in use are skipped, and files that changed since Glint wrote them are
    /// untracked instead of deleted. A file that cannot be trashed stays tracked and is listed in `failures`.
    /// Does nothing unless `cleansUp`.
    public func cleanUp() -> OutputCleanupReport {
        var report = OutputCleanupReport()
        guard let start = cleanupTarget() else { return report }
        let expired = Self.lock.withLock {
            Self.readIndex(in: start.directory).entries.filter { $0.date < start.cutoff }.map(\.fileName)
        }
        for name in expired {
            // Each file is judged and removed under the lock on fresh state, so a concurrent `retain` that reuses
            // it, or a settings change, is respected and other callers wait for at most one Trash operation.
            let proceed = Self.lock.withLock { () -> Bool in
                guard let target = cleanupTarget(), Self.isSameFolder(target.directory, start.directory) else { return false }
                var index = Self.readIndex(in: target.directory)
                guard let position = index.entries.firstIndex(where: { $0.fileName == name }),
                      index.entries[position].date < target.cutoff else { return true }
                let entry = index.entries[position]
                let url = Self.fileURL(name, in: target.directory)

                func untrack() {
                    index.entries.remove(at: position)
                    try? Self.writeIndex(index, in: target.directory)
                }

                switch Self.probe(url) {
                case .unavailable:
                    break
                case .missing:
                    untrack()
                case .present(let stamp):
                    if stamp.isRegularFile && stamp.size == entry.size && stamp.modified == entry.modified {
                        do {
                            // The in-use check and the move are one step, so a drag cannot claim the file in between.
                            if try activeFiles.removeUnlessActive(url, { try moveToTrash(url) }) {
                                untrack()
                                report.removed.append(url)
                            } else {
                                report.skippedActive.append(url)
                            }
                        } catch {
                            report.failures.append("\(name): \(error.localizedDescription)")
                        }
                    } else if activeFiles.contains(url) {
                        report.skippedActive.append(url)
                    } else {
                        untrack()
                        report.untracked.append(url)
                    }
                }
                return true
            }
            if !proceed { break }
        }
        return report
    }

    /// Moves `url` to the user's Trash.
    public static func moveToSystemTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: - Internals

    struct Entry: Codable, Equatable {
        /// Bare name of a file directly inside the folder that holds the index.
        var fileName: String
        var date: Date
        /// SHA-256 of the image's normalised pixels and size, see `digest(of:)`.
        var digest: String
        var source: OutputRetentionSource
        /// File size and modification time (nanoseconds since 1970) as they were when Glint wrote the file.
        var size: Int64
        var modified: Int64
        var backingScale: Double
    }

    struct Index: Codable, Equatable {
        var version = OutputRetention.indexVersion
        var entries: [Entry] = []
    }

    struct FileStamp: Equatable {
        var size: Int64
        var modified: Int64
        var isRegularFile: Bool
    }

    enum FileProbe: Equatable {
        case missing
        /// Present, but not readable right now (e.g. an I/O error); never treated as gone.
        case unavailable
        case present(FileStamp)
    }

    /// Looks at `url` itself without following a symlink.
    static func probe(_ url: URL) -> FileProbe {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .missing : .unavailable }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return .present(FileStamp(size: Int64(info.st_size), modified: modified, isRegularFile: info.st_mode & S_IFMT == S_IFREG))
    }

    static func indexURL(in directory: URL) -> URL {
        directory.appendingPathComponent(indexFileName, isDirectory: false)
    }

    /// The folder's index. Missing, corrupt and newer-versioned files read as empty, entries whose name could
    /// point outside the folder are dropped, and a name listed twice keeps its last entry.
    static func readIndex(in directory: URL) -> Index {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: indexURL(in: directory)),
              let decoded = try? decoder.decode(Index.self, from: data), decoded.version == indexVersion else { return Index() }
        var entries: [Entry] = []
        var positions: [String: Int] = [:]
        for entry in decoded.entries where isBareFileName(entry.fileName) {
            if let position = positions[entry.fileName] {
                entries[position] = entry
            } else {
                positions[entry.fileName] = entries.count
                entries.append(entry)
            }
        }
        return Index(entries: entries)
    }

    static func writeIndex(_ index: Index, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(index).write(to: indexURL(in: directory), options: .atomic)
    }

    /// A plain file name: not empty, not `.` or `..`, no path separator, and not the index itself.
    static func isBareFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name != indexFileName && !name.contains("/") && !name.contains("\0")
    }

    /// SHA-256 of the image's size and its pixels normalised to sRGB RGBA8, so identical-looking images hash
    /// the same whatever their original colour space, bit layout or row padding.
    static func digest(of image: CGImage) -> String? {
        let width = image.width, height = image.height
        guard let context = GlintBitmap.makeContext(width: width, height: height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data("glint-output-pixels-1:\(width)x\(height):".utf8))
        for row in 0..<height {
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: base + row * context.bytesPerRow, count: width * 4))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Pixels per point of a file written with `scale`, matching how `Exporter` resamples.
    static func storedScale(_ scale: ExportScale, backingScale: CGFloat) -> Double {
        switch scale {
        case .original: return backingScale.isFinite && backingScale > 0 ? Double(backingScale) : 1
        case .x1: return 1
        case .x2: return 2
        }
    }

    static func normalizedPath(_ url: URL) -> String {
        normalizedFolder(url.deletingLastPathComponent()) + "/" + url.lastPathComponent
    }

    static func normalizedFolder(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func isSameFolder(_ a: URL, _ b: URL) -> Bool { normalizedFolder(a) == normalizedFolder(b) }

    static func isDirectChild(_ url: URL, of directory: URL) -> Bool {
        url.isFileURL && isSameFolder(url.deletingLastPathComponent(), directory)
    }

    /// Newest first; of two entries with the same date the one added later wins.
    private static func newestFirst(_ entries: [Entry]) -> [Entry] {
        entries.enumerated().sorted { ($0.element.date, $0.offset) > ($1.element.date, $1.offset) }.map(\.element)
    }

    /// The URL of a tracked file. It never asks the disk, so it stays the URL callers would build for the file
    /// even if something else, e.g. a folder, has since taken the name.
    private static func fileURL(_ name: String, in directory: URL) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    private static func output(for entry: Entry, in directory: URL, reused: Bool) -> RetainedOutput {
        let scale = entry.backingScale.isFinite && entry.backingScale > 0 ? entry.backingScale : 1
        return RetainedOutput(url: fileURL(entry.fileName, in: directory), date: entry.date, source: entry.source,
                              backingScale: CGFloat(scale), reused: reused)
    }

    /// The Output folder and expiry cutoff for the current preferences; nil when cleanup is off.
    private func cleanupTarget() -> (directory: URL, cutoff: Date)? {
        guard cleansUp, let days = preferences.outputRetention.days,
              let directory = preferences.outputPaths.outputDirectory else { return nil }
        return (directory, now().addingTimeInterval(-Double(days) * 86_400))
    }

    /// Whether `directory` is the Output folder in the current preferences.
    private func isOutputFolder(_ directory: URL) -> Bool {
        preferences.outputPaths.outputDirectory.map { Self.isSameFolder($0, directory) } ?? false
    }

    /// Runs `body` under the index lock if copies are still kept and `directory` is still the Output folder, and
    /// throws `.disabled` if not. Hashing and encoding take a while, so the user may have changed either meanwhile.
    private func whileKeeping<T>(in directory: URL, _ body: () throws -> T) throws -> T {
        try Self.lock.withLock {
            guard retainsCopies, isOutputFolder(directory) else { throw OutputRetentionError.disabled }
            return try body()
        }
    }

    /// Refreshes and returns the newest unchanged tracked file whose pixels match `digest`, if there is one.
    private func reuse(digest: String, in directory: URL) throws -> RetainedOutput? {
        try Self.lock.withLock {
            var index = Self.readIndex(in: directory)
            var missing = Set<String>()
            var match: Entry?
            for entry in index.entries where entry.digest == digest {
                switch Self.probe(Self.fileURL(entry.fileName, in: directory)) {
                case .missing:
                    missing.insert(entry.fileName)
                case .present(let stamp) where stamp.isRegularFile && stamp.size == entry.size && stamp.modified == entry.modified:
                    if match.map({ $0.date <= entry.date }) ?? true { match = entry }
                case .present, .unavailable:
                    break
                }
            }
            index.entries.removeAll { missing.contains($0.fileName) }
            guard var entry = match else {
                if !missing.isEmpty { try? Self.writeIndex(index, in: directory) }
                return nil
            }
            index.entries.removeAll { $0.fileName == entry.fileName }
            entry.date = now()
            index.entries.append(entry)
            do {
                try Self.writeIndex(index, in: directory)
            } catch {
                throw OutputRetentionError.writeFailed(error.localizedDescription)
            }
            return Self.output(for: entry, in: directory, reused: true)
        }
    }

    /// Writes `data` to the first unused URL that `nextURL` offers. An existing file is never replaced.
    static func writeNewFile(_ data: Data, nextURL: () -> URL?) throws -> URL {
        guard var url = nextURL() else { throw OutputRetentionError.disabled }
        let fileManager = FileManager.default
        let staging = url.deletingLastPathComponent().appendingPathComponent(".glint-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try data.write(to: staging)
            // `moveItem` refuses to replace an existing file, e.g. one the pipeline saved a moment ago.
            for _ in 0..<5 {
                do {
                    try fileManager.moveItem(at: staging, to: url)
                    return url
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    guard let next = nextURL() else { throw OutputRetentionError.disabled }
                    url = next
                }
            }
        } catch let error as OutputRetentionError {
            throw error
        } catch {
            throw OutputRetentionError.writeFailed(error.localizedDescription)
        }
        throw OutputRetentionError.writeFailed("No unused file name was available in the Output folder.")
    }
}
