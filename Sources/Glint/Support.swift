import AppKit
import Foundation
import GlintCore
import UserNotifications

enum AppInfo {
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
    }
}

/// Extra, shell-only preference keys (the typed ones live in `AppPreferences`).
enum ShellKey {
    static let showMenuBarIcon = "glint.showMenuBarIcon"
    static let timerSeconds = "glint.timerSeconds"
    static let hideCursor = "glint.hideCursor"
    static let rememberArea = "glint.rememberArea"
    static let quickAccess = "glint.quickAccess"
    static let onboarded = "glint.onboarded"
    static let recentFiles = "glint.recentFiles"
}

extension Notification.Name {
    static let glintPreferencesChanged = Notification.Name("glint.preferencesChanged")
}

/// Posts user notifications; silently does nothing when the process is not a proper app bundle.
@MainActor
enum Notifier {
    private static var usable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func post(title: String, body: String, fileURL: URL? = nil) {
        guard AppPreferences.shared.notificationsEnabled, usable else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let fileURL { content.userInfo = ["file": fileURL.path] }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    static func playSound() {
        guard AppPreferences.shared.soundsEnabled else { return }
        (NSSound(named: "Grab") ?? NSSound(named: "Pop"))?.play()
    }
}

/// Manual GitHub release checks. Installation stays with Homebrew or the user's download.
@MainActor
enum UpdateChecker {
    static let homebrewCommand = "brew update && brew upgrade --cask glint"
    static let guideURL = URL(string: "https://mrashrhodes.github.io/glint/guide.html#updates")!
    static let releasesURL = GlintInfo.repositoryURL.appendingPathComponent("releases/latest")
    private static var isChecking = false

    static func check(silent: Bool = false) {
        guard !isChecking else { return }
        isChecking = true
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/MrAshRhodes/glint/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        Task { @MainActor in
            defer { isChecking = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    if !silent {
                        alert("Update check failed",
                              "GitHub could not provide release information. Check your connection or try again later. No changes were made to Glint.")
                    }
                    return
                }
                let release = try JSONDecoder().decode(Release.self, from: data)
                let tag = release.tag_name
                if isNewer(tag, than: AppInfo.version) {
                    let a = availableAlert(tag: tag, current: AppInfo.version)
                    NSApp.activate(ignoringOtherApps: true)
                    switch a.runModal() {
                    case .alertFirstButtonReturn:
                        if copyHomebrewCommand() {
                            alert("Homebrew command copied",
                                  "Save your edits and quit Glint, then paste this command into Terminal:\n\n\(homebrewCommand)\n\nReopen Glint when it finishes. Nothing has been installed yet.")
                        } else {
                            alert("Could not copy the command", "Run this in Terminal after quitting Glint:\n\n\(homebrewCommand)")
                        }
                    case .alertSecondButtonReturn:
                        if !NSWorkspace.shared.open(releasesURL) {
                            alert("Could not open the release page", "Open \(releasesURL.absoluteString) in your browser.")
                        }
                    default: break
                    }
                } else if !silent {
                    alert("You're up to date",
                          "Glint \(AppInfo.version) is up to date with the latest stable GitHub release.\n\nUpdates are manual. Glint checks only when you ask and does not download or install updates in the background.")
                }
            } catch {
                if !silent { alert("Update check failed", error.localizedDescription) }
            }
        }
    }

    private struct Release: Decodable {
        let tag_name: String
    }

    static func availableAlert(tag: String, current: String) -> NSAlert {
        let a = NSAlert()
        a.messageText = "Glint \(tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))) is available"
        a.informativeText = """
        You are running version \(current). Updates are manual; nothing will be installed automatically.

        Homebrew install: save your edits, quit Glint, then run:
        \(homebrewCommand)
        Reopen Glint afterward. “brew update” alone does not upgrade the app. The tap may briefly lag a new release.

        Direct download: quit Glint, download the new ZIP or DMG, replace Glint.app in Applications, then reopen it.

        Your preferences, presets and saved images stay in place. macOS may ask for Screen Recording permission again after an update.
        """
        a.addButton(withTitle: "Copy Homebrew Command")
        a.addButton(withTitle: "Open Release Page…")
        a.addButton(withTitle: "Later")
        return a
    }

    static func copyHomebrewCommand(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(homebrewCommand, forType: .string)
    }

    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
