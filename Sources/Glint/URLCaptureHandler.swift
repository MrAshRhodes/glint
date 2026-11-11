import AppKit

@MainActor
final class URLCaptureHandler {
    enum Action: String, CaseIterable {
        case area = "capture-area"
        case window = "capture-window"
        case fullscreen = "capture-fullscreen"
        case text = "capture-text"
        case repeatLast = "repeat-last"

        var mode: CapturePipeline.Mode {
            switch self {
            case .area: return .area
            case .window: return .window
            case .fullscreen: return .fullscreen
            case .text: return .text
            case .repeatLast: return .repeatLast
            }
        }

        var title: String {
            switch self {
            case .area: return "Capture Area"
            case .window: return "Capture Window"
            case .fullscreen: return "Capture Fullscreen"
            case .text: return "Capture Text (OCR)"
            case .repeatLast: return "Repeat Last Area"
            }
        }
    }

    struct Services {
        var confirm: @MainActor (Action) -> NSApplication.ModalResponse = { presentConfirmation(for: $0) }
        var isCaptureBusy: @MainActor () -> Bool
        var startCapture: @MainActor (CapturePipeline.Mode) -> Void
        var reject: @MainActor () -> Void = { NSSound.beep() }
    }

    private let services: Services
    private var isConfirming = false

    init(services: Services) {
        self.services = services
    }

    /// A recognized capture action is handled even when the user declines or the request is rejected.
    func handle(action: String) -> Bool {
        guard let action = Action(rawValue: action) else { return false }
        guard !isConfirming, !services.isCaptureBusy() else {
            services.reject()
            return true
        }
        // runModal processes events, including further URL requests, before it returns.
        isConfirming = true
        defer { isConfirming = false }
        guard services.confirm(action) == .alertSecondButtonReturn else { return true }
        guard !services.isCaptureBusy() else {
            services.reject()
            return true
        }
        services.startCapture(action.mode)
        return true
    }

    static func confirmationAlert(for action: Action) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow \(action.title)?"
        alert.informativeText = """
        An external app or link asked Glint to capture your screen. Only allow this if you requested it.

        After you allow this capture, Glint uses your current capture settings and may save raw history or \
        output files, or copy an image to the clipboard. Capture Text copies recognized text to the clipboard.

        This allows one capture only. Every capture URL requires confirmation.
        """
        let cancel = alert.addButton(withTitle: "Cancel")
        let capture = alert.addButton(withTitle: "Allow Capture")
        cancel.keyEquivalent = "\r"
        capture.keyEquivalent = ""
        alert.showsSuppressionButton = false
        return alert
    }

    private static func presentConfirmation(for action: Action) -> NSApplication.ModalResponse {
        let alert = confirmationAlert(for: action)
        NSApp.activate(ignoringOtherApps: true)
        defer { alert.window.orderOut(nil) }
        return alert.runModal()
    }
}
