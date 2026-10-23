import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

private struct TrashRefused: LocalizedError {
    var errorDescription: String? { "Trash refused" }
}

private enum FixtureError: Error { case unreadable(URL) }

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result { lock.withLock { body(&value) } }
}

/// A clock the tests move by hand.
private final class TestClock: @unchecked Sendable {
    private let date = Box(Date(timeIntervalSince1970: 1_790_000_000))
    var now: Date { date.withValue { $0 } }
    func advance(_ seconds: TimeInterval) { date.withValue { $0 = $0.addingTimeInterval(seconds) } }
}

/// Stands in for the Trash: moves files into a fixture folder, or refuses on request. Never touches the real Trash.
private final class FakeTrash: @unchecked Sendable {
    private struct State {
        var refused: Set<String> = []
        var moved: [URL] = []
        var afterEach: (@Sendable () -> Void)?
    }

    private let folder: URL
    private let state = Box(State())

    init(folder: URL) { self.folder = folder }

    var trashed: [URL] { state.withValue { $0.moved } }
    func refuse(_ name: String) { state.withValue { _ = $0.refused.insert(name) } }
    func allow(_ name: String) { state.withValue { _ = $0.refused.remove(name) } }
    func afterEachTrash(_ action: @escaping @Sendable () -> Void) { state.withValue { $0.afterEach = action } }

    func move(_ url: URL) throws {
        let (isRefused, count, action) = state.withValue { ($0.refused.contains(url.lastPathComponent), $0.moved.count, $0.afterEach) }
        if isRefused { throw TrashRefused() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("\(count)-\(url.lastPathComponent)"))
        state.withValue { $0.moved.append(url) }
        action?()
    }
}

/// Wraps a fake Trash so the first move stops half way, until the test lets it go.
private final class StallingTrash: @unchecked Sendable {
    /// Signalled once the first move has started and is waiting.
    let stalled = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)
    private let trash: FakeTrash
    private let isFirst = Box(true)

    init(_ trash: FakeTrash) { self.trash = trash }

    func move(_ url: URL) throws {
        if isFirst.withValue({ let first = $0; $0 = false; return first }) {
            stalled.signal()
            _ = proceed.wait(timeout: .now() + 30)
        }
        try trash.move(url)
    }

    func resume() { proceed.signal() }
}

/// How a tracked file can change behind Glint's back.
enum RetentionChange: CaseIterable {
    case grown, touched, deleted, symlinked, directory
}

/// Ways the same pixels can be laid out in memory.
enum RetentionPixelLayout: CaseIterable {
    case rgbaPremultiplied, bgraPremultiplied, rgbxOpaque, paddedRows

    var bitmapInfo: UInt32 {
        switch self {
        case .rgbaPremultiplied, .paddedRows:
            return CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        case .bgraPremultiplied:
            return CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        case .rgbxOpaque:
            return CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        }
    }
}

/// What happens while a cleanup run is moving files.
enum RetentionMidRunChange: CaseIterable {
    case historyTurnedOff, retentionSetToForever, folderChanged
}

/// A settings change the user can make while an image is still being stored.
enum RetentionRevocation: CaseIterable {
    case keepingTurnedOff, historyTurnedOff, outputFolderChanged
}

/// Files `register(savedFile:)` must not track.
enum RetentionIneligibleFile: CaseIterable {
    case manualFolder, rawFolder, subfolder, symlink, directory, missing
}

private func isWriteFailure(_ error: any Error) -> Bool {
    if case OutputRetentionError.writeFailed = error { return true }
    return false
}

private struct EncoderFailed: Error {}

/// Runs `body` on a thread of its own, so a busy dispatch pool can't keep it from starting. Tests that hold the
/// index lock while they wait for another thread rely on that.
private final class BackgroundThread: @unchecked Sendable {
    private let group = DispatchGroup()

    init(_ body: @escaping @Sendable () -> Void) {
        let group = group
        group.enter()
        Thread {
            body()
            group.leave()
        }.start()
    }

    /// Whether `body` has finished, waiting up to `seconds` for it.
    func finishes(within seconds: Double = 10) -> Bool { group.wait(timeout: .now() + seconds) == .success }
}

/// Whether `begin` returns, instead of waiting on something that never finishes.
private func beginsPromptly(_ active: OutputActiveFiles, _ url: URL) -> Bool {
    BackgroundThread { active.begin(url) }.finishes()
}

/// Pixels that report the first time anything reads them, so a test can act at that exact moment.
private final class ObservedPixels {
    private let bytes: UnsafeMutableRawBufferPointer
    private let onFirstRead: @Sendable () -> Void
    private let wasRead = Box(false)

    init(_ pixels: [UInt8], onFirstRead: @escaping @Sendable () -> Void) {
        bytes = .allocate(byteCount: pixels.count, alignment: 1)
        bytes.copyBytes(from: pixels)
        self.onFirstRead = onFirstRead
    }

    deinit { bytes.deallocate() }

    var baseAddress: UnsafeRawPointer {
        noteRead()
        return UnsafeRawPointer(bytes.baseAddress!)
    }

    func copy(to buffer: UnsafeMutableRawPointer, from position: Int, count: Int) -> Int {
        noteRead()
        let available = max(0, min(count, bytes.count - position))
        buffer.copyMemory(from: bytes.baseAddress! + position, byteCount: available)
        return available
    }

    private func noteRead() {
        if wasRead.withValue({ let was = $0; $0 = true; return !was }) { onFirstRead() }
    }
}

/// A solid image that calls `onFirstRead` the first time its pixels are read.
private func makeObservedImage(width: Int, height: Int, red8: UInt8, green8: UInt8, blue8: UInt8,
                               onFirstRead: @escaping @Sendable () -> Void) -> CGImage {
    let pixels = Array([[UInt8]](repeating: [red8, green8, blue8, 255], count: width * height).joined())
    var callbacks = CGDataProviderDirectCallbacks(
        version: 0,
        getBytePointer: { info in Unmanaged<ObservedPixels>.fromOpaque(info!).takeUnretainedValue().baseAddress },
        releaseBytePointer: { _, _ in },
        getBytesAtPosition: { info, buffer, position, count in
            Unmanaged<ObservedPixels>.fromOpaque(info!).takeUnretainedValue().copy(to: buffer, from: Int(position), count: count)
        },
        releaseInfo: { info in Unmanaged<ObservedPixels>.fromOpaque(info!).release() })
    let info = Unmanaged.passRetained(ObservedPixels(pixels, onFirstRead: onFirstRead)).toOpaque()
    let provider = CGDataProvider(directInfo: info, size: Int64(pixels.count), callbacks: &callbacks)!
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: ColorSpaces.sRGB, bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)!
}

/// Runs `retain` on another thread and holds the index lock on this one until `revoke` has run. The retain is
/// stopped inside its encoder first, so it has passed every check made before it needs the lock.
private func retainWhileHoldingTheIndexLock(_ f: RetentionFixture, revoking revoke: (@Sendable () -> Void)?) throws
    -> Result<RetainedOutput, any Error> {
    let encoding = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
    let retention = f.makeRetention(encode: { image, format, scale, backingScale in
        encoding.signal()
        _ = proceed.wait(timeout: .now() + 10)
        return try Exporter.data(for: image, format: format, scale: scale, backingScale: backingScale)
    })
    let image = f.image(1)
    let outcome = Box<Result<RetainedOutput, any Error>?>(nil)
    let thread = BackgroundThread {
        outcome.withValue { $0 = Result { try retention.retain(image, source: .copied, backingScale: 2) } }
    }
    try #require(encoding.wait(timeout: .now() + 10) == .success)

    OutputRetention.lock.lock()
    proceed.signal()
    // The retain can't get past the lock, so whatever it checked before waiting is already out of date.
    Thread.sleep(forTimeInterval: 0.15)
    revoke?()
    OutputRetention.lock.unlock()

    try #require(thread.finishes())
    return try #require(outcome.withValue { $0 })
}

/// The same for `register`, stopped while it hashes the image.
private func registerWhileHoldingTheIndexLock(_ f: RetentionFixture, saved: URL, revoking revoke: (@Sendable () -> Void)?) throws {
    let hashing = DispatchSemaphore(value: 0)
    let image = f.observedImage(1) { hashing.signal() }
    let retention = f.retention

    OutputRetention.lock.lock()
    let thread = BackgroundThread { retention.register(savedFile: saved, image: image, backingScale: 2) }
    let hashed = hashing.wait(timeout: .now() + 10) == .success
    Thread.sleep(forTimeInterval: 0.15)
    revoke?()
    OutputRetention.lock.unlock()

    try #require(hashed)
    try #require(thread.finishes())
}

private func patternImage(layout: RetentionPixelLayout, changingLastPixel: Bool = false) -> CGImage {
    let width = 9, height = 5
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: layout == .paddedRows ? width * 4 + 36 : 0,
                            space: ColorSpaces.sRGB, bitmapInfo: layout.bitmapInfo)!
    for x in 0..<width {
        context.setFillColor(RGBAColor(red8: UInt8(x * 25), green8: UInt8(250 - x * 20), blue8: 77).cgColor)
        context.fill(CGRect(x: x, y: 0, width: 1, height: height))
    }
    if changingLastPixel {
        context.setFillColor(RGBAColor(red8: 1, green8: 2, blue8: 3).cgColor)
        context.fill(CGRect(x: width - 1, y: height - 1, width: 1, height: 1))
    }
    return context.makeImage()!
}

/// A history folder, preferences suite, clock and fake Trash that live under `.build/TestFixtures`.
private final class RetentionFixture {
    let root: URL
    let history: URL
    let defaults: UserDefaults
    let preferences: AppPreferences
    let clock: TestClock
    let trash: FakeTrash
    let active: OutputActiveFiles
    let retention: OutputRetention
    private let suite: String

    /// A nil `keepCopies` or `period` leaves that preference at its default.
    init(keepCopies: Bool? = true, period: OutputRetentionPeriod? = nil) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/TestFixtures/\(UUID().uuidString)")
        let history = root.appendingPathComponent("History")
        let suite = "glint.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let preferences = AppPreferences(defaults: defaults)
        preferences.historyDirectory = history
        preferences.saveDirectory = root.appendingPathComponent("Manual")
        if let keepCopies { preferences.keepCopiedImages = keepCopies }
        if let period { preferences.outputRetention = period }
        let clock = TestClock()
        let trash = FakeTrash(folder: root.appendingPathComponent("FakeTrash"))
        let active = OutputActiveFiles()
        self.root = root
        self.history = history
        self.suite = suite
        self.defaults = defaults
        self.preferences = preferences
        self.clock = clock
        self.trash = trash
        self.active = active
        retention = OutputRetention(preferences: preferences, now: { clock.now }, moveToTrash: { try trash.move($0) },
                                    activeFiles: active)
    }

    var output: URL { history.appendingPathComponent("Output") }
    var raw: URL { history.appendingPathComponent("Raw") }
    var manual: URL { root.appendingPathComponent("Manual") }
    var outside: URL { root.appendingPathComponent("Outside") }
    /// A history folder the settings can be moved to; nothing is created there unless Glint writes to it.
    var elsewhere: URL { root.appendingPathComponent("Elsewhere") }
    var indexURL: URL { OutputRetention.indexURL(in: output) }
    var indexBytes: Data? { try? Data(contentsOf: indexURL) }
    var entries: [OutputRetention.Entry] { OutputRetention.readIndex(in: output).entries }
    var entryNames: [String] { entries.map(\.fileName) }

    /// Everything directly in Output except the index, hidden staging files included.
    var outputFiles: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
        return names.filter { $0 != OutputRetention.indexFileName }.sorted()
    }

    /// Index files anywhere under the fixture.
    var indexFiles: [String] {
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return walker.compactMap { $0 as? String }.filter { $0.hasSuffix(OutputRetention.indexFileName) }
    }

    func image(_ seed: Int, width: Int = 24, height: Int = 16) -> CGImage {
        TestImages.solid(width, height, RGBAColor(red8: UInt8(seed % 256), green8: UInt8(seed / 256 % 256), blue8: 90))
    }

    /// The same pixels as `image(seed)`, reporting the first time they are read.
    func observedImage(_ seed: Int, width: Int = 24, height: Int = 16, onFirstRead: @escaping @Sendable () -> Void) -> CGImage {
        makeObservedImage(width: width, height: height, red8: UInt8(seed % 256), green8: UInt8(seed / 256 % 256), blue8: 90,
                          onFirstRead: onFirstRead)
    }

    /// Another pipeline over the same preferences, clock and Trash, with its own Trash or image encoder.
    func makeRetention(moveToTrash: (@Sendable (URL) throws -> Void)? = nil,
                       encode: (@Sendable (CGImage, ExportFormat, ExportScale, CGFloat) throws -> Data)? = nil) -> OutputRetention {
        let clock = clock, trash = trash
        return OutputRetention(preferences: preferences, now: { clock.now }, moveToTrash: moveToTrash ?? { try trash.move($0) },
                               activeFiles: active,
                               encode: encode ?? { try Exporter.data(for: $0, format: $1, scale: $2, backingScale: $3) })
    }

    /// Makes `change` happen when called.
    func revocation(_ change: RetentionRevocation) -> @Sendable () -> Void {
        let preferences = preferences, elsewhere = elsewhere
        return {
            switch change {
            case .keepingTurnedOff: preferences.keepCopiedImages = false
            case .historyTurnedOff: preferences.saveHistory = false
            case .outputFolderChanged: preferences.historyDirectory = elsewhere
            }
        }
    }

    func retain(_ image: CGImage, source: OutputRetentionSource = .copied, backingScale: CGFloat = 2) throws -> RetainedOutput {
        try retention.retain(image, source: source, backingScale: backingScale)
    }

    func age(days: Double) -> Date { clock.now.addingTimeInterval(-days * 86_400) }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func isRegularFile(_ url: URL) -> Bool {
        if case .present(let stamp) = OutputRetention.probe(url) { return stamp.isRegularFile }
        return false
    }

    /// Writes a file and lists it in the index of `folder` (Output by default) as Glint would have.
    @discardableResult
    func track(_ name: String, at date: Date, in folder: URL? = nil, source: OutputRetentionSource = .copied,
               digest: String? = nil, backingScale: Double = 2, bytes: Int = 16) throws -> URL {
        let directory = folder ?? output
        let url = try plant(name, in: directory, bytes: bytes)
        guard case .present(let stamp) = OutputRetention.probe(url) else { throw FixtureError.unreadable(url) }
        var index = OutputRetention.readIndex(in: directory)
        index.entries.removeAll { $0.fileName == name }
        index.entries.append(OutputRetention.Entry(fileName: name, date: date, digest: digest ?? "digest-\(name)", source: source,
                                                   size: stamp.size, modified: stamp.modified, backingScale: backingScale))
        try OutputRetention.writeIndex(index, in: directory)
        return url
    }

    /// Writes a file Glint knows nothing about.
    @discardableResult
    func plant(_ name: String, in folder: URL? = nil, bytes: Int = 8, modified: Date? = nil) throws -> URL {
        let directory = folder ?? output
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x33, count: bytes).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    func writeRawIndex(_ text: String) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: indexURL)
    }

    func apply(_ change: RetentionChange, to url: URL) throws {
        let fileManager = FileManager.default
        switch change {
        case .grown:
            let grown = try Data(contentsOf: url) + Data([0])
            try grown.write(to: url)
        case .touched:
            try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: url.path)
        case .deleted:
            try fileManager.removeItem(at: url)
        case .symlinked:
            let target = try plant("target.bin", in: outside)
            try fileManager.removeItem(at: url)
            try fileManager.createSymbolicLink(at: url, withDestinationURL: target)
        case .directory:
            try fileManager.removeItem(at: url)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        }
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Output retention")
struct OutputRetentionTests {
    // MARK: - Opt-in switches

    @Test func isOffAndSideEffectFreeByDefault() throws {
        let f = try RetentionFixture(keepCopies: nil); defer { f.tearDown() }
        #expect(!f.preferences.keepCopiedImages && f.preferences.outputRetention == .forever)
        #expect(!f.retention.retainsCopies && !f.retention.tracksSavedOutputs && !f.retention.cleansUp)

        #expect(throws: OutputRetentionError.disabled) { try f.retain(f.image(1)) }
        f.retention.register(savedFile: f.output.appendingPathComponent("saved.png"), image: f.image(1), backingScale: 2)
        #expect(f.retention.latest() == nil)
        #expect(f.retention.cleanUp().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.history.path))
        #expect(f.defaults.object(forKey: AppPreferences.Key.keepCopiedImages) == nil)
        #expect(f.defaults.object(forKey: AppPreferences.Key.outputRetentionDays) == nil)

        // The default Trash and in-use list are only needed once cleanup has something to remove.
        let plain = OutputRetention(preferences: f.preferences)
        #expect(!plain.cleansUp && plain.cleanUp().isEmpty)
    }

    @Test func switchesFollowTheThreePreferences() throws {
        let f = try RetentionFixture(keepCopies: nil); defer { f.tearDown() }
        for history in [true, false] {
            for keep in [true, false] {
                for period in OutputRetentionPeriod.allCases {
                    f.preferences.saveHistory = history
                    f.preferences.keepCopiedImages = keep
                    f.preferences.outputRetention = period
                    let state = "history \(history), keep \(keep), \(period.displayName)"
                    #expect(f.retention.retainsCopies == (history && keep), "\(state)")
                    #expect(f.retention.tracksSavedOutputs == (history && (keep || period != .forever)), "\(state)")
                    #expect(f.retention.cleansUp == (history && period != .forever), "\(state)")
                }
            }
        }
    }

    @Test func pausesWithoutHistoryAndNeverTurnsItBackOn() throws {
        let f = try RetentionFixture(period: .oneDay); defer { f.tearDown() }
        let kept = try f.retain(f.image(1))
        let old = try f.track("old.png", at: f.age(days: 3))
        let before = f.indexBytes

        f.preferences.saveHistory = false
        #expect(!f.retention.retainsCopies && !f.retention.tracksSavedOutputs && !f.retention.cleansUp)
        #expect(throws: OutputRetentionError.disabled) { try f.retain(f.image(2), source: .dragged) }
        f.retention.register(savedFile: try f.plant("saved.png"), image: f.image(2), backingScale: 2)
        #expect(f.retention.latest() == nil)
        #expect(f.retention.cleanUp().isEmpty)
        #expect(f.exists(kept.url) && f.exists(old) && f.trash.trashed.isEmpty)
        #expect(f.indexBytes == before)
        #expect(!f.preferences.saveHistory)

        f.preferences.saveHistory = true
        #expect(f.retention.latest()?.url == kept.url)
        #expect(f.retention.cleanUp().removed == [old])
    }

    @Test func latestStaysAvailableWhenKeepingIsTurnedOff() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let kept = try f.retain(f.image(1))
        f.preferences.keepCopiedImages = false

        #expect(f.retention.latest()?.url == kept.url)
        #expect(f.retention.isManaged(kept.url))
        #expect(throws: OutputRetentionError.disabled) { try f.retain(f.image(2)) }
        #expect(f.outputFiles == [kept.url.lastPathComponent])
    }

    // MARK: - Retaining

    @Test func retainsTheComposedImageAndSurvivesARestart() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let source = TestImages.framed(width: 40, height: 30, margins: EdgeMargins(top: 3, left: 3, bottom: 3, right: 3))

        let out = try f.retain(source, source: .copied, backingScale: 2)

        #expect(out.url.deletingLastPathComponent().path == f.output.path)
        #expect(out.url.lastPathComponent == "Glint-\(FileNaming.datetime(f.clock.now)).png")
        #expect(out.date == f.clock.now && out.source == .copied && out.backingScale == 2 && !out.reused)
        let reloaded = try #require(GlintImageIO.load(url: out.url))
        #expect(OutputRetention.digest(of: reloaded) == OutputRetention.digest(of: source))
        let bytes = try Data(contentsOf: out.url)
        let entry = try #require(f.entries.first)
        #expect(f.entries.count == 1 && entry.fileName == out.url.lastPathComponent && entry.source == .copied)
        #expect(entry.digest == OutputRetention.digest(of: source) && entry.backingScale == 2)
        #expect(entry.size == Int64(bytes.count))
        #expect(f.outputFiles == [out.url.lastPathComponent])

        let restarted = OutputRetention(preferences: AppPreferences(defaults: f.defaults), moveToTrash: { _ in })
        #expect(restarted.latest() == RetainedOutput(url: out.url, date: out.date, source: .copied, backingScale: 2))
    }

    @Test func retainedFileUsesTheExportFormatAndNaming() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        f.preferences.exportFormat = .jpeg(quality: 0.8)
        f.preferences.fileNameTemplate = "Shot-{datetime}"

        let out = try f.retain(f.image(7), source: .dragged)

        #expect(out.url.lastPathComponent == "Shot-\(FileNaming.datetime(f.clock.now)).jpg")
        #expect(Array(try Data(contentsOf: out.url).prefix(2)) == [0xFF, 0xD8])
        #expect(out.source == .dragged)
    }

    @Test(arguments: ExportScale.allCases)
    func retainedFileFollowsTheExportScale(scale: ExportScale) throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        f.preferences.exportScale = scale

        let out = try f.retain(f.image(9, width: 300, height: 150), source: .copied, backingScale: 3)

        let stored = try #require(GlintImageIO.load(url: out.url))
        let expected: (width: Int, height: Int, scale: CGFloat)
        switch scale {
        case .original: expected = (300, 150, 3)
        case .x1: expected = (100, 50, 1)
        case .x2: expected = (200, 100, 2)
        }
        #expect(stored.width == expected.width && stored.height == expected.height)
        #expect(out.backingScale == expected.scale)
        #expect(f.entries.first?.backingScale == Double(expected.scale))
    }

    @Test func storedScaleMatchesHowTheExporterResamples() {
        #expect(OutputRetention.storedScale(.original, backingScale: 3) == 3)
        #expect(OutputRetention.storedScale(.original, backingScale: 1.5) == 1.5)
        for unusable in [0, -2, .nan, .infinity] as [CGFloat] {
            #expect(OutputRetention.storedScale(.original, backingScale: unusable) == 1)
        }
        #expect(OutputRetention.storedScale(.x1, backingScale: 3) == 1)
        #expect(OutputRetention.storedScale(.x2, backingScale: 1) == 2)
    }

    @Test func neverOverwritesAFileAlreadyInOutput() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let taken = try f.plant("Glint-\(FileNaming.datetime(f.clock.now)).png", bytes: 12)
        let before = try Data(contentsOf: taken)

        let out = try f.retain(f.image(1))

        #expect(out.url.lastPathComponent == "Glint-\(FileNaming.datetime(f.clock.now))-2.png")
        #expect(try Data(contentsOf: taken) == before)
        #expect(f.entryNames == [out.url.lastPathComponent])
    }

    @Test func failsCleanlyWhenTheOutputFolderCannotBeUsed() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        try FileManager.default.createDirectory(at: f.history, withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: f.output)

        #expect { try f.retain(f.image(1)) } throws: { isWriteFailure($0) }
        #expect(try Data(contentsOf: f.output) == Data("not a folder".utf8))
        #expect(f.retention.latest() == nil)
        #expect(f.retention.cleanUp().isEmpty)
    }

    @Test func leavesNoOrphanFileWhenTheIndexCannotBeWritten() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        // A folder squatting on the index name makes every index write fail.
        try FileManager.default.createDirectory(at: f.indexURL, withIntermediateDirectories: true)

        #expect { try f.retain(f.image(1)) } throws: { isWriteFailure($0) }
        #expect(f.outputFiles.isEmpty)
        #expect(f.retention.latest() == nil)
    }

    // MARK: - Duplicate avoidance

    @Test func reusesAnUnchangedFileInsteadOfWritingAnother() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let first = try f.retain(f.image(1), source: .copied)
        let bytes = try Data(contentsOf: first.url)

        f.clock.advance(60)
        let again = try f.retain(f.image(1), source: .dragged)

        #expect(again.reused && again.url == first.url && again.source == .copied)
        #expect(again.date == f.clock.now && again.backingScale == first.backingScale)
        #expect(f.outputFiles == [first.url.lastPathComponent])
        #expect(f.entries.map(\.date) == [f.clock.now])
        #expect(try Data(contentsOf: first.url) == bytes)

        f.clock.advance(1)
        let other = try f.retain(f.image(2), source: .dragged)
        #expect(!other.reused && other.url != first.url && other.source == .dragged)
        #expect(f.outputFiles.count == 2)
        #expect(f.retention.latest()?.url == other.url)

        f.clock.advance(1)
        #expect(try f.retain(f.image(1)).url == first.url)
        #expect(f.retention.latest()?.url == first.url)
    }

    @Test func reuseIgnoresALaterChangeOfExportFormat() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let first = try f.retain(f.image(1))
        f.preferences.exportFormat = .jpeg(quality: 0.5)
        f.preferences.exportScale = .x1

        let again = try f.retain(f.image(1))

        #expect(again.reused && again.url == first.url && again.backingScale == first.backingScale)
        #expect(f.outputFiles == [first.url.lastPathComponent])
    }

    @Test(arguments: RetentionChange.allCases)
    func doesNotReuseAFileThatChanged(change: RetentionChange) throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let first = try f.retain(f.image(1))
        try f.apply(change, to: first.url)

        f.clock.advance(5)
        let second = try f.retain(f.image(1))

        #expect(!second.reused && second.url != first.url && f.isRegularFile(second.url))
        let firstName = first.url.lastPathComponent, secondName = second.url.lastPathComponent
        // A deleted file's entry is pruned; the others stay tracked beside the new file.
        #expect(f.entryNames == (change == .deleted ? [secondName] : [firstName, secondName]))
    }

    @Test func reusePrefersTheNewestUnchangedMatch() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let image = f.image(1)
        let digest = try #require(OutputRetention.digest(of: image))
        let older = try f.track("older.png", at: f.age(days: 2), digest: digest)
        let newer = try f.track("newer.png", at: f.age(days: 1), digest: digest)

        #expect(try f.retain(image).url == newer)

        try f.apply(.grown, to: newer)
        let fallback = try f.retain(image)
        #expect(fallback.reused && fallback.url == older)
    }

    @Test(arguments: RetentionPixelLayout.allCases)
    func digestIgnoresPixelLayout(layout: RetentionPixelLayout) throws {
        let reference = try #require(OutputRetention.digest(of: patternImage(layout: .rgbaPremultiplied)))
        #expect(reference.count == 64 && reference.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(OutputRetention.digest(of: patternImage(layout: layout)) == reference)
        #expect(OutputRetention.digest(of: patternImage(layout: layout, changingLastPixel: true)) != reference)
    }

    @Test func digestSeparatesImagesWithTheSamePixelsInDifferentShapes() {
        let color = RGBAColor(red8: 10, green8: 20, blue8: 30)
        let digests = [(8, 4), (4, 8), (2, 16), (16, 2)].map { OutputRetention.digest(of: TestImages.solid($0.0, $0.1, color)) }
        #expect(Set(digests).count == 4 && !digests.contains(nil))
        #expect(OutputRetention.digest(of: TestImages.solid(8, 4, color)) == digests[0])
    }

    // MARK: - Latest

    @Test func latestIsTheNewestTrackedFile() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        #expect(f.retention.latest() == nil)
        try f.track("a.png", at: f.age(days: 3), source: .copied, backingScale: 2)
        let b = try f.track("b.png", at: f.age(days: 1), source: .dragged, backingScale: 3)
        try f.track("c.png", at: f.age(days: 2), source: .saved, backingScale: 1)

        #expect(f.retention.latest() == RetainedOutput(url: b, date: f.age(days: 1), source: .dragged, backingScale: 3))

        let tie = f.age(days: 0)
        try f.track("t1.png", at: tie)
        let t2 = try f.track("t2.png", at: tie)
        #expect(f.retention.latest()?.url == t2)
    }

    @Test func latestDropsEntriesWhoseFileIsGone() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let a = try f.track("a.png", at: f.age(days: 3))
        let b = try f.track("b.png", at: f.age(days: 1))
        try FileManager.default.removeItem(at: b)

        #expect(f.retention.latest()?.url == a)
        #expect(f.entryNames == ["a.png"])

        try FileManager.default.removeItem(at: a)
        #expect(f.retention.latest() == nil)
        #expect(f.entries.isEmpty)
    }

    @Test func latestSkipsSymlinksAndFoldersButKeepsTheirEntries() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let good = try f.track("good.png", at: f.age(days: 3))
        let link = try f.track("link.png", at: f.age(days: 2))
        let folder = try f.track("folder.png", at: f.age(days: 1))
        try f.apply(.symlinked, to: link)
        try f.apply(.directory, to: folder)

        #expect(f.retention.latest()?.url == good)
        #expect(f.entryNames == ["good.png", "link.png", "folder.png"])

        try FileManager.default.removeItem(at: good)
        #expect(f.retention.latest() == nil)
    }

    @Test func latestFollowsTheOutputFolder() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let historyB = f.root.appendingPathComponent("HistoryB")
        let a = try f.track("a.png", at: f.age(days: 1))
        let b = try f.track("b.png", at: f.age(days: 2), in: historyB.appendingPathComponent("Output"))
        #expect(f.retention.latest()?.url == a)

        f.preferences.historyDirectory = historyB
        #expect(f.retention.latest()?.url == b)

        f.preferences.historyDirectory = f.root.appendingPathComponent("HistoryEmpty")
        #expect(f.retention.latest() == nil)
        #expect(!f.exists(f.root.appendingPathComponent("HistoryEmpty")))
    }

    @Test func latestFallsBackToOneForAnUnusableScale() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        try f.track("zero.png", at: f.age(days: 2), backingScale: 0)
        #expect(f.retention.latest()?.backingScale == 1)
        try f.track("negative.png", at: f.age(days: 1), backingScale: -2)
        #expect(f.retention.latest()?.backingScale == 1)
    }

    @Test func isManagedAndDiscardUseTheFilesOwnFolder() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let tracked = try f.track("tracked.png", at: f.age(days: 0))
        let untracked = try f.plant("untracked.png")
        let oldOutput = f.root.appendingPathComponent("OldHistory/Output")
        let inOldFolder = try f.track("old.png", at: f.age(days: 5), in: oldOutput)

        #expect(f.retention.isManaged(tracked) && f.retention.isManaged(inOldFolder))
        #expect(!f.retention.isManaged(untracked))
        #expect(!f.retention.isManaged(f.root.appendingPathComponent("Elsewhere/tracked.png")))
        #expect(!f.retention.isManaged(URL(string: "https://example.com/tracked.png")!))

        let before = f.indexBytes
        f.retention.discard(untracked)
        f.retention.discard(f.root.appendingPathComponent("Nowhere/x.png"))
        #expect(f.indexBytes == before && !f.exists(f.root.appendingPathComponent("Nowhere")))

        f.retention.discard(tracked)
        #expect(!f.retention.isManaged(tracked) && f.exists(tracked) && f.entries.isEmpty)
        #expect(f.retention.isManaged(inOldFolder))
    }

    // MARK: - The index

    @Test func indexIsHiddenVersionedJSONInsideOutput() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let out = try f.retain(f.image(1), source: .dragged)

        #expect(f.indexURL.lastPathComponent == ".glint-output-index.json")
        #expect(f.indexFiles == ["History/Output/.glint-output-index.json"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.indexURL)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        let entries = try #require(object["entries"] as? [[String: Any]])
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(Set(entry.keys) == ["fileName", "date", "digest", "source", "size", "modified", "backingScale"])
        #expect(entry["fileName"] as? String == out.url.lastPathComponent)
        #expect(entry["source"] as? String == "dragged")
        #expect(entry["date"] as? Double == f.clock.now.timeIntervalSince1970)
        #expect((entry["digest"] as? String)?.count == 64)
        #expect(f.outputFiles == [out.url.lastPathComponent])
    }

    @Test(arguments: [
        "", "not json {", "null", "[]", "{}", #"{"version":1}"#, #"{"version":"1","entries":[]}"#,
        #"{"version":1,"entries":[{"fileName":"victim.png"}]}"#, #"{"version":0,"entries":[]}"#, #"{"version":2,"entries":[]}"#,
    ])
    func anUnreadableIndexReadsAsEmptyAndNeverDeletes(content: String) throws {
        let f = try RetentionFixture(period: .oneDay); defer { f.tearDown() }
        let victim = try f.plant("victim.png", modified: Date(timeIntervalSince1970: 1_000_000_000))
        try f.writeRawIndex(content)
        let before = f.indexBytes

        #expect(f.retention.latest() == nil)
        #expect(!f.retention.isManaged(victim))
        #expect(f.retention.cleanUp().isEmpty)
        f.retention.discard(victim)

        #expect(f.exists(victim) && f.trash.trashed.isEmpty)
        #expect(f.indexBytes == before)
    }

    @Test func aNewerIndexVersionIsNeverUsedToDelete() throws {
        let f = try RetentionFixture(period: .oneDay); defer { f.tearDown() }
        let victim = try f.track("victim.png", at: f.age(days: 30))
        var index = OutputRetention.readIndex(in: f.output)
        index.version = OutputRetention.indexVersion + 1
        try OutputRetention.writeIndex(index, in: f.output)
        let before = f.indexBytes

        #expect(f.retention.cleanUp().isEmpty)
        #expect(f.retention.latest() == nil && !f.retention.isManaged(victim))
        #expect(f.exists(victim) && f.indexBytes == before)
    }

    @Test func retainReplacesAnUnreadableIndex() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        try f.writeRawIndex("not json {")

        let out = try f.retain(f.image(1))

        #expect(f.entryNames == [out.url.lastPathComponent])
        #expect(f.retention.latest()?.url == out.url)
    }

    @Test func entriesThatEscapeTheOutputFolderAreIgnored() throws {
        let f = try RetentionFixture(period: .oneDay); defer { f.tearDown() }
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        let victims = [
            try f.plant("victim.png", in: f.history, modified: old),
            try f.plant("raw.png", in: f.raw, modified: old),
            try f.plant("inner.png", in: f.output.appendingPathComponent("sub"), modified: old),
        ]
        let ok = try f.track("ok.png", at: f.age(days: 3))
        func entry(_ name: String) -> OutputRetention.Entry {
            OutputRetention.Entry(fileName: name, date: old, digest: "d", source: .copied, size: 8, modified: 0, backingScale: 1)
        }
        var index = OutputRetention.readIndex(in: f.output)
        index.entries += ["../victim.png", "../Raw/raw.png", "sub/inner.png", "..", ".", "", "/abs.png", "a\0b.png",
                          OutputRetention.indexFileName].map(entry)
        try OutputRetention.writeIndex(index, in: f.output)

        #expect(f.entryNames == ["ok.png"])
        #expect(f.retention.latest()?.url == ok)
        let report = f.retention.cleanUp()
        #expect(report.removed == [ok] && report.untracked.isEmpty && report.failures.isEmpty)
        for url in victims { #expect(f.exists(url), "\(url.lastPathComponent)") }
    }

    @Test func aTwiceListedNameKeepsItsLastEntry() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let url = try f.track("twice.png", at: f.age(days: 3), source: .copied)
        var index = OutputRetention.readIndex(in: f.output)
        var later = try #require(index.entries.first)
        later.source = .dragged
        later.date = f.age(days: 1)
        index.entries.append(later)
        try OutputRetention.writeIndex(index, in: f.output)

        #expect(f.entries == [later])
        #expect(f.retention.latest() == RetainedOutput(url: url, date: later.date, source: .dragged, backingScale: 2))
    }

    @Test(arguments: ["a.png", "a..b.png", "..hidden", ".hidden", "Glint 2026-10-21 15.04.05.png", "é.png"])
    func ordinaryFileNamesAreBare(name: String) {
        #expect(OutputRetention.isBareFileName(name))
    }

    @Test(arguments: ["", ".", "..", "../x.png", "a/b.png", "/abs.png", "x\0y.png", ".glint-output-index.json"])
    func pathLikeFileNamesAreNotBare(name: String) {
        #expect(!OutputRetention.isBareFileName(name))
    }

    @Test func aNameTooLongToLookUpIsNeverTreatedAsGone() throws {
        let f = try RetentionFixture(period: .oneDay); defer { f.tearDown() }
        let name = String(repeating: "a", count: 300) + ".png"
        try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: true)
        #expect(OutputRetention.probe(f.output.appendingPathComponent(name)) == .unavailable)

        var index = OutputRetention.Index()
        index.entries = [OutputRetention.Entry(fileName: name, date: f.age(days: 9), digest: "d", source: .copied, size: 1,
                                               modified: 0, backingScale: 1)]
        try OutputRetention.writeIndex(index, in: f.output)

        #expect(f.retention.cleanUp().isEmpty)
        #expect(f.retention.latest() == nil)
        #expect(f.entryNames == [name])
    }

    // MARK: - Registering files the pipeline saved

    @Test func registerTracksAFileThePipelineSavedSoACopyReusesIt() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let saved = try f.plant("Glint-saved.png", bytes: 32)

        f.retention.register(savedFile: saved, image: f.image(4), backingScale: 2)

        let entry = try #require(f.entries.first)
        #expect(f.entries.count == 1 && entry.fileName == "Glint-saved.png" && entry.source == .saved)
        #expect(entry.digest == OutputRetention.digest(of: f.image(4)) && entry.date == f.clock.now)
        #expect(entry.size == 32 && entry.backingScale == 2)

        let copy = try f.retain(f.image(4), source: .copied)
        #expect(copy.reused && copy.url == saved && copy.source == .saved)
        #expect(f.outputFiles == ["Glint-saved.png"])

        f.clock.advance(30)
        f.retention.register(savedFile: saved, image: f.image(4), backingScale: 2)
        #expect(f.entries.count == 1 && f.entries.first?.date == f.clock.now)
    }

    @Test func registerRecordsTheScaleTheFileWasWrittenAt() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        f.preferences.exportScale = .x2
        f.retention.register(savedFile: try f.plant("saved.png"), image: f.image(1), backingScale: 3)
        #expect(f.entries.first?.backingScale == 2)

        f.preferences.exportScale = .original
        f.retention.register(savedFile: try f.plant("original.png"), image: f.image(2), backingScale: 3)
        #expect(f.entries.last?.backingScale == 3)
    }

    @Test(arguments: ExportScale.allCases)
    func registerUsesTheExplicitExportScaleInsteadOfChangedPreferences(_ exportScale: ExportScale) throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        f.preferences.exportScale = exportScale == .x1 ? .x2 : .x1
        for (index, backingScale) in ([3, 0, -2, .nan, .infinity] as [CGFloat]).enumerated() {
            f.retention.register(savedFile: try f.plant("saved-\(index).png"), image: f.image(index),
                                 backingScale: backingScale, exportScale: exportScale)
            let expected: Double
            switch exportScale {
            case .original: expected = index == 0 ? 3 : 1
            case .x1: expected = 1
            case .x2: expected = 2
            }
            #expect(f.entries.last?.backingScale == expected)
        }
    }

    @Test func aCleanupOnlyPeriodStillTracksSavedFiles() throws {
        let f = try RetentionFixture(keepCopies: false, period: .sevenDays); defer { f.tearDown() }
        #expect(f.retention.tracksSavedOutputs && f.retention.cleansUp && !f.retention.retainsCopies)
        let saved = try f.plant("saved.png")

        f.retention.register(savedFile: saved, image: f.image(1), backingScale: 2)

        #expect(f.entryNames == ["saved.png"])
        #expect(throws: OutputRetentionError.disabled) { try f.retain(f.image(2)) }
        f.clock.advance(7 * 86_400)
        #expect(f.retention.cleanUp().isEmpty)
        f.clock.advance(1)
        #expect(f.retention.cleanUp().removed == [saved])
    }

    @Test(arguments: RetentionIneligibleFile.allCases)
    func registerIgnoresEverythingButARegularFileInOutput(kind: RetentionIneligibleFile) throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: f.output, withIntermediateDirectories: true)
        let url: URL
        switch kind {
        case .manualFolder:
            url = try f.plant("shot.png", in: f.manual)
        case .rawFolder:
            url = try f.plant("raw.png", in: f.raw)
        case .subfolder:
            url = try f.plant("shot.png", in: f.output.appendingPathComponent("sub"))
        case .symlink:
            url = f.output.appendingPathComponent("link.png")
            try fileManager.createSymbolicLink(at: url, withDestinationURL: f.plant("target.png", in: f.outside))
        case .directory:
            url = f.output.appendingPathComponent("folder.png")
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        case .missing:
            url = f.output.appendingPathComponent("gone.png")
        }

        f.retention.register(savedFile: url, image: f.image(1), backingScale: 2)

        #expect(f.indexFiles.isEmpty)
    }

    // MARK: - Settings changed while an image is being stored

    @Test func anObservedImageHashesLikeAPlainOneAndReportsItsFirstRead() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let reads = Box(0)
        let observed = f.observedImage(5) { reads.withValue { $0 += 1 } }
        #expect(reads.withValue { $0 } == 0)

        let digest = try #require(OutputRetention.digest(of: observed))

        #expect(digest == OutputRetention.digest(of: f.image(5)))
        #expect(reads.withValue { $0 } == 1)
        _ = OutputRetention.digest(of: observed)
        #expect(reads.withValue { $0 } == 1)
    }

    @Test(arguments: RetentionRevocation.allCases)
    func retainWritesNothingWhenKeepingIsRevokedWhileHashing(change: RetentionRevocation) throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let image = f.observedImage(1, onFirstRead: f.revocation(change))

        #expect(throws: OutputRetentionError.disabled) { try f.retain(image) }

        #expect(!f.exists(f.history) && !f.exists(f.elsewhere))
    }

    @Test(arguments: RetentionRevocation.allCases)
    func retainWritesNothingWhenKeepingIsRevokedWhileEncoding(change: RetentionRevocation) throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let revoke = f.revocation(change)
        let retention = f.makeRetention(encode: { image, format, scale, backingScale in
            revoke()
            return try Exporter.data(for: image, format: format, scale: scale, backingScale: backingScale)
        })

        #expect(throws: OutputRetentionError.disabled) { try retention.retain(f.image(1), source: .copied, backingScale: 2) }

        #expect(!f.exists(f.history) && !f.exists(f.elsewhere))
    }

    @Test(arguments: RetentionRevocation.allCases)
    func retainLeavesAReusableFileAloneWhenKeepingIsRevokedWhileHashing(change: RetentionRevocation) throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let first = try f.retain(f.image(1))
        let index = f.indexBytes
        let bytes = try Data(contentsOf: first.url)
        f.clock.advance(60)
        let image = f.observedImage(1, onFirstRead: f.revocation(change))

        #expect(throws: OutputRetentionError.disabled) { try f.retain(image) }

        #expect(f.indexBytes == index && f.outputFiles == [first.url.lastPathComponent])
        #expect(try Data(contentsOf: first.url) == bytes && !f.exists(f.elsewhere))
    }

    @Test func retainReportsAnEncoderFailureAndWritesNothing() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let retention = f.makeRetention(encode: { _, _, _, _ in throw EncoderFailed() })

        #expect(throws: OutputRetentionError.encodingFailed) { try retention.retain(f.image(1), source: .copied, backingScale: 2) }

        #expect(!f.exists(f.history))
    }

    @Test(arguments: RetentionRevocation.allCases)
    func registerTracksNothingWhenTrackingIsRevokedWhileHashing(change: RetentionRevocation) throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let saved = try f.plant("saved.png")

        f.retention.register(savedFile: saved, image: f.observedImage(1, onFirstRead: f.revocation(change)), backingScale: 2)

        #expect(f.indexFiles.isEmpty && f.exists(saved) && !f.exists(f.elsewhere))
    }

    @Test func registerKeepsTrackingWhenOnlyKeepingCopiesIsTurnedOffWhileExpiryIsOn() throws {
        let f = try RetentionFixture(period: .sevenDays); defer { f.tearDown() }
        let saved = try f.plant("saved.png")

        f.retention.register(savedFile: saved, image: f.observedImage(1, onFirstRead: f.revocation(.keepingTurnedOff)),
                             backingScale: 2)

        #expect(!f.retention.retainsCopies && f.entryNames == ["saved.png"])
    }

    @Test(arguments: RetentionRevocation.allCases)
    func retainChecksAgainOnceItHasTheIndexLock(change: RetentionRevocation) throws {
        let f = try RetentionFixture(); defer { f.tearDown() }

        let result = try retainWhileHoldingTheIndexLock(f, revoking: f.revocation(change))

        #expect { try result.get() } throws: { ($0 as? OutputRetentionError) == .disabled }
        #expect(!f.exists(f.history) && !f.exists(f.elsewhere))
    }

    @Test func retainWaitingForTheIndexLockStoresTheImageWhenNothingChanged() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }

        let out = try retainWhileHoldingTheIndexLock(f, revoking: nil).get()

        #expect(f.exists(out.url) && f.entryNames == [out.url.lastPathComponent])
    }

    @Test(arguments: RetentionRevocation.allCases)
    func registerChecksAgainOnceItHasTheIndexLock(change: RetentionRevocation) throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let saved = try f.plant("saved.png")

        try registerWhileHoldingTheIndexLock(f, saved: saved, revoking: f.revocation(change))

        #expect(f.indexFiles.isEmpty && f.exists(saved) && !f.exists(f.elsewhere))
    }

    @Test func registerWaitingForTheIndexLockTracksTheFileWhenNothingChanged() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let saved = try f.plant("saved.png")

        try registerWhileHoldingTheIndexLock(f, saved: saved, revoking: nil)

        #expect(f.entryNames == ["saved.png"])
    }

    // MARK: - Writing a new file

    @Test func writeNewFileSkipsNamesThatAreTaken() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let taken = try f.plant("taken.png", bytes: 5)
        let victim = f.outside.appendingPathComponent("victim.bin")
        try FileManager.default.createDirectory(at: f.outside, withIntermediateDirectories: true)
        let dangling = f.output.appendingPathComponent("dangling.png")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: victim)
        let fresh = f.output.appendingPathComponent("fresh.png")
        let candidates = Box([taken, dangling, fresh])

        let written = try OutputRetention.writeNewFile(Data([1, 2, 3])) {
            candidates.withValue { $0.isEmpty ? nil : $0.removeFirst() }
        }

        #expect(written == fresh)
        #expect(try Data(contentsOf: fresh) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: taken) == Data(repeating: 0x33, count: 5))
        #expect(!f.exists(victim))
        #expect(f.outputFiles == ["dangling.png", "fresh.png", "taken.png"])
    }

    @Test func writeNewFileGivesUpAfterRepeatedCollisions() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let taken = try f.plant("taken.png", bytes: 5)

        #expect { try OutputRetention.writeNewFile(Data([9])) { taken } } throws: { isWriteFailure($0) }

        #expect(try Data(contentsOf: taken) == Data(repeating: 0x33, count: 5))
        #expect(f.outputFiles == ["taken.png"])
    }

    @Test func writeNewFileReportsMissingNamesAndFolders() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        #expect(throws: OutputRetentionError.disabled) { try OutputRetention.writeNewFile(Data([1])) { nil } }

        let nowhere = f.root.appendingPathComponent("Nowhere/x.png")
        #expect { try OutputRetention.writeNewFile(Data([1])) { nowhere } } throws: { isWriteFailure($0) }
        #expect(!f.exists(nowhere.deletingLastPathComponent()))
    }

    // MARK: - Cleanup

    @Test func foreverNeverRemovesAnything() throws {
        let f = try RetentionFixture(period: .forever); defer { f.tearDown() }
        let old = try f.track("old.png", at: f.age(days: 10_000))
        let before = f.indexBytes

        #expect(f.retention.cleanUp().isEmpty)
        #expect(f.exists(old) && f.indexBytes == before && f.trash.trashed.isEmpty)
    }

    @Test(arguments: OutputRetentionPeriod.allCases.filter { $0 != .forever })
    func expiresOnlyFilesDatedBeforeTheCutoff(period: OutputRetentionPeriod) throws {
        let f = try RetentionFixture(period: period); defer { f.tearDown() }
        let cutoff = f.clock.now.addingTimeInterval(-Double(period.rawValue) * 86_400)
        let older = try f.track("older.png", at: cutoff.addingTimeInterval(-1))
        let justOlder = try f.track("just-older.png", at: cutoff.addingTimeInterval(-0.001))
        let exact = try f.track("exact.png", at: cutoff)
        let newer = try f.track("newer.png", at: cutoff.addingTimeInterval(1))

        let report = f.retention.cleanUp()

        #expect(report.removed == [older, justOlder])
        #expect(report.skippedActive.isEmpty && report.untracked.isEmpty && report.failures.isEmpty)
        #expect(f.trash.trashed == [older, justOlder])
        #expect(f.exists(exact) && f.exists(newer) && !f.exists(older) && !f.exists(justOlder))
        #expect(f.entryNames == ["exact.png", "newer.png"])

        f.clock.advance(0.001)
        #expect(f.retention.cleanUp().removed == [exact])
        f.clock.advance(1)
        #expect(f.retention.cleanUp().removed == [newer])
        #expect(f.entries.isEmpty)
    }

    @Test func dropsEntriesWhoseFileIsGoneWithoutReportingThem() throws {
        let f = try RetentionFixture(period: .oneDay); defer { f.tearDown() }
        let gone = try f.track("gone.png", at: f.age(days: 3))
        let fresh = try f.track("fresh.png", at: f.age(days: 0))
        try FileManager.default.removeItem(at: gone)

        #expect(f.retention.cleanUp().isEmpty)
        #expect(f.entryNames == ["fresh.png"] && f.exists(fresh))
    }

    @Test func followsTheCurrentOutputFolder() throws {
        let f = try RetentionFixture(period: .oneDay); defer { f.tearDown() }
        let historyB = f.root.appendingPathComponent("HistoryB")
        let inA = try f.track("a.png", at: f.age(days: 5))
        let inB = try f.track("b.png", at: f.age(days: 5), in: historyB.appendingPathComponent("Output"))
        let indexA = f.indexBytes

        f.preferences.historyDirectory = historyB
        #expect(f.retention.cleanUp().removed == [inB])
        #expect(f.exists(inA) && f.indexBytes == indexA)

        f.preferences.historyDirectory = f.history
        #expect(f.retention.cleanUp().removed == [inA])
    }

    @Test func leavesFilesInUseAlone() throws {
        let f = try RetentionFixture(period: .oneDay); defer { f.tearDown() }
        let busy = try f.track("busy.png", at: f.age(days: 3))
        let idle = try f.track("idle.png", at: f.age(days: 3))
        f.active.begin(busy)
        f.active.begin(busy)

        var report = f.retention.cleanUp()
        #expect(report.removed == [idle] && report.skippedActive == [busy] && report.untracked.isEmpty)
        #expect(f.exists(busy) && f.entryNames == ["busy.png"])

        f.active.end(busy)
        report = f.retention.cleanUp()
        #expect(report.removed.isEmpty && report.skippedActive == [busy])

        f.active.end(busy)
        report = f.retention.cleanUp()
        #expect(report.removed == [busy] && report.skippedActive.isEmpty)
        #expect(!f.exists(busy) && f.entries.isEmpty)
    }

    @Test func keepsAndReportsFilesThatCannotBeTrashed() throws {
        let f = try RetentionFixture(period: .oneDay); defer { f.tearDown() }
        let stuck = try f.track("stuck.png", at: f.age(days: 3))
        let fine = try f.track("fine.png", at: f.age(days: 3))
        f.trash.refuse("stuck.png")

        let report = f.retention.cleanUp()

        #expect(report.removed == [fine])
        #expect(report.failures == ["stuck.png: Trash refused"])
        #expect(!report.isEmpty)
        #expect(f.exists(stuck) && f.entryNames == ["stuck.png"])

        f.trash.allow("stuck.png")
        #expect(f.retention.cleanUp().removed == [stuck])
        #expect(f.entries.isEmpty)
    }

    @Test func onlyTouchesTrackedRegularFilesDirectlyInOutput() throws {
        let f = try RetentionFixture(period: .oneDay); defer { f.tearDown() }
        let ancient = Date(timeIntervalSince1970: 1_000_000_000)
        let mine = try f.track("mine.png", at: f.age(days: 3))
        let untouched = [
            try f.plant("legacy.png", modified: ancient),
            try f.plant("Screenshot 2020.png", modified: ancient),
            try f.plant("nested.png", in: f.output.appendingPathComponent("sub"), modified: ancient),
            try f.plant("Glint-raw.png", in: f.raw, modified: ancient),
            try f.plant("manual.png", in: f.manual, modified: ancient),
        ]
        let target = try f.plant("target.png", in: f.outside, modified: ancient)
        let link = f.output.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let report = f.retention.cleanUp()

        #expect(report.removed == [mine] && report.untracked.isEmpty && report.failures.isEmpty)
        #expect(f.trash.trashed == [mine])
        for url in untouched + [target] { #expect(f.exists(url), "\(url.lastPathComponent)") }
        #expect(OutputRetention.probe(link) != .missing)
    }

    @Test(arguments: RetentionChange.allCases)
    func untracksFilesThatChangedInsteadOfDeletingThem(change: RetentionChange) throws {
        let f = try RetentionFixture(period: .oneDay); defer { f.tearDown() }
        let url = try f.track("changed.png", at: f.age(days: 3))
        try f.apply(change, to: url)

        let report = f.retention.cleanUp()

        #expect(f.trash.trashed.isEmpty && f.entries.isEmpty)
        if change == .deleted {
            #expect(report.isEmpty)
        } else {
            #expect(report.untracked == [url] && report.removed.isEmpty && report.failures.isEmpty)
            #expect(OutputRetention.probe(url) != .missing)
        }
    }

    @Test func reusingAFileRestartsItsExpiryClock() throws {
        let f = try RetentionFixture(period: .oneDay); defer { f.tearDown() }
        let first = try f.retain(f.image(1))

        f.clock.advance(20 * 3_600)
        #expect(try f.retain(f.image(1)).reused)

        f.clock.advance(10 * 3_600)
        #expect(f.retention.cleanUp().isEmpty && f.exists(first.url))

        f.clock.advance(15 * 3_600)
        #expect(f.retention.cleanUp().removed == [first.url])
    }

    @Test(arguments: RetentionMidRunChange.allCases)
    func stopsWhenTheSettingsChangeMidRun(change: RetentionMidRunChange) throws {
        let f = try RetentionFixture(period: .oneDay); defer { f.tearDown() }
        let first = try f.track("first.png", at: f.age(days: 3))
        let second = try f.track("second.png", at: f.age(days: 3))
        let preferences = f.preferences
        let elsewhere = f.root.appendingPathComponent("Elsewhere")
        f.trash.afterEachTrash {
            switch change {
            case .historyTurnedOff: preferences.saveHistory = false
            case .retentionSetToForever: preferences.outputRetention = .forever
            case .folderChanged: preferences.historyDirectory = elsewhere
            }
        }

        let report = f.retention.cleanUp()

        #expect(report.removed == [first] && f.trash.trashed == [first])
        #expect(f.exists(second) && f.entryNames == ["second.png"])
    }

    // MARK: - A drag racing cleanup

    @Test func aDragStartingWhileTheFileIsBeingTrashedWaitsForTheMove() throws {
        let f = try RetentionFixture(period: .oneDay); defer { f.tearDown() }
        let url = try f.track("old.png", at: f.age(days: 3))
        let trash = StallingTrash(f.trash)
        defer { trash.resume() }
        let log = Box<[String]>([])
        let cleanup = f.makeRetention(moveToTrash: { try trash.move($0); log.withValue { $0.append("trashed") } })
        let report = Box(OutputCleanupReport())
        let active = f.active

        let cleaning = BackgroundThread { report.withValue { $0 = cleanup.cleanUp() } }
        try #require(trash.stalled.wait(timeout: .now() + 10) == .success)

        let dragging = BackgroundThread {
            active.begin(url)
            log.withValue { $0.append("drag started") }
        }
        // The drag has to wait for the move. The short wait gives a drag that wrongly goes ahead time to show itself.
        #expect(!dragging.finishes(within: 0.3))
        trash.resume()
        try #require(cleaning.finishes() && dragging.finishes())

        #expect(log.withValue { $0 } == ["trashed", "drag started"])
        #expect(report.withValue { $0 }.removed == [url] && !f.exists(url) && f.entries.isEmpty)
        #expect(f.active.contains(url))
        f.active.end(url)
    }

    @Test func anUnrelatedDragIsNotHeldUpAndAFileClaimedMidRunIsKept() throws {
        let f = try RetentionFixture(period: .oneDay); defer { f.tearDown() }
        let first = try f.track("a.png", at: f.age(days: 3))
        let second = try f.track("b.png", at: f.age(days: 3))
        let trash = StallingTrash(f.trash)
        defer { trash.resume() }
        let cleanup = f.makeRetention(moveToTrash: { try trash.move($0) })
        let report = Box(OutputCleanupReport())

        let cleaning = BackgroundThread { report.withValue { $0 = cleanup.cleanUp() } }
        try #require(trash.stalled.wait(timeout: .now() + 10) == .success)
        // a.png is on its way to the Trash. Claiming b.png needn't wait for that, and keeps it safe from the same run.
        #expect(beginsPromptly(f.active, second))
        trash.resume()
        try #require(cleaning.finishes())

        let done = report.withValue { $0 }
        #expect(done.removed == [first] && done.skippedActive == [second] && done.failures.isEmpty)
        #expect(!f.exists(first) && f.exists(second) && f.entryNames == ["b.png"])
        f.active.end(second)
    }

    @Test func removeUnlessActiveSkipsFilesInUseAndNeverLeavesOneLockedOut() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let active = f.active
        let file = f.output.appendingPathComponent("x.png")
        var removals = 0

        let idle = active.removeUnlessActive(file) { removals += 1 }
        #expect(idle && removals == 1 && !active.contains(file))

        active.begin(file)
        let busy = active.removeUnlessActive(file) { removals += 1 }
        #expect(!busy && removals == 1 && active.contains(file))
        active.end(file)

        #expect(throws: TrashRefused.self) { try active.removeUnlessActive(file) { throw TrashRefused() } }
        #expect(!active.contains(file))
        #expect(beginsPromptly(active, file) && active.contains(file))
        active.end(file)
    }

    // MARK: - Concurrency

    @Test func concurrentCallersShareOneConsistentIndex() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let clock = f.clock
        // A second pipeline in the same process has its own instance over the same folder.
        let second = OutputRetention(preferences: f.preferences, now: { clock.now }, moveToTrash: { _ in }, activeFiles: f.active)
        let instances = [f.retention, second]
        let images = (1...8).map { f.image($0) }
        let results = Box<[RetainedOutput]>([])
        let failures = Box<[String]>([])

        DispatchQueue.concurrentPerform(iterations: 24) { i in
            do {
                let out = try instances[i / 8 % 2].retain(images[i % 8], source: i.isMultiple(of: 2) ? .copied : .dragged,
                                                          backingScale: 2)
                results.withValue { $0.append(out) }
            } catch {
                failures.withValue { $0.append("\(error)") }
            }
            _ = instances[(i / 8 + 1) % 2].latest()
        }

        #expect(failures.withValue { $0 }.isEmpty)
        let all = results.withValue { $0 }
        #expect(all.count == 24 && all.filter { !$0.reused }.count == 8)
        #expect(f.entries.count == 8 && Set(f.entries.map(\.digest)).count == 8)
        #expect(f.outputFiles.count == 8 && Set(f.outputFiles) == Set(f.entryNames))
    }

    // MARK: - Small types

    @Test func activeFilesNestAndMatchByResolvedPath() throws {
        let f = try RetentionFixture(); defer { f.tearDown() }
        let active = OutputActiveFiles()
        let file = f.output.appendingPathComponent("x.png")
        let alias = f.root.appendingPathComponent("Alias")
        try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.output)
        let viaAlias = alias.appendingPathComponent("x.png")
        #expect(!active.contains(file))

        active.begin(file)
        active.begin(viaAlias)
        #expect(active.contains(file) && active.contains(viaAlias))
        active.end(file)
        #expect(active.contains(file))
        active.end(viaAlias)
        #expect(!active.contains(file) && !active.contains(viaAlias))

        active.end(file)
        active.begin(file)
        #expect(active.contains(file))
        #expect(!active.contains(f.output.appendingPathComponent("y.png")))
        #expect(OutputActiveFiles.shared === OutputActiveFiles.shared)
    }

    @Test func periodsMapToDaysAndDisplayNames() {
        let periods = OutputRetentionPeriod.allCases
        #expect(periods == [.forever, .oneDay, .sevenDays, .thirtyDays, .ninetyDays])
        #expect(periods.map(\.rawValue) == [0, 1, 7, 30, 90] && periods.map(\.id) == [0, 1, 7, 30, 90])
        #expect(periods.map(\.days) == [nil, 1, 7, 30, 90])
        #expect(periods.map(\.displayName) == ["Forever", "1 day", "7 days", "30 days", "90 days"])
        for period in periods { #expect(OutputRetentionPeriod(storedDays: period.rawValue) == period) }
        for unknown in [-1, -30, 2, 14, 365, Int.max, Int.min] {
            #expect(OutputRetentionPeriod(storedDays: unknown) == .forever, "\(unknown)")
        }
    }

    @Test func errorsAndReportsDescribeThemselves() {
        #expect(OutputRetentionError.disabled.errorDescription?.isEmpty == false)
        #expect(OutputRetentionError.encodingFailed.errorDescription?.isEmpty == false)
        #expect(OutputRetentionError.writeFailed("Disk full").errorDescription == "Disk full")
        #expect(OutputRetentionError.writeFailed("Disk full").localizedDescription == "Disk full")

        let url = URL(fileURLWithPath: "/Output/x.png")
        #expect(OutputCleanupReport().isEmpty)
        #expect(!OutputCleanupReport(removed: [url]).isEmpty)
        #expect(!OutputCleanupReport(skippedActive: [url]).isEmpty)
        #expect(!OutputCleanupReport(untracked: [url]).isEmpty)
        #expect(!OutputCleanupReport(failures: ["x.png: no"]).isEmpty)
        #expect(!RetainedOutput(url: url, date: Date(), source: .saved, backingScale: 1).reused)
    }
}
