import Foundation
@testable import GlintCapture
import Testing
@testable import Glint

@Suite("Screen Recording recovery UI")
@MainActor
struct PermissionsPaneTests {
    @Test func reauthorizeCopyMatchesTheGuidance() {
        #expect(PermissionsPane.reauthorizeTitle == "Re-authorize Screen Recording…")
        #expect(PermissionsPane.reauthorizeCaption == """
        Already switched on in System Settings but captures still fail? This can happen after an update. \
        Glint will clear its old entry and request access again.
        """)
        #expect(PermissionsPane.accessHint.contains("Quit & Reopen"))
    }

    @Test func outcomesExplainTheNextStep() {
        #expect(PermissionsPane.message(for: .alreadyGranted) == nil)
        #expect(PermissionsPane.message(for: .requestedAgain)?.contains("Quit & Reopen") == true)
        for fallback in [ScreenRecordingPermission.ReauthorizationOutcome.missingBundleIdentifier, .resetFailed] {
            let message = PermissionsPane.message(for: fallback)
            #expect(message?.contains("remove Glint with “−”") == true)
            #expect(message?.contains("add it again with “+”") == true)
        }
    }

    @Test(arguments: [true, false])
    func firstLaunchAlwaysShowsSetup(_ granted: Bool) throws {
        try withIsolatedDefaults { defaults in
            #expect(PermissionsWindow.shouldPresentAtLaunch(granted: granted, defaults: defaults))
        }
    }

    @Test func previouslyGrantedButNowMissingShowsSetupAtLaunch() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: ShellKey.onboarded)
            ScreenRecordingPermission.recordObservation(granted: true, version: "1.3.0", defaults: defaults)

            #expect(PermissionsWindow.shouldPresentAtLaunch(granted: false, defaults: defaults))
            #expect(!PermissionsWindow.shouldPresentAtLaunch(granted: true, defaults: defaults))
        }
    }

    @Test func neverGrantedDoesNotNagAtLaunch() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: ShellKey.onboarded)

            #expect(!PermissionsWindow.shouldPresentAtLaunch(granted: false, defaults: defaults))
            #expect(!ScreenRecordingPermission.needsReauthorization(granted: false, defaults: defaults))
        }
    }

    @Test func requestedOrDeniedOnlyDoesNotNagAtLaunchButKeepsRecovery() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: ShellKey.onboarded)
            // Ad-hoc releases up to 1.2.0 stored only this key, which cannot prove access was granted.
            defaults.set(true, forKey: "glint.screenRecordingRequested")

            #expect(!PermissionsWindow.shouldPresentAtLaunch(granted: false, defaults: defaults))
            #expect(ScreenRecordingPermission.needsReauthorization(granted: false, defaults: defaults))
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "glint.permissions-pane.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
