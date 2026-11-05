import AVFoundation
import CoreGraphics
import Foundation

/// Exports a trimmed range of a recording to GIF or MP4 without blocking the caller.
///
/// Exports are cancellable: cancelling the surrounding `Task` stops frame generation or the export session, deletes the
/// partial file and throws `CancellationError`. Encoding failures throw `RecordingExportError`; renderer errors are
/// propagated unchanged, also after deleting the partial file. The source file is only ever read.
public enum RecordingExporter {
    public typealias ProgressHandler = @Sendable (Double) -> Void
    /// Receives an oriented source frame and its source-recording time in seconds (not trim-relative time).
    public typealias FrameRenderer = @Sendable (CGImage, TimeInterval) throws -> CGImage

    /// How far past the file's real duration a requested range may end before it counts as invalid. The capture layer
    /// reports a duration measured on its own clock, which can differ slightly from the file's.
    static let rangeSlack: TimeInterval = 0.1

    /// Exports `range` of `source` and returns the new file, a uniquely named temporary in `outputDirectory` that the
    /// caller owns. `progress` is called off the main thread with a fraction from 0 to 1.
    /// `frameRenderer` receives oriented source frames before resizing, with source-recording seconds clamped to
    /// the selected trim start. It must return a constant size and throw on failure; no unrendered frame is ever
    /// substituted. Transparent pixels are flattened against white in both formats.
    public static func export(source: URL, range: ClosedRange<TimeInterval>, options: RecordingExportOptions,
                              outputDirectory: URL? = nil, progress: ProgressHandler? = nil,
                              frameRenderer: FrameRenderer? = nil) async throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RecordingExportError.sourceMissing(source.lastPathComponent)
        }
        try Task.checkCancellation()
        if options.format == .gif, !GIFLimits.isSupported(framesPerSecond: options.gif.framesPerSecond) {
            throw RecordingExportError.unsupportedFrameRate(options.gif.framesPerSecond)
        }

        let asset = AVURLAsset(url: source)
        let sourceDuration = try await readableDuration(of: asset)
        let range = try validatedRange(range, sourceDuration: sourceDuration)
        if options.format == .gif,
           let issue = GIFLimits.issue(duration: range.upperBound - range.lowerBound, options: options.gif) {
            throw RecordingExportError.gifLimitExceeded(issue)
        }

        let directory = outputDirectory ?? RecordingExportFiles.defaultWorkingDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RecordingExportError.writeFailed(error.localizedDescription)
        }
        let output = directory.appendingPathComponent("RecordingExport-\(UUID().uuidString).\(options.format.fileExtension)")

        do {
            switch options.format {
            case .gif:
                try await writeGIF(asset: asset, range: range, options: options.gif, to: output,
                                   progress: progress, frameRenderer: frameRenderer)
            case .mp4:
                if let frameRenderer {
                    try await writeStyledMP4(asset: asset, range: range, to: output,
                                             progress: progress, frameRenderer: frameRenderer)
                } else {
                    try await writeMP4(asset: asset, range: range, sourceDuration: sourceDuration, to: output, progress: progress)
                }
            }
            try Task.checkCancellation()
            progress?(1)
            return output
        } catch {
            RecordingExportFiles.remove(output)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// `range` clamped to a source of `sourceDuration` seconds, or the error that says why it can't be exported.
    public static func validatedRange(_ range: ClosedRange<TimeInterval>,
                                      sourceDuration: TimeInterval) throws -> ClosedRange<TimeInterval> {
        let start = range.lowerBound
        let end = range.upperBound
        guard start.isFinite, end.isFinite, sourceDuration.isFinite, start >= 0, start < sourceDuration,
              end <= sourceDuration + rangeSlack else {
            throw RecordingExportError.invalidRange(start: start, end: end, sourceDuration: sourceDuration)
        }
        let clampedEnd = min(end, sourceDuration)
        let minimum = min(RecordingTrim.minimumDuration, sourceDuration)
        guard clampedEnd - start >= minimum - 1e-6 else {
            throw RecordingExportError.rangeTooShort(minimum: minimum)
        }
        return start...clampedEnd
    }

    /// The file's own duration in seconds. Used to align the editor with the real file; throws if it isn't a playable video.
    public static func readableDuration(of asset: AVAsset) async throws -> TimeInterval {
        do {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else { throw RecordingExportError.sourceUnreadable("it has no video track.") }
            guard duration.isNumeric, duration.seconds > 0 else {
                throw RecordingExportError.sourceUnreadable("it has no duration.")
            }
            return duration.seconds
        } catch let error as RecordingExportError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RecordingExportError.sourceUnreadable(error.localizedDescription)
        }
    }

    // MARK: GIF

    private static func writeGIF(asset: AVAsset, range: ClosedRange<TimeInterval>, options: GIFExportOptions, to url: URL,
                                 progress: ProgressHandler?, frameRenderer: FrameRenderer?) async throws {
        let fps = Double(options.framesPerSecond)
        let count = GIFLimits.frameCount(duration: range.upperBound - range.lowerBound, framesPerSecond: options.framesPerSecond)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var writer: GIFStreamWriter?
        var renderedSize: CGSize?
        do {
            try await withTaskCancellationHandler {
                for index in 0..<count {
                    try Task.checkCancellation()
                    // Frame times stay at least half a frame inside the range, so the last one is never past the end.
                    let seconds = min(range.lowerBound + Double(index) / fps, range.upperBound - 0.001)
                    let sourceFrame = try await image(from: generator, at: seconds)
                    try autoreleasepool {
                        let frame = try frameRenderer?(sourceFrame, seconds) ?? sourceFrame
                        let size = CGSize(width: frame.width, height: frame.height)
                        if let renderedSize, size != renderedSize {
                            throw RecordingExportError.encodingFailed("the rendered frame dimensions changed")
                        }
                        renderedSize = size
                        if writer == nil {
                            let outputSize = options.maxWidth.outputSize(for: size)
                            writer = try GIFStreamWriter(url: url, width: Int(outputSize.width), height: Int(outputSize.height))
                        }
                        guard let writer else { throw RecordingExportError.encodingFailed("no GIF writer") }
                        let scaled = try opaqueScaled(frame, width: writer.width, height: writer.height)
                        try Task.checkCancellation()
                        try writer.append(scaled, delayCentiseconds: delay(forFrame: index, framesPerSecond: fps))
                    }
                    progress?(Double(index + 1) / Double(count))
                }
            } onCancel: {
                generator.cancelAllCGImageGeneration()
            }
            try Task.checkCancellation()
            try writer?.finish()
        } catch {
            writer?.abort()
            throw error
        }
    }

    /// Centisecond delay of frame `index`. GIF delays are whole centiseconds, so each is rounded against the running
    /// total; the animation then lasts as long as the range even at 15 fps (6.67 cs per frame).
    static func delay(forFrame index: Int, framesPerSecond fps: Double) -> Int {
        let end = (Double(index + 1) * 100 / fps).rounded()
        let start = (Double(index) * 100 / fps).rounded()
        return Int(end - start)
    }

    private static func image(from generator: AVAssetImageGenerator, at seconds: TimeInterval) async throws -> CGImage {
        do {
            return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 6000)).image
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw RecordingExportError.frameUnavailable(time: seconds, reason: error.localizedDescription)
        }
    }

    /// Redraws `image` at `width`×`height` in sRGB without alpha, so the GIF has no transparency and consistent colour.
    private static func opaqueScaled(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: ColorSpaces.sRGB, bitmapInfo: info) else {
            throw RecordingExportError.encodingFailed("couldn't allocate a \(width)×\(height) frame buffer")
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else {
            throw RecordingExportError.encodingFailed("couldn't scale a frame")
        }
        return scaled
    }

    // MARK: MP4

    /// Carries the session into the `@Sendable` cancellation handler; `AVAssetExportSession` is thread-safe for these calls.
    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    /// Passthrough for the whole file (lossless and instant), otherwise a highest-quality H.264 re-encode: a
    /// passthrough cut can only start on a keyframe, which would make the trim inexact.
    private static func writeMP4(asset: AVAsset, range: ClosedRange<TimeInterval>, sourceDuration: TimeInterval, to url: URL,
                                 progress: ProgressHandler?) async throws {
        let isWholeFile = range.lowerBound <= 0.001 && range.upperBound >= sourceDuration - 0.001
        let presets = isWholeFile ? [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
                                  : [AVAssetExportPresetHighestQuality]
        let timeRange = isWholeFile ? nil : CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 6000),
                                                        end: CMTime(seconds: range.upperBound, preferredTimescale: 6000))
        var failure: Error = RecordingExportError.exportSessionFailed("no export preset is available")
        for preset in presets {
            do {
                try await runExportSession(asset: asset, preset: preset, timeRange: timeRange, to: url, progress: progress)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                RecordingExportFiles.remove(url)
                failure = error
            }
        }
        throw failure
    }

    private static func runExportSession(asset: AVAsset, preset: String, timeRange: CMTimeRange?, to url: URL,
                                         progress: ProgressHandler?) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw RecordingExportError.exportSessionFailed("the \(preset) preset isn't available for this recording")
        }
        guard session.supportedFileTypes.contains(.mp4) else {
            throw RecordingExportError.exportSessionFailed("the \(preset) preset can't write MP4")
        }
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }

        let box = SessionBox(session)
        let poller = Task {
            while !Task.isCancelled {
                progress?(Double(box.session.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { poller.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously { continuation.resume() }
                // The handler can fire before the session starts, when cancelling does nothing.
                if Task.isCancelled { box.session.cancelExport() }
            }
        } onCancel: {
            box.session.cancelExport()
        }
        if Task.isCancelled || session.status == .cancelled { throw CancellationError() }
        guard session.status == .completed else {
            throw RecordingExportError.exportSessionFailed(session.error?.localizedDescription ?? "unknown error")
        }
    }
}
