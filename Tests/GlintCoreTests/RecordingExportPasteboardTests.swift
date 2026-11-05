import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GlintCore

@Suite("Recording pasteboard")
struct RecordingExportPasteboardTests {
    private let gifType = NSPasteboard.PasteboardType(UTType.gif.identifier)

    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("glint.recording.tests.\(UUID().uuidString)"))
    }

    private func exportedFile(_ fixture: RecordingExportFixture, format: RecordingFileFormat) async throws -> URL {
        let source = try await fixture.video(frames: 20, fps: 10)
        return try await RecordingExporter.export(source: source, range: 0...1.5, options: RecordingExportOptions(format: format),
                                                  outputDirectory: fixture.outputDirectory)
    }

    @Test func gifGoesOnAsAnimatedGIFDataAndAFileURLWithNoStillImageFallback() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let board = pasteboard(); defer { board.releaseGlobally() }
        let exported = try await exportedFile(fixture, format: .gif)
        let original = try Data(contentsOf: exported)
        let directory = fixture.directory.appendingPathComponent("clipboard")

        let durable = try RecordingPasteboard.copy(exported, format: .gif, to: board, directory: directory)

        let itemTypes = Set(try #require(board.pasteboardItems?.first?.types))
        #expect(itemTypes == [gifType, .fileURL], "\(itemTypes)")
        #expect(!itemTypes.contains(.png) && !itemTypes.contains(.tiff) && !itemTypes.contains(.pdf))
        let data = try #require(board.data(forType: gifType))
        #expect(data == original)
        let pasted = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(pasted) > 1)

        let fileString = try #require(board.string(forType: .fileURL))
        let fileURL = try #require(URL(string: fileString))
        #expect(fileURL.standardizedFileURL == durable.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: durable.path))
        #expect(durable.pathExtension == "gif" && durable.path.hasPrefix(directory.path))
        #expect(durable.lastPathComponent.hasPrefix("Glint Recording "))
        #expect(try Data(contentsOf: durable) == original)
        #expect(board.pasteboardItems?.count == 1)
    }

    @Test func mp4GoesOnAsAFileURLToAnOwnedCopyOnly() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let board = pasteboard(); defer { board.releaseGlobally() }
        let exported = try await exportedFile(fixture, format: .mp4)
        let original = try Data(contentsOf: exported)
        let directory = fixture.directory.appendingPathComponent("clipboard")

        let durable = try RecordingPasteboard.copy(exported, format: .mp4, to: board, directory: directory)

        #expect(Set(try #require(board.pasteboardItems?.first?.types)) == [.fileURL])
        let fileString = try #require(board.string(forType: .fileURL))
        let fileURL = try #require(URL(string: fileString))
        #expect(fileURL.isFileURL && FileManager.default.fileExists(atPath: fileURL.path))
        #expect(fileURL.standardizedFileURL == durable.standardizedFileURL)
        #expect(durable.pathExtension == "mp4")
        #expect(try Data(contentsOf: durable) == original)
        #expect(board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]))
    }

    @Test func theCopySurvivesTheStagedFileBeingRemoved() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let board = pasteboard(); defer { board.releaseGlobally() }
        let exported = try await exportedFile(fixture, format: .gif)
        let durable = try RecordingPasteboard.copy(exported, format: .gif, to: board, directory: fixture.directory.appendingPathComponent("clipboard"))

        try? FileManager.default.removeItem(at: fixture.outputDirectory)

        #expect(FileManager.default.fileExists(atPath: durable.path))
        #expect(!FileManager.default.fileExists(atPath: exported.path))
    }

    @Test func eachCopyReplacesTheClipboardWithoutLeavingAnImageBehind() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let board = pasteboard(); defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("something earlier", forType: .string)
        board.setData(Data([1, 2, 3]), forType: .png)
        let exported = try await exportedFile(fixture, format: .mp4)

        try RecordingPasteboard.copy(exported, format: .mp4, to: board, directory: fixture.directory.appendingPathComponent("clipboard"))

        #expect(board.string(forType: .string) == nil && board.data(forType: .png) == nil)
    }

    @Test func aMissingExportFailsWithoutTouchingTheClipboard() throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let board = pasteboard(); defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("keep", forType: .string)
        let directory = fixture.directory.appendingPathComponent("clipboard")

        #expect(throws: RecordingExportError.self) {
            try RecordingPasteboard.copy(fixture.directory.appendingPathComponent("missing.gif"), format: .gif, to: board, directory: directory)
        }

        #expect(board.string(forType: .string) == "keep")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty)
    }

    @Test func expiredCopiesAreRemovedOnTheNextCopy() async throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let board = pasteboard(); defer { board.releaseGlobally() }
        let directory = fixture.directory.appendingPathComponent("clipboard")
        let first = try await exportedFile(fixture, format: .mp4)
        let old = try RecordingPasteboard.copy(first, format: .mp4, to: board, directory: directory, now: Date())
        let oldFolder = old.deletingLastPathComponent()
        let aged = Date().addingTimeInterval(-(RecordingPasteboard.retention + 3600))
        try FileManager.default.setAttributes([.modificationDate: aged], ofItemAtPath: oldFolder.path)

        let recent = try await exportedFile(fixture, format: .mp4)
        let newest = try RecordingPasteboard.copy(recent, format: .mp4, to: board, directory: directory)

        #expect(!FileManager.default.fileExists(atPath: oldFolder.path))
        #expect(FileManager.default.fileExists(atPath: newest.path))
    }

    @Test func pruneKeepsRecentCopiesAndIgnoresAMissingFolder() throws {
        let fixture = try RecordingExportFixture(); defer { fixture.cleanUp() }
        let directory = fixture.directory.appendingPathComponent("clipboard")
        RecordingPasteboard.pruneExpired(in: directory)

        let fresh = directory.appendingPathComponent("fresh", isDirectory: true)
        let stale = directory.appendingPathComponent("stale", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: stale.path)

        RecordingPasteboard.pruneExpired(in: directory)

        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func defaultDirectoryLivesInTheCachesFolder() {
        #expect(RecordingPasteboard.defaultDirectory.path.hasSuffix("Glint/Clipboard/Recordings"))
        #expect(RecordingPasteboard.defaultDirectory.path.contains("/Caches/"))
    }
}
