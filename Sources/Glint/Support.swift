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

/// GitHub-releases update check (no Sparkle).
@MainActor
enum UpdateChecker {
    static func check(silent: Bool = false) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/MrAshRhodes/glint/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        Task { @MainActor in
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    if !silent { alert("No releases found", "Could not read the latest release information.") }
                    return
                }
                let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? GlintInfo.repositoryURL
                if isNewer(tag, than: AppInfo.version) {
                    let a = NSAlert()
                    a.messageText = "Glint \(tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))) is available"
                    a.informativeText = "You are running version \(AppInfo.version)."
                    a.addButton(withTitle: "Download")
                    a.addButton(withTitle: "Later")
                    NSApp.activate(ignoringOtherApps: true)
                    if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
                } else if !silent {
                    alert("You're up to date", "Glint \(AppInfo.version) is the latest version.")
                }
            } catch {
                if !silent { alert("Update check failed", error.localizedDescription) }
            }
        }
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
