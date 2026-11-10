import Foundation
import Testing
@testable import GlintCore

@Suite("Capture signposts")
struct CaptureSignpostsTests {
    private struct Boom: Error {}

    @Test func triggersAreAFixedSetOfLabels() {
        #expect(CaptureSignposts.Trigger(rawValue: "hotkey") == .hotkey)
        #expect(CaptureSignposts.Trigger(rawValue: "menu") == .menu)
        #expect(CaptureSignposts.Trigger(rawValue: "url") == .url)
        #expect(CaptureSignposts.Trigger(rawValue: "timer") == .timer)
        #expect(CaptureSignposts.Trigger(rawValue: "area") == nil)
    }

    @Test func outcomeSeparatesCancellationFromFailure() {
        #expect(CaptureSignposts.Outcome(error: CancellationError()) == .cancelled)
        #expect(CaptureSignposts.Outcome(error: Boom()) == .failed)
    }

    @Test func handlesExistExactlyWhenSignpostsAreEnabled() {
        let enabled = CaptureSignposts.signposter.isEnabled
        let plain = CaptureSignposts.begin("TestInterval")
        let capture = CaptureSignposts.beginCapture(trigger: .hotkey, mode: "area")
        let queue = CaptureSignposts.beginQueueDelay(eventAgeSeconds: 0.0125)
        #expect((plain != nil) == enabled)
        #expect((capture != nil) == enabled)
        #expect((queue != nil) == enabled)
        CaptureSignposts.end(plain)
        CaptureSignposts.end(capture, .cancelled)
        CaptureSignposts.end(queue, .failed)
    }

    @Test func endingNothingIsHarmless() {
        CaptureSignposts.end(nil)
        CaptureSignposts.end(nil, .cancelled)
        CaptureSignposts.end(nil, .failed)
    }

    @Test func intervalsCanBeEndedFromAnotherTask() async {
        let interval = CaptureSignposts.begin("TestCrossTask")
        await Task.detached { CaptureSignposts.end(interval) }.value
    }

    @Test func measureReturnsTheBodysValue() async throws {
        #expect(CaptureSignposts.measure("TestSync") { 42 } == 42)
        let value = try CaptureSignposts.measure("TestSyncThrowing") { () throws -> String in "ok" }
        #expect(value == "ok")
        let asyncValue = await CaptureSignposts.measure("TestAsync") { () async -> Int in 7 }
        #expect(asyncValue == 7)
    }

    @Test func measureRethrowsTheBodysError() async {
        #expect(throws: Boom.self) {
            try CaptureSignposts.measure("TestSyncError") { () throws -> Int in throw Boom() }
        }
        await #expect(throws: CancellationError.self) {
            try await CaptureSignposts.measure("TestAsyncCancel") { () async throws -> Int in throw CancellationError() }
        }
    }
}
