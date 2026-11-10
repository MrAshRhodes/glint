import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: Codable, Equatable, Hashable, Sendable {
    case png(interlaced: Bool)
    case jpeg(quality: Double)
    case heic(quality: Double)
    case tiff

    public static let plainPNG = ExportFormat.png(interlaced: false)

    public var fileExtension: String {
        switch self { case .png: return "png"; case .jpeg: return "jpg"; case .heic: return "heic"; case .tiff: return "tiff" }
    }

    var utType: UTType {
        switch self { case .png: return .png; case .jpeg: return .jpeg; case .heic: return .heic; case .tiff: return .tiff }
    }

    /// The `CaptureSignposts` interval name for encoding in this format.
    fileprivate var encodeSignpost: StaticString {
        switch self { case .png: "EncodePNG"; case .jpeg: "EncodeJPEG"; case .heic: "EncodeHEIC"; case .tiff: "EncodeTIFF" }
    }

    public var supportsAlpha: Bool {
        if case .jpeg = self { return false }
        return true
    }
}

public enum ExportScale: String, Codable, CaseIterable, Sendable {
    case original, x1, x2
}

public enum ExportError: Error, Equatable {
    case encodingFailed
    case writeFailed(String)
    /// `Exporter.write(replacing: false)` found a file at the destination and left it alone.
    case fileExists
}

public enum Exporter {
    /// Encodes `image`. `x1`/`x2` resample to 1×/2× the image's point size (pixels / `backingScale`).
    ///
    /// A plain PNG of the image that is on the clipboard (`copyToClipboard`) at the same scale and density is the one
    /// already made for it, so copying and saving a capture encode it once.
    public static func data(for image: CGImage, format: ExportFormat = .plainPNG, scale: ExportScale = .original,
                            backingScale: CGFloat = 1) throws -> Data {
        if format == .plainPNG, let shared = LazyImageClipboard.sharedPNG(for: image, scale: scale, backingScale: backingScale) {
            return shared
        }
        return try encode(image, format: format, scale: scale, backingScale: backingScale)
    }

    /// Always encodes, never reusing the clipboard's bytes.
    static func encode(_ image: CGImage, format: ExportFormat, scale: ExportScale, backingScale: CGFloat) throws -> Data {
        try CaptureSignposts.measure(format.encodeSignpost) {
            try encoded(image, format: format, scale: scale, backingScale: backingScale)
        }
    }

    /// Pixels per point the encoded file's density records: the backing scale as captured, or the fixed 1× or 2× of a
    /// resampled export.
    static func densityFactor(scale: ExportScale, backingScale: CGFloat) -> CGFloat {
        switch scale {
        case .original: return backingScale
        case .x1: return 1
        case .x2: return 2
        }
    }

    private static func encoded(_ image: CGImage, format: ExportFormat, scale: ExportScale,
                                backingScale: CGFloat) throws -> Data {
        var output = resampled(image, scale: scale, backingScale: backingScale)
        let dpiFactor = densityFactor(scale: scale, backingScale: backingScale)
        if !format.supportsAlpha { output = flattened(output) }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            throw ExportError.encodingFailed
        }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * dpiFactor,
            kCGImagePropertyDPIHeight: 72 * dpiFactor,
        ]
        switch format {
        case .png(let interlaced):
            if interlaced { props[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGInterlaceType: 1] }
        case .jpeg(let q), .heic(let q):
            props[kCGImageDestinationLossyCompressionQuality] = min(max(q, 0.01), 1)
        case .tiff: break
        }
        CGImageDestinationAddImage(dest, output, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encodingFailed }
        return data as Data
    }

    /// Encodes `image` and writes it to `url`, replacing a file that is already there.
    ///
    /// Pass `replacing: false` for a name that was only checked to be unused, not reserved: the file then appears
    /// complete or not at all, and one that another writer created meanwhile is left alone and reported as
    /// `ExportError.fileExists`, so the caller can pick another name.
    @discardableResult
    public static func write(_ image: CGImage, to url: URL, format: ExportFormat = .plainPNG, scale: ExportScale = .original,
                             backingScale: CGFloat = 1, replacing: Bool = true) throws -> URL {
        let bytes = try data(for: image, format: format, scale: scale, backingScale: backingScale)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if replacing {
                try bytes.write(to: url, options: .atomic)
            } else {
                try writeWithoutReplacing(bytes, to: url)
            }
        } catch ExportError.fileExists {
            throw ExportError.fileExists
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return url
    }

    /// Stages `bytes` beside `url` and moves them into place, which fails instead of replacing an existing file.
    private static func writeWithoutReplacing(_ bytes: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let staging = url.deletingLastPathComponent().appendingPathComponent(".glint-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: staging) }
        try bytes.write(to: staging)
        do {
            try fileManager.moveItem(at: staging, to: url)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw ExportError.fileExists
        }
    }

    /// Puts the image on the general pasteboard as a PNG, plus a TIFF for legacy apps, without waiting for either to
    /// be encoded.
    ///
    /// The clipboard is replaced at once with a promise. The PNG is encoded in the background from then on, so it is
    /// normally ready by the time anything pastes, and `write` and `data(for:)` reuse it for the same image. The TIFF is
    /// made, from the PNG, only when an app asks for it. So `true` means the clipboard took the promise; an image that
    /// cannot be encoded (not expected for a bitmap) shows up as an empty paste. Call `flushPendingClipboard()` as the
    /// app quits so a promise that nothing has collected yet is not lost.
    ///
    /// Pass the same `scale` and `backingScale` as the matching `write`: both representations then have the file's
    /// pixel size and density, so apps that honour image resolution paste it at the saved copy's point size.
    @discardableResult
    public static func copyToClipboard(_ image: CGImage, scale: ExportScale = .original, backingScale: CGFloat = 1,
                                       pasteboard: NSPasteboard = .general) -> Bool {
        let signpost = CaptureSignposts.begin("Pasteboard")
        let published = LazyImageClipboard.publish(image, scale: scale, backingScale: backingScale, on: pasteboard)
        CaptureSignposts.end(signpost, published ? .completed : .failed)
        return published
    }

    /// Makes the clipboard's promised representations real, so the image can still be pasted after the app has quit.
    /// Does nothing when the clipboard has since been replaced or nothing is promised.
    public static func flushPendingClipboard() {
        LazyImageClipboard.flushPending()
    }

    static func resampled(_ image: CGImage, scale: ExportScale, backingScale: CGFloat) -> CGImage {
        let factor: CGFloat
        switch scale {
        case .original: return image
        case .x1: factor = 1
        case .x2: factor = 2
        }
        let w = max(Int((CGFloat(image.width) / max(backingScale, 0.1) * factor).rounded()), 1)
        let h = max(Int((CGFloat(image.height) / max(backingScale, 0.1) * factor).rounded()), 1)
        guard w != image.width || h != image.height, let ctx = GlintBitmap.makeContext(width: w, height: h) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    static func flattened(_ image: CGImage, background: RGBAColor = .white) -> CGImage {
        guard let ctx = GlintBitmap.makeContext(width: image.width, height: image.height) else { return image }
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }
}

// MARK: - Naming and paths

public enum FileNaming {
    public static let defaultTemplate = "Glint-{datetime}"
    public static let rawTemplate = "Glint-{datetime}-{uuid}"

    /// `yyyy-MM-dd-HH.mm.ss` in the given time zone (local by default).
    public static func datetime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        return f.string(from: date)
    }

    /// Replaces `{datetime}` and `{uuid}`; characters illegal in file names are replaced by `-`.
    public static func fileName(template: String, date: Date = Date(), uuid: UUID = UUID(),
                                timeZone: TimeZone = .current) -> String {
        var name = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = defaultTemplate }
        name = name.replacingOccurrences(of: "{datetime}", with: datetime(date, timeZone: timeZone))
            .replacingOccurrences(of: "{uuid}", with: uuid.uuidString)
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return name
    }

    /// `dir/base.ext`, or `dir/base-2.ext`, `-3`… if that exists.
    public static func uniqueURL(directory: URL, baseName: String, ext: String,
                                 fileManager: FileManager = .default) -> URL {
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}

/// Raw/Output history folders and the default save location.
public struct OutputPaths: Equatable, Sendable {
    /// Base of the history; `Raw/` and `Output/` live below it. Nil disables history.
    public var historyDirectory: URL?
    public var saveDirectory: URL
    public var fileNameTemplate: String
    public var timeZone: TimeZone

    public init(historyDirectory: URL?, saveDirectory: URL, fileNameTemplate: String = FileNaming.defaultTemplate,
                timeZone: TimeZone = .current) {
        self.historyDirectory = historyDirectory; self.saveDirectory = saveDirectory
        self.fileNameTemplate = fileNameTemplate; self.timeZone = timeZone
    }

    public var rawDirectory: URL? { historyDirectory?.appendingPathComponent("Raw", isDirectory: true) }
    public var outputDirectory: URL? { historyDirectory?.appendingPathComponent("Output", isDirectory: true) }

    /// Unused URL for the unstyled capture. Creates the directory.
    public func rawURL(date: Date = Date(), uuid: UUID = UUID()) -> URL? {
        guard let dir = rawDirectory else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = FileNaming.fileName(template: FileNaming.rawTemplate, date: date, uuid: uuid, timeZone: timeZone)
        return FileNaming.uniqueURL(directory: dir, baseName: name, ext: "png")
    }

    /// Unused URL for the rendered result in `Output/`. Creates the directory.
    public func outputURL(date: Date = Date(), format: ExportFormat = .plainPNG) -> URL? {
        guard let dir = outputDirectory else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = FileNaming.fileName(template: fileNameTemplate, date: date, timeZone: timeZone)
        return FileNaming.uniqueURL(directory: dir, baseName: name, ext: format.fileExtension)
    }

    /// Unused URL in the save directory (Save / Save As default).
    public func saveURL(date: Date = Date(), format: ExportFormat = .plainPNG) -> URL {
        try? FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        let name = FileNaming.fileName(template: fileNameTemplate, date: date, timeZone: timeZone)
        return FileNaming.uniqueURL(directory: saveDirectory, baseName: name, ext: format.fileExtension)
    }
}
