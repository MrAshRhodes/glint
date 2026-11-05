import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

@Suite("Recording trim")
struct RecordingExportTrimTests {
    @Test func startsAsTheWholeRecording() {
        let trim = RecordingTrim(sourceDuration: 8)
        #expect(trim.start == 0 && trim.end == 8 && trim.duration == 8)
        #expect(trim.isFullRange)
        #expect(trim.range == 0...8)
    }

    @Test func startClampsToZeroAndToTheEndMinusTheMinimum() {
        var trim = RecordingTrim(sourceDuration: 8)
        trim.setStart(-3)
        #expect(trim.start == 0)
        trim.setStart(7.95)
        #expect(abs(trim.start - 7.8) < 1e-9)
        #expect(trim.duration >= RecordingTrim.minimumDuration - 1e-9)
        trim.setStart(2)
        #expect(trim.start == 2 && trim.end == 8)
    }

    @Test func endClampsToTheSourceAndToTheStartPlusTheMinimum() {
        var trim = RecordingTrim(sourceDuration: 8)
        trim.setStart(3)
        trim.setEnd(99)
        #expect(trim.end == 8)
        trim.setEnd(3.05)
        #expect(abs(trim.end - 3.2) < 1e-9)
        trim.setEnd(5)
        #expect(trim.start == 3 && trim.end == 5 && !trim.isFullRange)
    }

    @Test func nonFiniteValuesAreIgnored() {
        var trim = RecordingTrim(sourceDuration: 8)
        trim.setStart(2)
        trim.setStart(.nan)
        trim.setEnd(.infinity)
        trim.setEnd(.nan)
        #expect(trim.start == 2 && trim.end == 8)
        #expect(RecordingTrim(sourceDuration: .nan).sourceDuration == 0)
        #expect(RecordingTrim(sourceDuration: -4).sourceDuration == 0)
    }

    @Test func aRecordingShorterThanTheMinimumCannotBeTrimmed() {
        var trim = RecordingTrim(sourceDuration: 0.1)
        trim.setStart(0.05)
        trim.setEnd(0.05)
        #expect(trim.start == 0 && trim.end == 0.1)
        #expect(trim.shortestDuration == 0.1)
    }

    @Test func limitDurationShortensFromTheEndAndKeepsTheStart() {
        var trim = RecordingTrim(sourceDuration: 60)
        trim.setStart(10)
        trim.limitDuration(to: 30)
        #expect(trim.start == 10 && trim.end == 40)
        trim.limitDuration(to: 100)
        #expect(trim.end == 40)
        trim.limitDuration(to: 0)
        #expect(abs(trim.duration - RecordingTrim.minimumDuration) < 1e-9)
    }

    @Test func adoptingTheRealDurationFollowsAWholeRangeAndClampsATrimmedOne() {
        var whole = RecordingTrim(sourceDuration: 5)
        whole.setSourceDuration(5.4)
        #expect(whole.end == 5.4 && whole.isFullRange)

        var trimmed = RecordingTrim(sourceDuration: 5)
        trimmed.setStart(1)
        trimmed.setEnd(4.9)
        trimmed.setSourceDuration(4.5)
        #expect(trimmed.start == 1 && trimmed.end == 4.5 && trimmed.sourceDuration == 4.5)

        var tiny = RecordingTrim(sourceDuration: 5)
        tiny.setStart(4.0)
        tiny.setSourceDuration(1.0)
        #expect(tiny.start <= 1.0 - tiny.shortestDuration + 1e-9 && tiny.end == 1.0)

        var unknown = RecordingTrim(sourceDuration: 0)
        unknown.setSourceDuration(3)
        #expect(unknown.end == 3 && unknown.isFullRange)
        unknown.setSourceDuration(.nan)
        unknown.setSourceDuration(-1)
        #expect(unknown.sourceDuration == 3)
    }
}

@Suite("GIF limits")
struct RecordingExportLimitsTests {
    @Test func frameCountRoundsAndIsAtLeastOne() {
        #expect(GIFLimits.frameCount(duration: 2, framesPerSecond: 15) == 30)
        #expect(GIFLimits.frameCount(duration: 0.2, framesPerSecond: 10) == 2)
        #expect(GIFLimits.frameCount(duration: 0.01, framesPerSecond: 10) == 1)
        #expect(GIFLimits.frameCount(duration: .nan, framesPerSecond: 10) == 1)
    }

    @Test func maxDurationIsTheTighterOfTheDurationAndFrameLimits() {
        #expect(GIFLimits.maxDuration(framesPerSecond: 10) == 30)
        #expect(GIFLimits.maxDuration(framesPerSecond: 15) == 30)
        #expect(GIFLimits.maxDuration(framesPerSecond: 20) == 22.5)
        #expect(GIFLimits.maxDuration == 30 && GIFLimits.maxFrameCount == 450)
    }

    @Test func rangesAtTheLimitPassAndRangesOverItAreFlagged() throws {
        for fps in GIFLimits.frameRates {
            let options = GIFExportOptions(framesPerSecond: fps)
            let limit = GIFLimits.maxDuration(framesPerSecond: fps)
            #expect(GIFLimits.issue(duration: limit, options: options) == nil, "fps \(fps) at the limit")
            #expect(GIFLimits.issue(duration: limit + 0.5, options: options) != nil, "fps \(fps) over the limit")
        }
        let issue = try #require(GIFLimits.issue(duration: 40, options: GIFExportOptions(framesPerSecond: 15)))
        #expect(issue.frameCount == 600 && issue.maxDuration == 30 && issue.framesPerSecond == 15)
    }

    @Test func issueMessageNamesTheNumbersAndTheWaysOut() throws {
        let issue = try #require(GIFLimits.issue(duration: 40, options: GIFExportOptions(framesPerSecond: 20)))
        #expect(issue.message.contains("40.0 s"))
        #expect(issue.message.contains("22.5 s"))
        #expect(issue.message.contains("450"))
        #expect(issue.message.contains("20 fps"))
        #expect(issue.message.contains("MP4"))
    }

    @Test func defaultsAreFifteenFpsAndSixHundredFortyPixels() {
        let options = RecordingExportOptions()
        #expect(options.format == .gif)
        #expect(options.gif.framesPerSecond == 15 && options.gif.maxWidth == .w640)
        #expect(GIFLimits.frameRates == [10, 15, 20])
        #expect(GIFLimits.isSupported(framesPerSecond: 15) && !GIFLimits.isSupported(framesPerSecond: 12))
    }

    @Test func maxWidthKeepsTheAspectRatioAndNeverUpscales() {
        let hd = CGSize(width: 1920, height: 1080)
        #expect(GIFMaxWidth.w480.outputSize(for: hd) == CGSize(width: 480, height: 270))
        #expect(GIFMaxWidth.w640.outputSize(for: hd) == CGSize(width: 640, height: 360))
        #expect(GIFMaxWidth.w720.outputSize(for: hd) == CGSize(width: 720, height: 405))
        #expect(GIFMaxWidth.original.outputSize(for: hd) == CGSize(width: 1280, height: 720))
        #expect(GIFMaxWidth.original.outputSize(for: CGSize(width: 800, height: 600)) == CGSize(width: 800, height: 600))
        #expect(GIFMaxWidth.w720.outputSize(for: CGSize(width: 200, height: 100)) == CGSize(width: 200, height: 100))
        #expect(GIFMaxWidth.w480.outputSize(for: .zero) == CGSize(width: 1, height: 1))
        #expect(GIFMaxWidth.original.displayName.contains("1280"))
    }

    @Test func estimatedSizeGrowsWithDurationFrameRateAndWidth() {
        let source = CGSize(width: 1920, height: 1080)
        func estimate(_ seconds: Double, _ fps: Int, _ width: GIFMaxWidth) -> Int {
            GIFLimits.estimatedByteCount(duration: seconds, options: GIFExportOptions(framesPerSecond: fps, maxWidth: width), sourceSize: source)
        }
        #expect(estimate(10, 15, .w640) > 0)
        #expect(estimate(10, 15, .w640) > estimate(5, 15, .w640))
        #expect(estimate(10, 20, .w640) > estimate(10, 10, .w640))
        #expect(estimate(10, 15, .w720) > estimate(10, 15, .w480))
    }

    @Test func secondsFormatInSecondsThenMinutes() {
        #expect(GIFLimits.format(seconds: 0) == "0.0 s")
        #expect(GIFLimits.format(seconds: 12.34) == "12.3 s")
        #expect(GIFLimits.format(seconds: -1) == "0.0 s")
        #expect(GIFLimits.format(seconds: 62.3) == "1:02.3")
    }

    @Test func formatsExposeExtensionsAndTypes() {
        #expect(RecordingFileFormat.gif.fileExtension == "gif" && RecordingFileFormat.mp4.fileExtension == "mp4")
        #expect(RecordingFileFormat.gif.utType.identifier == "com.compuserve.gif")
        #expect(RecordingFileFormat.mp4.utType.preferredFilenameExtension == "mp4")
        #expect(RecordingFileFormat.allCases == [.gif, .mp4])
    }

    @Test func everyErrorHasAReadableMessage() {
        let issue = GIFLimitIssue(duration: 40, framesPerSecond: 15, frameCount: 600, maxDuration: 30)
        let errors: [RecordingExportError] = [
            .sourceMissing("a.mp4"), .sourceUnreadable("no track"),
            .invalidRange(start: 1, end: 9, sourceDuration: 5), .rangeTooShort(minimum: 0.2),
            .unsupportedFrameRate(12), .gifLimitExceeded(issue), .frameUnavailable(time: 1, reason: "x"),
            .encodingFailed("y"), .writeFailed("z"), .exportSessionFailed("w"), .pasteboardWriteFailed,
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false, "\(error)")
            #expect(error.localizedDescription == error.errorDescription)
        }
    }
}
