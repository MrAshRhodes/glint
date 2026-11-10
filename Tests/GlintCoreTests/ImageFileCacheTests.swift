import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

private extension RGBAColor {
    static let green = RGBAColor(r: 0, g: 1, b: 0)
    static let blue = RGBAColor(r: 0, g: 0, b: 1)
}

/// Counts decodes, which is what a cache hit skips.
private final class LoadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func load(_ url: URL) -> CGImage? {
        lock.lock()
        calls += 1
        lock.unlock()
        return GlintImageIO.load(url: url)
    }
}

@Suite("Image file cache")
struct ImageFileCacheTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-image-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ color: RGBAColor, width: Int = 32, height: Int = 24, to url: URL,
                       modified: Date? = nil) throws -> URL {
        try Exporter.write(TestImages.solid(width, height, color), to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    @Test func reusesTheImageUntilTheFileChanges() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write(.red, to: dir.appendingPathComponent("a.png"))
        let cache = ImageFileCache(), count = LoadCount()
        let first = try #require(cache.image(at: url, load: count.load))
        let second = try #require(cache.image(at: url, load: count.load))
        #expect(first === second && count.value == 1)

        try write(.blue, to: url, modified: Date().addingTimeInterval(120))
        let rewritten = try #require(cache.image(at: url, load: count.load))
        #expect(count.value == 2)
        #expect(TestImages.pixel(rewritten, 0, 0).b == 255 && TestImages.pixel(rewritten, 0, 0).r == 0)
    }

    @Test func aChangedSizeIsNoticedEvenWithTheSameModificationDate() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date().addingTimeInterval(-3600)
        let url = try write(.red, width: 32, to: dir.appendingPathComponent("a.png"), modified: date)
        let cache = ImageFileCache(), count = LoadCount()
        _ = cache.image(at: url, load: count.load)
        try write(.red, width: 48, to: url, modified: date)
        let wider = try #require(cache.image(at: url, load: count.load))
        #expect(count.value == 2 && wider.width == 48)
    }

    @Test func aSameSizeRewriteThatKeepsTheModificationDateIsNoticed() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.tiff")
        let date = Date().addingTimeInterval(-3600)
        func write(_ color: RGBAColor) throws {
            try Exporter.write(TestImages.solid(32, 24, color), to: url, format: .tiff)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try write(.red)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let cache = ImageFileCache(), count = LoadCount()
        let red = try #require(cache.image(at: url, load: count.load))
        #expect(TestImages.pixel(red, 0, 0).r > 200 && TestImages.pixel(red, 0, 0).b < 50)

        try write(.blue)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int == size,
                "the rewrite must keep the size for this to test the stamp")
        let blue = try #require(cache.image(at: url, load: count.load))
        #expect(count.value == 2)
        #expect(TestImages.pixel(blue, 0, 0).b > 200 && TestImages.pixel(blue, 0, 0).r < 50)
    }

    @Test func differentVariantsOfOneFileAreKeptApart() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write(.red, to: dir.appendingPathComponent("a.png"))
        let cache = ImageFileCache(), count = LoadCount()
        let plain = try #require(cache.image(at: url, load: count.load))
        let primary = try #require(cache.image(at: url, variant: "primary", load: count.load))
        #expect(count.value == 2 && plain !== primary && cache.count == 2)
        #expect(cache.image(at: url, load: count.load) === plain)
        #expect(cache.image(at: url, variant: "primary", load: count.load) === primary)
        #expect(count.value == 2)
    }

    @Test func dropsTheLeastRecentlyUsedImage() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try write(.red, to: dir.appendingPathComponent("a.png"))
        let b = try write(.green, to: dir.appendingPathComponent("b.png"))
        let c = try write(.blue, to: dir.appendingPathComponent("c.png"))
        let cache = ImageFileCache(capacity: 2), count = LoadCount()
        _ = cache.image(at: a, load: count.load)
        _ = cache.image(at: b, load: count.load)
        _ = cache.image(at: a, load: count.load)
        #expect(count.value == 2)
        _ = cache.image(at: c, load: count.load)
        #expect(count.value == 3 && cache.count == 2)
        _ = cache.image(at: a, load: count.load)
        #expect(count.value == 3, "a was used more recently than b")
        _ = cache.image(at: b, load: count.load)
        #expect(count.value == 4, "b was dropped to make room for c")
    }

    @Test func staysWithinTheByteBudget() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try write(.red, width: 64, height: 64, to: dir.appendingPathComponent("a.png"))
        let b = try write(.green, width: 64, height: 64, to: dir.appendingPathComponent("b.png"))
        let one = 64 * 4 * 64
        let cache = ImageFileCache(capacity: 8, maxBytes: one + one / 2), count = LoadCount()
        _ = cache.image(at: a, load: count.load)
        _ = cache.image(at: b, load: count.load)
        #expect(cache.count == 1)

        let tiny = ImageFileCache(capacity: 8, maxBytes: 100)
        let image = try #require(tiny.image(at: a, load: count.load))
        #expect(image.width == 64 && tiny.count == 0, "an image over the budget is returned but not kept")
    }

    @Test func failuresAndMissingFilesAreNotRemembered() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: url)
        let cache = ImageFileCache(), count = LoadCount()
        #expect(cache.image(at: url, load: count.load) == nil)
        #expect(cache.image(at: url, load: count.load) == nil)
        #expect(count.value == 2 && cache.count == 0)

        try write(.red, to: url, modified: Date().addingTimeInterval(60))
        #expect(cache.image(at: url, load: count.load) != nil)
        #expect(count.value == 3 && cache.count == 1)

        let missing = dir.appendingPathComponent("missing.png")
        #expect(cache.image(at: missing, load: count.load) == nil)
        #expect(cache.image(at: missing, load: count.load) == nil)
        #expect(count.value == 5)
    }

    @Test func aSlowReadDoesNotBlockOtherCallers() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let slowFile = try write(.red, to: dir.appendingPathComponent("slow.png"))
        let quickFile = try write(.green, to: dir.appendingPathComponent("quick.png"))
        let cache = ImageFileCache()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let lock = NSLock()
        var waitedForRelease = false
        var slowImage: CGImage?
        DispatchQueue.global().async(group: group) {
            let image = cache.image(at: slowFile) { url in
                started.signal()
                let released = release.wait(timeout: .now() + 5) == .success
                lock.lock(); waitedForRelease = released; lock.unlock()
                return GlintImageIO.load(url: url)
            }
            lock.lock(); slowImage = image; lock.unlock()
        }
        #expect(started.wait(timeout: .now() + 10) == .success)
        #expect(cache.image(at: quickFile) != nil)
        release.signal()
        #expect(group.wait(timeout: .now() + 10) == .success)
        lock.lock(); defer { lock.unlock() }
        #expect(waitedForRelease, "the other caller had to wait for the slow read")
        #expect(slowImage != nil)
    }

    @Test func wallpaperIsDecodedOncePerRevisionAndKeepsItsErrors() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try write(.red, to: dir.appendingPathComponent("wallpaper.png"))
        let cache = ImageFileCache()
        let first = try DesktopWallpaper.load(url: url, using: cache).get()
        let second = try DesktopWallpaper.load(url: url, using: cache).get()
        #expect(first === second)
        #expect(PixelBuffer(first)?.data == PixelBuffer(try DesktopWallpaper.load(url: url).get())?.data)

        #expect(throws: DesktopWallpaperError.unavailable) { try DesktopWallpaper.load(url: nil, using: cache).get() }
        #expect(throws: DesktopWallpaperError.rotatingFolder) { try DesktopWallpaper.load(url: dir, using: cache).get() }
        let missing = dir.appendingPathComponent("missing.heic")
        #expect(throws: DesktopWallpaperError.unreadable("missing.heic")) {
            try DesktopWallpaper.load(url: missing, using: cache).get()
        }
        let remote = try #require(URL(string: "https://example.invalid/wallpaper.png"))
        #expect(throws: DesktopWallpaperError.unreadable("wallpaper.png")) {
            try DesktopWallpaper.load(url: remote, using: cache).get()
        }

        let broken = dir.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: broken)
        #expect(throws: DesktopWallpaperError.unreadable("broken.png")) {
            try DesktopWallpaper.load(url: broken, using: cache).get()
        }
        try write(.blue, to: broken, modified: Date().addingTimeInterval(60))
        let fixed = try DesktopWallpaper.load(url: broken, using: cache).get()
        #expect(TestImages.pixel(fixed, 0, 0).b == 255)
    }
}
