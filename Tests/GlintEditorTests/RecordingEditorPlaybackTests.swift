import AVFoundation
import Foundation
import Testing
@testable import GlintCore
@testable import GlintEditor

@Suite("Recording editor playback")
@MainActor
struct RecordingEditorPlaybackTests {
    @Test func playbackStopsAtTheEndHandleAndOnlyThere() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording(frames: 20, fps: 10)
        let playback = RecordingPlayback(url: recording.url, duration: recording.duration)
        defer { playback.shutdown() }
        let item = try #require(playback.player.currentItem)
        #expect(!item.forwardPlaybackEndTime.isValid, "a full-length range plays to the file's own end")

        playback.apply(range: 0.5...1.5, sourceDuration: recording.duration)
        #expect(abs(item.forwardPlaybackEndTime.seconds - 1.5) < 0.001)
        #expect(playback.range == 0.5...1.5)
        #expect(playback.currentTime == 0.5, "moving the start handle shows the new first frame")

        playback.apply(range: 0.5...1.0, sourceDuration: recording.duration)
        #expect(abs(item.forwardPlaybackEndTime.seconds - 1.0) < 0.001)
        #expect(abs(playback.currentTime - 0.95) < 0.001, "moving the end handle shows the new last frame")

        playback.apply(range: 0...recording.duration, sourceDuration: recording.duration)
        #expect(!item.forwardPlaybackEndTime.isValid)
    }

    @Test func seekingStaysInsideTheTrimRange() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording(frames: 20, fps: 10)
        let playback = RecordingPlayback(url: recording.url, duration: recording.duration)
        defer { playback.shutdown() }
        playback.apply(range: 0.5...1.5, sourceDuration: recording.duration)

        playback.seek(to: 10)
        #expect(playback.currentTime == 1.5)
        playback.seek(to: -4)
        #expect(playback.currentTime == 0.5)
        playback.seek(to: 1.0)
        #expect(playback.currentTime == 1.0)
    }

    @Test(.timeLimit(.minutes(1)))
    func playingLoopsInsideTheRangeUntilPaused() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording(frames: 40, fps: 10)
        let playback = RecordingPlayback(url: recording.url, duration: recording.duration)
        defer { playback.shutdown() }
        playback.apply(range: 1.0...1.6, sourceDuration: recording.duration)

        playback.play()
        #expect(playback.isPlaying)
        var highest = 0.0
        var previous = playback.currentTime
        var wrapped = false
        // Generous wall-clock budget: CI runners can starve the main actor for many seconds.
        let deadline = Date().addingTimeInterval(45)
        while !wrapped, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            let now = playback.currentTime
            #expect(now <= 1.6 + 0.05, "never plays past the end handle")
            #expect(now >= 1.0 - 0.05, "never plays before the start handle")
            if now > highest { highest = now }
            // Time only moves backwards when playback loops, so any clear drop is a wrap,
            // even if a slow sample misses the moments just after the start handle.
            if highest > 1.1, now + 0.05 < previous { wrapped = true }
            previous = now
        }
        #expect(wrapped, "playback wraps back to the start handle (reached \(highest))")
        #expect(playback.isPlaying)

        playback.pause()
        #expect(!playback.isPlaying)
    }

    @Test func shuttingDownReleasesTheFileAndStopsEverything() async throws {
        let fixture = try RecordingEditorFixture(); defer { fixture.cleanUp() }
        let recording = try await fixture.recording()
        let playback = RecordingPlayback(url: recording.url, duration: recording.duration)

        playback.play()
        playback.shutdown()

        #expect(playback.player.currentItem == nil && !playback.isPlaying)
        playback.play()
        playback.seek(to: 1)
        #expect(!playback.isPlaying && playback.player.currentItem == nil, "a shut-down player stays shut down")
        playback.shutdown()
    }

    @Test func timelineMapsTimeToPositionsAndBack() {
        let layout = TimelineLayout(width: 514, handleWidth: 14, duration: 10)

        #expect(layout.x(at: 0) == 7 && layout.x(at: 10) == 507)
        #expect(layout.x(at: 5) == 257)
        #expect(layout.time(at: 257) == 5)
        #expect(layout.time(at: -100) == 0 && layout.time(at: 9999) == 10, "positions outside the bar clamp")
        #expect(layout.x(at: 99) == 507 && layout.x(at: -3) == 7)
        for time in stride(from: 0.0, through: 10.0, by: 0.7) {
            #expect(abs(layout.time(at: layout.x(at: time)) - time) < 1e-9)
        }

        let empty = TimelineLayout(width: 514, handleWidth: 14, duration: 0)
        #expect(empty.x(at: 3) == 7 && empty.time(at: 300) == 0)
    }
}
