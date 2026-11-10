import Foundation
import GlintCore

/// `Glint --diagnose --timing`: cold and warm timings of the capture-to-export stages, printed as JSON.
///
/// The report holds durations, counts and fixed strings only. Window titles, display names, error text and pixels
/// never leave a stage, so the output is safe to paste into an issue or attach to a CI run.
public enum CaptureTiming {
    public struct Outcome: Equatable, Sendable {
        public let output: String
        public let errorOutput: String
        public let exitCode: Int32
    }

    /// Runs whichever of `--diagnose`, `--diagnose --timing` or the internal cold-run probe `arguments` ask for.
    /// Plain `--diagnose` stays the aggregate-only permission report.
    @MainActor
    public static func run(arguments: [String], glintVersion: String) async -> Outcome {
        await run(arguments: arguments, glintVersion: glintVersion, environment: .live)
    }

    /// Why `arguments` cannot run, or nil when they can. It needs no permission and no run loop, so callers can
    /// reject a typo before starting anything.
    public static func argumentError(for arguments: [String]) -> String? {
        if case .invalid(let message) = request(for: arguments) { return message }
        return nil
    }

    enum Stage: String, CaseIterable, Sendable {
        /// The ScreenCaptureKit content every capture starts with: the kept snapshot when it can serve the capture,
        /// else a new query, so a warm run times what a capture pays rather than a query it would skip.
        case shareableContent = "shareable_content"
        /// One display grab from that content, as the frozen overlay background does it.
        case displayGrab = "display_grab"
        /// The metadata-only window list behind selection snapping.
        case selectionSnapshot = "selection_snapshot"
        /// The styled render and PNG encode of the grabbed frame (a synthetic one without consent to grab pixels).
        case renderAndEncode = "render_and_encode"
    }

    // MARK: Options

    struct Options: Equatable, Sendable {
        static let iterationRange = 20...1000
        static let coldRunRange = 0...100

        /// Measured executions per stage in this process, after one discarded warm-up.
        var warmIterations = 50
        /// Freshly launched processes, one first execution per stage each.
        var coldRuns = 20
        /// Consent to grab real display pixels. Without it no pixel is ever read.
        var allowScreenCapture = false
    }

    enum Request: Equatable {
        case diagnose
        case timing(Options)
        case probe(allowScreenCapture: Bool)
        case invalid(String)
    }

    /// `arguments` may or may not start with the program name: only flags and their values matter.
    static func request(for arguments: [String]) -> Request {
        var options = Options()
        var diagnose = false, timing = false, probe = false, timingOptionGiven = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--diagnose": diagnose = true
            case "--timing": timing = true
            case "--timing-probe": probe = true
            case "--allow-screen-capture":
                options.allowScreenCapture = true
                timingOptionGiven = true
            case "--timing-iterations", "--timing-cold-runs":
                let range = argument == "--timing-iterations" ? Options.iterationRange : Options.coldRunRange
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), range.contains(value) else {
                    return .invalid("\(argument) needs a whole number from \(range.lowerBound) to \(range.upperBound)")
                }
                if argument == "--timing-iterations" { options.warmIterations = value } else { options.coldRuns = value }
                timingOptionGiven = true
                index += 1
            default:
                if argument.hasPrefix("--timing-") { return .invalid("unknown option: \(argument)") }
            }
            index += 1
        }
        if probe { return .probe(allowScreenCapture: options.allowScreenCapture) }
        if timing {
            return diagnose ? .timing(options) : .invalid("--timing is an option of --diagnose: run Glint --diagnose --timing")
        }
        if timingOptionGiven {
            return .invalid("--timing-iterations, --timing-cold-runs and --allow-screen-capture only apply to --diagnose --timing")
        }
        return .diagnose
    }

    // MARK: Plan

    enum SkipReason {
        static let noPermission = "Screen Recording permission is not granted"
        static let noConsent = "grabbing real display pixels needs --allow-screen-capture"
    }

    struct Plan: Equatable {
        var stages: [Stage] = []
        var skipped: [Stage: String] = [:]
    }

    /// Which stages may run. The content query needs the permission the diagnose report already checks; a pixel grab
    /// also needs the explicit consent flag, so nothing reads the screen unless the person asked for it.
    static func plan(permission: ScreenRecordingPermission.State, allowScreenCapture: Bool) -> Plan {
        var plan = Plan()
        for stage in Stage.allCases {
            switch stage {
            case .shareableContent, .displayGrab:
                if permission != .granted {
                    plan.skipped[stage] = SkipReason.noPermission
                } else if stage == .displayGrab && !allowScreenCapture {
                    plan.skipped[stage] = SkipReason.noConsent
                } else {
                    plan.stages.append(stage)
                }
            case .selectionSnapshot, .renderAndEncode:
                plan.stages.append(stage)
            }
        }
        return plan
    }

    // MARK: Report

    struct StageResult: Codable, Equatable {
        /// Executions that threw or never reported. Their error text is never kept.
        var failures: Int
        var timing: TimingSummary?
    }

    struct Report: Codable, Equatable {
        struct Frame: Codable, Equatable {
            var width: Int
            var height: Int
            /// `display` for a grabbed frame, `synthetic` for the generated stand-in.
            var source: String
        }

        struct Echo: Codable, Equatable {
            var warmIterations: Int
            var coldRuns: Int
            var allowScreenCapture: Bool

            enum CodingKeys: String, CodingKey {
                case warmIterations = "warm_iterations"
                case coldRuns = "cold_runs"
                case allowScreenCapture = "allow_screen_capture"
            }
        }

        var schemaVersion = 1
        var tool = "glint --diagnose --timing"
        var glintVersion: String
        var macOS: String
        var architecture: String
        var options: Echo
        var frame: Frame
        var definitions: [String: String]
        var cold: [String: StageResult]
        var warm: [String: StageResult]
        var skipped: [String: String]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case tool
            case glintVersion = "glint_version"
            case macOS = "macos"
            case architecture, options, frame, definitions, cold, warm, skipped
        }
    }

    static let definitions = [
        "cold": "first execution of the stage in a freshly launched Glint process, one process per run, "
            + "stages in a fixed order, OS caches not reset",
        "warm": "repeat executions in one process after one discarded warm-up execution",
    ]

    static func report(options: Options, glintVersion: String, plan: Plan, cold: [Stage: StageResult],
                       warm: [Stage: StageResult], frame: Report.Frame) -> Report {
        func named<Value>(_ values: [Stage: Value]) -> [String: Value] {
            Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return Report(
            glintVersion: glintVersion,
            macOS: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            architecture: architecture,
            options: Report.Echo(warmIterations: options.warmIterations, coldRuns: options.coldRuns,
                                 allowScreenCapture: options.allowScreenCapture),
            frame: frame, definitions: definitions, cold: named(cold), warm: named(warm), skipped: named(plan.skipped))
    }

    static func json<Value: Encodable>(_ value: Value, pretty: Bool = true) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                                          : [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: Measuring

    /// What the measurements need from the machine; tests substitute fakes.
    @MainActor
    protocol StageRunner: AnyObject {
        /// Setup for one execution of `stage` that must not count toward it. Called before every execution, so a
        /// fallback input is built here and a cold sample never pays for it.
        func prepare(for stage: Stage) async
        func run(_ stage: Stage) async throws
        /// The frame the latest `renderAndEncode` worked on.
        var frame: Report.Frame { get }
    }

    @MainActor
    struct Environment {
        var permission: @MainActor () -> ScreenRecordingPermission.State
        var diagnose: @MainActor () async -> String
        var makeRunner: @MainActor (_ allowScreenCapture: Bool) -> any StageRunner
        /// First-execution timings from one freshly launched process; nil when it failed to produce any.
        var launchColdProbe: @MainActor (_ allowScreenCapture: Bool) async -> [Stage: Double]?
    }

    /// Milliseconds for one execution, or nil when it threw.
    @MainActor
    static func time(_ stage: Stage, with runner: any StageRunner) async -> Double? {
        await runner.prepare(for: stage)
        let clock = ContinuousClock()
        let start = clock.now
        do { try await runner.run(stage) } catch { return nil }
        return TimingStatistics.milliseconds(start.duration(to: clock.now))
    }

    @MainActor
    static func measureWarm(_ stages: [Stage], iterations: Int, runner: any StageRunner) async -> [Stage: StageResult] {
        var results: [Stage: StageResult] = [:]
        for stage in stages {
            _ = await time(stage, with: runner)
            var samples: [Double] = []
            var failures = 0
            for _ in 0..<iterations {
                if let milliseconds = await time(stage, with: runner) { samples.append(milliseconds) } else { failures += 1 }
            }
            results[stage] = StageResult(failures: failures, timing: TimingStatistics.summarize(samples))
        }
        return results
    }

    @MainActor
    static func measureCold(_ stages: [Stage], runs: Int,
                            launch: @MainActor () async -> [Stage: Double]?) async -> [Stage: StageResult] {
        guard runs > 0 else { return [:] }
        var samples: [Stage: [Double]] = [:]
        var failures: [Stage: Int] = [:]
        for _ in 0..<runs {
            let probe = await launch()
            for stage in stages {
                if let milliseconds = probe?[stage], milliseconds.isFinite, milliseconds >= 0 {
                    samples[stage, default: []].append(milliseconds)
                } else {
                    failures[stage, default: 0] += 1
                }
            }
        }
        return Dictionary(uniqueKeysWithValues: stages.map {
            ($0, StageResult(failures: failures[$0] ?? 0, timing: TimingStatistics.summarize(samples[$0] ?? [])))
        })
    }

    /// One first execution of every stage in order: what a freshly launched cold-run process reports.
    @MainActor
    static func probe(_ stages: [Stage], runner: any StageRunner) async -> [Stage: Double] {
        var timings: [Stage: Double] = [:]
        for stage in stages {
            if let milliseconds = await time(stage, with: runner) { timings[stage] = milliseconds }
        }
        return timings
    }

    static func probeLine(_ timings: [Stage: Double]) -> String {
        json(Dictionary(uniqueKeysWithValues: timings.map { ($0.key.rawValue, $0.value) }), pretty: false)
    }

    /// The timings on the last non-empty line of a probe's output; nil when it is not a probe report.
    static func parseProbeOutput(_ data: Data) -> [Stage: Double]? {
        guard let text = String(data: data, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).last,
              let decoded = try? JSONDecoder().decode([String: Double].self, from: Data(line.utf8)) else { return nil }
        var timings: [Stage: Double] = [:]
        for (name, milliseconds) in decoded where milliseconds.isFinite && milliseconds >= 0 {
            if let stage = Stage(rawValue: name) { timings[stage] = milliseconds }
        }
        return timings
    }

    // MARK: Entry point

    @MainActor
    static func run(arguments: [String], glintVersion: String, environment: Environment) async -> Outcome {
        switch request(for: arguments) {
        case .invalid(let message):
            return Outcome(output: "", errorOutput: message, exitCode: 2)
        case .diagnose:
            return Outcome(output: await environment.diagnose(), errorOutput: "", exitCode: 0)
        case .probe(let allowScreenCapture):
            let plan = plan(permission: environment.permission(), allowScreenCapture: allowScreenCapture)
            let timings = await probe(plan.stages, runner: environment.makeRunner(allowScreenCapture))
            return Outcome(output: probeLine(timings), errorOutput: "", exitCode: 0)
        case .timing(let options):
            let plan = plan(permission: environment.permission(), allowScreenCapture: options.allowScreenCapture)
            let cold = await measureCold(plan.stages, runs: options.coldRuns) {
                await environment.launchColdProbe(options.allowScreenCapture)
            }
            let runner = environment.makeRunner(options.allowScreenCapture)
            let warm = await measureWarm(plan.stages, iterations: options.warmIterations, runner: runner)
            let report = report(options: options, glintVersion: glintVersion, plan: plan, cold: cold, warm: warm,
                                frame: runner.frame)
            return Outcome(output: json(report), errorOutput: "", exitCode: 0)
        }
    }
}
