import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GlintCore

private extension RGBAColor {
    static let blue = RGBAColor(r: 0, g: 0, b: 1)
    static let green = RGBAColor(r: 0, g: 1, b: 0)
}

@Suite("Lazy clipboard")
@MainActor
struct LazyClipboardTests {
    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("glint.test.lazy.\(UUID().uuidString)"))
    }

    private func decoded(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func density(of data: Data) throws -> Double {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return try #require(properties[kCGImagePropertyDPIWidth] as? Double)
    }

    /// Counts encodes and, when given a gate, holds each one until the gate opens.
    private final class Encodes: @unchecked Sendable {
        private let lock = NSLock()
        private var counted = 0
        let started = DispatchSemaphore(value: 0)
        let gate: DispatchSemaphore?
        let result: Data?

        init(gate: DispatchSemaphore? = nil, result: Data? = nil) {
            self.gate = gate
            self.result = result
        }

        var count: Int { lock.withLock { counted } }

        var encoder: LazyImageClipboard.Encoder {
            { [self] image, scale, backingScale in
                lock.withLock { counted += 1 }
                started.signal()
                gate?.wait()
                return try result ?? Exporter.encode(image, format: .plainPNG, scale: scale, backingScale: backingScale)
            }
        }
    }

    @Test func publishingDoesNotWaitForTheEncode() throws {
        let pb = pasteboard(); defer { pb.releaseGlobally() }
        let encodes = Encodes(gate: DispatchSemaphore(value: 0), result: Data([1, 2, 3]))
        let image = TestImages.solid(40, 30, .red)

        // The encoder is held shut, so a publish that waited for it would never return.
        #expect(LazyImageClipboard.publish(image, scale: .original, backingScale: 1, on: pb, encoder: encodes.encoder))
        #expect(encodes.started.wait(timeout: .now() + 5) == .success)
        #expect(LazyImageClipboard.current(on: pb) != nil)

        encodes.gate?.signal()
        #expect(pb.data(forType: .png) == Data([1, 2, 3]))
    }

    @Test func aPasteWhileTheEncodeIsRunningGetsItsResult() throws {
        let pb = pasteboard(); defer { pb.releaseGlobally() }
        let encodes = Encodes(gate: DispatchSemaphore(value: 0))
        let image = TestImages.framed(width: 64, height: 48, margins: EdgeMargins(top: 4, left: 4, bottom: 4, right: 4))
        #expect(LazyImageClipboard.publish(image, scale: .original, backingScale: 1, on: pb, encoder: encodes.encoder))
        let provider = try #require(LazyImageClipboard.current(on: pb))
        #expect(encodes.started.wait(timeout: .now() + 5) == .success)

        let results = ResultsBox()
        let group = DispatchGroup()
        for _ in 0..<3 {
            DispatchQueue.global().async(group: group) { results.add(provider.pngData()) }
        }
        encodes.gate?.signal()
        #expect(group.wait(timeout: .now() + 10) == .success)

        let pngs = results.all
        #expect(pngs.count == 3 && pngs.allSatisfy { $0 != nil && $0 == pngs[0] })
        #expect(encodes.count == 1)
    }

    private final class ResultsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Data?] = []
        func add(_ value: Data?) { lock.withLock { values.append(value) } }
        var all: [Data?] { lock.withLock { values } }
    }

    @Test func pastingAndSavingEncodeThePNGOnce() throws {
        let pb = pasteboard(); defer { pb.releaseGlobally() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = TestImages.framed(width: 90, height: 60, margins: EdgeMargins(top: 3, left: 3, bottom: 3, right: 3))
        let encodes = Encodes()
        #expect(LazyImageClipboard.publish(image, scale: .x2, backingScale: 2, on: pb, encoder: encodes.encoder))

        let pasted = try #require(pb.data(forType: .png))
        let saved = try Exporter.write(image, to: dir.appendingPathComponent("saved.png"), scale: .x2, backingScale: 2)
        let again = try Exporter.data(for: image, format: .plainPNG, scale: .x2, backingScale: 2)

        #expect(try Data(contentsOf: saved) == pasted)
        #expect(again == pasted)
        #expect(encodes.count == 1)
    }

    @Test func onlyAnIdenticalPlainPNGIsReused() throws {
        let pb = pasteboard(); defer { pb.releaseGlobally() }
        let sentinel = Data([9, 9, 9])
        let image = TestImages.solid(40, 30, .blue)
        #expect(LazyImageClipboard.publish(image, scale: .original, backingScale: 2, on: pb,
                                           encoder: Encodes(result: sentinel).encoder))

        #expect(try Exporter.data(for: image, scale: .original, backingScale: 2) == sentinel)
        // Anything that would encode differently is encoded for real.
        #expect(try Exporter.data(for: image, scale: .original, backingScale: 1) != sentinel)
        #expect(try Exporter.data(for: image, scale: .x1, backingScale: 2) != sentinel)
        #expect(try Exporter.data(for: image, format: .png(interlaced: true), scale: .original, backingScale: 2) != sentinel)
        #expect(try Exporter.data(for: image, format: .jpeg(quality: 0.8), scale: .original, backingScale: 2) != sentinel)
        // The same pixels in another image object are not the published image.
        let copy = TestImages.solid(40, 30, .blue)
        #expect(try Exporter.data(for: copy, scale: .original, backingScale: 2) != sentinel)
    }

    @Test func replacingTheClipboardFinishesTheOldImage() throws {
        let pb = pasteboard(); defer { pb.releaseGlobally() }
        let sentinel = Data([7, 7, 7])
        let first = TestImages.solid(20, 20, .red)
        #expect(LazyImageClipboard.publish(first, scale: .original, backingScale: 1, on: pb,
                                           encoder: Encodes(result: sentinel).encoder))
        let provider = try #require(LazyImageClipboard.current(on: pb))
        #expect(try Exporter.data(for: first) == sentinel)

        let second = TestImages.solid(21, 20, .green)
        #expect(Exporter.copyToClipboard(second, pasteboard: pb))

        #expect(provider.pngData() == nil)
        #expect(try Exporter.data(for: first) != sentinel)
        let current = try #require(LazyImageClipboard.current(on: pb))
        #expect(current !== provider)
        #expect(try decoded(#require(pb.data(forType: .png))).width == 21)
    }

    @Test func theImageStaysPasteableAfterItsCreatorIsGone() throws {
        let pb = pasteboard(); defer { pb.releaseGlobally() }
        autoreleasepool {
            let image = TestImages.framed(width: 70, height: 50, margins: EdgeMargins(top: 2, left: 2, bottom: 2, right: 2))
            #expect(Exporter.copyToClipboard(image, scale: .x1, backingScale: 2, pasteboard: pb))
        }
        // Nothing but the clipboard refers to the image or the provider now.
        let png = try #require(pb.data(forType: .png))
        let tiff = try #require(pb.data(forType: .tiff))
        #expect(try decoded(png).width == 35 && decoded(png).height == 25)
        #expect(try decoded(tiff).width == 35 && decoded(tiff).height == 25)
        #expect(try abs(density(of: png) - 72) < 0.1 && abs(density(of: tiff) - 72) < 0.1)
    }

    @Test func theTIFFHasTheSamePixelsAsADirectEncode() throws {
        let pb = pasteboard(); defer { pb.releaseGlobally() }
        let image = TestImages.framed(width: 80, height: 40, margins: EdgeMargins(top: 5, left: 5, bottom: 5, right: 5))
        #expect(Exporter.copyToClipboard(image, scale: .original, backingScale: 2, pasteboard: pb))

        let pasted = try decoded(#require(pb.data(forType: .tiff)))
        let direct = try decoded(Exporter.encode(image, format: .tiff, scale: .original, backingScale: 2))
        try expectSamePixels(pasted, direct)
        #expect(try abs(density(of: #require(pb.data(forType: .tiff))) - 144) < 0.1)
    }

    @Test func aTranslucentImageKeepsItsAlphaInBothRepresentations() throws {
        let pb = pasteboard(); defer { pb.releaseGlobally() }
        let image = TestImages.solid(16, 16, RGBAColor(r: 1, g: 0, b: 0, a: 0.5))
        #expect(Exporter.copyToClipboard(image, pasteboard: pb))
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            let pasted = try decoded(#require(pb.data(forType: type)))
            let pixel = TestImages.pixel(pasted, 8, 8)
            #expect(abs(Int(pixel.a) - 128) <= 1, "\(type.rawValue) alpha \(pixel.a)")
            #expect(pixel.r > 250 || abs(Int(pixel.r) - 128) <= 2, "\(type.rawValue) red \(pixel.r)")
        }
    }

    @Test func flushingHandsEveryRepresentationToThePasteboard() throws {
        let pb = pasteboard(); defer { pb.releaseGlobally() }
        let image = TestImages.framed(width: 50, height: 50, margins: EdgeMargins(top: 2, left: 2, bottom: 2, right: 2))
        #expect(Exporter.copyToClipboard(image, pasteboard: pb))
        let provider = try #require(LazyImageClipboard.current(on: pb))

        Exporter.flushPendingClipboard()

        // The pasteboard has taken both, so it no longer depends on this object.
        #expect(provider.pngData() == nil)
        #expect(LazyImageClipboard.current(on: pb) == nil)
        #expect(try decoded(#require(pb.data(forType: .png))).width == 50)
        #expect(try decoded(#require(pb.data(forType: .tiff))).width == 50)
    }

    @Test func flushingLeavesAReplacedClipboardAlone() throws {
        let pb = pasteboard(); defer { pb.releaseGlobally() }
        #expect(Exporter.copyToClipboard(TestImages.solid(10, 10, .red), pasteboard: pb))
        pb.clearContents()
        pb.setString("later", forType: .string)

        Exporter.flushPendingClipboard()

        #expect(pb.string(forType: .string) == "later")
        #expect(pb.data(forType: .png) == nil)
    }

    @Test func aFailedEncodeIsAnEmptyPasteNotACrash() throws {
        let pb = pasteboard(); defer { pb.releaseGlobally() }
        let failing: LazyImageClipboard.Encoder = { _, _, _ in throw ExportError.encodingFailed }
        let image = TestImages.solid(10, 10, .red)
        #expect(LazyImageClipboard.publish(image, scale: .original, backingScale: 1, on: pb, encoder: failing))

        #expect(pb.data(forType: .png) == nil)
        #expect(pb.data(forType: .tiff) == nil)
        // Saving still encodes for real rather than reusing the failure.
        #expect(try Exporter.data(for: image).count > 8)
    }
}
