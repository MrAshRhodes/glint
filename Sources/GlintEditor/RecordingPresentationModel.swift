import Combine
import Foundation
import GlintCore

/// The presentation effects of one recording: click highlights, cursor emphasis and zoom segments.
///
/// Times are seconds in the original recording, like annotation ranges, so trimming never moves an effect.
/// Every change is undoable through the editor's undo manager; a drag is one undo step.
@MainActor
final class RecordingPresentationModel: ObservableObject {
    static let defaultZoomDuration: TimeInterval = 2
    static let minimumZoomDuration = ZoomSegment.minimumDuration

    let capture: PresentationCapture?
    let frameSize: CGSize
    @Published private(set) var settings = PresentationSettings()
    @Published var selectedZoomID: UUID? {
        didSet { if selectedZoomID == nil { editingArea = false } }
    }
    /// While the area of the selected zoom is edited, the preview shows the whole frame.
    @Published var editingArea = false {
        didSet { if editingArea, selectedZoom == nil { editingArea = false } }
    }
    weak var undoManager: UndoManager?
    private var interactionStart: PresentationSettings?

    init(capture: PresentationCapture?, frameSize: CGSize) {
        self.capture = capture
        self.frameSize = frameSize
    }

    var presentation: Presentation { Presentation(capture: capture, settings: settings) }
    var hasPointerData: Bool { !(capture?.pointer.isEmpty ?? true) }
    var hasClicks: Bool { !(capture?.clicks.isEmpty ?? true) }
    /// Enlarging or hiding needs a pointer that is not already part of the footage.
    var pointerIsEditable: Bool { hasPointerData && capture?.pointerIsBaked == false }
    var selectedZoom: ZoomSegment? { settings.zooms.first { $0.id == selectedZoomID } }
    var clicks: [ClickEvent] { capture?.clicks ?? [] }

    // MARK: Editing

    /// Applies `change` as one undoable step, or, during an interaction, as part of the interaction's step.
    func update(_ actionName: String, _ change: (inout PresentationSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let previous = settings
        settings = next
        if interactionStart == nil { registerUndo(from: previous, actionName: actionName) }
    }

    func beginInteraction() {
        if interactionStart == nil { interactionStart = settings }
    }

    func endInteraction(actionName: String) {
        guard let start = interactionStart else { return }
        interactionStart = nil
        if start != settings { registerUndo(from: start, actionName: actionName) }
    }

    private func registerUndo(from previous: PresentationSettings, actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            let current = model.settings
            model.settings = previous
            if model.selectedZoom == nil { model.selectedZoomID = nil }
            model.registerUndo(from: current, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    // MARK: Zoom segments

    /// A two-second zoom on the middle of the frame starting at `time`, kept inside the recording.
    @discardableResult
    func addZoom(at time: TimeInterval, sourceDuration: TimeInterval) -> UUID? {
        guard sourceDuration > Self.minimumZoomDuration, frameSize.width > 0, frameSize.height > 0 else { return nil }
        let duration = min(Self.defaultZoomDuration, sourceDuration)
        let start = min(max(time.isFinite ? time : 0, 0), sourceDuration - duration)
        let rect = CGRect(x: frameSize.width / 4, y: frameSize.height / 4,
                          width: frameSize.width / 2, height: frameSize.height / 2)
        let zoom = ZoomSegment(start: start, end: start + duration, rect: rect)
        update("Add Zoom") { $0.zooms.append(zoom) }
        selectedZoomID = zoom.id
        return zoom.id
    }

    func deleteZoom(_ id: UUID) {
        update("Delete Zoom") { $0.zooms.removeAll { $0.id == id } }
        if selectedZoomID == id { selectedZoomID = nil }
    }

    func setZoomBoundary(_ time: TimeInterval, isStart: Bool, id: UUID, sourceDuration: TimeInterval) {
        guard time.isFinite, sourceDuration > 0 else { return }
        update("Change Zoom Timing") { settings in
            guard let index = settings.zooms.firstIndex(where: { $0.id == id }) else { return }
            var zoom = settings.zooms[index]
            let minimum = min(Self.minimumZoomDuration, sourceDuration)
            if isStart {
                zoom.start = min(max(time, 0), zoom.end - minimum)
            } else {
                zoom.end = max(min(time, sourceDuration), zoom.start + minimum)
            }
            settings.zooms[index] = zoom
        }
    }

    /// Moves a segment to start at `time`, keeping its duration and staying inside the recording.
    func moveZoom(to time: TimeInterval, id: UUID, sourceDuration: TimeInterval) {
        guard time.isFinite, sourceDuration > 0 else { return }
        update("Move Zoom") { settings in
            guard let index = settings.zooms.firstIndex(where: { $0.id == id }) else { return }
            var zoom = settings.zooms[index]
            let duration = min(zoom.end - zoom.start, sourceDuration)
            zoom.start = min(max(time, 0), sourceDuration - duration)
            zoom.end = zoom.start + duration
            settings.zooms[index] = zoom
        }
    }

    /// The requested area in source pixels; it is clamped to the frame.
    func setZoomRect(_ rect: CGRect, id: UUID) {
        let frame = CGRect(origin: .zero, size: frameSize)
        let clamped = rect.standardized.intersection(frame)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return }
        update("Change Zoom Area") { settings in
            guard let index = settings.zooms.firstIndex(where: { $0.id == id }) else { return }
            settings.zooms[index].rect = clamped
        }
    }

    // MARK: Clicks and cursor

    func setClicksEnabled(_ enabled: Bool) { update("Click Highlights") { $0.clicks.enabled = enabled } }

    func removeClick(_ id: UUID) { update("Remove Click") { $0.clicks.removed.insert(id) } }

    func restoreClicks() { update("Restore Clicks") { $0.clicks.removed.removeAll() } }

    func setClickStyle(_ change: @escaping (inout ClickHighlightStyle) -> Void) {
        update("Click Highlight Style") { change(&$0.clicks) }
    }

    func setCursor(_ change: @escaping (inout CursorEmphasis) -> Void) {
        update("Cursor Emphasis") { change(&$0.cursor) }
    }

    /// The nearest kept click within `tolerance` seconds of `time`, for removing the click under the playhead.
    func click(near time: TimeInterval, tolerance: TimeInterval = 0.3) -> ClickEvent? {
        clicks.filter { !settings.clicks.removed.contains($0.id) && abs($0.time - time) <= tolerance }
            .min { abs($0.time - time) < abs($1.time - time) }
    }
}
