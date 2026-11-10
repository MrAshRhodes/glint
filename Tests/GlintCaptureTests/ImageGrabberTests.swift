import CoreGraphics
import Foundation
import Testing
@testable import GlintCapture

@Suite("Image grabbing policy")
struct ImageGrabberTests {
    private func image() -> CGImage {
        CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    private func display(_ id: CGDirectDisplayID) -> DisplayInfo {
        DisplayInfo(id: id, frame: CGRect(x: 0, y: 0, width: 4, height: 4),
                    scale: 1, name: "Display \(id)", isMain: id == 1)
    }

    @Test func detachingACropPreservesTheProvidedWideGamutProfile() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let ctx = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(try #require(CGColor(colorSpace: p3, components: [1, 0, 0, 0.5])))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let source = try #require(ctx.makeImage())
        let frozen = FrozenDisplay(display: display(1), image: source)
        let crop = try #require(frozen.crop(CGRect(x: 1, y: 1, width: 2, height: 2)))
        #expect(crop.grab.image.width == 2 && crop.grab.image.height == 2)
        #expect(crop.grab.image.colorSpace?.name == CGColorSpace.displayP3)
        #expect(crop.grab.image.alphaInfo == .premultipliedFirst)
    }

    @Test func ownWindowPolicyDefaultsToExclusionButAllowsSelfCapture() {
        var options = CaptureOptions()
        #expect(options.excludeOwnWindows)
        #expect(options.excludedWindowIDs.isEmpty)
        #expect(options.excludesWindow(1, pid: 42, ownPID: 42))
        #expect(!options.excludesWindow(2, pid: 7, ownPID: 42))
        options.excludeOwnWindows = false
        #expect(!options.excludesWindow(1, pid: 42, ownPID: 42))
        options.excludedWindowIDs = [1, 2]
        #expect(options.excludesWindow(1, pid: 42, ownPID: 42))
        #expect(options.excludesWindow(2, pid: 7, ownPID: 42))
        #expect(options.excludesWindow(1, pid: nil, ownPID: 42))
    }

    @Test func regionFallbackRequiresNoWindowExclusions() {
        var options = CaptureOptions()
        #expect(!ImageGrabber.allowsRectFallback(options))
        options.excludeOwnWindows = false
        #expect(ImageGrabber.allowsRectFallback(options))
        options.excludedWindowIDs = [99]
        #expect(!ImageGrabber.allowsRectFallback(options))
        options.excludedWindowIDs = []
        options.allowScreencaptureFallback = false
        #expect(!ImageGrabber.allowsRectFallback(options))
    }

    @Test func disallowedFallbackSurfacesPrimaryFailure() async {
        var fallbackCalled = false
        await #expect(throws: CaptureError.self) {
            try await ImageGrabber.captureWithFallback(allowed: false, capture: {
                throw CaptureError.failed("primary")
            }, fallback: {
                fallbackCalled = true
                return ImageGrabber.Grab(image: image(), scale: 1)
            })
        }
        #expect(!fallbackCalled)
    }

    @Test func permittedFallbackRunsOnlyAfterFailure() async throws {
        var fallbackCalled = false
        let expected = ImageGrabber.Grab(image: image(), scale: 1)
        let result = try await ImageGrabber.captureWithFallback(allowed: true, capture: {
            throw CaptureError.failed("primary")
        }, fallback: {
            fallbackCalled = true
            return expected
        })
        #expect(fallbackCalled)
        #expect(result.image === expected.image)
        fallbackCalled = false
        _ = try await ImageGrabber.captureWithFallback(allowed: true, capture: {
            expected
        }, fallback: {
            fallbackCalled = true
            return expected
        })
        #expect(!fallbackCalled)
    }

    @Test func cancellationNeverRunsFallback() async {
        var fallbackCalled = false
        await #expect(throws: CancellationError.self) {
            try await ImageGrabber.captureWithFallback(allowed: true, capture: {
                throw CancellationError()
            }, fallback: {
                fallbackCalled = true
                return ImageGrabber.Grab(image: image(), scale: 1)
            })
        }
        await #expect(throws: CaptureError.self) {
            try await ImageGrabber.captureWithFallback(allowed: true, capture: {
                throw CaptureError.cancelled
            }, fallback: {
                fallbackCalled = true
                return ImageGrabber.Grab(image: image(), scale: 1)
            })
        }
        #expect(!fallbackCalled)
    }

    @Test func cancellationDuringPrimaryCaptureDiscardsPixels() async {
        let task = Task {
            try await ImageGrabber.captureWithFallback(allowed: true, capture: {
                withUnsafeCurrentTask { $0?.cancel() }
                return ImageGrabber.Grab(image: image(), scale: 1)
            }, fallback: {
                Issue.record("Cancellation must not invoke fallback")
                return ImageGrabber.Grab(image: image(), scale: 1)
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func excludedWindowIsRejectedBeforeAnyLiveCapture() async {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = WindowInfo(id: 1, pid: ownPID, ownerName: "Glint", title: "Editor",
                             frame: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 0)
        await #expect(throws: CaptureError.self) {
            try await ImageGrabber.grabWindow(own, scale: 1, options: CaptureOptions())
        }
        var options = CaptureOptions()
        options.excludeOwnWindows = false
        options.excludedWindowIDs = [own.id]
        await #expect(throws: CaptureError.self) {
            try await ImageGrabber.grabWindow(own, scale: 1, options: options)
        }
        // A window from the freeze never bypasses the policy.
        await #expect(throws: CaptureError.self) {
            try await ImageGrabber.grabWindow(own, scale: 1, options: options,
                                              known: StubWindow(windowID: own.id, frame: own.frame))
        }
    }

    private struct StubWindow: QueriedWindow {
        let windowID: CGWindowID
        let frame: CGRect
    }

    @Test func freezeTimeWindowIsReusedOnlyWhileItsSizeMatchesTheLiveWindow() {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let known = StubWindow(windowID: 5, frame: frame)
        #expect(ImageGrabber.reusable(known, liveFrame: frame)?.windowID == 5)
        // The grab renders the window itself, so only its size matters, not where it moved.
        #expect(ImageGrabber.reusable(known, liveFrame: frame.offsetBy(dx: 500, dy: -30))?.windowID == 5)
        #expect(ImageGrabber.reusable(known, liveFrame: CGRect(x: 10, y: 20, width: 300.005, height: 200)) != nil)

        let stale = [CGRect(x: 10, y: 20, width: 301, height: 200), CGRect(x: 10, y: 20, width: 300, height: 199),
                     CGRect(x: 10, y: 20, width: CGFloat.nan, height: 200), .null, .infinite]
        for live in stale {
            #expect(ImageGrabber.reusable(known, liveFrame: live) == nil)
        }
        #expect(ImageGrabber.reusable(known, liveFrame: nil) == nil)
        #expect(ImageGrabber.reusable(nil, liveFrame: frame) == nil)
    }

    @Test func resolvingUsesTheKnownWindowWithoutAnyLookup() async throws {
        let pixels = image()
        var lookups = 0
        let grab = try await ImageGrabber.grabResolvingWindow(known: 1, fresh: { lookups += 1; return 2 }) { window in
            #expect(window == 1)
            return ImageGrabber.Grab(image: pixels, scale: 1)
        }
        #expect(grab.image === pixels)
        #expect(lookups == 0)
    }

    @Test func resolvingLooksTheWindowUpOnceWhenNothingIsKnown() async throws {
        var lookups = 0
        var grabbed: [Int] = []
        _ = try await ImageGrabber.grabResolvingWindow(known: nil, fresh: { lookups += 1; return 7 }) { window in
            grabbed.append(window)
            return ImageGrabber.Grab(image: image(), scale: 1)
        }
        #expect(lookups == 1)
        #expect(grabbed == [7])

        await #expect(throws: CaptureError.self) {
            try await ImageGrabber.grabResolvingWindow(known: nil, fresh: { () -> Int? in nil }) { _ in
                Issue.record("A window that is not listed has nothing to grab")
                return ImageGrabber.Grab(image: image(), scale: 1)
            }
        }
    }

    @Test func failedKnownWindowIsRetriedOnceOnAFreshLookup() async throws {
        var lookups = 0
        var grabbed: [Int] = []
        let pixels = image()
        let grab = try await ImageGrabber.grabResolvingWindow(known: 1, fresh: { lookups += 1; return 2 }) { window in
            grabbed.append(window)
            if window == 1 { throw CaptureError.failed("stale window") }
            return ImageGrabber.Grab(image: pixels, scale: 1)
        }
        #expect(grab.image === pixels)
        #expect(grabbed == [1, 2])
        #expect(lookups == 1)
    }

    @Test func failedKnownWindowThatIsGoneIsReportedMissing() async {
        let error = await #expect(throws: CaptureError.self) {
            try await ImageGrabber.grabResolvingWindow(known: 1, fresh: { () -> Int? in nil }) { _ in
                throw CaptureError.failed("stale window")
            }
        }
        guard case .windowNotFound? = error else {
            Issue.record("Expected windowNotFound, got \(String(describing: error))")
            return
        }
    }

    @Test func failedFreshWindowIsNotRetriedAgain() async {
        var lookups = 0
        var grabbed: [Int] = []
        await #expect(throws: CaptureError.self) {
            try await ImageGrabber.grabResolvingWindow(known: nil, fresh: { lookups += 1; return 7 }) { window in
                grabbed.append(window)
                throw CaptureError.failed("grab")
            }
        }
        #expect(lookups == 1)
        #expect(grabbed == [7])
    }

    @Test func cancellationNeverRetriesAKnownWindow() async {
        var lookups = 0
        for error in [CancellationError(), CaptureError.cancelled] as [Error] {
            await #expect(throws: (any Error).self) {
                try await ImageGrabber.grabResolvingWindow(known: 1, fresh: { lookups += 1; return 2 }) { _ in
                    throw error
                }
            }
        }
        #expect(lookups == 0)

        let task = Task {
            try await ImageGrabber.grabResolvingWindow(known: 1, fresh: { lookups += 1; return 2 }) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw CaptureError.failed("grab")
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(lookups == 0)
    }

    @Test func cachedContentThatWorksIsNotRefreshed() async throws {
        var refreshes = 0
        let length = try await ImageGrabber.retryingOnFreshSnapshot("kept", isCached: { _ in true }, refresh: { _ in
            refreshes += 1
            return "fresh"
        }, work: { $0.count })
        #expect(length == 4)
        #expect(refreshes == 0)
    }

    @Test func cachedContentThatFailsIsRetriedOnceOnFreshContent() async throws {
        var worked: [String] = []
        var refreshes = 0
        let pixels = image()
        let grab = try await ImageGrabber.retryingOnFreshSnapshot("kept", isCached: { $0 == "kept" }, refresh: { _ in
            refreshes += 1
            return "fresh"
        }, work: { content in
            worked.append(content)
            if content == "kept" { throw CaptureError.failed("stale content") }
            return ImageGrabber.Grab(image: pixels, scale: 1)
        })
        #expect(grab.image === pixels)
        #expect(worked == ["kept", "fresh"])
        #expect(refreshes == 1)
    }

    @Test func contentQueriedForTheCaptureIsNotRetried() async {
        var worked = 0
        var refreshes = 0
        await #expect(throws: CaptureError.self) {
            try await ImageGrabber.retryingOnFreshSnapshot("fresh", isCached: { _ in false }, refresh: { _ in
                refreshes += 1
                return "again"
            }, work: { _ -> Int in
                worked += 1
                throw CaptureError.failed("grab")
            })
        }
        #expect(worked == 1)
        #expect(refreshes == 0)
    }

    @Test func aFailureOnRefreshedContentIsReportedAfterOneRetry() async {
        var worked: [String] = []
        var refreshes = 0
        let error = await #expect(throws: CaptureError.self) {
            try await ImageGrabber.retryingOnFreshSnapshot("kept", isCached: { _ in true }, refresh: { _ in
                refreshes += 1
                return "fresh"
            }, work: { content -> Int in
                worked.append(content)
                throw CaptureError.failed("grab \(content)")
            })
        }
        #expect(worked == ["kept", "fresh"])
        #expect(refreshes == 1)
        guard case .failed(let message)? = error else {
            Issue.record("Expected failed, got \(String(describing: error))")
            return
        }
        #expect(message == "grab fresh")
    }

    @Test func aFailedRefreshIsReportedInsteadOfTheStaleFailure() async {
        var worked = 0
        let error = await #expect(throws: CaptureError.self) {
            try await ImageGrabber.retryingOnFreshSnapshot("kept", isCached: { _ in true }, refresh: { _ -> String in
                throw CaptureError.permissionDenied
            }, work: { _ -> Int in
                worked += 1
                throw CaptureError.failed("stale content")
            })
        }
        #expect(worked == 1)
        guard case .permissionDenied? = error else {
            Issue.record("Expected permissionDenied, got \(String(describing: error))")
            return
        }
    }

    @Test func cancellationNeverRetriesCachedContent() async {
        var refreshes = 0
        for error in [CancellationError(), CaptureError.cancelled] as [Error] {
            await #expect(throws: (any Error).self) {
                try await ImageGrabber.retryingOnFreshSnapshot("kept", isCached: { _ in true }, refresh: { _ in
                    refreshes += 1
                    return "fresh"
                }, work: { _ -> Int in throw error })
            }
        }
        #expect(refreshes == 0)

        let task = Task {
            try await ImageGrabber.retryingOnFreshSnapshot("kept", isCached: { _ in true }, refresh: { _ in
                refreshes += 1
                return "fresh"
            }, work: { _ -> Int in
                withUnsafeCurrentTask { $0?.cancel() }
                throw CaptureError.failed("grab")
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(refreshes == 0)
    }

    @Test func freezingUsesEveryDisplayInInputOrderWithoutDiskFallback() async throws {
        let pixels = image()
        var options = CaptureOptions()
        options.excludeOwnWindows = false
        options.excludedWindowIDs = [99]
        let frozen = try await ImageGrabber.freeze([display(2), display(1)], options: options) { _, received in
            #expect(!received.allowScreencaptureFallback)
            #expect(!received.excludeOwnWindows)
            #expect(received.excludedWindowIDs == [99])
            return ImageGrabber.Grab(image: pixels, scale: 1)
        }
        #expect(frozen.map(\.display.id) == [2, 1])
        #expect(frozen.allSatisfy { $0.image === pixels })
    }

    @Test func freezingNeverReturnsPartialSuccess() async {
        let pixels = image()
        await #expect(throws: CaptureError.self) {
            try await ImageGrabber.freeze([display(1), display(2)], options: CaptureOptions()) { display, _ in
                if display.id == 2 { throw CaptureError.failed("second display") }
                return ImageGrabber.Grab(image: pixels, scale: 1)
            }
        }
    }

    @Test func freezingPropagatesCancellationFromAnyDisplay() async {
        let pixels = image()
        await #expect(throws: CancellationError.self) {
            try await ImageGrabber.freeze([display(1), display(2)], options: CaptureOptions()) { display, _ in
                if display.id == 2 { throw CancellationError() }
                return ImageGrabber.Grab(image: pixels, scale: 1)
            }
        }
    }

    @Test func freezingRequiresAtLeastOneDisplay() async {
        await #expect(throws: CaptureError.self) {
            try await ImageGrabber.freeze([], options: CaptureOptions()) { _, _ in
                Issue.record("No display should be captured")
                return ImageGrabber.Grab(image: image(), scale: 1)
            }
        }
    }

    @Test func freezingQueriesShareableContentOnceForEveryDisplay() async throws {
        let pixels = image()
        var fetches = 0
        var options = CaptureOptions()
        options.excludedWindowIDs = [99]
        let frozen = try await ImageGrabber.freeze([display(3), display(1), display(2)], options: options, content: {
            fetches += 1
            return fetches
        }) { _, received, snapshot in
            #expect(snapshot == 1)
            #expect(!received.allowScreencaptureFallback)
            #expect(received.excludedWindowIDs == [99])
            return ImageGrabber.Grab(image: pixels, scale: 1)
        }
        #expect(fetches == 1)
        #expect(frozen.map(\.display.id) == [3, 1, 2])
        #expect(frozen.allSatisfy { $0.image === pixels })
    }

    @Test func freezingWithoutDisplaysNeverQueriesContent() async {
        await #expect(throws: CaptureError.self) {
            try await ImageGrabber.freeze([], options: CaptureOptions(), content: {
                Issue.record("No content should be queried")
                return 0
            }) { _, _, _ in
                Issue.record("No display should be captured")
                return ImageGrabber.Grab(image: image(), scale: 1)
            }
        }
    }

    @Test func failedContentQueryCapturesNothing() async {
        await #expect(throws: CaptureError.self) {
            try await ImageGrabber.freeze([display(1), display(2)], options: CaptureOptions(), content: { () -> Int in
                throw CaptureError.permissionDenied
            }) { _, _, _ in
                Issue.record("No display should be captured")
                return ImageGrabber.Grab(image: image(), scale: 1)
            }
        }
    }

    @Test func cancelledFreezeReportsCancellationOverGrabFailure() async {
        await #expect(throws: CancellationError.self) {
            try await ImageGrabber.freeze([display(1)], options: CaptureOptions(), content: { 0 }) { _, _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw CaptureError.failed("grab")
            }
        }
    }
}
