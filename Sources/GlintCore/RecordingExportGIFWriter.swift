import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes an animated GIF to disk one frame at a time, so memory stays at about one frame however long the GIF is.
///
/// ImageIO's multi-frame GIF destination keeps every frame in memory until it is finalized (measured: about 4 GB
/// for 450 frames at 1280 px wide). Instead each frame is encoded as a one-frame GIF and its image data is spliced
/// into a single growing file behind a loop-forever header and a per-frame delay.
final class GIFStreamWriter {
    let width: Int
    let height: Int
    private let url: URL
    private var handle: FileHandle?

    init(url: URL, width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= Int(UInt16.max), height <= Int(UInt16.max) else {
            throw RecordingExportError.encodingFailed("\(width)×\(height) is not a valid GIF size")
        }
        self.url = url
        self.width = width
        self.height = height
        do {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw RecordingExportError.writeFailed("couldn't create \(url.lastPathComponent)")
            }
            let handle = try FileHandle(forWritingTo: url)
            self.handle = handle
            try handle.write(contentsOf: Self.header(width: width, height: height))
        } catch let error as RecordingExportError {
            throw error
        } catch {
            throw RecordingExportError.writeFailed(error.localizedDescription)
        }
    }

    deinit { try? handle?.close() }

    /// Appends `image`, which must be `width`×`height`, shown for `delayCentiseconds`.
    func append(_ image: CGImage, delayCentiseconds: Int) throws {
        guard let handle else { throw RecordingExportError.writeFailed("the GIF is already closed") }
        guard image.width == width, image.height == height else {
            throw RecordingExportError.encodingFailed("frame size differs from the GIF size")
        }
        let single = try Self.encodeSingleFrame(image)
        guard let block = Self.imageBlock(fromSingleFrameGIF: single) else {
            throw RecordingExportError.encodingFailed("the system GIF encoder produced an unexpected layout")
        }
        let delay = UInt16(clamping: max(delayCentiseconds, 2))
        // Disposal 1 (leave in place), no transparency: every frame covers the whole canvas.
        var frame: [UInt8] = [0x21, 0xF9, 0x04, 0x04, UInt8(delay & 0xFF), UInt8(delay >> 8), 0x00, 0x00]
        frame.append(contentsOf: block)
        do {
            try handle.write(contentsOf: frame)
        } catch {
            throw RecordingExportError.writeFailed(error.localizedDescription)
        }
    }

    /// Writes the trailer and closes the file.
    func finish() throws {
        guard let handle else { return }
        self.handle = nil
        do {
            try handle.write(contentsOf: [0x3B])
            try handle.close()
        } catch {
            throw RecordingExportError.writeFailed(error.localizedDescription)
        }
    }

    /// Closes and deletes the partial file.
    func abort() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Format

    static func header(width: Int, height: Int) -> [UInt8] {
        var bytes = Array("GIF89a".utf8)
        bytes += [UInt8(width & 0xFF), UInt8(width >> 8), UInt8(height & 0xFF), UInt8(height >> 8)]
        // No global colour table: each frame carries its own palette.
        bytes += [0x70, 0x00, 0x00]
        // NETSCAPE2.0 application extension: loop count 0 = forever.
        bytes += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]
        return bytes
    }

    private static func encodeSingleFrame(_ image: CGImage) throws -> [UInt8] {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 1, nil) else {
            throw RecordingExportError.encodingFailed("the system has no GIF encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RecordingExportError.encodingFailed("a frame couldn't be encoded")
        }
        return [UInt8](data as Data)
    }

    /// The image descriptor, colour table and LZW data of the only frame in `bytes`, rewritten to use a local colour
    /// table so it can sit in any GIF. Extensions in the source are dropped. Nil if `bytes` isn't a one-frame GIF.
    static func imageBlock(fromSingleFrameGIF bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count > 13, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 else { return nil }
        let screenFlags = bytes[10]
        let globalSizeBits = screenFlags & 0x07
        var index = 13
        var globalTable: [UInt8] = []
        if screenFlags & 0x80 != 0 {
            let size = 3 * (1 << (Int(globalSizeBits) + 1))
            guard index + size <= bytes.count else { return nil }
            globalTable = Array(bytes[index..<index + size])
            index += size
        }
        while index < bytes.count {
            switch bytes[index] {
            case 0x21:
                guard let next = endOfSubBlocks(in: bytes, from: index + 2) else { return nil }
                index = next
            case 0x2C:
                guard index + 10 <= bytes.count else { return nil }
                var block = Array(bytes[index..<index + 9])
                let flags = bytes[index + 9]
                index += 10
                var table: [UInt8]
                if flags & 0x80 != 0 {
                    let size = 3 * (1 << (Int(flags & 0x07) + 1))
                    guard index + size <= bytes.count else { return nil }
                    table = Array(bytes[index..<index + size])
                    index += size
                    block.append(flags)
                } else {
                    guard !globalTable.isEmpty else { return nil }
                    table = globalTable
                    block.append((flags & 0x40) | 0x80 | globalSizeBits)
                }
                guard index < bytes.count, let end = endOfSubBlocks(in: bytes, from: index + 1) else { return nil }
                block.append(contentsOf: table)
                block.append(contentsOf: bytes[index..<end])
                return block
            default:
                return nil
            }
        }
        return nil
    }

    /// Index just past the zero-length terminator of the data sub-blocks that start at `start`.
    private static func endOfSubBlocks(in bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            let length = Int(bytes[index])
            if length == 0 { return index + 1 }
            index += length + 1
        }
        return nil
    }
}
