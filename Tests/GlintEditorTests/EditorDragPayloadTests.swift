import AppKit
import Testing
import UniformTypeIdentifiers
@testable import GlintCore
@testable import GlintEditor

private enum PayloadFailure: Error { case refused, timedOut }

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: Bool?

    var value: Bool? { lock.withLock { recorded } }
    func record(_ value: Bool) { lock.withLock { recorded = value } }
}

private func makeImage() throws -> CGImage {
    let context = try #require(GlintBitmap.makeContext(width: 8, height: 6))
    context.setFillColor(RGBAColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
    return try #require(context.makeImage())
}

/// A payload whose file is written by `Exporter`, like the editor's.
private func makePayload(in directory: URL, fileName: String = "Shot.png", before: @escaping @Sendable () throws -> Void = {})
    throws -> (payload: EditorDragPayload, delivery: EditorDragPayload.Delivery) {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let delivery = EditorDragPayload.Delivery(url: directory.appendingPathComponent(fileName), image: try makeImage())
    let payload = EditorDragPayload(fileName: fileName) {
        try before()
        _ = try Exporter.write(delivery.image, to: delivery.url, format: .plainPNG, scale: .original, backingScale: 2)
        return delivery
    }
    return (payload, delivery)
}

/// A payload whose file has been written already.
@MainActor
private func finishedPayload(in directory: URL, fileName: String) async throws -> EditorDragPayload {
    let (payload, _) = try makePayload(in: directory, fileName: fileName)
    guard case .success = await payload.delivery() else { throw PayloadFailure.refused }
    return payload
}

@Suite("Editor drag payload")
@MainActor
struct EditorDragPayloadTests {
    private func board() -> NSPasteboard {
        NSPasteboard(name: .init("glint.drag.tests.\(UUID().uuidString)"))
    }

    @Test func offersTheFilePromiseAndTheFileURL() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let (payload, _) = try makePayload(in: f.directory)
        let board = board(); defer { board.releaseGlobally() }
        let plain = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: try #require(payload.delegate))

        let types = payload.writableTypes(for: board)
        #expect(types.contains(.fileURL))
        #expect(Set(types) == Set(plain.writableTypes(for: board)).union([.fileURL]))
    }

    @Test func theFileURLIsPromisedAndTheOtherTypesKeepTheirOptions() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let (payload, _) = try makePayload(in: f.directory)
        let board = board(); defer { board.releaseGlobally() }
        let plain = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: try #require(payload.delegate))

        #expect(payload.writingOptions(forType: .fileURL, pasteboard: board) == .promised)
        for type in plain.writableTypes(for: board) {
            #expect(payload.writingOptions(forType: type, pasteboard: board)
                == plain.writingOptions(forType: type, pasteboard: board))
        }
    }

    @Test func theFileURLIsTheFinishedFileOnceTheRenderEnded() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let (payload, delivery) = try makePayload(in: f.directory)

        let handedOut = try #require(payload.pasteboardPropertyList(forType: .fileURL) as? String)
        let url = try #require(URL(string: handedOut))
        #expect(url.standardizedFileURL.path == delivery.url.standardizedFileURL.path)
        let image = try #require(GlintImageIO.load(url: url))
        #expect(image.width == delivery.image.width && image.height == delivery.image.height)

        // Asking again, or another way, gives the same file.
        guard case .success(let again) = await payload.delivery(), case .success(let waited) = payload.waitForDelivery()
        else {
            Issue.record("The payload reported a failure")
            return
        }
        #expect(again.url == delivery.url && waited.url == delivery.url)
    }

    @Test func aDestinationThatAsksForTheFileGetsTheFinishedPNG() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let (payload, delivery) = try makePayload(in: f.directory, fileName: "Promised.png")
        let delegate = try #require(payload.delegate)
        let destination = f.directory.appendingPathComponent("Dropped/Out.png")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        #expect(delegate.filePromiseProvider(payload, fileNameForType: UTType.png.identifier) == "Promised.png")
        let error: Error? = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(payload, writePromiseTo: destination) { continuation.resume(returning: $0) }
        }
        #expect(error == nil)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: delivery.url))
        #expect(GlintImageIO.load(url: destination) != nil)
    }

    @Test func aFailedRenderHandsOutNothing() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let payload = EditorDragPayload(fileName: "Shot.png") { throw PayloadFailure.refused }
        let delegate = try #require(payload.delegate)
        let destination = f.directory.appendingPathComponent("Out.png")
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)

        guard case .failure(let failure) = await payload.delivery() else {
            Issue.record("A failed render reported a delivery")
            return
        }
        #expect(failure as? PayloadFailure == .refused)
        #expect(payload.pasteboardPropertyList(forType: .fileURL) == nil)
        let error: Error? = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(payload, writePromiseTo: destination) { continuation.resume(returning: $0) }
        }
        #expect(error as? PayloadFailure == .refused)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func aFileMarkedForRemovalGoesWhenThePayloadIsReleased() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let marked = f.directory.appendingPathComponent("Marked.png")
        let untouched = f.directory.appendingPathComponent("Untouched.png")
        var payloads = [try await finishedPayload(in: f.directory, fileName: "Marked.png"),
                        try await finishedPayload(in: f.directory, fileName: "Untouched.png")]
        payloads[0].removeFileWhenReleased = marked
        #expect(FileManager.default.fileExists(atPath: marked.path))

        payloads.removeAll()
        await waitUntil { !FileManager.default.fileExists(atPath: marked.path) }
        #expect(!FileManager.default.fileExists(atPath: marked.path))
        #expect(FileManager.default.fileExists(atPath: untouched.path))
    }

    @Test func theRenderStartsAtOnceAndNeverRunsOnTheMainThread() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let gate = DispatchSemaphore(value: 0)
        let onMain = Flag()
        // The render waits for the test, so creating the payload must not wait for the render.
        let (payload, delivery) = try makePayload(in: f.directory) {
            onMain.record(Thread.isMainThread)
            guard gate.wait(timeout: .now() + 20) == .success else { throw PayloadFailure.timedOut }
        }
        #expect(!FileManager.default.fileExists(atPath: delivery.url.path))
        gate.signal()

        guard case .success(let finished) = await payload.delivery() else {
            Issue.record("The payload did not finish")
            return
        }
        #expect(finished.url == delivery.url && FileManager.default.fileExists(atPath: finished.url.path))
        #expect(onMain.value == false)
    }

    @Test func everyoneWaitingIsToldWhenTheRenderEnds() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let gate = DispatchSemaphore(value: 0)
        let (payload, delivery) = try makePayload(in: f.directory) {
            guard gate.wait(timeout: .now() + 20) == .success else { throw PayloadFailure.timedOut }
        }
        async let first = payload.delivery()
        async let second = payload.delivery()
        try await Task.sleep(for: .milliseconds(50))
        gate.signal()

        for outcome in await [first, second] {
            guard case .success(let finished) = outcome else {
                Issue.record("A waiting caller was not given the file")
                continue
            }
            #expect(finished.url == delivery.url)
        }
    }
}
