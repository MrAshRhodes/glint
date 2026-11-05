import AVFoundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

enum FrameWriterError: LocalizedError, Equatable {
    case noFrames
    case writerFailed(String)
    case alreadyFinished

    var errorDescription: String? {
        switch self {
        case .noFrames: return "No frames were captured from the display."
        case .writerFailed(let message): return "The recording could not be written: \(message)"
        case .alreadyFinished: return "The recording was already finished."
        }
    }
}

/// Encodes frames into an H.264 `.mp4`.
///
/// Not thread-safe: call every method from one serial queue. Memory stays bounded because a frame the encoder
/// cannot take yet is dropped instead of queued.
final class FrameWriter: @unchecked Sendable {
    enum AppendResult: Equatable {
        case written
        /// Not a complete frame, wrong size or invalid timestamp.
        case skipped
        /// The encoder was busy; the frame was dropped.
        case notReady
        /// The timestamp did not advance past the previous frame.
        case outOfOrder
        /// The recording already reached `maximumDuration`.
        case limitReached
        case failed
        case closed
    }

    struct Summary: Equatable {
        let duration: TimeInterval
        let frameCount: Int
        let pixelSize: CGSize
    }

    let url: URL
    let width: Int
    let height: Int
    let frameRate: Int
    let maximumDuration: TimeInterval

    private(set) var framesWritten = 0
    private(set) var framesDropped = 0
    private(set) var failure: Error?

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let frameDuration: CMTime
    private var startTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var lastArrival: CMTime?
    private var isClosed = false
    private var isCompleted = false

    /// `width` and `height` must be even. An existing file at `url` is replaced.
    init(url: URL, width: Int, height: Int, frameRate: Int = RecordingLimits.frameRate,
         maximumDuration: TimeInterval = RecordingLimits.maximumDuration) throws {
        guard width >= 2, height >= 2, width % 2 == 0, height % 2 == 0 else {
            throw FrameWriterError.writerFailed("The video size \(width) × \(height) is not valid.")
        }
        try? FileManager.default.removeItem(at: url)
        self.url = url
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.maximumDuration = maximumDuration
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: Self.outputSettings(
            width: width, height: height, frameRate: frameRate))
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { throw FrameWriterError.writerFailed("The video track could not be added.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw FrameWriterError.writerFailed(writer.error?.localizedDescription ?? "The file could not be created.")
        }
    }

    static func outputSettings(width: Int, height: Int, frameRate: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate(width: width, height: height, frameRate: frameRate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoAllowFrameReorderingKey: false]
        ]
    }

    /// About 0.12 bits per pixel: roughly 7.5 Mbit/s at 1080p30, which keeps text and UI edges clean.
    static func bitRate(width: Int, height: Int, frameRate: Int) -> Int {
        let estimate = Double(width) * Double(height) * Double(frameRate) * 0.12
        return Int(min(max(estimate, 1_500_000), 40_000_000))
    }

    static func hostTime() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    /// Whether ScreenCaptureKit marked the buffer as a freshly rendered frame (not idle, blank or suspended).
    static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }

    /// `arrival` is when the frame reached us on the host clock; it anchors the stop time of the last frame.
    func append(_ sampleBuffer: CMSampleBuffer, arrival: CMTime = FrameWriter.hostTime()) -> AppendResult {
        guard Self.isCompleteFrame(sampleBuffer), let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return .skipped
        }
        return append(pixelBuffer: pixelBuffer, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                      arrival: arrival)
    }

    func append(pixelBuffer: CVPixelBuffer, at presentationTime: CMTime,
                arrival: CMTime = FrameWriter.hostTime()) -> AppendResult {
        guard !isClosed else { return .closed }
        guard writer.status == .writing else {
            failure = failure ?? writer.error ?? FrameWriterError.writerFailed("The writer stopped unexpectedly.")
            return .failed
        }
        guard presentationTime.isNumeric, CVPixelBufferGetWidth(pixelBuffer) == width,
              CVPixelBufferGetHeight(pixelBuffer) == height else { return .skipped }
        if let last = lastPresentationTime, presentationTime <= last { return .outOfOrder }
        if let start = startTime, (presentationTime - start).seconds > maximumDuration { return .limitReached }
        guard input.isReadyForMoreMediaData else {
            framesDropped += 1
            return .notReady
        }
        if startTime == nil {
            writer.startSession(atSourceTime: presentationTime)
            startTime = presentationTime
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            failure = writer.error ?? FrameWriterError.writerFailed("A frame could not be appended.")
            return .failed
        }
        lastPresentationTime = presentationTime
        lastArrival = arrival
        framesWritten += 1
        return .written
    }

    /// Closes the file. The last frame is held until `now`, so a still screen keeps its real duration even though
    /// ScreenCaptureKit sends no frames while nothing changes. On failure the partial file is deleted.
    func finish(at now: CMTime = FrameWriter.hostTime()) async throws -> Summary {
        guard !isClosed else { throw FrameWriterError.alreadyFinished }
        isClosed = true
        guard writer.status == .writing else {
            let message = writer.error?.localizedDescription ?? "The writer stopped unexpectedly."
            discardFile()
            throw FrameWriterError.writerFailed(message)
        }
        guard let start = startTime, let last = lastPresentationTime, let arrival = lastArrival else {
            writer.cancelWriting()
            discardFile()
            throw FrameWriterError.noFrames
        }
        let held = CMTimeMaximum(CMTimeSubtract(now, arrival), frameDuration)
        let limit = CMTimeMaximum(CMTimeAdd(start, CMTime(seconds: maximumDuration, preferredTimescale: 600)),
                                  CMTimeAdd(last, frameDuration))
        let end = CMTimeMinimum(CMTimeAdd(last, held), limit)
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            let message = writer.error?.localizedDescription ?? "The file could not be finalised."
            discardFile()
            throw FrameWriterError.writerFailed(message)
        }
        isCompleted = true
        return Summary(duration: (end - start).seconds, frameCount: framesWritten,
                       pixelSize: CGSize(width: width, height: height))
    }

    /// Abandons the recording and deletes the file. Does nothing once `finish` succeeded.
    func cancel() {
        guard !isCompleted else { return }
        if !isClosed, writer.status == .writing { writer.cancelWriting() }
        isClosed = true
        discardFile()
    }

    private func discardFile() {
        try? FileManager.default.removeItem(at: url)
    }
}
