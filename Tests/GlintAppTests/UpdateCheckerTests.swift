import AppKit
import Testing
@testable import Glint

@Suite("Manual update guidance")
@MainActor
struct UpdateCheckerTests {
    @Test func updateAlertExplainsBothInstallMethods() {
        _ = NSApplication.shared
        let alert = UpdateChecker.availableAlert(tag: "v1.0.1", current: "1.0.0")
        #expect(alert.messageText == "Glint 1.0.1 is available")
        #expect(alert.informativeText.contains("version 1.0.0"))
        #expect(alert.informativeText.contains("nothing will be installed automatically"))
        #expect(alert.informativeText.contains("quit Glint"))
        #expect(alert.informativeText.contains(UpdateChecker.homebrewCommand))
        #expect(alert.informativeText.contains("alone does not upgrade"))
        #expect(alert.informativeText.contains("replace Glint.app"))
        #expect(alert.informativeText.contains("If captures stop working after updating"))
        #expect(alert.informativeText.contains("About → Permissions"))
        #expect(alert.informativeText.contains("click “Re-authorize Screen Recording…”"))
        #expect(alert.buttons.map(\.title) == ["Copy Homebrew Command", "Open Release Page…", "Later"])
    }

    @Test func copiesAnUpgradeNotJustATapRefresh() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(UpdateChecker.copyHomebrewCommand(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "brew update && brew upgrade --cask glint")
    }

    @Test func comparesStableReleaseVersions() {
        #expect(UpdateChecker.isNewer("v1.0.1", than: "1.0.0"))
        #expect(UpdateChecker.isNewer("v1.10.0", than: "1.9.0"))
        #expect(!UpdateChecker.isNewer("v1.0.1", than: "1.0.1"))
        #expect(!UpdateChecker.isNewer("v1.0.0", than: "1.0.1"))
        #expect(!UpdateChecker.isNewer("v1.0", than: "1.0.0"))
    }

    @Test func updateLinksStayOnProjectDestinations() {
        #expect(UpdateChecker.releasesURL.absoluteString == "https://github.com/MrAshRhodes/glint/releases/latest")
        #expect(UpdateChecker.guideURL.absoluteString == "https://mrashrhodes.github.io/glint/guide.html#updates")
    }
}
