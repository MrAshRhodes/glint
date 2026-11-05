import AVFoundation
import CoreImage
import CoreVideo
import Foundation

extension RecordingExporter {
    /// Only cancellation crosses executors; reading, rendering and appending remain serial.
    private final class StyledExportSession: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter

        init(reader: AVAssetReader, writer: AVAssetWriter) {
            self.reader = reader
            self.writer = writer
        }

        func cancel() {
            reader.cancelReading()
            writer.cancelWriting()
        }
    }

    static func writeStyledMP4(asset: AVAsset, range: ClosedRange<TimeInterval>, to url: URL,
                               progress: ProgressHandler?, frameRenderer: FrameRenderer) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingExportError.sourceUnreadable("it has no video track.")
        }
        let trackTransform = try await track.load(.preferredTransform)
        // Track transforms use top-left coordinates; Core Image uses bottom-left coordinates.
        let transform = CGAffineTransform(a: trackTransform.a, b: -trackTransform.b,
                                          c: -trackTransform.c, d: trackTransform.d,
                                          tx: trackTransform.tx, ty: -trackTransform.ty)
        let minimumFrameDuration = try await track.load(.minFrameDuration)
        let frameDuration = minimumFrameDuration.isNumeric && minimumFrameDuration.seconds > 0
            ? minimumFrameDuration : CMTime(value: 1, timescale: 30)
        let start = CMTime(seconds: range.lowerBound, preferredTimescale: 600_000)
        let end = CMTime(seconds: range.upperBound, preferredTimescale: 600_000)
        let duration = end - start
        let reader = try AVAssetReader(asset: asset)
        // Include the frame spanning the trim boundary, then clamp its timestamp to zero. Later frames preserve
        // their original spacing, and endSession clips the final frame to the exact selected end.
        reader.timeRange = CMTimeRange(start: max(.zero, start - frameDuration), end: end)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw RecordingExportError.encodingFailed("couldn't create a video reader")
        }
        reader.add(output)
        // AVFoundation may create sibling .sb-* staging files. Keep the entire transaction in an owned directory
        // so cancellation/rendering failures cannot leave any of those partial files behind.
        let workDirectory = url.deletingPathExtension()
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let workingURL = workDirectory.appendingPathComponent(url.lastPathComponent)
        let writer = try AVAssetWriter(outputURL: workingURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let session = StyledExportSession(reader: reader, writer: writer)
        let encoder = StyledFrameEncoder(writer: writer)
        let context = CIContext(options: [.cacheIntermediates: false])

        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard reader.startReading() else {
                    throw RecordingExportError.encodingFailed(reader.error?.localizedDescription ?? "couldn't start reading")
                }
                var previousTime: CMTime?
                while true {
                    try Task.checkCancellation()
                    while !encoder.isReady {
                        try Task.checkCancellation()
                        guard writer.status == .writing else {
                            throw RecordingExportError.encodingFailed(writer.error?.localizedDescription ?? "the writer stopped")
                        }
                        try await Task.sleep(nanoseconds: 2_000_000)
                    }
                    let hasSample = try autoreleasepool {
                        guard let sample = output.copyNextSampleBuffer() else { return false }
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        guard time.isNumeric else {
                            throw RecordingExportError.encodingFailed("a frame has no presentation timestamp")
                        }
                        let sampleDuration = CMSampleBufferGetDuration(sample)
                        let length = sampleDuration.isNumeric && sampleDuration.seconds > 0 ? sampleDuration : frameDuration
                        guard time < end, time + length > start else { return true }
                        let presentationTime = max(.zero, time - start)
                        guard previousTime == nil || presentationTime > previousTime! else {
                            throw RecordingExportError.encodingFailed("frame timestamps are not increasing")
                        }
                        guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                            throw RecordingExportError.encodingFailed("a video frame has no image buffer")
                        }
                        let oriented = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
                        let extent = oriented.extent.integral
                        let normalized = oriented.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                        guard let image = context.createCGImage(normalized, from: CGRect(origin: .zero, size: extent.size),
                                                                format: .RGBA8, colorSpace: ColorSpaces.sRGB) else {
                            throw RecordingExportError.encodingFailed("couldn't orient a video frame")
                        }
                        let rendered = try frameRenderer(image)
                        try Task.checkCancellation()
                        try encoder.append(rendered, at: presentationTime)
                        previousTime = presentationTime
                        progress?(min(0.99, max(0, presentationTime.seconds / duration.seconds)))
                        return true
                    }
                    if !hasSample { break }
                }
                try Task.checkCancellation()
                guard reader.status == .completed else {
                    throw RecordingExportError.encodingFailed(reader.error?.localizedDescription ?? "the reader stopped")
                }
                guard previousTime != nil else {
                    throw RecordingExportError.encodingFailed("the selected range contains no video frames")
                }
                encoder.finish(at: duration)
                await writer.finishWriting()
                try Task.checkCancellation()
                guard writer.status == .completed else {
                    throw RecordingExportError.encodingFailed(writer.error?.localizedDescription ?? "couldn't finish writing")
                }
                try FileManager.default.moveItem(at: workingURL, to: url)
            } onCancel: {
                session.cancel()
            }
        } catch {
            session.cancel()
            throw error
        }
    }

    /// Holds only the encoder's bounded pixel-buffer pool, never an array of frames or pending render tasks.
    private final class StyledFrameEncoder {
        let writer: AVAssetWriter
        private var input: AVAssetWriterInput?
        private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        private var imageSize: CGSize?
        private var width = 0
        private var height = 0

        init(writer: AVAssetWriter) { self.writer = writer }

        var isReady: Bool { input?.isReadyForMoreMediaData ?? true }

        func append(_ image: CGImage, at time: CMTime) throws {
            let size = CGSize(width: image.width, height: image.height)
            if let imageSize, size != imageSize {
                throw RecordingExportError.encodingFailed("the rendered frame dimensions changed")
            }
            if input == nil {
                imageSize = size
                // H.264 requires even dimensions. Pad right/bottom rather than rescaling or cropping the styled image.
                width = image.width + image.width % 2
                height = image.height + image.height % 2
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoColorPropertiesKey: [
                        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                        AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                    ],
                ])
                input.expectsMediaDataInRealTime = false
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                ])
                guard writer.canAdd(input) else {
                    throw RecordingExportError.encodingFailed("the styled dimensions aren't supported by the video encoder")
                }
                writer.add(input)
                guard writer.startWriting() else {
                    throw RecordingExportError.encodingFailed(writer.error?.localizedDescription ?? "couldn't start writing")
                }
                writer.startSession(atSourceTime: .zero)
                self.input = input
                self.adaptor = adaptor
            }
            guard let adaptor, let pool = adaptor.pixelBufferPool else {
                throw RecordingExportError.encodingFailed("couldn't allocate the video frame pool")
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
                  let buffer else {
                throw RecordingExportError.encodingFailed("couldn't allocate a video frame")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                          space: ColorSpaces.sRGB, bitmapInfo: info) else {
                throw RecordingExportError.encodingFailed("couldn't create the video drawing context")
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw RecordingExportError.encodingFailed(writer.error?.localizedDescription ?? "couldn't append a styled frame")
            }
        }

        func finish(at time: CMTime) {
            writer.endSession(atSourceTime: time)
            input?.markAsFinished()
        }
    }
}
