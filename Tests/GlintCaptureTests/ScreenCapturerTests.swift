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

        #expect(fixture.events == ["permission", "select", "isOnScreen", "displays", "window"])
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

        #expect(fixture.events == ["permission", "select", "isOnScreen"])
        #expect(try pixel(result.image) == [255, 0, 0, 255])
    }

    @Test func failedOrdinaryWindowGrabFallsBackToFrozenPixels() async throws {
        let fixture = try Fixture()
        fixture.outcome = .window(fixture.window(layer: 0))
        fixture.windowError = CaptureError.windowNotFound

        let result = try await fixture.capturer().captureWindow()

        #expect(fixture.events == ["permission", "select", "isOnScreen", "displays", "window"])
        #expect(try pixel(result.image) == [255, 0, 0, 255])
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
        var windowError: Error?
        var selectError: Error?
        var events: [String] = []
        var freezeRequests: [Bool] = []
        var presentationHooks: [Bool] = []
        var selectionOptions: CaptureOptions?
        var windowOptions: CaptureOptions?

        init() throws {
            defaults = try #require(UserDefaults(suiteName: defaultsName))
            currentDisplays = [display]
            outcome = .area(area, display.id)
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
                return (self.outcome, self.frozen)
            }
            services.isOnScreen = { _ in self.events.append("isOnScreen"); return self.onScreen }
            services.grabWindow = { _, _, options in
                self.events.append("window")
                self.windowOptions = options
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
            let capturer = ScreenCapturer(services: services, defaults: defaults)
            capturer.options.settleDelay = 0
            return capturer
        }
    }
}
