import Foundation
import Testing
@testable import GlintCapture

private typealias Permission = ScreenRecordingPermission

private actor ResetRecorder {
    private(set) var commands: [Permission.ResetCommand] = []
    private let succeeds: Bool

    init(succeeds: Bool) { self.succeeds = succeeds }

    func run(_ command: Permission.ResetCommand) -> Bool {
        commands.append(command)
        return succeeds
    }
}

@MainActor
private final class Harness {
    let recorder: ResetRecorder
    let granted: Bool
    let requestGrantsAccess: Bool
    var requests = 0
    var settingsOpened = 0

    init(granted: Bool, resetSucceeds: Bool, requestGrantsAccess: Bool = false) {
        self.granted = granted
        self.requestGrantsAccess = requestGrantsAccess
        recorder = ResetRecorder(succeeds: resetSucceeds)
    }

    func services(bundleIdentifier: String?) -> Permission.ReauthorizationServices {
        let recorder = recorder
        return Permission.ReauthorizationServices(
            bundleIdentifier: bundleIdentifier,
            isGranted: { self.granted },
            runReset: { await recorder.run($0) },
            request: { self.requests += 1; return self.requestGrantsAccess },
            openSettings: { self.settingsOpened += 1 }
        )
    }
}

@Suite("Screen Recording re-authorization")
@MainActor
struct ScreenRecordingPermissionTests {
    private let bundleID = "io.github.mrashrhodes.glint"

    @Test func resetTargetsOnlyGlintsOwnScreenCaptureEntry() throws {
        let command = try #require(Permission.resetCommand(bundleIdentifier: bundleID))
        #expect(command.executableURL.path == "/usr/bin/tccutil")
        #expect(command.arguments == ["reset", "ScreenCapture", bundleID])
    }

    @Test(arguments: [nil, "", "   ", "\n"] as [String?])
    func missingBundleIdentifierIsRefusedWithoutRunning(_ identifier: String?) async {
        #expect(Permission.resetCommand(bundleIdentifier: identifier) == nil)
        let harness = Harness(granted: false, resetSucceeds: true)

        let outcome = await Permission.reauthorize(using: harness.services(bundleIdentifier: identifier))

        #expect(outcome == .missingBundleIdentifier)
        #expect(await harness.recorder.commands.isEmpty)
        #expect(harness.requests == 0)
        #expect(harness.settingsOpened == 1)
    }

    @Test(arguments: [true, false])
    func successfulResetRequestsAccessAndOpensSettingsIfStillMissing(_ requestGrantsAccess: Bool) async throws {
        let harness = Harness(granted: false, resetSucceeds: true, requestGrantsAccess: requestGrantsAccess)

        let outcome = await Permission.reauthorize(using: harness.services(bundleIdentifier: bundleID))

        #expect(outcome == .requestedAgain)
        #expect(await harness.recorder.commands == [try #require(Permission.resetCommand(bundleIdentifier: bundleID))])
        #expect(harness.requests == 1)
        #expect(harness.settingsOpened == (requestGrantsAccess ? 0 : 1))
    }

    @Test func failedResetFallsBackToSystemSettings() async {
        let harness = Harness(granted: false, resetSucceeds: false)

        let outcome = await Permission.reauthorize(using: harness.services(bundleIdentifier: bundleID))

        #expect(outcome == .resetFailed)
        #expect(await harness.recorder.commands.count == 1)
        #expect(harness.requests == 0)
        #expect(harness.settingsOpened == 1)
    }

    @Test func grantedAccessIsNeverReset() async {
        let harness = Harness(granted: true, resetSucceeds: true)

        let outcome = await Permission.reauthorize(using: harness.services(bundleIdentifier: bundleID))

        #expect(outcome == .alreadyGranted)
        #expect(await harness.recorder.commands.isEmpty)
        #expect(harness.requests == 0)
        #expect(harness.settingsOpened == 0)
    }

    @Test func processRunnerReportsExitStatusWithoutHanging() async {
        let success = Permission.ResetCommand(executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        let failure = Permission.ResetCommand(executableURL: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
        let missing = Permission.ResetCommand(
            executableURL: URL(fileURLWithPath: "/nonexistent/glint-\(UUID().uuidString)"), arguments: []
        )
        #expect(await Permission.runProcess(success))
        #expect(await !Permission.runProcess(failure))
        #expect(await !Permission.runProcess(missing))
    }

    @Test(arguments: [true, false], [true, false])
    func reauthorizationNeedsAMissingGrantWithHistory(_ requested: Bool, _ previouslyGranted: Bool) {
        let version: String? = previouslyGranted ? "1.2.0" : nil
        #expect(!Permission.needsReauthorization(granted: true, requested: requested, grantedVersion: version))
        #expect(Permission.needsReauthorization(granted: false, requested: requested, grantedVersion: version)
            == (requested || previouslyGranted))
    }

    @Test(arguments: [true, false], [true, false])
    func launchRecoveryNeedsAPositivelyRecordedGrant(_ requested: Bool, _ previouslyGranted: Bool) throws {
        let version: String? = previouslyGranted ? "1.3.0" : nil
        #expect(!Permission.lostRecordedGrant(granted: true, grantedVersion: version))
        #expect(Permission.lostRecordedGrant(granted: false, grantedVersion: version) == previouslyGranted)
        try withIsolatedDefaults { defaults in
            defaults.set(requested, forKey: Permission.requestedKey)
            if let version { defaults.set(version, forKey: Permission.grantedVersionKey) }
            #expect(Permission.lostRecordedGrant(granted: false, defaults: defaults) == previouslyGranted)
        }
    }

    @Test func keysStayNamespacedAndCompatibleWithEarlierReleases() {
        #expect(Permission.requestedKey == "glint.screenRecordingRequested")
        #expect(Permission.grantedVersionKey == "glint.screenRecordingGrantedVersion")
    }

    @Test func upgradeFromAnEarlierReleaseCountsAsStale() throws {
        try withIsolatedDefaults { defaults in
            #expect(!Permission.needsReauthorization(granted: false, defaults: defaults))
            #expect(Permission.state(granted: false, defaults: defaults) == .unknown)

            // Releases before grant tracking only stored that access had been requested.
            defaults.set(true, forKey: Permission.requestedKey)
            #expect(Permission.state(granted: false, defaults: defaults) == .denied)
            #expect(Permission.needsReauthorization(granted: false, defaults: defaults))
            #expect(!Permission.needsReauthorization(granted: true, defaults: defaults))
            #expect(Permission.state(granted: true, defaults: defaults) == .granted)
        }
    }

    @Test func grantObservationIsRecordedOnlyWhileGranted() throws {
        try withIsolatedDefaults { defaults in
            Permission.recordObservation(granted: false, version: "1.3.0", defaults: defaults)
            #expect(defaults.string(forKey: Permission.grantedVersionKey) == nil)
            #expect(!Permission.needsReauthorization(granted: false, defaults: defaults))

            Permission.recordObservation(granted: true, version: "1.3.0", defaults: defaults)
            #expect(defaults.string(forKey: Permission.grantedVersionKey) == "1.3.0")
            #expect(!Permission.needsReauthorization(granted: true, defaults: defaults))

            Permission.recordObservation(granted: false, version: "1.4.0", defaults: defaults)
            #expect(defaults.string(forKey: Permission.grantedVersionKey) == "1.3.0")
            #expect(Permission.needsReauthorization(granted: false, defaults: defaults))

            Permission.recordObservation(granted: true, version: "1.4.0", defaults: defaults)
            #expect(defaults.string(forKey: Permission.grantedVersionKey) == "1.4.0")
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "glint.permission.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
