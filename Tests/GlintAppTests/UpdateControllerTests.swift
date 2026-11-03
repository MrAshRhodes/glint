import AppKit
import Foundation
import GlintCore
import Testing
@testable import Glint

@Suite("Update controller", .serialized)
@MainActor
struct UpdateControllerTests {
    private var configuration: Result<UpdateConfiguration, UpdateConfiguration.Problem> {
        UpdateConfiguration.resolve(from: [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": Data(repeating: 0, count: 32).base64EncodedString(),
        ])
    }

    private func makeController(
        _ engine: FakeUpdateEngine,
        notices: NoticeLog? = nil
    ) -> UpdateController {
        let notices = notices ?? NoticeLog()
        return UpdateController(
            source: .direct,
            configuration: configuration,
            runningVersion: "1.5.5",
            makeEngine: { engine },
            presentNotice: { notices.append($0) }
        )
    }

    @Test func defaultOffDoesNotStartOrCheck() {
        let engine = FakeUpdateEngine()
        let notices = NoticeLog()
        let controller = makeController(engine, notices: notices)
        #expect(controller.availability == .ready)
        #expect(controller.frequency == .never)
        #expect(!controller.isStarted)
        #expect(controller.canCheckNow)
        #expect(controller.lastCheck == nil)
        #expect(engine.events.isEmpty)
        #expect(notices.items.isEmpty)
    }

    @Test(arguments: UpdateCheckFrequency.allCases)
    func manualCheckWorksAtEveryFrequency(_ frequency: UpdateCheckFrequency) {
        let engine = FakeUpdateEngine()
        engine.automaticallyChecksForUpdates = frequency != .never
        engine.updateCheckInterval = frequency.interval ?? 86_400
        engine.events = []
        let controller = makeController(engine)
        controller.checkForUpdates(nil)
        controller.checkForUpdates(nil)
        #expect(engine.events == ["start", "check", "check"])
        #expect(controller.frequency == frequency)
        #expect(controller.isStarted)
    }

    @Test func schedulesUseExactIntervalsBeforeEnablingAndNeverDisables() {
        let engine = FakeUpdateEngine()
        let controller = makeController(engine)
        let schedules: [(UpdateCheckFrequency, TimeInterval)] = [(.daily, 86_400), (.weekly, 604_800), (.monthly, 2_592_000)]
        for (frequency, seconds) in schedules {
            engine.events = []
            controller.setFrequency(frequency)
            #expect(engine.updateCheckInterval == seconds)
            #expect(engine.automaticallyChecksForUpdates)
            // The interval is set before checks turn on, so Sparkle's first cycle already uses it.
            #expect(Array(engine.events.suffix(2)) == ["interval", "automatic:true"])
            #expect(controller.frequency == frequency)
        }
        engine.events = []
        controller.setFrequency(.never)
        #expect(engine.events == ["automatic:false"])
        #expect(controller.frequency == .never)
        controller.checkForUpdates(nil)
        #expect(engine.events == ["automatic:false", "check"])
    }

    @Test func choosingTheCurrentFrequencyWritesNothing() {
        let engine = FakeUpdateEngine()
        let controller = makeController(engine)
        controller.setFrequency(.never)
        #expect(engine.events.isEmpty)
        #expect(!controller.isStarted)
        controller.setFrequency(.weekly)
        engine.events = []
        controller.setFrequency(.weekly)
        #expect(engine.events.isEmpty)
    }

    @Test func persistedScheduleStartsAtLaunchAndNotificationsRefreshUI() {
        let engine = FakeUpdateEngine()
        engine.automaticallyChecksForUpdates = true
        engine.updateCheckInterval = 604_800
        engine.events = []
        let controller = makeController(engine)
        #expect(controller.frequency == .weekly)
        #expect(controller.isStarted)
        // Starting resumes Sparkle's own schedule; it never checks immediately on Glint's behalf.
        #expect(engine.events == ["start"])

        let item = NSMenuItem(
            title: "Check for Updates…", action: #selector(UpdateController.checkForUpdates(_:)), keyEquivalent: ""
        )
        item.target = controller
        #expect(controller.validateMenuItem(item))

        engine.canCheckForUpdates = false
        engine.lastUpdateCheckDate = Date(timeIntervalSince1970: 12_345)
        engine.onChange?()
        #expect(!controller.canCheckNow)
        #expect(controller.lastCheck == engine.lastUpdateCheckDate)
        #expect(!controller.validateMenuItem(item))

        let other = NSMenuItem(title: "Other", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        #expect(controller.validateMenuItem(other))

        engine.canCheckForUpdates = true
        engine.onChange?()
        #expect(controller.canCheckNow)
        #expect(controller.validateMenuItem(item))
    }

    @Test func beforeStartingAManualCheckIsAlwaysPossible() {
        let engine = FakeUpdateEngine()
        // An updater that hasn't started reports it can't check; the controller starts it on demand instead.
        engine.canCheckForUpdates = false
        let controller = makeController(engine)
        #expect(controller.canCheckNow)
        engine.onChange?()
        #expect(controller.canCheckNow)
        controller.checkForUpdates(nil)
        #expect(engine.events == ["start", "check"])
        #expect(!controller.canCheckNow)
    }

    @Test func startFailureReportsTheErrorWithoutCheckingOrPersistingASchedule() {
        let engine = FakeUpdateEngine()
        engine.startError = NSError(domain: "UpdaterTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Test start failure",
        ])
        let notices = NoticeLog()
        let controller = makeController(engine, notices: notices)
        controller.checkForUpdates(nil)
        controller.setFrequency(.daily)
        #expect(engine.events == ["start", "start"])
        #expect(!controller.isStarted)
        #expect(controller.frequency == .never)
        #expect(!engine.automaticallyChecksForUpdates)
        #expect(notices.items.count == 2)
        for notice in notices.items {
            #expect(notice.title == "Couldn’t Check for Updates")
            #expect(notice.message == "Test start failure")
            #expect(notice.link == UpdateController.releasesURL)
            #expect(notice.copyableCommand == nil)
        }

        // The next attempt retries, and succeeds once the updater can start.
        engine.startError = nil
        engine.events = []
        controller.checkForUpdates(nil)
        #expect(engine.events == ["start", "check"])
        #expect(controller.isStarted)
        #expect(notices.items.count == 2)
    }

    @Test func aPersistedScheduleThatFailsToStartAtLaunchStaysSilent() {
        let engine = FakeUpdateEngine()
        engine.automaticallyChecksForUpdates = true
        engine.updateCheckInterval = 86_400
        engine.events = []
        engine.startError = NSError(domain: "UpdaterTest", code: 2)
        let notices = NoticeLog()
        let controller = makeController(engine, notices: notices)
        #expect(engine.events == ["start"])
        #expect(!controller.isStarted)
        #expect(controller.frequency == .daily)
        #expect(controller.canCheckNow)
        #expect(notices.items.isEmpty)

        engine.startError = nil
        controller.checkForUpdates(nil)
        #expect(engine.events == ["start", "start", "check"])
        #expect(notices.items.isEmpty)
    }

    @Test(arguments: [nil, "1.5.4"] as [String?])
    func homebrewNeverBuildsAnUpdaterEvenWithoutAKey(_ caskVersion: String?) throws {
        var built = false
        let notices = NoticeLog()
        let controller = UpdateController(
            source: .homebrew(caskVersion: caskVersion),
            configuration: .failure(.missingPublicKey),
            runningVersion: "1.5.4",
            makeEngine: { built = true; return FakeUpdateEngine() },
            presentNotice: { notices.append($0) }
        )
        controller.setFrequency(.daily)
        controller.checkForUpdates(nil)
        #expect(!built)
        #expect(controller.availability == .homebrew(hint: nil))
        #expect(controller.frequency == .never)
        #expect(controller.canCheckNow)
        #expect(!controller.isStarted)

        let notice = try #require(notices.items.only)
        #expect(notice == UpdateController.homebrewNotice())
        #expect(notice.title == "Homebrew Keeps Glint Up to Date")
        #expect(notice.copyableCommand == UpdateInstallSource.homebrewUpdateCommand)
        #expect(notice.copyableCommand == "brew update && brew upgrade --cask glint")
        #expect(notice.message.contains("brew update && brew upgrade --cask glint"))
        #expect(notice.link == nil)
    }

    @Test func homebrewNoticeExplainsAStaleRecord() throws {
        let source = UpdateInstallSource.homebrew(caskVersion: "1.5.4")
        let hint = try #require(source.staleRecordHint(runningVersion: "1.5.5"))
        let notices = NoticeLog()
        let controller = UpdateController(
            source: source,
            configuration: configuration,
            runningVersion: "1.5.5",
            makeEngine: { Issue.record("Homebrew copies must not build an updater"); return FakeUpdateEngine() },
            presentNotice: { notices.append($0) }
        )
        #expect(controller.availability == .homebrew(hint: hint))
        controller.checkForUpdates(nil)
        let notice = try #require(notices.items.only)
        #expect(notice == UpdateController.homebrewNotice(hint: hint))
        #expect(notice.message.hasSuffix("\n\n" + hint))
        #expect(notice.copyableCommand == UpdateInstallSource.homebrewUpdateCommand)
    }

    @Test(arguments: [
        UpdateConfiguration.Problem.missingFeedURL, .feedURLNotHTTPS, .missingPublicKey, .invalidPublicKey,
    ])
    func buildsThatCantUpdateExplainWhyAndLinkToReleases(_ problem: UpdateConfiguration.Problem) throws {
        var built = false
        let notices = NoticeLog()
        let controller = UpdateController(
            source: .direct,
            configuration: .failure(problem),
            runningVersion: "1.5.5",
            makeEngine: { built = true; return FakeUpdateEngine() },
            presentNotice: { notices.append($0) }
        )
        #expect(controller.availability == .unavailable(problem.explanation))
        controller.setFrequency(.weekly)
        #expect(controller.frequency == .never)
        #expect(notices.items.isEmpty)

        controller.checkForUpdates(nil)
        #expect(!built)
        let notice = try #require(notices.items.only)
        #expect(notice.title == "This Copy of Glint Can’t Update Itself")
        #expect(notice.message == problem.explanation + "\n\nDownload the latest version from the releases page.")
        #expect(notice.link == UpdateController.releasesURL)
        #expect(notice.copyableCommand == nil)
    }

    @Test func copyPutsTheCommandOnThePasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("something else", forType: .string)
        #expect(UpdateController.copy(UpdateInstallSource.homebrewUpdateCommand, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "brew update && brew upgrade --cask glint")
        #expect(pasteboard.pasteboardItems?.count == 1)
    }

    @Test func linksPointAtTheLatestReleaseAndTheGuide() {
        #expect(UpdateController.releasesURL.absoluteString == "https://github.com/MrAshRhodes/glint/releases/latest")
        #expect(UpdateController.guideURL.absoluteString == "https://mrashrhodes.github.io/glint/guide.html#updates")
    }

    @Test func shippingInfoPlistKeepsEveryAutomaticBehaviorOff() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == false)
        #expect(plist["SUAutomaticallyUpdate"] as? Bool == false)
        #expect(plist["SUAllowsAutomaticUpdates"] as? Bool == false)
        #expect(plist["SUEnableSystemProfiling"] as? Bool == false)
        #expect(plist["SURequireSignedFeed"] as? Bool == true)
        #expect(plist["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(plist["SUFeedURL"] as? String == "https://github.com/MrAshRhodes/glint/releases/latest/download/appcast.xml")
        // Release builds inject the key (Scripts/build_app.sh); the source template must never carry one.
        #expect(plist["SUPublicEDKey"] == nil)
    }
}

/// Collects notices instead of showing an alert, so no test ever runs a modal.
@MainActor
private final class NoticeLog {
    private(set) var items: [UpdateController.Notice] = []
    func append(_ notice: UpdateController.Notice) { items.append(notice) }
}

@MainActor
private final class FakeUpdateEngine: UpdateEngine {
    var events: [String] = []
    var automaticallyChecksForUpdates = false {
        didSet { events.append("automatic:\(automaticallyChecksForUpdates)") }
    }
    var updateCheckInterval: TimeInterval = 86_400 {
        didSet { events.append("interval") }
    }
    var canCheckForUpdates = true
    var lastUpdateCheckDate: Date?
    var onChange: (() -> Void)?
    var startError: Error?

    func start() throws {
        events.append("start")
        if let startError { throw startError }
    }

    func checkForUpdates() {
        events.append("check")
        canCheckForUpdates = false
        onChange?()
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
