import Foundation
import Testing
@testable import GlintCapture

@Suite("Recording timeline")
struct RecordingTimelineTests {
    @Test func countdownCountsDownOneSecondAtATime() {
        var countdown = RecordingCountdown(seconds: 3)
        #expect(countdown.remaining == 3 && !countdown.isFinished)
        #expect(countdown.tick() == .counting(2))
        #expect(countdown.tick() == .counting(1))
        #expect(countdown.tick() == .finished)
        #expect(countdown.isFinished && countdown.remaining == 0)
        #expect(countdown.tick() == .finished)
        #expect(countdown.remaining == 0)
    }

    @Test func noCountdownIsFinishedImmediately() {
        #expect(RecordingCountdown(seconds: 0).isFinished)
        #expect(RecordingCountdown(seconds: -4).isFinished)
        #expect(RecordingCountdown(seconds: -4).remaining == 0)
    }

    @Test func countdownChoicesMatchTheMenu() {
        #expect(RecordingCountdownChoice.allCases.map(\.seconds) == [0, 3, 5, 10])
        #expect(RecordingCountdownChoice.allCases.map(\.title) == ["None", "3s", "5s", "10s"])
    }

    @Test func elapsedTimeIsFormattedAsClockTime() {
        #expect(ElapsedTimeFormatter.string(from: 0) == "00:00")
        #expect(ElapsedTimeFormatter.string(from: 9.99) == "00:09")
        #expect(ElapsedTimeFormatter.string(from: 65) == "01:05")
        #expect(ElapsedTimeFormatter.string(from: 599.4) == "09:59")
        #expect(ElapsedTimeFormatter.string(from: 600) == "10:00")
        #expect(ElapsedTimeFormatter.string(from: 3600) == "1:00:00")
        #expect(ElapsedTimeFormatter.string(from: 3725) == "1:02:05")
    }

    @Test func elapsedTimeToleratesInvalidValues() {
        #expect(ElapsedTimeFormatter.string(from: -5) == "00:00")
        #expect(ElapsedTimeFormatter.string(from: .nan) == "00:00")
        #expect(ElapsedTimeFormatter.string(from: .infinity) == "00:00")
    }

    @Test func spokenElapsedTimeIsWrittenOut() {
        let english = Locale(identifier: "en_US")
        #expect(ElapsedTimeFormatter.spoken(from: 0, locale: english) == "0 seconds")
        #expect(ElapsedTimeFormatter.spoken(from: 1, locale: english) == "1 second")
        #expect(ElapsedTimeFormatter.spoken(from: 7.9, locale: english) == "7 seconds")
        #expect(ElapsedTimeFormatter.spoken(from: 60, locale: english) == "1 minute")
        #expect(ElapsedTimeFormatter.spoken(from: 65, locale: english) == "1 minute, 5 seconds")
        #expect(ElapsedTimeFormatter.spoken(from: 3725, locale: english) == "1 hour, 2 minutes, 5 seconds")
        #expect(ElapsedTimeFormatter.spoken(from: -3, locale: english) == "0 seconds")
        #expect(ElapsedTimeFormatter.spoken(from: .nan, locale: english) == "0 seconds")
    }

    @Test func countdownChoicesHaveSpokenNames() {
        #expect(RecordingCountdownChoice.allCases.map(\.spokenTitle) == ["No countdown", "3 seconds", "5 seconds", "10 seconds"])
    }

    @MainActor
    @Test func recordingLimitIsTenMinutesAtThirtyFramesPerSecond() {
        #expect(RecordingLimits.maximumDuration == 600)
        #expect(RecordingLimits.frameRate == 30)
        #expect(ScreenRecordingSession.maximumDuration == RecordingLimits.maximumDuration)
    }
}
