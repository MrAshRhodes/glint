import Foundation

/// Temporary staging and atomic delivery of exported files.
public enum RecordingExportFiles {
    /// Where exports are staged when no better place is given. Each export gets its own subfolder.
    public static var defaultWorkingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("GlintRecordingExports", isDirectory: true)
    }

    /// A fresh, empty folder to stage an export that will be moved to `destination`. It sits on the destination's volume
    /// when the system allows, so the final step is a rename. The caller removes it when done.
    public static func makeStagingDirectory(forDestination destination: URL? = nil,
                                            fileManager: FileManager = .default) throws -> URL {
        if let destination,
           let directory = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: destination, create: true) {
            return directory
        }
        let directory = defaultWorkingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RecordingExportError.writeFailed(error.localizedDescription)
        }
        return directory
    }

    /// Moves `staged` to `destination`, replacing an existing file in one step so a failure never leaves a half-written
    /// or missing destination.
    public static func commit(_ staged: URL, to destination: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: staged.path) else {
            throw RecordingExportError.writeFailed("the exported file is missing")
        }
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged, options: [.usingNewMetadataOnly])
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
        } catch let error as RecordingExportError {
            throw error
        } catch {
            throw RecordingExportError.writeFailed(error.localizedDescription)
        }
    }

    /// `Glint Recording 2026-11-05 at 14.29.16.gif`, like the system's screenshot names.
    public static func defaultFileName(format: RecordingFileFormat, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Glint Recording \(formatter.string(from: date)).\(format.fileExtension)"
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
