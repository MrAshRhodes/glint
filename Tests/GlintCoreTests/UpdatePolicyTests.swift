import Foundation
import Testing
@testable import GlintCore

@Suite("Update policy")
struct UpdatePolicyTests {
    // MARK: Schedule

    @Test func automaticChecksAreOffByDefault() {
        #expect(UpdateCheckFrequency.default == .never)
        #expect(UpdateCheckFrequency.never.interval == nil)
    }

    @Test func frequenciesMapToExactIntervals() {
        #expect(UpdateCheckFrequency.allCases == [.never, .daily, .weekly, .monthly])
        #expect(UpdateCheckFrequency.allCases.map(\.title) == ["Never", "Daily", "Weekly", "Monthly"])
        #expect(UpdateCheckFrequency.daily.interval == 86_400)
        #expect(UpdateCheckFrequency.weekly.interval == 604_800)
        #expect(UpdateCheckFrequency.monthly.interval == 2_592_000)
    }

    @Test func persistedStateRoundTripsEveryChoice() {
        for frequency in UpdateCheckFrequency.allCases {
            let restored = UpdateCheckFrequency(
                automaticChecks: frequency.interval != nil,
                interval: frequency.interval ?? 86_400
            )
            #expect(restored == frequency)
        }
    }

    @Test func automaticChecksOffIsNeverWhateverTheStoredInterval() {
        for interval in [0, 60, 86_400, 604_800, 2_592_000, 31_536_000] as [TimeInterval] {
            #expect(UpdateCheckFrequency(automaticChecks: false, interval: interval) == .never)
        }
    }

    @Test func handEditedIntervalsSnapToTheNearestPreset() {
        #expect(UpdateCheckFrequency(automaticChecks: true, interval: 0) == .daily)
        #expect(UpdateCheckFrequency(automaticChecks: true, interval: 3 * 3_600) == .daily)
        #expect(UpdateCheckFrequency(automaticChecks: true, interval: 3 * 86_400) == .daily)
        #expect(UpdateCheckFrequency(automaticChecks: true, interval: 5 * 86_400) == .weekly)
        #expect(UpdateCheckFrequency(automaticChecks: true, interval: 20 * 86_400) == .monthly)
        #expect(UpdateCheckFrequency(automaticChecks: true, interval: 365 * 86_400) == .monthly)
    }

    // MARK: Configuration

    private static let key = Data((0..<UpdateConfiguration.publicKeyLength).map(UInt8.init)).base64EncodedString()
    private static let feed = "https://github.com/MrAshRhodes/glint/releases/latest/download/appcast.xml"

    @Test func configurationNeedsAnHTTPSFeedAndAnEd25519PublicKey() throws {
        let plist: [String: Any] = ["SUFeedURL": " \(Self.feed) ", "SUPublicEDKey": " \(Self.key)\n"]
        let configuration = try UpdateConfiguration.resolve(from: plist).get()
        #expect(configuration.feedURL.absoluteString == Self.feed)
        #expect(configuration.publicKey == Self.key)
    }

    @Test func configurationReportsEachMissingOrMalformedValue() {
        func problem(_ plist: [String: Any]?) -> UpdateConfiguration.Problem? {
            if case .failure(let problem) = UpdateConfiguration.resolve(from: plist) { return problem }
            return nil
        }
        #expect(problem(nil) == .missingFeedURL)
        #expect(problem([:]) == .missingFeedURL)
        #expect(problem(["SUFeedURL": "  ", "SUPublicEDKey": Self.key]) == .missingFeedURL)
        #expect(problem(["SUFeedURL": 3, "SUPublicEDKey": Self.key]) == .missingFeedURL)
        #expect(problem(["SUFeedURL": "http://example.com/appcast.xml", "SUPublicEDKey": Self.key]) == .feedURLNotHTTPS)
        #expect(problem(["SUFeedURL": "file:///tmp/appcast.xml", "SUPublicEDKey": Self.key]) == .feedURLNotHTTPS)
        #expect(problem(["SUFeedURL": "https:///appcast.xml", "SUPublicEDKey": Self.key]) == .feedURLNotHTTPS)
        #expect(problem(["SUFeedURL": Self.feed]) == .missingPublicKey)
        #expect(problem(["SUFeedURL": Self.feed, "SUPublicEDKey": ""]) == .missingPublicKey)
        #expect(problem(["SUFeedURL": Self.feed, "SUPublicEDKey": "not base64!"]) == .invalidPublicKey)
        let short = Data(repeating: 1, count: 31).base64EncodedString()
        #expect(problem(["SUFeedURL": Self.feed, "SUPublicEDKey": short]) == .invalidPublicKey)
        let long = Data(repeating: 1, count: 33).base64EncodedString()
        #expect(problem(["SUFeedURL": Self.feed, "SUPublicEDKey": long]) == .invalidPublicKey)
    }

    @Test func everyProblemHasItsOwnPlainLanguageExplanation() {
        let problems: [UpdateConfiguration.Problem] = [.missingFeedURL, .feedURLNotHTTPS, .missingPublicKey, .invalidPublicKey]
        let explanations = problems.map(\.explanation)
        #expect(explanations.allSatisfy { !$0.isEmpty })
        #expect(Set(explanations).count == problems.count)
        #expect(UpdateConfiguration.Problem.missingPublicKey.explanation.contains("signing key"))
    }

    // MARK: Install source

    /// A throwaway Homebrew-like tree: `prefix/Caskroom` plus an `Applications` folder.
    private struct Fixture {
        let root: URL
        var caskroom: URL { root.appendingPathComponent("prefix/Caskroom", isDirectory: true) }
        var applications: URL { root.appendingPathComponent("Applications", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("glint-update-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: caskroom, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        }

        func app(in folder: URL) throws -> URL {
            let url = folder.appendingPathComponent("Glint.app", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func stagedFolder(token: String = "glint", version: String = "1.5.4") throws -> URL {
            let folder = caskroom.appendingPathComponent("\(token)/\(version)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        func link(_ link: URL, to destination: URL) throws {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        }

        func detect(_ bundle: URL) -> UpdateInstallSource {
            UpdateInstallSource.detect(bundleURL: bundle, caskroomRoots: [caskroom])
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func caskThatMovedTheAppIntoApplicationsIsHomebrewManaged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installed = try fixture.app(in: fixture.applications)
        try fixture.link(try fixture.stagedFolder().appendingPathComponent("Glint.app"), to: installed)
        #expect(fixture.detect(installed) == .homebrew(caskVersion: "1.5.4"))
    }

    @Test func caskThatStagedTheAppAndLinkedItIntoApplicationsIsHomebrewManaged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let staged = try fixture.app(in: fixture.stagedFolder())
        let linked = fixture.applications.appendingPathComponent("Glint.app")
        try fixture.link(linked, to: staged)
        #expect(fixture.detect(linked) == .homebrew(caskVersion: "1.5.4"))
        #expect(fixture.detect(staged) == .homebrew(caskVersion: "1.5.4"))
    }

    @Test func aSeparateDirectCopyStillUpdatesItselfWhileTheCaskIsInstalledElsewhere() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let brewCopy = try fixture.app(in: fixture.applications)
        try fixture.link(try fixture.stagedFolder().appendingPathComponent("Glint.app"), to: brewCopy)
        let downloads = fixture.root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let directCopy = try fixture.app(in: downloads)
        #expect(fixture.detect(directCopy) == .direct)
        #expect(!fixture.detect(directCopy).isHomebrew)
    }

    @Test func otherCasksAndMissingCaskroomsDoNotCount() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installed = try fixture.app(in: fixture.applications)
        #expect(fixture.detect(installed) == .direct)
        let other = try fixture.stagedFolder(token: "something-else").appendingPathComponent("Glint.app")
        try fixture.link(other, to: installed)
        #expect(fixture.detect(installed) == .direct)
        let missing = fixture.root.appendingPathComponent("nowhere/Caskroom", isDirectory: true)
        #expect(UpdateInstallSource.detect(bundleURL: installed, caskroomRoots: [missing]) == .direct)
        #expect(UpdateInstallSource.detect(bundleURL: installed, caskroomRoots: []) == .direct)
    }

    @Test func aCaskroomLinkToAnotherLocationDoesNotMarkThisCopyAsHomebrew() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installed = try fixture.app(in: fixture.applications)
        let gone = fixture.root.appendingPathComponent("Removed/Glint.app")
        try fixture.link(try fixture.stagedFolder().appendingPathComponent("Glint.app"), to: gone)
        #expect(fixture.detect(installed) == .direct)
    }

    @Test func aStaleCaskroomLinkToTheRunningAppStaysHomebrewAndExplainsTheMismatch() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // The cask recorded 1.5.4; the app in /Applications was then replaced by hand with another version.
        let installed = try fixture.app(in: fixture.applications)
        try fixture.link(try fixture.stagedFolder(version: "1.5.4").appendingPathComponent("Glint.app"), to: installed)
        let source = fixture.detect(installed)
        #expect(source == .homebrew(caskVersion: "1.5.4"))

        let hint = try #require(source.staleRecordHint(runningVersion: "1.5.5"))
        #expect(hint.contains("1.5.4"))
        #expect(hint.contains("1.5.5"))
        #expect(hint.contains("Switching an install between Homebrew and direct downloads"))
        #expect(source.staleRecordHint(runningVersion: "1.5.4") == nil)
        #expect(source.staleRecordHint(runningVersion: nil) == nil)
        #expect(UpdateInstallSource.direct.staleRecordHint(runningVersion: "1.5.5") == nil)
        #expect(UpdateInstallSource.homebrew(caskVersion: nil).staleRecordHint(runningVersion: "1.5.5") == nil)
    }

    @Test func aCaskroomPathIsHomebrewEvenUnderAPrefixNobodyListed() {
        let bundle = URL(fileURLWithPath: "/nonexistent-prefix/Caskroom/glint/1.4.0/Glint.app", isDirectory: true)
        #expect(UpdateInstallSource.detect(bundleURL: bundle, caskroomRoots: []) == .homebrew(caskVersion: "1.4.0"))
        let other = URL(fileURLWithPath: "/nonexistent-prefix/Caskroom/glint-nightly/1.4.0/Glint.app", isDirectory: true)
        #expect(UpdateInstallSource.detect(bundleURL: other, caskroomRoots: []) == .direct)
    }

    @Test func defaultCaskroomRootsCoverTheUsualPrefixesAndAnExplicitOne() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let usual = [
            "/opt/homebrew/Caskroom",
            "/usr/local/Caskroom",
            "/Users/tester/homebrew/Caskroom",
            "/Users/tester/.homebrew/Caskroom",
        ]
        #expect(UpdateInstallSource.defaultCaskroomRoots(environment: [:], home: home).map(\.path) == usual)
        #expect(UpdateInstallSource.defaultCaskroomRoots(environment: ["HOMEBREW_PREFIX": "/opt/brew"], home: home).map(\.path)
            == ["/opt/brew/Caskroom"] + usual)
        // A prefix that is already listed is not repeated, and it is searched first.
        #expect(UpdateInstallSource.defaultCaskroomRoots(environment: ["HOMEBREW_PREFIX": "/usr/local"], home: home).map(\.path)
            == ["/usr/local/Caskroom", "/opt/homebrew/Caskroom", "/Users/tester/homebrew/Caskroom", "/Users/tester/.homebrew/Caskroom"])
        #expect(UpdateInstallSource.defaultCaskroomRoots(environment: ["HOMEBREW_PREFIX": "relative"], home: home).map(\.path) == usual)
    }

    @Test func homebrewUpdateCommandMatchesTheDocumentedUpgrade() {
        #expect(UpdateInstallSource.homebrewUpdateCommand == "brew update && brew upgrade --cask glint")
        #expect(UpdateInstallSource.homebrew(caskVersion: nil).isHomebrew)
        #expect(!UpdateInstallSource.direct.isHomebrew)
    }
}
