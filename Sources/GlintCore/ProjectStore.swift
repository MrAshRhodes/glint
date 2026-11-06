import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads and writes `.glint` project packages.
///
/// A project is a directory package with fixed member names:
///
///     Name.glint/
///         manifest.json          format, formatVersion, requiredFeatures (checked first)
///         project.json           ProjectState
///         source/capture.png     screenshots: the original, unredacted capture
///         source/recording.mp4   recordings: the original clip
///         assets/background.png  an image background, when one is used
///         assets/watermark.png   an image watermark, when one is set
///
/// Opening never trusts the package: only the names above are read, each through `O_NOFOLLOW` so a symlink is
/// refused rather than followed, every member must be a regular file under a size cap, and paths stored in
/// `project.json` are ignored and replaced with the package's own members. Saving builds the whole package in a
/// staging folder and moves it into place in one step, so a failure never leaves a half-written project.
public enum ProjectStore {
    public static let fileExtension = "glint"
    /// `io.github.mrashrhodes.glint.project`, a package type declared in the app's Info.plist.
    public static let contentType = UTType(exportedAs: ProjectManifest.formatName, conformingTo: .package)

    /// Package member paths. Fixed so nothing in the package can point the reader elsewhere.
    public enum Member {
        public static let manifest = "manifest.json"
        public static let project = "project.json"
        public static let capture = "source/capture.png"
        public static let recording = "source/recording.mp4"
        public static let background = "assets/background.png"
        public static let watermark = "assets/watermark.png"
    }

    /// Upper bounds on what opening a project will read, so a hostile package can't exhaust memory.
    public enum Limits {
        public static let manifestBytes = 64 * 1024
        public static let projectBytes = 64 * 1024 * 1024
        public static let imageBytes = 1024 * 1024 * 1024
        public static let assetBytes = 256 * 1024 * 1024
        public static let videoBytes: Int64 = 64 * 1024 * 1024 * 1024
        /// Largest decoded image, in pixels.
        public static let imagePixels = 400_000_000
    }

    public static func isProject(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    /// `Glint Project 2026-11-05 at 14.29.16.glint`, matching the recording export names.
    public static func defaultFileName(date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Glint Project \(formatter.string(from: date)).\(fileExtension)"
    }

    // MARK: Writing

    /// Writes `project` to `url` atomically, replacing an existing project there.
    ///
    /// Image backgrounds and watermarks are embedded, so the project opens the same on another Mac. A desktop
    /// wallpaper background stores only the setting; the wallpaper itself is read again when the project opens.
    public static func write(_ project: GlintProject, to url: URL, generator: String? = nil,
                             fileManager: FileManager = .default) throws {
        switch (project.state, project.source) {
        case (.screenshot, .image), (.recording, .video): break
        default: throw ProjectFormatError.mismatchedSource
        }
        let staging: URL
        do {
            staging = try RecordingExportFiles.makeStagingDirectory(forDestination: url, fileManager: fileManager)
        } catch {
            throw ProjectFormatError.writeFailed(error.localizedDescription)
        }
        defer { try? fileManager.removeItem(at: staging) }
        let package = staging.appendingPathComponent(url.lastPathComponent, isDirectory: true)
        do {
            try fileManager.createDirectory(at: package.appendingPathComponent("source"), withIntermediateDirectories: true)
            var state = project.state
            state.settings = try embedAssets(state.settings, in: package, fileManager: fileManager)
            switch project.source {
            case .image(let image):
                try encodePNG(image).write(to: package.appendingPathComponent(Member.capture))
            case .video(let video):
                // Copy the clip itself even if the editor was handed a symlink to it.
                try fileManager.copyItem(at: video.resolvingSymlinksInPath(),
                                         to: package.appendingPathComponent(Member.recording))
            }
            let manifest = ProjectManifest(requiredFeatures: ProjectFeatures.required(by: state).sorted(),
                                           generator: generator)
            try encoder.encode(manifest).write(to: package.appendingPathComponent(Member.manifest))
            try encoder.encode(state).write(to: package.appendingPathComponent(Member.project))
            try RecordingExportFiles.commit(package, to: url, fileManager: fileManager)
        } catch let error as ProjectFormatError {
            throw error
        } catch {
            throw ProjectFormatError.writeFailed(error.localizedDescription)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Copies the background and watermark images into the package and points the settings at the members, so the
    /// project never records the user's own file paths.
    private static func embedAssets(_ settings: RenderSettings, in package: URL,
                                    fileManager: FileManager) throws -> RenderSettings {
        var settings = settings
        if case .image(let path, let fit) = settings.background {
            guard let image = GlintImageIO.load(url: URL(fileURLWithPath: path)) else {
                throw ProjectFormatError.unreadableAsset("background")
            }
            try writeAsset(image, member: Member.background, in: package, fileManager: fileManager)
            settings.background = .image(path: Member.background, fit: fit)
        }
        if let path = settings.watermark.imagePath {
            if let image = GlintImageIO.load(url: URL(fileURLWithPath: path)) {
                try writeAsset(image, member: Member.watermark, in: package, fileManager: fileManager)
                settings.watermark.imagePath = Member.watermark
            } else if settings.watermark.enabled, settings.watermark.kind == .image {
                throw ProjectFormatError.unreadableAsset("watermark")
            } else {
                settings.watermark.imagePath = nil
            }
        }
        return settings
    }

    private static func writeAsset(_ image: CGImage, member: String, in package: URL, fileManager: FileManager) throws {
        let url = package.appendingPathComponent(member)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encodePNG(image).write(to: url)
    }

    /// Lossless PNG that keeps the image's own colour space, so reopened pixels match the original capture.
    static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ProjectFormatError.writeFailed("the image could not be encoded")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ProjectFormatError.writeFailed("the image could not be encoded")
        }
        return data as Data
    }

    // MARK: Reading

    /// Opens the project at `url`. The manifest is checked before anything else is decoded.
    public static func read(from url: URL) throws -> GlintProject {
        let root = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else {
            throw errno == ENOTDIR ? ProjectFormatError.notAProject : ProjectFormatError.damaged(String(cString: strerror(errno)))
        }
        defer { close(root) }

        let manifestData: Data
        do {
            manifestData = try readMember(Member.manifest, in: root, limit: Limits.manifestBytes)
        } catch ProjectFormatError.missingMember {
            throw ProjectFormatError.notAProject
        }
        let manifest: ProjectManifest
        do {
            manifest = try JSONDecoder().decode(ProjectManifest.self, from: manifestData)
        } catch {
            throw ProjectFormatError.notAProject
        }
        try manifest.validate()

        var state: ProjectState
        do {
            state = try JSONDecoder().decode(ProjectState.self,
                                             from: readMember(Member.project, in: root, limit: Limits.projectBytes))
        } catch let error as ProjectFormatError {
            throw error
        } catch {
            throw ProjectFormatError.damaged("project.json can't be read")
        }
        let package = url.standardizedFileURL
        state.settings = try resolveAssets(state.settings, package: package, root: root)

        switch state {
        case .screenshot:
            let data = try readMember(Member.capture, in: root, limit: Limits.imageBytes)
            return GlintProject(state: state, source: .image(try decodeImage(data, member: Member.capture)))
        case .recording:
            try checkMember(Member.recording, in: root, limit: Limits.videoBytes)
            return GlintProject(state: state, source: .video(package.appendingPathComponent(Member.recording)))
        }
    }

    /// Points image backgrounds and watermarks at the package's own copies after checking them. The path stored in
    /// the JSON is never used.
    private static func resolveAssets(_ settings: RenderSettings, package: URL, root: Int32) throws -> RenderSettings {
        var settings = settings
        if case .image(_, let fit) = settings.background {
            _ = try decodeImage(readMember(Member.background, in: root, limit: Limits.assetBytes), member: Member.background)
            settings.background = .image(path: package.appendingPathComponent(Member.background).path, fit: fit)
        }
        if settings.watermark.imagePath != nil {
            do {
                _ = try decodeImage(readMember(Member.watermark, in: root, limit: Limits.assetBytes),
                                    member: Member.watermark)
                settings.watermark.imagePath = package.appendingPathComponent(Member.watermark).path
            } catch ProjectFormatError.missingMember where !(settings.watermark.enabled && settings.watermark.kind == .image) {
                settings.watermark.imagePath = nil
            }
        }
        return settings
    }

    private static func decodeImage(_ data: Data, member: String) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ProjectFormatError.damaged("\(member) isn't an image")
        }
        guard width > 0, height > 0, width <= Limits.imagePixels / height else {
            throw ProjectFormatError.memberTooLarge(member)
        }
        // Decoded as stored (no colour conversion), so the pixels are the ones that were saved.
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProjectFormatError.damaged("\(member) isn't an image")
        }
        return image
    }

    /// Opens `member` relative to the package without following any symlink on the way.
    private static func openMember(_ member: String, in root: Int32) throws -> Int32 {
        let components = member.split(separator: "/").map(String.init)
        var directory = root
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (isLast ? O_NONBLOCK : O_DIRECTORY)
            let fd = openat(directory, component, flags)
            guard fd >= 0 else {
                switch errno {
                case ENOENT: throw ProjectFormatError.missingMember(member)
                case ELOOP, ENOTDIR: throw ProjectFormatError.unsafeMember(member)
                default: throw ProjectFormatError.damaged("\(member): \(String(cString: strerror(errno)))")
                }
            }
            if isLast { return fd }
            opened.append(fd)
            directory = fd
        }
        throw ProjectFormatError.missingMember(member)
    }

    /// Checks `member` is a regular file no bigger than `limit`, returning its open descriptor and size.
    private static func statMember(_ member: String, in root: Int32, limit: Int64) throws -> (Int32, Int64) {
        let fd = try openMember(member, in: root)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw ProjectFormatError.unsafeMember(member)
        }
        guard Int64(info.st_size) <= limit else {
            close(fd)
            throw ProjectFormatError.memberTooLarge(member)
        }
        return (fd, Int64(info.st_size))
    }

    private static func checkMember(_ member: String, in root: Int32, limit: Int64) throws {
        let (fd, _) = try statMember(member, in: root, limit: limit)
        close(fd)
    }

    private static func readMember(_ member: String, in root: Int32, limit: Int) throws -> Data {
        let (fd, size) = try statMember(member, in: root, limit: Int64(limit))
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data: Data
        do {
            data = try handle.read(upToCount: Int(size) + 1) ?? Data()
        } catch {
            throw ProjectFormatError.damaged("\(member) can't be read")
        }
        guard data.count <= limit else { throw ProjectFormatError.memberTooLarge(member) }
        return data
    }
}
