import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
@testable import GlintCapture

@Suite("Screenshot permission errors")
struct CaptureErrorMappingTests {
    private func image() -> CGImage {
        CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    private func display(_ id: CGDirectDisplayID) -> DisplayInfo {
        DisplayInfo(id: id, frame: CGRect(x: 0, y: 0, width: 4, height: 4),
                    scale: 1, name: "Display \(id)", isMain: id == 1)
    }

    /// What ScreenCaptureKit throws when the user refuses (or has revoked) Screen Recording access.
    private var declined: NSError {
        NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
    }

    private func isPermissionDenied(_ error: Error) -> Bool {
        if case CaptureError.permissionDenied = error { return true }
        return false
    }

    @Test func declinedStreamIsPermissionDenied() {
        #expect(isPermissionDenied(ScreenRecorder.captureError(from: declined)))
    }

    @Test func otherStreamErrorsStayCaptureFailures() {
        let other = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedToStart.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: "Could not start"])
        guard case CaptureError.failed(let message) = ScreenRecorder.captureError(from: other) else {
            Issue.record("Expected a capture failure")
            return
        }
        #expect(message == "Could not start")
        #expect(!isPermissionDenied(ScreenRecorder.captureError(from: CaptureError.windowNotFound)))
    }

    @Test func declinedScreenshotReportsPermissionDeniedWithoutRunningTheFallback() async {
        var fallbackCalled = false
        var thrown: Error?
        do {
            _ = try await ImageGrabber.captureWithFallback(allowed: true, capture: {
                throw declined
            }, fallback: {
                fallbackCalled = true
                return ImageGrabber.Grab(image: image(), scale: 1)
            })
        } catch {
            thrown = error
        }
        #expect(thrown.map(isPermissionDenied) == true)
        #expect(!fallbackCalled)
    }

    @Test func declinedScreenshotReportsPermissionDeniedWhereNoFallbackIsAllowed() async {
        var thrown: Error?
        do {
            _ = try await ImageGrabber.captureWithFallback(allowed: false, capture: {
                throw declined
            }, fallback: {
                Issue.record("Fallback is not allowed")
                return ImageGrabber.Grab(image: image(), scale: 1)
            })
        } catch {
            thrown = error
        }
        #expect(thrown.map(isPermissionDenied) == true)
    }

    @Test func screenshotPermissionDenialIsRaisedOnceNotWrappedByTheFallback() async {
        var thrown: Error?
        do {
            _ = try await ImageGrabber.captureWithFallback(allowed: true, capture: {
                throw CaptureError.permissionDenied
            }, fallback: {
                Issue.record("A denied capture must not be retried through screencapture")
                return ImageGrabber.Grab(image: image(), scale: 1)
            })
        } catch {
            thrown = error
        }
        #expect(thrown.map(isPermissionDenied) == true)
    }

    @Test func otherScreenshotFailuresKeepTheirBehavior() async throws {
        var thrown: Error?
        do {
            _ = try await ImageGrabber.captureWithFallback(allowed: false, capture: {
                throw CaptureError.failed("primary")
            }, fallback: {
                Issue.record("Fallback is not allowed")
                return ImageGrabber.Grab(image: image(), scale: 1)
            })
        } catch {
            thrown = error
        }
        guard case CaptureError.failed(let message)? = thrown else {
            Issue.record("Expected the primary failure, got \(String(describing: thrown))")
            return
        }
        #expect(message == "primary")

        var fallbackCalled = false
        let streamFailure = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedToStart.rawValue)
        _ = try await ImageGrabber.captureWithFallback(allowed: true, capture: {
            throw streamFailure
        }, fallback: {
            fallbackCalled = true
            return ImageGrabber.Grab(image: image(), scale: 1)
        })
        #expect(fallbackCalled)
    }

    @Test func declinedShareableContentFreezesNothing() async {
        var thrown: Error?
        do {
            _ = try await ImageGrabber.freeze([display(1), display(2)], options: CaptureOptions(), content: { () -> Int in
                throw declined
            }) { _, _, _ in
                Issue.record("No display should be captured")
                return ImageGrabber.Grab(image: image(), scale: 1)
            }
        } catch {
            thrown = error
        }
        #expect(thrown.map(isPermissionDenied) == true)
    }

    @Test func declinedDisplayGrabFailsTheFreezeAsPermissionDenied() async {
        let pixels = image()
        var thrown: Error?
        do {
            _ = try await ImageGrabber.freeze([display(1), display(2)], options: CaptureOptions(), content: { 0 }) { display, _, _ in
                if display.id == 2 { throw declined }
                return ImageGrabber.Grab(image: pixels, scale: 1)
            }
        } catch {
            thrown = error
        }
        #expect(thrown.map(isPermissionDenied) == true)
    }

    @Test func cancelledFreezeReportsCancellationOverDeclinedGrab() async {
        await #expect(throws: CancellationError.self) {
            try await ImageGrabber.freeze([display(1)], options: CaptureOptions(), content: { 0 }) { _, _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw declined
            }
        }
    }

    @Test func cancelledFreezeReportsCancellationOverDeclinedContentQuery() async {
        await #expect(throws: CancellationError.self) {
            try await ImageGrabber.freeze([display(1)], options: CaptureOptions(), content: { () -> Int in
                withUnsafeCurrentTask { $0?.cancel() }
                throw declined
            }) { _, _, _ in
                Issue.record("No display should be captured")
                return ImageGrabber.Grab(image: image(), scale: 1)
            }
        }
    }

    @Test func cancellationIsNeverReportedAsPermissionDenied() async {
        var thrown: Error?
        do {
            _ = try await ImageGrabber.freeze([display(1)], options: CaptureOptions(), content: { () -> Int in
                throw CancellationError()
            }) { _, _, _ in
                Issue.record("No display should be captured")
                return ImageGrabber.Grab(image: image(), scale: 1)
            }
        } catch {
            thrown = error
        }
        #expect(thrown is CancellationError)
    }
}
