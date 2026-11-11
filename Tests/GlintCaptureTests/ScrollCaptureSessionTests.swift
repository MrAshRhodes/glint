import AppKit
import GlintCore
import Testing
@testable import GlintCapture

// The scrolling capture runs on fakes: a synthetic page stands in for the screen, time only passes when the
// session sleeps, and the test plays the user.

private struct ScrollPage {
    static let width = 64
    static let visible = 160
    let rows: [[UInt8]]

    init(height: Int) {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        rows = (0..<height).map { _ in
            (0..<Self.width).flatMap { _ -> [UInt8] in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let v = state >> 24
                return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), 255]
            }
        }
    }

    func frame(at offset: Int) -> CGImage { Self.image(Array(rows[offset..<(offset + Self.visible)])) }
    func image(rows range: Range<Int>) -> CGImage { Self.image(Array(rows[range])) }

    static func image(_ rows: [[UInt8]]) -> CGImage {
        let data = Data(rows.flatMap { $0 }) as CFData
        return CGImage(width: width, height: rows.count, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: ColorSpaces.sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }
}

private func bytes(_ image: CGImage) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
    out.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: ColorSpaces.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return out
}

@MainActor
private final class ScrollFakePicker: RegionPicking {
    let region: RecordingRegion?
    private var continuation: CheckedContinuation<RecordingRegion, Error>?

    init(_ region: RecordingRegion?) { self.region = region }

    func pick() async throws -> RecordingRegion {
        if let region { return region }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func cancel() {
        continuation?.resume(throwing: CaptureError.cancelled)
        continuation = nil
    }
}

@MainActor
private final class ScrollFakePresenter: ScrollCapturePresenting {
    private(set) var shown: CGRect?
    private(set) var actions: ScrollCaptureControlActions?
    private(set) var statuses: [ScrollCaptureStatus] = []
    private(set) var dismissed = false

    func show(region: RecordingRegion, actions: ScrollCaptureControlActions) {
        shown = region.rect
        self.actions = actions
    }

    func update(_ status: ScrollCaptureStatus, preview: CGImage?) { statuses.append(status) }
    func dismiss() { dismissed = true }
}

@MainActor
private final class ScrollFakeSource: ScrollFrameSource {
    let page: ScrollPage
    var offset = 0
    private(set) var frames = 0
    private(set) var capturedOffsets: [Int] = []
    var signatureError: CaptureError?
    var beforeSignature: (() -> Void)?
    /// Where the "user" has scrolled right after the frame with this number (1-based) was grabbed.
    var offsetAfterFrame: [Int: Int] = [:]

    init(page: ScrollPage) { self.page = page }

    func signature() async throws -> ScrollSignature {
        if let signatureError { throw signatureError }
        beforeSignature?()
        return ScrollSignature(image: page.frame(at: offset))!
    }

    func frame() async throws -> CGImage {
        frames += 1
        capturedOffsets.append(offset)
        let image = page.frame(at: offset)
        if let next = offsetAfterFrame[frames] { offset = next }
        return image
    }

    func signature(of frame: CGImage) -> ScrollSignature? { ScrollSignature(image: frame) }
}

@MainActor
private final class ScrollFakeDriver: ScrollDriving {
    var onScroll: ((CGFloat) -> Void)?
    var failOnStep: Int?
    private(set) var steps: [CGFloat] = []
    private(set) var stops = 0

    func scroll(by points: CGFloat) throws {
        #expect(stops == 0)
        if steps.count + 1 == failOnStep { throw CaptureError.failed("The selected window was covered.") }
        steps.append(points)
        onScroll?(points)
    }

    func stop() { stops += 1 }
}

@MainActor
private final class ScrollHarness {
    let display = DisplayInfo(id: 3, frame: CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 2,
                              name: "Synthetic", isMain: true)
    static let rect = CGRect(x: 100, y: 100, width: 320, height: 400)
    let picker: ScrollFakePicker
    let presenter = ScrollFakePresenter()
    let source = ScrollFakeSource(page: ScrollPage(height: 600))
    let driver = ScrollFakeDriver()
    var scrollerError: CaptureError?
    private(set) var scrollersMade = 0
    private(set) var session: ScrollCaptureSession!
    private(set) var presentersMade = 0
    /// Scroll positions the "user" moves to, one per tick.
    var script: [Int] = []
    /// Called on a tick once the script has run out.
    var onScriptEnd: ((ScrollHarness) -> Void)?
    private var clock: TimeInterval = 0

    init(waitsInPicker: Bool = false, limits: ScrollStitchLimits = ScrollStitchLimits(), autoScroll: Bool = false,
         timing: ScrollAutoScrollTiming = ScrollAutoScrollTiming()) {
        picker = ScrollFakePicker(waitsInPicker ? nil : RecordingRegion(rect: Self.rect, display: display))
        var environment = ScrollCaptureEnvironment(
            requirePermission: {},
            makePicker: { [unowned self] _ in picker },
            makePresenter: { [unowned self] in
                presentersMade += 1
                return presenter
            },
            makeSource: { [unowned self] _, _ in source },
            sleep: { [weak self] _ in await self?.tick() },
            now: { [unowned self] in clock })
        environment.limits = limits
        environment.automaticTiming = timing
        environment.makeScroller = { [unowned self] _ in
            scrollersMade += 1
            if let scrollerError { throw scrollerError }
            return driver
        }
        driver.onScroll = { [unowned self] points in
            // A subsequent step must not be sent before the previous viewport has been captured.
            #expect(source.capturedOffsets.last == source.offset)
            let rows = Int(points * CGFloat(ScrollPage.visible) / Self.rect.height)
            source.offset = min(source.offset + rows, source.page.rows.count - ScrollPage.visible)
        }
        session = ScrollCaptureSession(snapToEdges: false, showsCursor: false, autoScroll: autoScroll,
                                       environment: environment)
    }

    func tick() async {
        clock += 0.1
        if script.isEmpty {
            onScriptEnd?(self)
        } else {
            source.offset = script.removeFirst()
        }
        await Task.yield()
    }

    func run() -> Task<CaptureResult, Error> {
        let session = session!
        return Task { try await session.run() }
    }

    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() { await Task.yield() }
    }
}

@MainActor
@Suite("Scrolling capture session")
struct ScrollCaptureSessionTests {
    @Test func stitchesWhileScrollingThenFinishes() async throws {
        let harness = ScrollHarness()
        harness.script = [90, 180, 270]
        harness.onScriptEnd = { $0.session.finish() }
        let result = try await harness.run().value

        #expect(result.kind == .scrolling)
        #expect(result.scale == 2)
        #expect(result.displayID == 3)
        #expect(result.rect == ScrollHarness.rect)
        #expect(result.image.width == ScrollPage.width && result.image.height == 430)
        #expect(bytes(result.image) == bytes(harness.source.page.image(rows: 0..<430)))
        #expect(harness.presenter.shown == ScrollHarness.rect)
        #expect(harness.presenter.dismissed)
        #expect(harness.presenter.statuses.last?.frames == 4)
        #expect(harness.session.phase == .idle)
        #expect(harness.scrollersMade == 0)
        #expect(harness.presenter.statuses.contains { $0.pace == .tooFast })
    }

    @Test func scrollingRightAfterAGrabStillGrabsTheRestOnceStill() async throws {
        let harness = ScrollHarness()
        harness.script = [90]
        harness.source.offsetAfterFrame = [2: 110]
        var idleTicks = 0
        harness.onScriptEnd = { harness in
            idleTicks += 1
            if idleTicks == 10 { harness.session.finish() }
        }
        // The first frame is grabbed at 0; the user then scrolls to 90 and, just after that grab, on to 110.
        let result = try await harness.run().value
        #expect(result.image.height == 270)
        #expect(bytes(result.image) == bytes(harness.source.page.image(rows: 0..<270)))
    }

    @Test func finishingCapturesTheFinalSmallScrollBeforeItSettles() async throws {
        let harness = ScrollHarness()
        harness.script = [20]
        harness.onScriptEnd = { $0.session.finish() }
        let result = try await harness.run().value
        #expect(result.image.height == 180)
        let matches = bytes(result.image) == bytes(harness.source.page.image(rows: 0..<180))
        #expect(matches)
    }

    @Test func automaticStepsCaptureTheWholePageBeforeAskingToFinish() async throws {
        let harness = ScrollHarness(autoScroll: true)
        let run = harness.run()
        await harness.waitUntil { harness.presenter.statuses.last?.manualFallback != nil }
        #expect(harness.presenter.statuses.last?.manualFallback?.contains("bottom was reached") == true)
        #expect(harness.session.phase == .capturing)
        #expect(harness.source.offset == 440)
        #expect(harness.driver.steps.count > 3)
        #expect(harness.driver.stops == 1)
        #expect(harness.presenter.statuses.contains { $0.isAutomatic })
        harness.session.finish()
        let result = try await run.value
        let matches = bytes(result.image) == bytes(harness.source.page.image(rows: 0..<600))
        #expect(result.image.height == 600)
        #expect(matches)
        #expect(harness.presenter.dismissed)
        #expect(harness.driver.stops == 1)
    }

    @Test func automaticFinishDuringASettlingStepKeepsThatStepAndStops() async throws {
        let harness = ScrollHarness(autoScroll: true)
        harness.driver.onScroll = { _ in }
        var ticks = 0
        harness.onScriptEnd = {
            ticks += 1
            if ticks == 1 { $0.session.finish() }
            // The application responds after Done was requested, while its last wheel event is still settling.
            if ticks == 3 { $0.source.offset = 32 }
        }
        let result = try await harness.run().value
        #expect(harness.driver.steps.count == 1)
        #expect(harness.driver.stops == 1)
        #expect(result.image.height == 192)
    }

    @Test func automaticCancellationStopsPendingScrollAndDismisses() async {
        let harness = ScrollHarness(autoScroll: true)
        harness.onScriptEnd = { $0.session.cancel() }
        await #expect { try await harness.run().value } throws: { error in
            if case .cancelled = error as? CaptureError { return true }
            return false
        }
        #expect(harness.driver.steps.count == 1)
        #expect(harness.driver.stops == 1)
        #expect(harness.presenter.dismissed)
        #expect(harness.session.phase == .idle)
    }

    @Test func cancellingTheRunTaskStopsAutomaticScrolling() async {
        let harness = ScrollHarness(autoScroll: true)
        let run = harness.run()
        harness.onScriptEnd = { _ in run.cancel() }
        await #expect { try await run.value } throws: { error in
            if case .cancelled = error as? CaptureError { return true }
            return false
        }
        #expect(harness.driver.steps.count == 1)
        #expect(harness.driver.stops == 1)
        #expect(harness.presenter.dismissed)
    }

    @Test func automaticSourceFailureDoesNotReturnAPartialCapture() async {
        let harness = ScrollHarness(autoScroll: true)
        harness.source.signatureError = .failed("Screen capture failed")
        await #expect(throws: CaptureError.self) { try await harness.run().value }
        #expect(harness.driver.steps.count == 1)
        #expect(harness.driver.stops == 1)
        #expect(harness.presenter.dismissed)
    }

    @Test func deniedAutomaticPermissionKeepsCapturingManualScrollsWithoutResume() async throws {
        let harness = ScrollHarness(autoScroll: true)
        harness.scrollerError = .failed("Accessibility permission denied")
        let run = harness.run()
        await harness.waitUntil { harness.scrollersMade == 1 }
        #expect(harness.driver.steps.isEmpty)
        harness.source.offset = 40
        await harness.waitUntil { harness.presenter.statuses.last?.frames == 2 }
        #expect(harness.session.phase == .capturing)
        #expect(harness.presenter.statuses.last?.frames == 2)
        harness.session.finish()
        let result = try await run.value
        #expect(result.image.height == 200)
        #expect(bytes(result.image) == bytes(harness.source.page.image(rows: 0..<200)))
        #expect(harness.scrollersMade == 1)
        #expect(harness.driver.steps.isEmpty)
    }

    @Test func automaticTargetLossPausesRatherThanFinishingSilently() async throws {
        let harness = ScrollHarness(autoScroll: true)
        harness.driver.failOnStep = 2
        let run = harness.run()
        await harness.waitUntil { harness.session.phase == .paused }
        #expect(harness.presenter.statuses.last?.automaticStop?.contains("selected window was covered") == true)
        #expect(harness.driver.stops == 1)
        #expect(harness.driver.steps.count == 1)
        harness.session.finish()
        let result = try await run.value
        #expect(result.image.height == 192)
    }

    @Test func ignoredAutomaticEventsStillCaptureSubsequentManualScrolling() async throws {
        let harness = ScrollHarness(autoScroll: true)
        harness.driver.onScroll = { _ in }
        let run = harness.run()
        await harness.waitUntil { harness.driver.stops == 1 }
        harness.source.offset = 40
        await harness.waitUntil { harness.presenter.statuses.last?.frames == 2 }
        #expect(harness.session.phase == .capturing)
        #expect(harness.presenter.statuses.last?.frames == 2)
        #expect(harness.presenter.statuses.last?.manualFallback != nil)
        #expect(harness.driver.steps.count == 3)
        harness.session.finish()
        let result = try await run.value
        #expect(result.image.height == 200)
        let matches = bytes(result.image) == bytes(harness.source.page.image(rows: 0..<200))
        #expect(matches)
        #expect(harness.driver.stops == 1)
    }

    @Test func automaticSafetyLimitRequiresExplicitCompletion() async throws {
        let harness = ScrollHarness(autoScroll: true, timing: ScrollAutoScrollTiming(maxSteps: 2))
        let run = harness.run()
        await harness.waitUntil { harness.session.phase == .paused }
        #expect(harness.presenter.statuses.last?.automaticStop?.contains("safety limit") == true)
        #expect(harness.driver.steps.count == 2)
        #expect(harness.driver.stops == 1)
        harness.session.finish()
        #expect(try await run.value.image.height == 224)
    }

    @Test func automaticUnsettledContentStopsBeforeSendingAnotherStep() async throws {
        let harness = ScrollHarness(autoScroll: true)
        harness.source.beforeSignature = {
            harness.source.offset = harness.source.offset == 20 ? 40 : 20
        }
        let run = harness.run()
        await harness.waitUntil { harness.session.phase == .paused }
        #expect(harness.presenter.statuses.last?.automaticStop?.contains("did not settle") == true)
        #expect(harness.driver.steps.count == 1)
        #expect(harness.driver.stops == 1)
        harness.session.finish()
        #expect(try await run.value.image.height == 160)
    }

    @Test func automaticBadJoinStopsAndCanBeRecoveredManually() async throws {
        let harness = ScrollHarness(autoScroll: true)
        harness.driver.onScroll = { _ in harness.source.offset = 140 }
        let run = harness.run()
        await harness.waitUntil { harness.session.phase == .paused }
        #expect(harness.presenter.statuses.last?.warning == .tooFast)
        #expect(harness.driver.steps.count == 1)
        #expect(harness.driver.stops == 1)
        harness.source.offset = 90
        harness.presenter.actions?.resume()
        harness.onScriptEnd = { $0.session.finish() }
        #expect(try await run.value.image.height == 250)
        #expect(harness.driver.steps.count == 1)
    }

    @Test func finishingWithAnUncapturedBadJoinRequiresReview() async throws {
        let harness = ScrollHarness()
        // Finish while the first change is still settling, before polling attempts the bad join.
        harness.onScriptEnd = {
            $0.onScriptEnd = nil
            $0.source.offset = 140
            $0.session.finish()
        }
        let run = harness.run()
        await harness.waitUntil { harness.session.phase == .paused }
        #expect(harness.presenter.statuses.last?.warning == .tooFast)
        harness.session.finish()
        #expect(try await run.value.image.height == 160)
    }

    @Test func finishingAnAutomaticBadStepStillRequiresReview() async throws {
        let harness = ScrollHarness(autoScroll: true)
        harness.driver.onScroll = { _ in harness.source.offset = 140 }
        harness.onScriptEnd = {
            $0.onScriptEnd = nil
            $0.session.finish()
        }
        let run = harness.run()
        await harness.waitUntil { harness.session.phase == .paused }
        #expect(harness.presenter.statuses.last?.warning == .tooFast)
        #expect(harness.driver.stops == 1)
        harness.session.finish()
        #expect(try await run.value.image.height == 160)
    }

    @Test func manualPaceUpdatesWhileMovingAndAfterWaiting() async throws {
        let harness = ScrollHarness()
        harness.script = [4, 8, 12, 16]
        var idleTicks = 0
        harness.onScriptEnd = {
            idleTicks += 1
            if idleTicks == 24 { $0.session.finish() }
        }
        #expect(try await harness.run().value.image.height == 176)
        #expect(harness.presenter.statuses.contains { $0.pace == .steady })
        #expect(harness.presenter.statuses.contains { $0.pace == .tooSlow })
        #expect(!harness.presenter.statuses.contains { $0.isPaused })
    }

    @Test func finishingWhileSelectingCancels() async {
        let harness = ScrollHarness(waitsInPicker: true)
        let run = harness.run()
        await harness.waitUntil { harness.session.phase == .selecting }
        harness.session.finish()
        await #expect(throws: CaptureError.self) { try await run.value }
        #expect(harness.presentersMade == 0)
    }

    @Test func cancelFromControlsThrowsAndDismisses() async {
        let harness = ScrollHarness()
        harness.script = [90]
        harness.onScriptEnd = { $0.presenter.actions?.cancel() }
        do {
            _ = try await harness.run().value
            Issue.record("Expected the capture to be cancelled")
        } catch {
            guard case .cancelled = error as? CaptureError else {
                Issue.record("Unexpected error \(error)")
                return
            }
        }
        #expect(harness.presenter.dismissed)
    }

    @Test func scrollingTooFarPausesUntilResumed() async throws {
        let harness = ScrollHarness()
        harness.script = [90, 230, 230, 230, 230]
        let run = harness.run()
        await harness.waitUntil { harness.session.phase == .paused }
        #expect(harness.presenter.statuses.last?.warning == .tooFast)
        #expect(harness.presenter.statuses.last?.isPaused == true)

        // The user scrolls back up a little and resumes.
        harness.script = []
        harness.source.offset = 180
        harness.onScriptEnd = { $0.session.finish() }
        harness.presenter.actions?.resume()
        let result = try await run.value
        #expect(bytes(result.image) == bytes(harness.source.page.image(rows: 0..<340)))
    }

    @Test func undoRemovesTheLastStep() async throws {
        let harness = ScrollHarness()
        harness.script = [90, 180]
        harness.onScriptEnd = { harness in
            harness.onScriptEnd = nil
            harness.presenter.actions?.undo()
            harness.session.finish()
        }
        let result = try await harness.run().value
        #expect(bytes(result.image) == bytes(harness.source.page.image(rows: 0..<250)))
    }

    @Test func finishingAfterUndoStillIncludesSubsequentSmallMovement() async throws {
        let harness = ScrollHarness()
        harness.script = [90, 180]
        var ticks = 0
        harness.onScriptEnd = {
            ticks += 1
            if ticks == 1 {
                $0.presenter.actions?.undo()
            } else {
                $0.source.offset = 200
                $0.session.finish()
            }
        }
        #expect(try await harness.run().value.image.height == 360)
    }

    @Test func heightLimitPausesAndDoneKeepsTheImage() async throws {
        let harness = ScrollHarness(limits: ScrollStitchLimits(maxHeight: 300))
        harness.script = [90, 180, 270]
        let run = harness.run()
        await harness.waitUntil { harness.session.phase == .paused }
        #expect(harness.presenter.statuses.last?.warning == .heightLimit)
        // Resume does nothing at the limit; only Done, Undo and Cancel do.
        harness.presenter.actions?.resume()
        harness.presenter.actions?.done()
        let result = try await run.value
        #expect(result.image.height == 300)
    }
}

@Suite("Scrolling capture layout")
struct ScrollCaptureLayoutTests {
    let usable = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let size = CGSize(width: 240, height: 360)

    @Test func controlsGoRightOfTheRegion() {
        let frame = ScrollCaptureLayout.hudFrame(size: size, region: CGRect(x: 200, y: 100, width: 600, height: 700),
                                                 usable: usable)
        #expect(frame == CGRect(x: 816, y: 100, width: 240, height: 360))
    }

    @Test func controlsGoLeftWhenTheRightIsFull() {
        let frame = ScrollCaptureLayout.hudFrame(size: size, region: CGRect(x: 600, y: 100, width: 800, height: 700),
                                                 usable: usable)
        #expect(frame == CGRect(x: 344, y: 100, width: 240, height: 360))
    }

    @Test func controlsGoInsideWhenNeitherSideFits() {
        let frame = ScrollCaptureLayout.hudFrame(size: size, region: CGRect(x: 100, y: 600, width: 1300, height: 290),
                                                 usable: usable)
        #expect(frame.maxX == 1384)
        #expect(frame.maxY <= usable.maxY - RecordingLayout.margin)
    }

    @Test func previewHighlightFollowsTheRows() {
        let rect = ScrollPreviewView.imageRect(imageSize: CGSize(width: 100, height: 400),
                                               in: CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(rect == CGRect(x: 75, y: 0, width: 50, height: 200))
        let band = ScrollPreviewView.highlightRect(rows: 100..<200, imageHeight: 400, imageRect: rect)
        #expect(band == CGRect(x: 75, y: 50, width: 50, height: 50))
    }
}

@MainActor
@Suite("Scrolling capture pace controls")
struct ScrollCapturePaceControlsTests {
    @Test func manualPaceIsVisibleAndWarnsWithoutPausing() {
        let hud = ScrollCaptureHUDView(chrome: .live)
        for pace in [ScrollCapturePace.steady, .tooFast, .tooSlow] {
            let status = ScrollCaptureStatus(frames: 1, height: 160, pace: pace)
            hud.apply(status, preview: nil)
            #expect(!hud.paceLabel.isHidden)
            #expect(hud.paceLabel.stringValue == pace.message)
            #expect(hud.paceLabel.drawsBackground == (pace != .steady))
            #expect(hud.warningLabel.isHidden)
            #expect(!status.isPaused)
        }
        hud.apply(ScrollCaptureStatus(isAutomatic: true), preview: nil)
        #expect(hud.paceLabel.stringValue.contains("Scrolling automatically"))
        #expect(!hud.paceLabel.drawsBackground)
    }

    @Test func stoppedAutomaticCaptureShowsManualRecoveryControls() {
        let hud = ScrollCaptureHUDView(chrome: .live)
        let status = ScrollCaptureStatus(frames: 1, height: 160, automaticStop: "Choose Resume to scroll manually.")
        hud.apply(status, preview: nil)
        #expect(status.isPaused)
        #expect(!hud.warningLabel.isHidden)
        #expect(hud.warningLabel.stringValue == status.automaticStop)
        #expect(!hud.resumeButton.isHidden)
        #expect(hud.paceLabel.isHidden)
    }

    @Test func nativeWheelEventIsBoundedAndTargetsTheSelectionPoint() throws {
        let point = CGPoint(x: -320, y: 240)
        let event = try #require(LiveScrollDriver.event(at: point, points: 500))
        #expect(event.location == point)
        #expect(event.flags.isEmpty)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -120)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0)
        #expect(LiveScrollDriver.event(at: point, points: .infinity) == nil)
    }

    @Test func nativeTargetIgnoresOwnOverlaysAndDetectsMovedOrCoveredWindows() throws {
        let point = CGPoint(x: -320, y: 240)
        func window(_ pid: Int, id: Int, x: CGFloat = -500) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: pid),
             kCGWindowNumber as String: NSNumber(value: id),
             kCGWindowAlpha as String: NSNumber(value: 1),
             kCGWindowBounds as String: CGRect(x: x, y: 0, width: 400, height: 500).dictionaryRepresentation]
        }
        let own = window(1, id: 10), original = window(2, id: 20), covering = window(3, id: 30)
        let target = try #require(LiveScrollDriver.target(at: point, windows: [own, original], excluding: 1))
        #expect(target.pid == 2 && target.windowID == 20)
        #expect(LiveScrollDriver.target(at: point, windows: [covering, original], excluding: 1) != target)
        #expect(LiveScrollDriver.target(at: point, windows: [window(2, id: 20, x: -450)], excluding: 1) != target)
        #expect(LiveScrollDriver.target(at: .zero, windows: [original], excluding: 1) == nil)
    }

    @Test func nativeTargetSkipsCursorMenuBarAndFloatingWindows() throws {
        let point = CGPoint(x: 100, y: 100)
        func window(_ pid: Int, id: Int, layer: Int) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: pid),
             kCGWindowNumber as String: NSNumber(value: id),
             kCGWindowLayer as String: NSNumber(value: layer),
             kCGWindowAlpha as String: NSNumber(value: 1),
             kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 400, height: 500).dictionaryRepresentation]
        }
        let cursor = window(858, id: 8, layer: 2_147_483_630), floating = window(5, id: 50, layer: 5)
        let app = window(2, id: 20, layer: 0)
        let target = try #require(LiveScrollDriver.target(at: point, windows: [cursor, floating, app], excluding: 1))
        #expect(target.pid == 2 && target.windowID == 20)
        #expect(LiveScrollDriver.target(at: point, windows: [cursor, floating], excluding: 1) == nil)
    }
}
