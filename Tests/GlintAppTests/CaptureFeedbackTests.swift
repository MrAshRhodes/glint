import AppKit
import GlintCapture
@testable import GlintCore
import Testing
@testable import Glint

@MainActor
private final class FeedbackLog {
    var notificationsEnabled = true
    var appIsActive = false
    var access = NotificationAccess.allowed
    var grantsRequest = true
    var whilePermissionIsPending: (@MainActor () -> Void)?
    private(set) var accessQueries = 0
    private(set) var requests = 0
    private(set) var notified: [(title: String, message: String, url: URL?)] = []
    private(set) var beeps = 0
    private(set) var alerts: [(title: String, message: String)] = []

    var permission: NotificationPermission {
        NotificationPermission(access: { [self] in
            accessQueries += 1
            whilePermissionIsPending?()
            return access
        }, request: { [self] in
            requests += 1
            whilePermissionIsPending?()
            return grantsRequest
        })
    }

    var feedback: FailureFeedback {
        FailureFeedback(notificationsEnabled: { [self] in notificationsEnabled },
                        isAppActive: { [self] in appIsActive },
                        permission: permission,
                        notify: { [self] in notified.append(($0, $1, $2)) },
                        beep: { [self] in beeps += 1 },
                        alert: { [self] in alerts.append(($0, $1)) })
    }
}

@Suite("Notification permission")
@MainActor
struct NotificationPermissionTests {
    @Test func grantedNotificationsNeverAskAgain() async {
        let log = FeedbackLog()
        for _ in 0..<3 { #expect(await log.permission.isGranted()) }
        #expect(log.requests == 0)
    }

    @Test func blockedNotificationsAreNotGrantedAndNeverAskAgain() async {
        let log = FeedbackLog()
        log.access = .blocked
        for _ in 0..<3 { #expect(await !log.permission.isGranted()) }
        #expect(log.requests == 0)
    }

    @Test(arguments: [true, false])
    func undecidedNotificationsAskOnceAndFollowTheAnswer(granted: Bool) async {
        let log = FeedbackLog()
        log.access = .undecided
        log.grantsRequest = granted
        #expect(await log.permission.isGranted() == granted)
        #expect(log.requests == 1)
    }

    @Test func theCurrentStatusIsReadEachTimeSoSettingsChangesAreHonoured() async {
        let log = FeedbackLog()
        #expect(await log.permission.isGranted())
        log.access = .blocked
        #expect(await !log.permission.isGranted())
        log.access = .allowed
        #expect(await log.permission.isGranted())
        #expect(log.accessQueries == 3 && log.requests == 0)
    }
}

@Suite("Failure feedback")
@MainActor
struct FailureFeedbackTests {
    @Test func aNotificationThatWillBeShownIsAllThatIsNeeded() async {
        let log = FeedbackLog()
        let url = URL(fileURLWithPath: "/tmp/glint-feedback.png")
        await log.feedback.report(title: "Capture failed", message: "Disk full", fileURL: url)
        #expect(log.notified.map(\.title) == ["Capture failed"])
        #expect(log.notified.first?.message == "Disk full" && log.notified.first?.url == url)
        #expect(log.beeps == 0 && log.alerts.isEmpty)
    }

    @Test func glintNotificationsTurnedOffStillBeepAndAlert() async {
        let log = FeedbackLog()
        log.notificationsEnabled = false
        await log.feedback.report(title: "Capture failed", message: "Display changed")
        #expect(log.notified.isEmpty)
        #expect(log.beeps == 1)
        #expect(log.alerts.map(\.title) == ["Capture failed"] && log.alerts.first?.message == "Display changed")
        #expect(log.accessQueries == 0 && log.requests == 0)
    }

    @Test func macOSBlockingNotificationsStillBeepsAndAlerts() async {
        let log = FeedbackLog()
        log.access = .blocked
        await log.feedback.report(title: "Recording failed", message: "Disk full")
        #expect(log.notified.isEmpty && log.beeps == 1)
        #expect(log.alerts.map(\.title) == ["Recording failed"] && log.alerts.first?.message == "Disk full")
        #expect(log.requests == 0)
    }

    @Test func aFrontmostGlintGetsTheAlertBecauseMacOSWithholdsItsBanners() async {
        let log = FeedbackLog()
        log.appIsActive = true
        await log.feedback.report(title: "Capture failed", message: "Display changed")
        #expect(log.notified.isEmpty && log.beeps == 1 && log.alerts.count == 1)
        #expect(log.accessQueries == 0 && log.requests == 0)
    }

    @Test func undecidedNotificationsAreRequestedOnceAndUsedWhenGranted() async {
        let log = FeedbackLog()
        log.access = .undecided
        await log.feedback.report(title: "Capture failed", message: "Display changed")
        #expect(log.requests == 1)
        #expect(log.notified.map(\.title) == ["Capture failed"])
        #expect(log.beeps == 0 && log.alerts.isEmpty)
    }

    @Test func undecidedNotificationsThatAreRefusedFallBackToBeepAndAlert() async {
        let log = FeedbackLog()
        log.access = .undecided
        log.grantsRequest = false
        await log.feedback.report(title: "Capture failed", message: "Display changed")
        #expect(log.requests == 1 && log.notified.isEmpty)
        #expect(log.beeps == 1 && log.alerts.map(\.title) == ["Capture failed"])
    }

    @Test(arguments: [NotificationAccess.allowed, .undecided], [true, false])
    func aChangeWhileWaitingForPermissionIsHonoured(access: NotificationAccess, glintComesToTheFront: Bool) async {
        let log = FeedbackLog()
        log.access = access
        log.whilePermissionIsPending = { [log] in
            if glintComesToTheFront { log.appIsActive = true } else { log.notificationsEnabled = false }
        }
        await log.feedback.report(title: "Capture failed", message: "Display changed")
        #expect(log.notified.isEmpty)
        #expect(log.beeps == 1 && log.alerts.map(\.title) == ["Capture failed"])
    }

    @Test func everyFailureIsVisibleExactlyOnceWhateverTheNotificationState() async {
        for enabled in [true, false] {
            for active in [true, false] {
                for access in [NotificationAccess.allowed, .blocked, .undecided] {
                    for grants in [true, false] {
                        let log = FeedbackLog()
                        log.notificationsEnabled = enabled
                        log.appIsActive = active
                        log.access = access
                        log.grantsRequest = grants
                        await log.feedback.report(title: "Failed", message: "Details")
                        let notifies = enabled && !active && (access == .allowed || access == .undecided && grants)
                        let state = "enabled=\(enabled) active=\(active) access=\(access) grants=\(grants)"
                        #expect(log.notified.count == (notifies ? 1 : 0), "\(state)")
                        #expect(log.alerts.count == (notifies ? 0 : 1), "\(state)")
                        #expect(log.beeps == log.alerts.count, "\(state)")
                        #expect(log.notified.count + log.alerts.count == 1, "\(state)")
                    }
                }
            }
        }
    }
}

@MainActor
private final class HeldCapture {
    private var continuation: CheckedContinuation<CaptureResult, Never>?

    func hold() async -> CaptureResult {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilHeld() async throws {
        for _ in 0..<200 where continuation == nil { await Task.yield() }
        _ = try #require(continuation)
    }

    func release(_ result: CaptureResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// Stands in for a scrolling capture that runs until it is finished or cancelled.
@MainActor
private final class RunningScroll: ScrollingCapture {
    let result: CaptureResult
    private(set) var finishes = 0
    private(set) var isRunning = false
    private var continuation: CheckedContinuation<CaptureResult, Error>?

    init(result: CaptureResult) { self.result = result }

    func run() async throws -> CaptureResult {
        isRunning = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish() {
        finishes += 1
        continuation?.resume(returning: result)
        continuation = nil
    }

    func cancel() {
        continuation?.resume(throwing: CaptureError.cancelled)
        continuation = nil
    }
}

@MainActor
private final class Reports {
    var failures: [(title: String, message: String, url: URL?)] = []
    var infos: [(title: String, message: String, url: URL?)] = []
    var permissionPrompts = 0
}

@Suite("Capture feedback")
@MainActor
struct CaptureFeedbackTests {
    private func result(_ f: CaptureFixture) -> CaptureResult {
        CaptureResult(image: f.image, scale: 1, displayID: 1, rect: CGRect(x: 0, y: 0, width: 100, height: 40),
                      kind: .area, windowInfo: nil)
    }

    private func pipeline(_ f: CaptureFixture, _ reports: Reports,
                          configure: (inout CapturePipeline.Services) -> Void = { _ in }) -> CapturePipeline {
        f.pipeline {
            $0.fail = { reports.failures.append(($0, $1, $2)) }
            $0.notify = { reports.infos.append(($0, $1, $2)) }
            $0.permissionDenied = { reports.permissionPrompts += 1 }
            configure(&$0)
        }
    }

    @Test(arguments: [CapturePipeline.Mode.area, .areaToClipboard, .window, .fullscreen, .repeatLast, .timer(3), .text, .scrolling])
    func startingWhileACaptureIsRunningIsRejectedAudibly(mode: CapturePipeline.Mode) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let held = HeldCapture()
        let first = f.pipeline { $0.capture = { _, _, _ in await held.hold() } }
        let running = try #require(first.start(.areaToClipboard))
        try await held.waitUntilHeld()
        #expect(f.rejections == 0)

        #expect(first.start(mode) == nil)
        #expect(f.rejections == 1)
        // Rejecting must not release the shared capturer's state.
        #expect(first.isBusy)

        held.release(result(f))
        await running.value
        #expect(f.copies == 1 && f.rejections == 1)
        #expect(!first.isBusy)
    }

    @Test func startingWhileRecordingIsRejectedAudiblyWithoutCapturing() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        var captures = 0
        let pipeline = f.pipeline {
            $0.capture = { _, _, _ in
                captures += 1
                throw CaptureError.cancelled
            }
        }
        var recording = true
        pipeline.isRecordingActive = { recording }

        #expect(pipeline.start(.area) == nil)
        #expect(f.rejections == 1 && captures == 0)

        recording = false
        try await #require(pipeline.start(.area)).value
        #expect(f.rejections == 1 && captures == 1)
    }

    @Test(arguments: [CapturePipeline.Mode.area, .areaToClipboard, .window, .fullscreen, .repeatLast, .timer(3), .text])
    func anIdleStartIsNeverRejected(mode: CapturePipeline.Mode) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let pipeline = f.pipeline {
            $0.capture = { _, _, _ in throw CaptureError.cancelled }
            $0.captureText = { _ in throw CaptureError.cancelled }
        }
        try await #require(pipeline.start(mode)).value
        try await #require(pipeline.start(mode)).value
        #expect(f.rejections == 0)
    }

    @Test func theScrollingShortcutFinishesTheRunningScrollInsteadOfBeeping() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let scroll = RunningScroll(result: CaptureResult(image: f.image, scale: 2, displayID: 1,
                                                         rect: CGRect(x: 0, y: 0, width: 50, height: 400),
                                                         kind: .scrolling, windowInfo: nil))
        f.scrolling = scroll
        let pipeline = f.pipeline()
        let task = try #require(pipeline.start(.scrolling))
        for _ in 0..<200 where !scroll.isRunning { await Task.yield() }
        #expect(scroll.isRunning)

        #expect(pipeline.start(.scrolling) == nil)
        #expect(scroll.finishes == 1 && f.rejections == 0)
        await task.value
        #expect(!pipeline.isBusy)
    }

    @Test func aCaptureFailureIsReportedOnceThroughTheFailureChannel() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let reports = Reports()
        let pipeline = pipeline(f, reports) { $0.capture = { _, _, _ in throw CaptureError.failed("Display changed") } }
        try await #require(pipeline.start(.area)).value
        #expect(reports.failures.map(\.title) == ["Capture failed"])
        #expect(reports.failures.first?.message == "Display changed")
        #expect(reports.infos.isEmpty && reports.permissionPrompts == 0)
        #expect(!pipeline.isBusy)
    }

    @Test(arguments: [0, 1])
    func cancellingACaptureIsNotAFailure(kind: Int) async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let reports = Reports()
        let pipeline = pipeline(f, reports) {
            $0.capture = { _, _, _ in
                if kind == 0 { throw CaptureError.cancelled }
                throw CancellationError()
            }
        }
        try await #require(pipeline.start(.area)).value
        #expect(reports.failures.isEmpty && reports.infos.isEmpty && reports.permissionPrompts == 0)
        #expect(f.rejections == 0)
    }

    @Test func aDeniedCaptureOpensThePermissionsWindowInsteadOfReportingAFailure() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let reports = Reports()
        let pipeline = pipeline(f, reports) { $0.capture = { _, _, _ in throw CaptureError.permissionDenied } }
        try await #require(pipeline.start(.area)).value
        #expect(reports.permissionPrompts == 1)
        #expect(reports.failures.isEmpty && reports.infos.isEmpty)
    }

    @Test func aTextRecognitionFailureIsReportedThroughTheFailureChannel() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let reports = Reports()
        f.failRecognition = true
        await pipeline(f, reports).recognizeText(in: f.image)
        #expect(reports.failures.map(\.title) == ["Text recognition failed"])
        #expect(reports.infos.isEmpty && f.copiedTexts.isEmpty)
    }

    @Test func recognizedTextAndAnEmptyResultAreNotFailures() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let reports = Reports()
        await pipeline(f, reports).recognizeText(in: f.image)
        f.lines = [RecognizedLine(text: "hello", box: .zero)]
        await pipeline(f, reports).recognizeText(in: f.image)
        #expect(reports.infos.map(\.title) == ["No text found", "Text copied"])
        #expect(reports.failures.isEmpty)
    }

    @Test func aRawSaveFailureIsAFailureButTheExportStillSucceedsQuietly() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let reports = Reports()
        f.preferences.saveRaw = true
        f.failRaw = true
        await pipeline(f, reports).handle(image: f.image, scale: 2, source: "test", rawURL: nil, saveRaw: true)
        #expect(reports.failures.map(\.title) == ["Raw screenshot not saved"])
        #expect(reports.infos.map(\.title) == ["Screenshot saved"])
    }

    @Test func aCompleteExportFailureIsAFailure() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let reports = Reports()
        f.failWrite = true
        f.copySucceeds = false
        await pipeline(f, reports).handle(image: f.image, scale: 2, source: "test", rawURL: nil, saveRaw: false)
        #expect(reports.failures.map(\.title) == ["Screenshot export failed"])
        #expect(reports.infos.isEmpty)
    }

    @Test func aPartialExportFailureIsAFailureThatKeepsTheSavedFile() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let reports = Reports()
        f.preferences.copyToClipboardAfterCapture = true
        f.copySucceeds = false
        await pipeline(f, reports).handle(image: f.image, scale: 2, source: "test", rawURL: nil, saveRaw: false)
        let saved = try #require(f.recent.first)
        #expect(reports.failures.map(\.title) == ["Screenshot saved, but copy failed"])
        #expect(reports.failures.first?.url == saved)
        #expect(reports.infos.isEmpty)

        let other = try CaptureFixture(); defer { other.cleanUp() }
        let otherReports = Reports()
        other.failWrite = true
        await pipeline(other, otherReports).handle(image: other.image, scale: 2, source: "test", rawURL: nil,
                                                   saveRaw: false)
        #expect(otherReports.failures.map(\.title) == ["Copied to clipboard, but save failed"])
        #expect(otherReports.infos.isEmpty)
    }

    @Test func aSuccessfulExportIsOnlyAnInformationalNotification() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let reports = Reports()
        await pipeline(f, reports).handle(image: f.image, scale: 2, source: "test", rawURL: nil, saveRaw: false)
        let saved = try #require(f.recent.first)
        #expect(reports.infos.map(\.title) == ["Screenshot saved"] && reports.infos.first?.url == saved)
        #expect(reports.failures.isEmpty)
    }

    @Test func failuresThatOfferARetryAreNotAlsoReportedAsFailures() async throws {
        let f = try CaptureFixture(); defer { f.cleanUp() }
        let reports = Reports()
        f.failRender = true
        await pipeline(f, reports).handle(image: f.image, scale: 2, source: "test", rawURL: nil, saveRaw: false)
        #expect(f.retryRequests.map(\.title) == ["Screenshot not exported"])
        #expect(reports.infos.map(\.title) == ["Screenshot not exported"])
        #expect(reports.failures.isEmpty)
    }
}
