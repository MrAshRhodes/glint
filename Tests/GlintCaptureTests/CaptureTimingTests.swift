import Foundation
import GlintCore
import Testing
@testable import GlintCapture

private typealias Stage = CaptureTiming.Stage

private struct PrivateFailure: Error, LocalizedError {
    var errorDescription: String? { "Secret browser title /Users/example/private.pdf pid=77319" }
}

@MainActor
private final class FakeRunner: CaptureTiming.StageRunner {
    var calls: [Stage] = []
    var prepared: [Stage] = []
    var events: [String] = []
    var failing: Set<Stage> = []
    var allowScreenCapture = false
    var setupDelay: Duration = .zero
    var frame = CaptureTiming.Report.Frame(width: 2880, height: 1800, source: "synthetic")

    func prepare(for stage: Stage) async {
        prepared.append(stage)
        events.append("prepare \(stage.rawValue)")
        if setupDelay > .zero { try? await Task.sleep(for: setupDelay) }
    }

    func run(_ stage: Stage) async throws {
        calls.append(stage)
        events.append("run \(stage.rawValue)")
        if failing.contains(stage) { throw PrivateFailure() }
    }
}

@MainActor
private final class FakeMachine {
    let runner = FakeRunner()
    var permission = ScreenRecordingPermission.State.granted
    var diagnoseCalls = 0
    var runnerRequests: [Bool] = []
    var coldLaunches: [Bool] = []
    var coldResult: [Stage: Double]? = [.shareableContent: 90, .displayGrab: 40, .selectionSnapshot: 3, .renderAndEncode: 300]

    var environment: CaptureTiming.Environment {
        CaptureTiming.Environment(
            permission: { self.permission },
            diagnose: { self.diagnoseCalls += 1; return "== diagnose ==" },
            makeRunner: { allow in
                self.runnerRequests.append(allow)
                self.runner.allowScreenCapture = allow
                return self.runner
            },
            launchColdProbe: { allow in
                self.coldLaunches.append(allow)
                return self.coldResult
            })
    }
}

@Suite("Capture timing")
@MainActor
struct CaptureTimingTests {
    // MARK: Arguments

    @Test func plainDiagnoseIsUnchanged() {
        #expect(CaptureTiming.request(for: ["--diagnose"]) == .diagnose)
        #expect(CaptureTiming.request(for: ["Glint", "--diagnose"]) == .diagnose)
    }

    @Test func timingHasDocumentedDefaults() {
        let expected = CaptureTiming.Options(warmIterations: 50, coldRuns: 20, allowScreenCapture: false)
        #expect(CaptureTiming.request(for: ["Glint", "--diagnose", "--timing"]) == .timing(expected))
        #expect(CaptureTiming.request(for: ["--timing", "--diagnose"]) == .timing(expected))
    }

    @Test func timingOptionsAreParsed() {
        let arguments = ["--diagnose", "--timing", "--timing-iterations", "30", "--timing-cold-runs", "0",
                         "--allow-screen-capture"]
        #expect(CaptureTiming.request(for: arguments)
                == .timing(CaptureTiming.Options(warmIterations: 30, coldRuns: 0, allowScreenCapture: true)))
        let edges = ["--diagnose", "--timing", "--timing-iterations", "1000", "--timing-cold-runs", "100"]
        #expect(CaptureTiming.request(for: edges)
                == .timing(CaptureTiming.Options(warmIterations: 1000, coldRuns: 100, allowScreenCapture: false)))
    }

    @Test func coldRunProbeIsRecognisedByItself() {
        #expect(CaptureTiming.request(for: ["--timing-probe"]) == .probe(allowScreenCapture: false))
        #expect(CaptureTiming.request(for: ["--timing-probe", "--allow-screen-capture"]) == .probe(allowScreenCapture: true))
    }

    @Test(arguments: [
        ["--diagnose", "--timing", "--timing-iterations", "19"],
        ["--diagnose", "--timing", "--timing-iterations", "1001"],
        ["--diagnose", "--timing", "--timing-iterations", "ten"],
        ["--diagnose", "--timing", "--timing-iterations"],
        ["--diagnose", "--timing", "--timing-iterations", "--timing"],
        ["--diagnose", "--timing", "--timing-cold-runs", "101"],
        ["--diagnose", "--timing", "--timing-cold-runs", "-1"],
        ["--diagnose", "--timing", "--timing-cold-runs", "2.5"],
        ["--diagnose", "--timing", "--timing-colds", "3"],
        ["--timing"],
        ["--diagnose", "--allow-screen-capture"],
        ["--diagnose", "--timing-iterations", "30"],
    ])
    func invalidTimingArgumentsAreRejected(_ arguments: [String]) {
        guard case .invalid(let message) = CaptureTiming.request(for: arguments) else {
            Issue.record("\(arguments) was accepted")
            return
        }
        #expect(message.hasPrefix("--") || message.hasPrefix("unknown option: --"))
    }

    @Test func argumentErrorIsTheRejectionMessageOrNil() {
        #expect(CaptureTiming.argumentError(for: ["--diagnose"]) == nil)
        #expect(CaptureTiming.argumentError(for: ["--diagnose", "--timing", "--timing-iterations", "20"]) == nil)
        #expect(CaptureTiming.argumentError(for: ["--timing-probe"]) == nil)
        #expect(CaptureTiming.argumentError(for: ["--timing"])
            == "--timing is an option of --diagnose: run Glint --diagnose --timing")
    }

    // MARK: Which stages may run

    @Test func everyStageRunsWithPermissionAndConsent() {
        let plan = CaptureTiming.plan(permission: .granted, allowScreenCapture: true)
        #expect(plan.stages == [.shareableContent, .displayGrab, .selectionSnapshot, .renderAndEncode])
        #expect(plan.skipped.isEmpty)
    }

    @Test func noPixelGrabWithoutConsent() {
        let plan = CaptureTiming.plan(permission: .granted, allowScreenCapture: false)
        #expect(plan.stages == [.shareableContent, .selectionSnapshot, .renderAndEncode])
        #expect(plan.skipped == [.displayGrab: CaptureTiming.SkipReason.noConsent])
    }

    @Test(arguments: [ScreenRecordingPermission.State.denied, .unknown], [true, false])
    func noPermissionSkipsEverythingThatNeedsIt(_ permission: ScreenRecordingPermission.State, _ consent: Bool) {
        let plan = CaptureTiming.plan(permission: permission, allowScreenCapture: consent)
        #expect(plan.stages == [.selectionSnapshot, .renderAndEncode])
        #expect(plan.skipped == [.shareableContent: CaptureTiming.SkipReason.noPermission,
                                 .displayGrab: CaptureTiming.SkipReason.noPermission])
    }

    // MARK: Measuring

    @Test func warmRunsDiscardOneWarmUpPerStage() async {
        let runner = FakeRunner()
        let results = await CaptureTiming.measureWarm([.selectionSnapshot, .renderAndEncode], iterations: 25, runner: runner)

        #expect(runner.calls == Array(repeating: Stage.selectionSnapshot, count: 26)
                + Array(repeating: Stage.renderAndEncode, count: 26))
        for stage in [Stage.selectionSnapshot, .renderAndEncode] {
            #expect(results[stage]?.failures == 0)
            #expect(results[stage]?.timing?.count == 25)
            #expect(results[stage]?.timing?.p95Reliable == true)
        }
    }

    @Test func failedRunsAreCountedNotTimed() async {
        let runner = FakeRunner()
        runner.failing = [.displayGrab]
        let results = await CaptureTiming.measureWarm([.displayGrab, .renderAndEncode], iterations: 20, runner: runner)

        #expect(results[.displayGrab]?.failures == 20)
        #expect(results[.displayGrab]?.timing == nil)
        #expect(results[.renderAndEncode]?.failures == 0)
        #expect(results[.renderAndEncode]?.timing?.count == 20)
    }

    @Test func coldRunsComeFromOneFreshProcessEach() async {
        var launches = 0
        let results = await CaptureTiming.measureCold([.shareableContent, .renderAndEncode], runs: 3) {
            launches += 1
            switch launches {
            case 1: return [.shareableContent: 100, .renderAndEncode: 300]
            case 2: return nil
            default: return [.shareableContent: 120]
            }
        }

        #expect(launches == 3)
        #expect(results[.shareableContent]?.failures == 1)
        #expect(results[.shareableContent]?.timing?.count == 2)
        #expect(results[.shareableContent]?.timing?.minMs == 100 && results[.shareableContent]?.timing?.maxMs == 120)
        #expect(results[.renderAndEncode]?.failures == 2)
        #expect(results[.renderAndEncode]?.timing?.count == 1)
        #expect(results[.renderAndEncode]?.timing?.p95Reliable == false)
    }

    @Test func noColdRunsNeverLaunchAProcess() async {
        var launches = 0
        let results = await CaptureTiming.measureCold(Stage.allCases, runs: 0) { launches += 1; return nil }
        #expect(launches == 0 && results.isEmpty)
    }

    @Test func probeRunsEachStageOnceInOrderWithItsSetupFirst() async {
        let runner = FakeRunner()
        runner.failing = [.selectionSnapshot]
        let timings = await CaptureTiming.probe([.shareableContent, .selectionSnapshot, .renderAndEncode], runner: runner)

        #expect(runner.calls == [.shareableContent, .selectionSnapshot, .renderAndEncode])
        #expect(runner.events == ["prepare shareable_content", "run shareable_content",
                                  "prepare selection_snapshot", "run selection_snapshot",
                                  "prepare render_and_encode", "run render_and_encode"])
        #expect(Set(timings.keys) == [.shareableContent, .renderAndEncode])
    }

    @Test func setupBeforeAStageIsNotPartOfItsTiming() async throws {
        let runner = FakeRunner()
        runner.setupDelay = .milliseconds(150)
        let milliseconds = try #require(await CaptureTiming.time(.renderAndEncode, with: runner))

        #expect(runner.events == ["prepare render_and_encode", "run render_and_encode"])
        #expect(milliseconds < 75)

        let warm = await CaptureTiming.measureWarm([.renderAndEncode], iterations: 1, runner: runner)
        #expect((warm[.renderAndEncode]?.timing?.maxMs ?? .infinity) < 75)
        #expect(runner.prepared.count == 3)
    }

    @Test func probeOutputRoundTripsAndToleratesNoise() throws {
        let timings: [Stage: Double] = [.shareableContent: 91.25, .renderAndEncode: 312.5]
        let line = CaptureTiming.probeLine(timings)
        #expect(!line.contains("\n"))
        #expect(CaptureTiming.parseProbeOutput(Data(line.utf8)) == timings)
        #expect(CaptureTiming.parseProbeOutput(Data("warning: something\n\(line)\n".utf8)) == timings)
        #expect(CaptureTiming.parseProbeOutput(Data(#"{"display_grab":-1,"nonsense":5,"selection_snapshot":2}"#.utf8))
                == [.selectionSnapshot: 2])
        #expect(CaptureTiming.parseProbeOutput(Data("not json".utf8)) == nil)
        #expect(CaptureTiming.parseProbeOutput(Data()) == nil)
    }

    // MARK: The whole command

    @Test func invalidArgumentsExitWithUsageErrorWithoutMeasuring() async {
        let machine = FakeMachine()
        let outcome = await CaptureTiming.run(arguments: ["--diagnose", "--timing", "--timing-iterations", "3"],
                                              glintVersion: "9.9", environment: machine.environment)
        #expect(outcome.exitCode == 2)
        #expect(outcome.output.isEmpty)
        #expect(outcome.errorOutput.contains("--timing-iterations needs a whole number from 20 to 1000"))
        #expect(machine.runnerRequests.isEmpty && machine.coldLaunches.isEmpty && machine.diagnoseCalls == 0)
    }

    @Test func plainDiagnosePrintsTheAggregateReportOnly() async {
        let machine = FakeMachine()
        let outcome = await CaptureTiming.run(arguments: ["--diagnose"], glintVersion: "9.9", environment: machine.environment)
        #expect(outcome == CaptureTiming.Outcome(output: "== diagnose ==", errorOutput: "", exitCode: 0))
        #expect(machine.runnerRequests.isEmpty && machine.coldLaunches.isEmpty)
        #expect(machine.runner.calls.isEmpty)
    }

    @Test func timingReportHasColdAndWarmSamplesPerStage() async throws {
        let machine = FakeMachine()
        let outcome = await CaptureTiming.run(
            arguments: ["--diagnose", "--timing", "--timing-iterations", "20", "--timing-cold-runs", "4"],
            glintVersion: "9.9", environment: machine.environment)
        #expect(outcome.exitCode == 0 && outcome.errorOutput.isEmpty)
        let report = try JSONDecoder().decode(CaptureTiming.Report.self, from: Data(outcome.output.utf8))

        #expect(report.glintVersion == "9.9" && report.schemaVersion == 1)
        #expect(report.options == .init(warmIterations: 20, coldRuns: 4, allowScreenCapture: false))
        #expect(report.frame == .init(width: 2880, height: 1800, source: "synthetic"))
        #expect(Set(report.definitions.keys) == ["cold", "warm"])
        #expect(report.skipped == ["display_grab": CaptureTiming.SkipReason.noConsent])

        let measured = ["shareable_content", "selection_snapshot", "render_and_encode"]
        #expect(Set(report.cold.keys) == Set(measured) && Set(report.warm.keys) == Set(measured))
        for name in measured {
            #expect(report.cold[name]?.timing?.count == 4 && report.cold[name]?.failures == 0)
            #expect(report.warm[name]?.timing?.count == 20 && report.warm[name]?.failures == 0)
        }
        #expect(machine.coldLaunches == [false, false, false, false])
        #expect(machine.runnerRequests == [false])
        #expect(machine.runner.calls.count == measured.count * 21)
    }

    @Test func consentReachesTheProcessesAndTheGrabRuns() async throws {
        let machine = FakeMachine()
        machine.runner.frame = .init(width: 3456, height: 2234, source: "display")
        let outcome = await CaptureTiming.run(
            arguments: ["--diagnose", "--timing", "--timing-iterations", "20", "--timing-cold-runs", "2",
                        "--allow-screen-capture"],
            glintVersion: "9.9", environment: machine.environment)
        let report = try JSONDecoder().decode(CaptureTiming.Report.self, from: Data(outcome.output.utf8))

        #expect(report.skipped.isEmpty)
        #expect(report.options.allowScreenCapture)
        #expect(report.frame == .init(width: 3456, height: 2234, source: "display"))
        #expect(report.cold["display_grab"]?.timing?.count == 2 && report.warm["display_grab"]?.timing?.count == 20)
        #expect(machine.coldLaunches == [true, true] && machine.runnerRequests == [true])
    }

    @Test func deniedPermissionStillTimesTheLocalStages() async throws {
        let machine = FakeMachine()
        machine.permission = .denied
        let outcome = await CaptureTiming.run(
            arguments: ["--diagnose", "--timing", "--timing-iterations", "20", "--timing-cold-runs", "1",
                        "--allow-screen-capture"],
            glintVersion: "9.9", environment: machine.environment)
        let report = try JSONDecoder().decode(CaptureTiming.Report.self, from: Data(outcome.output.utf8))

        #expect(report.skipped == ["shareable_content": CaptureTiming.SkipReason.noPermission,
                                   "display_grab": CaptureTiming.SkipReason.noPermission])
        #expect(Set(report.warm.keys) == ["selection_snapshot", "render_and_encode"])
        #expect(!machine.runner.calls.contains(.shareableContent) && !machine.runner.calls.contains(.displayGrab))
    }

    @Test func reportNeverContainsErrorTextOrAnythingPrivate() async throws {
        let machine = FakeMachine()
        machine.runner.failing = [.shareableContent, .selectionSnapshot]
        machine.coldResult = nil
        let outcome = await CaptureTiming.run(
            arguments: ["--diagnose", "--timing", "--timing-iterations", "20", "--timing-cold-runs", "2"],
            glintVersion: "9.9", environment: machine.environment)

        for secret in ["Secret", "browser", "/Users", "private.pdf", "77319", "PrivateFailure"] {
            #expect(!outcome.output.contains(secret), "\(secret) leaked")
        }
        let report = try JSONDecoder().decode(CaptureTiming.Report.self, from: Data(outcome.output.utf8))
        #expect(report.warm["shareable_content"] == .init(failures: 20, timing: nil))
        #expect(report.cold["shareable_content"] == .init(failures: 2, timing: nil))
        #expect(report.warm["render_and_encode"]?.failures == 0)
    }

    @Test func coldRunProbeReportsOneJSONLine() async {
        let machine = FakeMachine()
        machine.permission = .denied
        let outcome = await CaptureTiming.run(arguments: ["--timing-probe"], glintVersion: "9.9",
                                              environment: machine.environment)
        #expect(outcome.exitCode == 0 && outcome.errorOutput.isEmpty)
        #expect(!outcome.output.contains("\n"))
        let probed = CaptureTiming.parseProbeOutput(Data(outcome.output.utf8)) ?? [:]
        #expect(Set(probed.keys) == [.selectionSnapshot, .renderAndEncode])
        #expect(machine.runner.prepared == [.selectionSnapshot, .renderAndEncode] && machine.coldLaunches.isEmpty)
        #expect(machine.runner.calls == [.selectionSnapshot, .renderAndEncode])
    }

    @Test func liveRunnerWithoutConsentNeverGrabsPixels() async throws {
        let runner = CaptureTiming.LiveRunner(allowScreenCapture: false)
        await runner.prepare(for: .renderAndEncode)
        await #expect(throws: CaptureError.self) { try await runner.run(.displayGrab) }
        try await runner.run(.renderAndEncode)
        #expect(runner.frame == .init(width: 2880, height: 1800, source: "synthetic"))
    }

    @Test func liveRunnerBuildsTheFallbackFrameOutsideTheTimedRun() async throws {
        // Consent was given, but nothing was grabbed (no permission, or the grab failed): the render uses the
        // generated frame, and only the setup step creates it.
        let runner = CaptureTiming.LiveRunner(allowScreenCapture: true)
        await #expect(throws: CaptureError.self) { try await runner.run(.renderAndEncode) }
        await runner.prepare(for: .selectionSnapshot)
        await #expect(throws: CaptureError.self) { try await runner.run(.renderAndEncode) }
        await runner.prepare(for: .renderAndEncode)
        try await runner.run(.renderAndEncode)
        #expect(runner.frame == .init(width: 2880, height: 1800, source: "synthetic"))
    }
}
