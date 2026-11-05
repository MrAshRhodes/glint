import AppKit
import Foundation
import ImageIO
import Testing
@testable import GlintCore

@Suite("Recording export files")
struct RecordingExportFilesTests {
    private func scratch() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/TestFixtures/files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func commitReplacesAnExistingFileAtTheSamePath() throws {
        let directory = try scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("clip.gif")
        let staged = directory.appendingPathComponent("staged.gif")
        try Data("old".utf8).write(to: destination)
        try Data("new content".utf8).write(to: staged)

        try RecordingExportFiles.commit(staged, to: destination)

        #expect(try Data(contentsOf: destination) == Data("new content".utf8))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["clip.gif"])
    }

    @Test func commitCreatesTheDestinationAndItsFolder() throws {
        let directory = try scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("New Folder/clip.mp4")
        let staged = directory.appendingPathComponent("staged.mp4")
        try Data("video".utf8).write(to: staged)

        try RecordingExportFiles.commit(staged, to: destination)

        #expect(try Data(contentsOf: destination) == Data("video".utf8))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func commitOfAMissingFileFailsAndLeavesTheDestinationAlone() throws {
        let directory = try scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("clip.gif")
        try Data("keep me".utf8).write(to: destination)

        #expect(throws: RecordingExportError.self) {
            try RecordingExportFiles.commit(directory.appendingPathComponent("nope.gif"), to: destination)
        }
        #expect(try Data(contentsOf: destination) == Data("keep me".utf8))
    }

    @Test func stagingDirectoriesAreFreshAndEmpty() throws {
        let directory = try scratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("clip.gif")

        let forDestination = try RecordingExportFiles.makeStagingDirectory(forDestination: destination)
        let generic = try RecordingExportFiles.makeStagingDirectory()
        defer {
            try? FileManager.default.removeItem(at: forDestination)
            try? FileManager.default.removeItem(at: generic)
        }

        #expect(forDestination != generic)
        for url in [forDestination, generic] {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
            #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
        }
    }

    @Test func defaultFileNameUsesTheDateAndExtension() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_793_889_000)   // 2026-11-05 14:30:00 UTC
        #expect(RecordingExportFiles.defaultFileName(format: .gif, date: date, timeZone: utc) == "Glint Recording 2026-11-05 at 14.30.00.gif")
        #expect(RecordingExportFiles.defaultFileName(format: .mp4, date: date, timeZone: utc) == "Glint Recording 2026-11-05 at 14.30.00.mp4")
    }

    @Test func exportedFileCanBeCommittedOverAnExistingSave() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let source = try await fixture.video(frames: 20, fps: 10)
        let destination = fixture.directory.appendingPathComponent("Saved.gif")
        try Data("previous save".utf8).write(to: destination)
        let staging = try RecordingExportFiles.makeStagingDirectory(forDestination: destination)
        defer { try? FileManager.default.removeItem(at: staging) }

        let exported = try await RecordingExporter.export(source: source, range: 0...1.5, options: RecordingExportOptions(),
                                                          outputDirectory: staging)
        try RecordingExportFiles.commit(exported, to: destination)

        let gif = try #require(GIFInspection(url: destination))
        #expect(gif.frameCount > 1)
        #expect(!FileManager.default.fileExists(atPath: exported.path))
    }
}

@Suite("GIF stream writer")
struct RecordingExportGIFWriterTests {
    private func solid(_ width: Int, _ height: Int, _ color: RGBAColor) -> CGImage {
        TestImages.solid(width, height, color)
    }

    @Test func writesAnInfinitelyLoopingMultiFrameGIFWithPerFrameDelays() throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let url = fixture.directory.appendingPathComponent("direct.gif")
        let writer = try GIFStreamWriter(url: url, width: 40, height: 30)
        let colours: [RGBAColor] = [.red, RGBAColor(r: 0, g: 0.8, b: 0), RGBAColor(r: 0, g: 0, b: 1)]
        for (index, colour) in colours.enumerated() {
            try writer.append(solid(40, 30, colour), delayCentiseconds: 5 + index * 5)
        }
        try writer.finish()

        let gif = try #require(GIFInspection(url: url))
        #expect(gif.frameCount == 3)
        #expect(gif.loopCount == 0)
        #expect((gif.width, gif.height) == (40, 30))
        #expect(zip(gif.delays, [0.05, 0.10, 0.15]).allSatisfy { abs($0 - $1) < 0.001 }, "\(gif.delays)")
        for (index, colour) in colours.enumerated() {
            let pixel = TestImages.pixel(try #require(gif.image(at: index)), 20, 15)
            #expect(abs(Double(pixel.r) - colour.r * 255) < 12 && abs(Double(pixel.g) - colour.g * 255) < 12
                    && abs(Double(pixel.b) - colour.b * 255) < 12, "frame \(index): \(pixel)")
        }
    }

    @Test func abortDeletesThePartialFile() throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let url = fixture.directory.appendingPathComponent("partial.gif")
        let writer = try GIFStreamWriter(url: url, width: 40, height: 30)
        try writer.append(solid(40, 30, .red), delayCentiseconds: 10)
        #expect(FileManager.default.fileExists(atPath: url.path))

        writer.abort()

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(throws: RecordingExportError.self) { try writer.append(solid(40, 30, .red), delayCentiseconds: 10) }
    }

    @Test func rejectsFramesOfTheWrongSizeAndInvalidCanvases() throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let url = fixture.directory.appendingPathComponent("size.gif")
        let writer = try GIFStreamWriter(url: url, width: 40, height: 30)
        defer { writer.abort() }

        #expect(throws: RecordingExportError.self) { try writer.append(solid(41, 30, .red), delayCentiseconds: 10) }
        #expect(throws: RecordingExportError.self) { _ = try GIFStreamWriter(url: url, width: 0, height: 30) }
        #expect(throws: RecordingExportError.self) { _ = try GIFStreamWriter(url: url, width: 70_000, height: 30) }
    }

    @Test func spliceKeepsLocalColourTablesAndDropsExtensions() {
        // 1×1 GIF: global colour table of 2 entries, a Graphic Control Extension, then the image.
        let single: [UInt8] = Array("GIF89a".utf8) + [1, 0, 1, 0, 0x80, 0, 0]
            + [0xFF, 0, 0, 0, 0xFF, 0]
            + [0x21, 0xF9, 0x04, 0x00, 0x0A, 0x00, 0x00, 0x00]
            + [0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0x00]
            + [0x02, 0x02, 0x44, 0x01, 0x00]
            + [0x3B]

        let block = GIFStreamWriter.imageBlock(fromSingleFrameGIF: single)

        let expected: [UInt8] = [0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0x80]   // local colour table flag, 2 entries
            + [0xFF, 0, 0, 0, 0xFF, 0]
            + [0x02, 0x02, 0x44, 0x01, 0x00]
        #expect(block == expected)
    }

    @Test func spliceRejectsTruncatedOrForeignData() {
        #expect(GIFStreamWriter.imageBlock(fromSingleFrameGIF: []) == nil)
        #expect(GIFStreamWriter.imageBlock(fromSingleFrameGIF: Array("PNG not a gif at all".utf8)) == nil)
        #expect(GIFStreamWriter.imageBlock(fromSingleFrameGIF: Array("GIF89a".utf8) + [1, 0, 1, 0, 0x80, 0, 0, 0xFF]) == nil)
        let noImage: [UInt8] = Array("GIF89a".utf8) + [1, 0, 1, 0, 0x00, 0, 0, 0x3B]
        #expect(GIFStreamWriter.imageBlock(fromSingleFrameGIF: noImage) == nil)
    }

    @Test func delaysAddUpToTheRangeAtEveryFrameRate() {
        for fps in [10.0, 15.0, 20.0] {
            let total = (0..<Int(fps * 3)).reduce(0) { $0 + RecordingExporter.delay(forFrame: $1, framesPerSecond: fps) }
            #expect(total == 300, "fps \(fps): \(total) cs")
        }
        #expect((0..<3).map { RecordingExporter.delay(forFrame: $0, framesPerSecond: 15) } == [7, 6, 7])
    }
}
