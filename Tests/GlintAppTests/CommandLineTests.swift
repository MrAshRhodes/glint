import Testing
@testable import Glint

@Suite("Command-line arguments")
@MainActor
struct CommandLineTests {
    @Test(arguments: ["--help", "-h", "--version", "-v"])
    func helpAndVersionAliasesExitWithoutStartingGUI(_ argument: String) {
        #expect(CommandLine_.run(["Glint", argument]) == 0)
    }

    @Test func helpDescribesAggregateOnlyDiagnostics() {
        #expect(CommandLine_.usage.contains(
            "--diagnose                      Print capture permission, counts and status only, then exit"
        ))
    }

    @Test func helpDescribesTimingAndItsConsent() {
        #expect(CommandLine_.usage.contains(
            "--diagnose --timing [--timing-iterations N] [--timing-cold-runs N] [--allow-screen-capture]"
        ))
        #expect(CommandLine_.usage.contains("Display pixels are only grabbed with --allow-screen-capture"))
    }

    @Test(arguments: [
        ["--timing"],
        ["--diagnose", "--timing", "--timing-iterations", "5"],
        ["--diagnose", "--timing", "--timing-cold-runs", "many"],
        ["--diagnose", "--timing", "--timing-cold-runz", "3"],
        ["--diagnose", "--allow-screen-capture"],
        ["--allow-screen-capture"],
    ])
    func invalidTimingArgumentsAreAnArgumentErrorBeforeAnythingIsMeasured(_ arguments: [String]) {
        #expect(CommandLine_.run(["Glint"] + arguments) == 2)
    }

    @Test func noOptionsStartsGUI() {
        #expect(CommandLine_.run(["Glint"]) == nil)
    }

    @Test(arguments: ["invalid", "0", "-1", "nan", "inf", "1e999"])
    func invalidScaleIsAnArgumentError(_ value: String) {
        #expect(CommandLine_.run(["Glint", "--render", "unused-input.png", "unused-output.png", "--scale", value]) == 2)
    }

    @Test func missingScaleIsAnArgumentError() {
        #expect(CommandLine_.run(["Glint", "--render", "unused-input.png", "unused-output.png", "--scale"]) == 2)
    }
}
