import Foundation
import Testing
@testable import GlintCapture

@Suite("Capture diagnostic privacy")
@MainActor
struct CaptureDiagnosticsTests {
    @Test(arguments: [0, 1, 20], [true, false])
    func grantedReportsOnlyAggregateCounts(_ count: Int, _ captureBinaryAvailable: Bool) async {
        var calls = 0
        let report = await CaptureDiagnostics.report(
            permission: .granted,
            captureBinaryAvailable: captureBinaryAvailable,
            displayCount: count,
            windowCount: count * 2
        ) {
            calls += 1
            return (count, count * 3, count * 4)
        }

        #expect(calls == 1)
        #expect(report == """
        == Glint capture diagnostics ==
        Screen Recording: granted=true state=granted
        screencapture binary: \(captureBinaryAvailable ? "present" : "MISSING")
        Displays: \(count)
        On-screen windows: \(count * 2)
        ScreenCaptureKit: \(count) displays, \(count * 3) windows, \(count * 4) apps
        """)
    }

    @Test(arguments: [ScreenRecordingPermission.State.denied, .unknown], [true, false])
    func missingPermissionSkipsShareableContent(
        _ permission: ScreenRecordingPermission.State, _ captureBinaryAvailable: Bool
    ) async {
        var calls = 0
        let report = await CaptureDiagnostics.report(
            permission: permission,
            captureBinaryAvailable: captureBinaryAvailable,
            displayCount: 1,
            windowCount: 21
        ) {
            calls += 1
            return (1, 21, 3)
        }

        #expect(calls == 0)
        #expect(report == """
        == Glint capture diagnostics ==
        Screen Recording: granted=false state=\(permission.rawValue)
        screencapture binary: \(captureBinaryAvailable ? "present" : "MISSING")
        Displays: 1
        On-screen windows: 21
        ScreenCaptureKit: skipped (no permission)
        """)
    }

    @Test func enumerationFailureDoesNotExposeErrorMetadata() async {
        let error = NSError(
            domain: "PrivateOwner",
            code: 48271,
            userInfo: [NSLocalizedDescriptionKey: "Secret browser title /Users/example/private.pdf pid=77319"]
        )
        let report = await CaptureDiagnostics.report(
            permission: .granted,
            captureBinaryAvailable: true,
            displayCount: 1,
            windowCount: 16
        ) {
            throw error
        }

        #expect(report == """
        == Glint capture diagnostics ==
        Screen Recording: granted=true state=granted
        screencapture binary: present
        Displays: 1
        On-screen windows: 16
        ScreenCaptureKit: unavailable (enumeration failed)
        """)
        for privateValue in ["PrivateOwner", "48271", "Secret browser title", "/Users/example/private.pdf", "77319"] {
            #expect(!report.contains(privateValue))
        }
    }
}
