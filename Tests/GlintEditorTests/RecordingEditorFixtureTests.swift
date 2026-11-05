import AppKit
import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import GlintCore
@testable import GlintEditor

/// Writes small synthetic videos for the recording editor tests. Never touches the screen or needs any permission.
enum EditorSyntheticVideo {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func write(to url: URL, frames: Int, fps: Int32, size: CGSize) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = Int(size.width), height = Int(size.height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw Failure(description: "startWriting: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw Failure(description: "no pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw Failure(description: "no pixel buffer") }
            fill(buffer, step: index)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: fps)) else {
                throw Failure(description: "append failed: \(String(describing: writer.error))")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure(description: "finish: \(String(describing: writer.error))") }
    }

    /// A bar sweeps across the top so consecutive frames always differ.
    private static func fill(_ buffer: CVPixelBuffer, step: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * stride + x * 4
                let onBar = y < 12 && (x + step * 3) % width < 40
                p[0] = onBar ? 255 : 80
                p[1] = onBar ? 255 : 160
                p[2] = onBar ? 255 : 60
                p[3] = 255
            }
        }
    }
}

/// A scratch folder inside the repository's ignored `.build` folder with everything the editor touches redirected
/// into it: staging, the clipboard cache, a private pasteboard and the save panel.
@MainActor
final class RecordingEditorFixture {
    let directory: URL
    let board = NSPasteboard(name: .init("glint.recording.editor.tests.\(UUID().uuidString)"))
    /// What the stand-in save panel answers; nil means the user cancels it.
    var chosenDestination: URL?
    private(set) var panelRequests = 0

    init() throws {
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/TestFixtures/recording-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chosenDestination = directory.appendingPathComponent("saved/Export.gif")
    }

    var stagingRoot: URL { directory.appendingPathComponent("staging", isDirectory: true) }
    var clipboardDirectory: URL { directory.appendingPathComponent("clipboard", isDirectory: true) }

    /// Names left in the staging folder; empty once every export has cleaned up.
    var stagingLeftovers: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []).sorted()
    }

    /// A real, playable recording of `frames` frames at `fps`.
    func recording(frames: Int = 20, fps: Int32 = 10, size: CGSize = CGSize(width: 160, height: 90)) async throws -> RecordedVideo {
        let url = directory.appendingPathComponent("Recording-\(UUID().uuidString).mp4")
        try await EditorSyntheticVideo.write(to: url, frames: frames, fps: fps, size: size)
        return RecordedVideo(url: url, duration: Double(frames) / Double(fps), pixelSize: size)
    }

    /// A recording that exists only on paper, for tests whose export is replaced.
    func paperRecording(duration: TimeInterval, size: CGSize = CGSize(width: 1920, height: 1080)) throws -> RecordedVideo {
        let url = directory.appendingPathComponent("Paper-\(UUID().uuidString).mp4")
        try Data("not really a video".utf8).write(to: url)
        return RecordedVideo(url: url, duration: duration, pixelSize: size)
    }

    func services() -> RecordingEditorServices {
        var services = RecordingEditorServices()
        let staging = stagingRoot
        services.makeStagingDirectory = { _ in
            let folder = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        let board = board
        let clipboard = clipboardDirectory
        services.copyToPasteboard = { url, format in
            _ = try RecordingPasteboard.copy(url, format: format, to: board, directory: clipboard)
        }
        services.chooseDestination = { [weak self] _, _, completion in
            self?.panelRequests += 1
            completion(self?.chosenDestination)
        }
        return services
    }

    func cleanUp() {
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Polls `condition` on the main actor until it holds or `seconds` pass.
@MainActor
func waitUntil(seconds: TimeInterval = 15, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
}

/// Records what happened, in order, from callbacks that may run on any thread.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        items.append(event)
    }

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

@Suite("Recording editor fixture")
@MainActor
struct RecordingEditorFixtureTests {
    @Test func syntheticRecordingIsPlayableAndMatchesItsDescription() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording(frames: 20, fps: 10)

        let measured = try await RecordingExporter.readableDuration(of: AVURLAsset(url: recording.url))
        #expect(abs(measured - recording.duration) < 0.15)
        #expect(recording.pixelSize == CGSize(width: 160, height: 90))
    }
}
