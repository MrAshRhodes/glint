import AppKit
import Testing
@testable import GlintCapture

@MainActor
@Suite("Interactive screenshot pixels")
struct ScreenCapturerTests {
    @Test func immediateAreaUsesPreFocusPixelsAndOriginalDisplayGeometry() async throws {
        let fixture = try Fixture()
        fixture.currentDisplays = [
            DisplayInfo(id: 99, frame: CGRect(x: 1000, y: 1000, width: 100, height: 80),
                        scale: 1, name: "Reconfigured", isMain: true)
        ]
        let capturer = fixture.capturer()

        let result = try await capturer.captureArea()

        #expect(fixture.events == ["permission", "select"])
        #expect(fixture.freezeRequests == [true])
        #expect(result.displayID == fixture.display.id)
        #expect(result.rect == fixture.area)
        #expect(result.scale == 2)
        #expect(result.image.width == 40 && result.image.height == 40)
        #expect(try pixel(result.image) == [255, 0, 0, 255])
        #expect(capturer.lastArea == fixture.area)
    }

    @Test func textOnlyAlsoUsesPreFocusPixels() async throws {
        let fixture = try Fixture()
        let image = try await fixture.capturer().captureTextOnly()
        #expect(fixture.freezeRequests == [true])
        #expect(fixture.events == ["permission", "select"])
        #expect(try pixel(image) == [255, 0, 0, 255])
    }

    @Test func missingRequestedFrozenDisplayNeverFallsBackToLiveArea() async throws {
        for missing in [true, false] {
            let fixture = try Fixture()
            if missing {
                fixture.frozen = []
            } else {
                fixture.outcome = .area(fixture.area, 99)
            }
            await #expect(throws: CaptureError.self) { try await fixture.capturer().captureArea() }
            #expect(fixture.events == ["permission", "select"])
        }
    }

    @Test func invalidFrozenCropNeverFallsBackToLiveArea() async throws {
        let fixture = try Fixture()
        fixture.outcome = .area(CGRect(x: 500, y: 500, width: 20, height: 20), fixture.display.id)
        await #expect(throws: CaptureError.self) { try await fixture.capturer().captureArea() }
        #expect(fixture.events == ["permission", "select"])
    }

    @Test(arguments: [3, WindowEnumerator.popUpMenuLevel])
    func raisedWindowsUseFrozenPixelsEvenWhenStillOnScreen(layer: Int) async throws {
        let fixture = try Fixture()
        let window = fixture.window(layer: layer)
        fixture.outcome = .window(window)
        fixture.onScreen = true
        let result = try await fixture.capturer().captureWindow()

        #expect(fixture.freezeRequests == [true])
        #expect(fixture.events == ["permission", "select"])
        #expect(result.windowInfo == window)
        #expect(result.kind == .window)
        #expect(try pixel(result.image) == [255, 0, 0, 255])
    }

    @Test func ordinaryWindowKeepsIndependentCaptureAndShadowOptions() async throws {
        let fixture = try Fixture()
        let window = fixture.window(layer: 0)
        fixture.outcome = .window(window)
        let capturer = fixture.capturer()
        capturer.options.includeWindowShadow = true

        let result = try await capturer.captureWindow()

        #expect(fixture.events == ["permission", "select", "onScreenFrame", "displays", "window"])
        #expect(result.image === fixture.liveImage)
        #expect(try pixel(result.image) == [0, 0, 255, 255])
        #expect(fixture.windowOptions?.includeWindowShadow == true)
        #expect(result.windowInfo == window)
    }

    @Test func disappearedOrdinaryWindowUsesFrozenPixelsWithoutLiveGrab() async throws {
        let fixture = try Fixture()
        fixture.outcome = .window(fixture.window(layer: 0))
        fixture.onScreen = false

        let result = try await fixture.capturer().captureWindow()

        #expect(fixture.events == ["permission", "select", "onScreenFrame"])
        #expect(try pixel(result.image) == [255, 0, 0, 255])
    }

    @Test func failedOrdinaryWindowGrabFallsBackToFrozenPixels() async throws {
        let fixture = try Fixture()
        fixture.outcome = .window(fixture.window(layer: 0))
        fixture.windowError = CaptureError.windowNotFound

        let result = try await fixture.capturer().captureWindow()

        #expect(fixture.events == ["permission", "select", "onScreenFrame", "displays", "window"])
        #expect(try pixel(result.image) == [255, 0, 0, 255])
    }

    @Test func windowGrabDoesNotWaitForTheOverlayByDefault() async throws {
        let fixture = try Fixture()
        fixture.outcome = .window(fixture.window(layer: 0))
        fixture.closedAt = fixture.now

        _ = try await fixture.capturer().captureWindow()

        #expect(CaptureOptions().windowSettleDelay == 0)
        #expect(fixture.sleeps.isEmpty)
    }

    @Test func windowSettleIsAnOptInThatOnlyWaitsForWhatIsLeft() async throws {
        let fixture = try Fixture()
        fixture.outcome = .window(fixture.window(layer: 0))
        let capturer = fixture.capturer()
        capturer.options.windowSettleDelay = 0.12
        let full = Duration.seconds(0.12)

        fixture.closedAt = fixture.now.advanced(by: .milliseconds(-50))
        _ = try await capturer.captureWindow()
        #expect(fixture.sleeps == [full - .milliseconds(50)])

        fixture.sleeps = []
        fixture.closedAt = fixture.now.advanced(by: .milliseconds(-125))
        _ = try await capturer.captureWindow()
        fixture.closedAt = fixture.now.advanced(by: .seconds(-5))
        _ = try await capturer.captureWindow()
        #expect(fixture.sleeps.isEmpty)

        fixture.closedAt = nil
        _ = try await capturer.captureWindow()
        #expect(fixture.sleeps == [full])
    }

    @Test func aWindowSettleWaitAsksForTheWindowAgainBecauseItMayHaveChanged() async throws {
        let fixture = try Fixture()
        let window = fixture.window(layer: 0)
        fixture.outcome = .window(window)
        fixture.windows = [window.id: StubWindow(windowID: window.id, frame: window.frame)]
        let capturer = fixture.capturer()
        capturer.options.windowSettleDelay = 0.12

        fixture.closedAt = fixture.now
        _ = try await capturer.captureWindow()
        fixture.closedAt = fixture.now.advanced(by: .seconds(-1))
        _ = try await capturer.captureWindow()

        #expect(fixture.sleeps == [.seconds(0.12)])
        #expect(fixture.knownWindows == [nil, 42])
    }

    @Test func remainingSettleIsWhatHasNotYetElapsedAndNeverNegative() {
        let full = Duration.seconds(0.12)
        #expect(CaptureSettle.remaining(0.12, elapsed: nil) == full)
        #expect(CaptureSettle.remaining(0.12, elapsed: .zero) == full)
        #expect(CaptureSettle.remaining(0.12, elapsed: .milliseconds(30)) == full - .milliseconds(30))
        #expect(CaptureSettle.remaining(0.12, elapsed: .milliseconds(125)) == .zero)
        #expect(CaptureSettle.remaining(0.12, elapsed: .seconds(60)) == .zero)
        // A clock that appears to run backwards never owes more than the full delay.
        #expect(CaptureSettle.remaining(0.12, elapsed: .seconds(-1)) == full)
        for delay in [0, -1, .nan, .infinity, -.infinity] as [TimeInterval] {
            #expect(CaptureSettle.remaining(delay, elapsed: nil) == .zero)
            #expect(CaptureSettle.remaining(delay, elapsed: .zero) == .zero)
        }
    }

    @Test func settleWaitsAfterTheFrozenAreaCropOnlyForLiveGrabs() async throws {
        let fixture = try Fixture()
        let capturer = fixture.capturer()
        fixture.closedAt = fixture.now

        _ = try await capturer.captureArea()
        #expect(fixture.sleeps.isEmpty)

        fixture.closedAt = fixture.now.advanced(by: .milliseconds(-20))
        _ = try await capturer.captureWithTimer(seconds: 0, mode: .area)
        #expect(fixture.sleeps == [Duration.seconds(0.12) - .milliseconds(20)])

        fixture.sleeps = []
        fixture.closedAt = fixture.now.advanced(by: .seconds(-3))
        _ = try await capturer.captureWithTimer(seconds: 0, mode: .area)
        #expect(fixture.sleeps.isEmpty)

        fixture.closedAt = nil
        _ = try await capturer.captureWithTimer(seconds: 0, mode: .area)
        #expect(fixture.sleeps == [.seconds(0.12)])
    }

    @Test func skippedSettleStillStopsACancelledCapture() async throws {
        let fixture = try Fixture()
        fixture.outcome = .window(fixture.window(layer: 0))
        fixture.afterProbe = { withUnsafeCurrentTask { $0?.cancel() } }
        let capturer = fixture.capturer()
        let task = Task { @MainActor in try await capturer.captureWindow() }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.events == ["permission", "select", "onScreenFrame"])
    }

    @Test func windowFromTheFreezeIsReusedOnlyWhileItsSizeMatches() async throws {
        let fixture = try Fixture()
        let window = fixture.window(layer: 0)
        fixture.outcome = .window(window)
        fixture.windows = [window.id: StubWindow(windowID: window.id, frame: window.frame)]
        let capturer = fixture.capturer()

        _ = try await capturer.captureWindow()
        // Moving a window does not change what an independent grab renders.
        fixture.liveFrame = window.frame.offsetBy(dx: 300, dy: 40)
        _ = try await capturer.captureWindow()
        // A resize would distort a grab sized from the old frame, so it asks again.
        fixture.liveFrame = CGRect(origin: window.frame.origin,
                                   size: CGSize(width: window.frame.width + 1, height: window.frame.height))
        _ = try await capturer.captureWindow()
        // So does a window the freeze never listed.
        fixture.liveFrame = window.frame
        fixture.windows = [:]
        _ = try await capturer.captureWindow()

        #expect(fixture.knownWindows == [42, 42, nil, nil])
    }

    @Test func timedWindowGrabAlwaysResolvesTheWindowAfresh() async throws {
        let fixture = try Fixture()
        let window = fixture.window(layer: 0)
        fixture.outcome = .window(window)
        fixture.windows = [window.id: StubWindow(windowID: window.id, frame: window.frame)]

        _ = try await fixture.capturer().captureWindow()
        _ = try await fixture.capturer().captureWithTimer(seconds: 0, mode: .window)

        #expect(fixture.knownWindows == [42, nil])
    }

    @Test func windowCancellationIsNotConvertedToAFrozenSuccess() async throws {
        let fixture = try Fixture()
        fixture.outcome = .window(fixture.window(layer: 0))
        fixture.windowError = CancellationError()
        await #expect(throws: CancellationError.self) { try await fixture.capturer().captureWindow() }

        fixture.windowError = CaptureError.cancelled
        await #expect(throws: CaptureError.self) { try await fixture.capturer().captureWindow() }
    }

    @Test(arguments: [TimedCaptureMode.area, .window])
    func timerOptsOutOfFrozenCaptureEvenForRaisedWindows(mode: TimedCaptureMode) async throws {
        let fixture = try Fixture()
        if mode == .window { fixture.outcome = .window(fixture.window(layer: WindowEnumerator.popUpMenuLevel)) }
        var ticks: [Int] = []

        let result = try await fixture.capturer().captureWithTimer(seconds: 0, mode: mode) { ticks.append($0) }

        #expect(ticks == [0])
        #expect(fixture.freezeRequests == [false])
        #expect(result.image === fixture.liveImage)
        #expect(fixture.events == ["permission", "select", "displays", mode == .window ? "window" : "rect"])
    }

    @Test func ownWindowPolicyIsForwardedToSelectionAndWindowCapture() async throws {
        let fixture = try Fixture()
        fixture.outcome = .window(fixture.window(layer: 0))
        let capturer = fixture.capturer()
        #expect(capturer.options.excludeOwnWindows)
        capturer.options.excludeOwnWindows = false
        capturer.options.excludedWindowIDs = [11, 12]

        _ = try await capturer.captureWindow()

        #expect(fixture.selectionOptions?.excludeOwnWindows == false)
        #expect(fixture.selectionOptions?.excludedWindowIDs == [11, 12])
        #expect(fixture.windowOptions?.excludeOwnWindows == false)
        #expect(fixture.windowOptions?.excludedWindowIDs == [11, 12])
    }

    @Test func fullscreenAndRepeatRemainDirectCapturesWithoutSelection() async throws {
        let fixture = try Fixture()
        let capturer = fixture.capturer()
        capturer.lastArea = fixture.area

        let fullscreen = try await capturer.captureFullscreen(display: fixture.display.id)
        let repeated = try await capturer.captureLastArea()

        #expect(fullscreen.image === fixture.liveImage && repeated.image === fixture.liveImage)
        #expect(fixture.freezeRequests.isEmpty)
        #expect(fixture.events == ["permission", "displays", "display", "permission", "displays", "rect"])
    }

    @Test func presentationHookReachesOnlyTheNextSelection() async throws {
        let fixture = try Fixture()
        let capturer = fixture.capturer()
        let selections: [@MainActor (ScreenCapturer) async throws -> Void] = [
            { _ = try await $0.captureArea() },
            { _ = try await $0.captureWindow() },
            { _ = try await $0.captureTextOnly() },
            { _ = try await $0.captureWithTimer(seconds: 0, mode: .area) },
            { _ = try await $0.captureWithTimer(seconds: 0, mode: .window) }
        ]
        for select in selections {
            var presentations = 0
            capturer.onSelectionPresented = { presentations += 1 }
            try await select(capturer)
            #expect(presentations == 1)
            #expect(capturer.onSelectionPresented == nil)

            try await select(capturer)
            #expect(presentations == 1)
            #expect(fixture.presentationHooks.suffix(2) == [true, false])
        }
        #expect(fixture.presentationHooks.count == selections.count * 2)
    }

    @Test func presentationHookIsConsumedByAFailedSelectionButNotByDirectCaptures() async throws {
        let fixture = try Fixture()
        let capturer = fixture.capturer()
        capturer.lastArea = fixture.area
        var presentations = 0
        capturer.onSelectionPresented = { presentations += 1 }

        _ = try await capturer.captureFullscreen(display: fixture.display.id)
        _ = try await capturer.captureLastArea()
        #expect(capturer.onSelectionPresented != nil)

        fixture.selectError = CaptureError.cancelled
        await #expect(throws: CaptureError.self) { try await capturer.captureArea() }
        #expect(capturer.onSelectionPresented == nil)

        fixture.selectError = nil
        _ = try await capturer.captureArea()
        #expect(presentations == 0)
        #expect(fixture.presentationHooks == [true, false])
    }

    private func pixel(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { data[$0] }
    }

    private struct StubWindow: QueriedWindow {
        let windowID: CGWindowID
        let frame: CGRect
    }

    @MainActor
    private final class Fixture {
        let display = DisplayInfo(id: 7, frame: CGRect(x: -100, y: -20, width: 100, height: 80),
                                  scale: 2, name: "Original", isMain: true)
        let area = CGRect(x: -80, y: 0, width: 20, height: 20)
        let liveImage: CGImage
        let defaults: UserDefaults
        let defaultsName = "ScreenCapturerTests.\(UUID().uuidString)"
        var currentDisplays: [DisplayInfo]
        var outcome: SelectionOutcome
        var frozen: [FrozenDisplay]
        var onScreen = true
        var liveFrame: CGRect
        var windows: [CGWindowID: any QueriedWindow] = [:]
        var closedAt: ContinuousClock.Instant?
        let now = ContinuousClock.now
        var windowError: Error?
        var selectError: Error?
        var afterProbe: (() -> Void)?
        var events: [String] = []
        var sleeps: [Duration] = []
        var knownWindows: [CGWindowID?] = []
        var freezeRequests: [Bool] = []
        var presentationHooks: [Bool] = []
        var selectionOptions: CaptureOptions?
        var windowOptions: CaptureOptions?

        init() throws {
            defaults = try #require(UserDefaults(suiteName: defaultsName))
            currentDisplays = [display]
            outcome = .area(area, display.id)
            liveFrame = area
            // Device RGB fills avoid color matching so pixel assertions stay exact.
            func image(red: CGFloat, blue: CGFloat) throws -> CGImage {
                let context = try #require(CGContext(data: nil, width: 200, height: 160, bitsPerComponent: 8,
                                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(red: red, green: 0, blue: blue, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
                return try #require(context.makeImage())
            }
            liveImage = try image(red: 0, blue: 1)
            frozen = [FrozenDisplay(display: display, image: try image(red: 1, blue: 0))]
        }

        deinit { defaults.removePersistentDomain(forName: defaultsName) }

        func window(layer: Int) -> WindowInfo {
            WindowInfo(id: 42, pid: 123, ownerName: "Test", title: "Window", frame: area, layer: layer)
        }

        func capturer() -> ScreenCapturer {
            var services = ScreenCapturer.Services()
            services.permission = { self.events.append("permission") }
            services.displays = { self.events.append("displays"); return self.currentDisplays }
            services.select = { _, _, options, freeze, presented in
                self.events.append("select")
                self.freezeRequests.append(freeze)
                self.selectionOptions = options
                self.presentationHooks.append(presented != nil)
                if let error = self.selectError { throw error }
                presented?()
                return ScreenCapturer.Selection(outcome: self.outcome, frozen: self.frozen,
                                                closedAt: self.closedAt, windows: self.windows)
            }
            services.now = { self.now }
            services.sleep = { self.sleeps.append($0) }
            services.onScreenFrame = { _ in
                self.events.append("onScreenFrame")
                self.afterProbe?()
                return self.onScreen ? self.liveFrame : nil
            }
            services.grabWindow = { _, _, options, known in
                self.events.append("window")
                self.windowOptions = options
                self.knownWindows.append(known?.windowID)
                if let error = self.windowError { throw error }
                return ImageGrabber.Grab(image: self.liveImage, scale: 2)
            }
            services.grabRect = { _, _, _ in
                self.events.append("rect")
                return ImageGrabber.Grab(image: self.liveImage, scale: 2)
            }
            services.grabDisplay = { _, _ in
                self.events.append("display")
                return ImageGrabber.Grab(image: self.liveImage, scale: 2)
            }
            return ScreenCapturer(services: services, defaults: defaults)
        }
    }
}
