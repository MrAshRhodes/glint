import Testing
@testable import Glint

@Suite("Command-line arguments")
struct CommandLineTests {
    @Test(arguments: ["--help", "-h", "--version", "-v"])
    func helpAndVersionAliasesExitWithoutStartingGUI(_ argument: String) {
        #expect(CommandLine_.run(["Glint", argument]) == 0)
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
