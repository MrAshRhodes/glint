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
}

public enum Exporter {
    /// Encodes `image`. `x1`/`x2` resample to 1×/2× the image's point size (pixels / `backingScale`).
    public static func data(for image: CGImage, format: ExportFormat = .plainPNG, scale: ExportScale = .original,
                            backingScale: CGFloat = 1) throws -> Data {
        var output = resampled(image, scale: scale, backingScale: backingScale)
        let dpiFactor: CGFloat
        switch scale {
        case .original: dpiFactor = backingScale
        case .x1: dpiFactor = 1
        case .x2: dpiFactor = 2
        }
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

    @discardableResult
    public static func write(_ image: CGImage, to url: URL, format: ExportFormat = .plainPNG, scale: ExportScale = .original,
                             backingScale: CGFloat = 1) throws -> URL {
        let bytes = try data(for: image, format: format, scale: scale, backingScale: backingScale)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return url
    }

    /// Puts a PNG (plus TIFF for legacy apps) on the general pasteboard.
    @discardableResult
    public static func copyToClipboard(_ image: CGImage, pasteboard: NSPasteboard = .general) -> Bool {
        guard let png = try? data(for: image, format: .plainPNG) else { return false }
        pasteboard.clearContents()
        var ok = pasteboard.setData(png, forType: .png)
        if let tiff = try? data(for: image, format: .tiff) { ok = pasteboard.setData(tiff, forType: .tiff) && ok }
        return ok
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
