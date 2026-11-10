import CoreGraphics
import Darwin
import Foundation

/// Decoded images read from disk, reused until the file changes. It keeps at most `capacity` images and `maxBytes` of
/// pixels, dropping the least recently used first. An image larger than `maxBytes` is returned but not kept, and a
/// file that can't be read is never remembered, so fixing it takes effect on the next call.
///
/// The file is read outside the lock, so a slow decode never blocks other callers and any thread may call it.
public final class ImageFileCache: @unchecked Sendable {
    public let capacity: Int
    public let maxBytes: Int

    private struct Time: Equatable {
        var seconds: Int
        var nanoseconds: Int

        init(_ time: timespec) {
            seconds = time.tv_sec
            nanoseconds = time.tv_nsec
        }
    }

    /// What identifies a revision of a file: writing to it or replacing it changes at least one of these. The change
    /// time and the inode do so even when a copy keeps the old modification time and size.
    private struct Stamp: Equatable {
        var device: Int32
        var inode: UInt64
        var modified: Time
        var changed: Time
        var size: Int64

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            modified = Time(info.st_mtimespec)
            changed = Time(info.st_ctimespec)
            size = Int64(info.st_size)
        }
    }

    private struct Entry {
        var path: String
        var variant: String
        var stamp: Stamp
        var image: CGImage
        var bytes: Int
    }

    private let lock = NSLock()
    /// Least recently used first.
    private var entries: [Entry] = []

    public init(capacity: Int = 3, maxBytes: Int = RenderCache.defaultMaxBytes) {
        self.capacity = max(capacity, 0)
        self.maxBytes = max(maxBytes, 0)
    }

    /// The image at `url`, decoded with `load` only when this revision of the file isn't held. A nil from `load`
    /// is returned as it is and not remembered. `variant` names how the file is decoded: two decodes of one file that
    /// can differ, such as the first image of a multi-image file and its primary image, use different variants.
    public func image(at url: URL, variant: String = "",
                      load: (URL) -> CGImage? = { GlintImageIO.load(url: $0) }) -> CGImage? {
        guard url.isFileURL, let stamp = Stamp(path: url.path) else { return load(url) }
        if let hit = lookup(url.path, variant, stamp) { return hit }
        // The stamp is read before the file, so a file replaced meanwhile is read again next time.
        guard let image = load(url) else { return nil }
        store(Entry(path: url.path, variant: variant, stamp: stamp, image: image,
                    bytes: image.bytesPerRow * image.height))
        return image
    }

    public func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// The number of images currently held.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private func lookup(_ path: String, _ variant: String, _ stamp: Stamp) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.path == path && $0.variant == variant }) else { return nil }
        guard entries[index].stamp == stamp else {
            entries.remove(at: index)
            return nil
        }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.image
    }

    private func store(_ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.path == entry.path && $0.variant == entry.variant }
        guard entry.bytes <= maxBytes, capacity > 0 else { return }
        entries.append(entry)
        var total = entries.reduce(0) { $0 + $1.bytes }
        while entries.count > capacity || total > maxBytes, entries.count > 1 {
            total -= entries.removeFirst().bytes
        }
    }
}
