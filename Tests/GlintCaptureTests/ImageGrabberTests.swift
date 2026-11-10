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
