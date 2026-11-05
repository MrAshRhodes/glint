import AppKit
import Foundation
import GlintCapture
import GlintCore
import GlintEditor

/// The slice of `ScreenRecordingSession` the app shell drives; a protocol so tests never record the screen.
@MainActor
protocol RecordingSessioning: AnyObject {
    var onPhaseChanged: ((RecordingPhase) -> Void)? { get set }
    /// Why the recording ended; nil until it has.
    var stopReason: RecordingStopReason? { get }
    func run() async throws -> RecordedVideo
    func stop()
    func cancel()
}

extension ScreenRecordingSession: RecordingSessioning {}

/// Menu/hotkey entry point for screen recording: select a region, record, then open the recording editor.
@MainActor
final class RecordingCoordinator {
    struct Services {
        var makeSession: @MainActor (_ snapToEdges: Bool) -> any RecordingSessioning = {
            ScreenRecordingSession(snapToEdges: $0, showsCursor: true)
        }
        /// Opens the editor for a finished recording. The returned object is kept alive until `onClose` fires.
        var presentEditor: @MainActor (RecordedVideo, @escaping @MainActor () -> Void) -> AnyObject = { video, onClose in
            Services.openEditor(video, preferences: AppPreferences(), presetStore: PresetStore(), onClose: onClose)
        }
        var notify: @MainActor (String, String) -> Void = { Notifier.post(title: $0, body: $1) }
        var showPermissions: @MainActor () -> Void = { PermissionsWindow.shared.show() }
        var beep: @MainActor () -> Void = { NSSound.beep() }

        @MainActor
        static func openEditor(_ video: RecordedVideo, preferences: AppPreferences, presetStore: PresetStore,
                               onClose: @escaping @MainActor () -> Void) -> AnyObject {
            let controller = RecordingEditorWindowController(recording: video, preferences: preferences,
                                                             presetStore: presetStore)
            controller.onClose = { MainActor.assumeIsolated { onClose() } }
            NSApp.activate(ignoringOtherApps: true)
            controller.showEditor()
            return controller
        }
    }

    private let services: Services
    private let snapToEdges: () -> Bool
    private let isCaptureBusy: () -> Bool
    private var session: (any RecordingSessioning)?
    private var editors: [ObjectIdentifier: AnyObject] = [:]
    private(set) var phase: RecordingPhase = .idle

    /// Mirrors the phase into the menu bar title (nil clears it).
    var onStatusTitle: ((String?) -> Void)?

    init(services: Services = Services(), snapToEdges: @escaping () -> Bool, isCaptureBusy: @escaping () -> Bool) {
        self.services = services
        self.snapToEdges = snapToEdges
        self.isCaptureBusy = isCaptureBusy
    }

    /// True from the moment a recording is requested until its editor opens or it is cancelled.
    var isActive: Bool { session != nil }

    /// True once frames may already be written, so quitting would lose footage.
    var isCapturing: Bool {
        switch phase {
        case .recording, .finishing: return true
        case .idle, .selecting, .ready, .countdown: return false
        }
    }

    var openEditorCount: Int { editors.count }

    static var timeLimitMessage: String {
        let minutes = Int(ScreenRecordingSession.maximumDuration / 60)
        return "Recording stopped at the \(minutes)-minute limit. Your clip is open in the editor."
    }

    static func statusTitle(for phase: RecordingPhase) -> String? {
        switch phase {
        case .idle, .selecting, .ready: return nil
        case .countdown(let remaining): return remaining > 0 ? " \(remaining)" : nil
        case .recording: return " ● REC"
        case .finishing: return " …"
        }
    }

    /// Hotkey and menu behaviour: start when idle, otherwise stop (while recording) or cancel (before recording).
    func toggle() {
        if let session {
            switch phase {
            case .recording: session.stop()
            case .finishing: break
            case .idle, .selecting, .ready, .countdown: session.cancel()
            }
        } else {
            start()
        }
    }

    func start() {
        guard session == nil else { return }
        guard !isCaptureBusy() else {
            services.beep()
            return
        }
        let session = services.makeSession(snapToEdges())
        self.session = session
        session.onPhaseChanged = { [weak self] phase in self?.apply(phase) }
        Task { @MainActor in
            do {
                let video = try await session.run()
                let reason = session.stopReason
                finish(session)
                if reason == .timeLimit {
                    services.notify("Recording stopped", Self.timeLimitMessage)
                }
                present(video)
            } catch CaptureError.cancelled {
                finish(session)
            } catch CaptureError.permissionDenied {
                finish(session)
                services.showPermissions()
            } catch {
                finish(session)
                services.notify("Recording failed", error.localizedDescription)
            }
        }
    }

    /// Discards the current recording, if any (used when the app quits).
    func cancel() { session?.cancel() }

    private func apply(_ phase: RecordingPhase) {
        guard session != nil else { return }
        self.phase = phase
        onStatusTitle?(Self.statusTitle(for: phase))
    }

    private func finish(_ finished: any RecordingSessioning) {
        guard session === finished else { return }
        finished.onPhaseChanged = nil
        session = nil
        phase = .idle
        onStatusTitle?(nil)
    }

    private func present(_ video: RecordedVideo) {
        var token: AnyObject?
        var closed = false
        token = services.presentEditor(video) { [weak self] in
            closed = true
            guard let self, let token else { return }
            self.editors[ObjectIdentifier(token)] = nil
        }
        if let token, !closed { editors[ObjectIdentifier(token)] = token }
    }
}

extension RecordingCoordinator.Services {
    /// Opens recordings in an editor that shares the app's preferences and presets, like the screenshot editor.
    init(preferences: AppPreferences, presetStore: PresetStore) {
        self.init()
        presentEditor = { video, onClose in
            Self.openEditor(video, preferences: preferences, presetStore: presetStore, onClose: onClose)
        }
    }
}
