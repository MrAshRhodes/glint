import AppKit
import GlintCore

/// A region picked for recording, in global CG coordinates on a single display.
struct RecordingRegion {
    let rect: CGRect
    let display: DisplayInfo
}

/// What the on-screen controls can ask of the session.
struct RecordingControlActions {
    var record: (RecordingCountdownChoice, CGRect) -> Void
    var stop: () -> Void
    var cancel: () -> Void
}

@MainActor
protocol RegionPicking: AnyObject {
    /// Throws `CaptureError.cancelled` when the user backs out or `cancel()` is called.
    func pick() async throws -> RecordingRegion
    func cancel()
}

/// The on-screen side of a recording: adjustable region frame, control bar, countdown and recording pill.
@MainActor
protocol RecordingPresenting: AnyObject {
    func showReady(region: RecordingRegion, actions: RecordingControlActions)
    /// Shows the number in the countdown phase; a `remaining` of 0 hides it.
    func showCountdown(_ remaining: Int)
    func showRecording(elapsed: TimeInterval)
    func updateElapsed(_ elapsed: TimeInterval)
    func dismiss()
}

/// The pieces a `ScreenRecordingSession` talks to. Tests replace them so the flow runs without a display,
/// without Screen Recording permission and without real time passing.
struct RecordingEnvironment {
    var requirePermission: @MainActor () throws -> Void
    var makePicker: @MainActor (_ snapToEdges: Bool) -> any RegionPicking
    var makePresenter: @MainActor () -> any RecordingPresenting
    var makeEngine: @MainActor (RecordingTarget) -> any RecordingEngine
    var makeOutputURL: @MainActor () -> URL
    var sleep: @Sendable (TimeInterval) async throws -> Void
    var now: @MainActor () -> TimeInterval
    var maximumDuration: TimeInterval
    /// Tracks the pointer while recording; nil records no presentation data.
    var makePointerSampler: @MainActor (RecordingGeometry) -> PointerSampler? = { _ in nil }

    @MainActor
    static var live: RecordingEnvironment {
        RecordingEnvironment(
            requirePermission: { try ScreenCapturer.requirePermission() },
            makePicker: { SelectionRegionPicker(snapToEdges: $0) },
            makePresenter: { RecordingOverlayPresenter() },
            makeEngine: { ScreenRecorder(target: $0) },
            makeOutputURL: {
                FileManager.default.temporaryDirectory.appendingPathComponent("Glint Recording \(UUID().uuidString).mp4")
            },
            sleep: { try await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1_000_000_000)) },
            now: { ProcessInfo.processInfo.systemUptime },
            maximumDuration: RecordingLimits.maximumDuration,
            makePointerSampler: { geometry in
                PointerSampler(geometry: geometry, source: LivePointerSource(),
                               now: { ProcessInfo.processInfo.systemUptime })
            })
    }
}

/// Region selection through the same overlay screenshots use. Space before a drag switches to picking a window,
/// which records that window's area; holding it during a drag moves the selection.
@MainActor
final class SelectionRegionPicker: RegionPicking {
    private let selection: SelectionSession

    init(snapToEdges: Bool) {
        selection = SelectionSession(mode: .area, lastArea: nil, snapToEdges: snapToEdges)
    }

    func pick() async throws -> RecordingRegion {
        let outcome = try await selection.run()
        let displays = WindowEnumerator.displays()
        switch outcome {
        case .area(let rect, let displayID):
            guard let display = displays.first(where: { $0.id == displayID }) else { throw CaptureError.noDisplay }
            return try Self.region(rect, on: display)
        case .window(let window):
            let midpoint = CGPoint(x: window.frame.midX, y: window.frame.midY)
            guard let index = CaptureGeometry.index(containing: midpoint, in: displays.map(\.frame)) else {
                throw CaptureError.noDisplay
            }
            return try Self.region(window.frame, on: displays[index])
        }
    }

    func cancel() { selection.cancel() }

    private static func region(_ rect: CGRect, on display: DisplayInfo) throws -> RecordingRegion {
        let clipped = rect.intersection(display.frame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { throw CaptureError.invalidRect }
        return RecordingRegion(rect: clipped, display: display)
    }
}
