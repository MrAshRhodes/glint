import AppKit
import GlintCore
import UserNotifications

/// What macOS currently lets Glint do with notifications.
enum NotificationAccess: Equatable {
    case allowed
    case blocked
    case undecided
}

/// Whether a notification can be posted. The status is read each time, so a change in System Settings is honoured on
/// the next post, and macOS is asked for authorisation only while the user has not been asked yet.
struct NotificationPermission {
    var access: () async -> NotificationAccess
    var request: () async -> Bool

    func isGranted() async -> Bool {
        switch await access() {
        case .allowed: return true
        case .blocked: return false
        case .undecided: return await request()
        }
    }

    static let system = NotificationPermission(
        access: {
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .notDetermined: return .undecided
            case .denied: return .blocked
            default: return .allowed
            }
        },
        request: {
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
        }
    )
}

/// Reports a failure so it cannot go unnoticed: a notification when one will be shown, otherwise a beep and an alert.
/// macOS does not show banners for the active app, so a failure while Glint is frontmost gets the alert too.
@MainActor
struct FailureFeedback {
    var notificationsEnabled: () -> Bool
    var isAppActive: () -> Bool
    var permission: NotificationPermission
    var notify: (String, String, URL?) -> Void
    var beep: () -> Void
    var alert: (String, String) -> Void

    /// A banner is only shown while notifications are on and another app is in front.
    private var bannerWouldShow: Bool { notificationsEnabled() && !isAppActive() }

    func report(title: String, message: String, fileURL: URL? = nil) async {
        // Checked again after the wait: authorisation can take a while, and Glint may have come to the front meanwhile.
        if bannerWouldShow, await permission.isGranted(), bannerWouldShow {
            notify(title, message, fileURL)
        } else {
            beep()
            alert(title, message)
        }
    }

    static let system = FailureFeedback(
        notificationsEnabled: { AppPreferences.shared.notificationsEnabled },
        isAppActive: { NSApp.isActive },
        permission: .system,
        notify: { Notifier.add(title: $0, body: $1, fileURL: $2) },
        beep: { NSSound.beep() },
        alert: { title, message in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    )
}
