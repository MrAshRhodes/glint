import AppKit
import Foundation
import UniformTypeIdentifiers

/// Puts an exported recording on the clipboard.
///
/// A GIF goes on as `public.gif` data plus a `public.file-url`, so apps that take animated images and apps that take
/// files (Finder, mail) both get the real animation. No still-image fallback is added: it would paste a static frame.
/// An MP4 goes on as a file URL only.
///
/// A file URL on the clipboard is a promise that the file still exists when someone pastes, which can be long after
/// the editor closes. So the file is moved into a cache folder of its own (never the editor's temporary files) and stays
/// there for `retention`; each copy also removes copies older than that. The clipboard holds only one item, so at most
/// the latest copy is still pasteable; older ones are just leftovers waiting to expire. Pasting after the retention
/// period, or after the system purges its caches, finds no file, though a GIF's data stays on the clipboard.
///
/// The item itself carries only the flavors above. macOS may additionally advertise flavors it can synthesize from
/// them (for a GIF, a TIFF of the first frame), which only apps that ignore `public.gif` would pick.
public enum RecordingPasteboard {
    public static let retention: TimeInterval = 24 * 60 * 60

    public static var defaultDirectory: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches"))
            .appendingPathComponent("Glint/Clipboard/Recordings", isDirectory: true)
    }

    /// Moves `exported` into `directory` under a readable name, puts it on `pasteboard`, and returns its new location.
    /// On failure `exported` is left where it was.
    @discardableResult
    public static func copy(_ exported: URL, format: RecordingFileFormat, to pasteboard: NSPasteboard = .general,
                            directory: URL = defaultDirectory, now: Date = Date()) throws -> URL {
        let fileManager = FileManager.default
        pruneExpired(in: directory, now: now)

        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let durable = folder.appendingPathComponent(RecordingExportFiles.defaultFileName(format: format, date: now))
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.copyItem(at: exported, to: durable)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw RecordingExportError.writeFailed(error.localizedDescription)
        }

        let item = NSPasteboardItem()
        if format == .gif {
            guard let data = try? Data(contentsOf: durable) else {
                try? fileManager.removeItem(at: folder)
                throw RecordingExportError.writeFailed("couldn't read \(durable.lastPathComponent)")
            }
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        }
        item.setString(durable.absoluteString, forType: .fileURL)

        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            try? fileManager.removeItem(at: folder)
            throw RecordingExportError.pasteboardWriteFailed
        }
        try? fileManager.removeItem(at: exported)
        return durable
    }

    /// Deletes copies in `directory` last modified more than `retention` before `now`.
    public static func pruneExpired(in directory: URL = defaultDirectory, now: Date = Date(), retention: TimeInterval = retention) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > retention {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}
