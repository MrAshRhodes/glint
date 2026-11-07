import CoreGraphics
import Foundation
import GlintCore

/// Tracked redactions in a recording: the canvas edits the tracked position at the current time, and every
/// edit there becomes a manual keyframe rather than moving the whole track.
extension EditorModel {
    /// The annotation as the canvas shows and edits it at the current recording time.
    func editingView(_ annotation: Annotation) -> Annotation {
        isRecording ? annotation.editingView(at: recordingTime) : annotation
    }

    var selectedEditingAnnotations: [Annotation] { selectedAnnotations.map(editingView) }

    /// Visible annotations positioned for hit testing at the current time.
    var hitTestAnnotations: [Annotation] { visibleAnnotations.map(editingView) }

    var selectionHasTrackedRedaction: Bool { selectedAnnotations.contains { $0.track != nil } }

    /// Turns canvas edits of tracked redactions into manual keyframes at the current time.
    func absorbingTrackedEdits(_ new: [Annotation]) -> [Annotation] {
        guard isRecording else { return new }
        let current = Dictionary(annotations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return new.map { Self.absorbTrackedEdit($0, current: current[$0.id], at: recordingTime) }
    }

    /// The canvas may hand back an annotation built from an older copy, such as the drag's starting state, so
    /// only its geometry is taken; the track always comes from `current`.
    nonisolated static func absorbTrackedEdit(_ incoming: Annotation, current: Annotation?,
                                              at time: TimeInterval) -> Annotation {
        guard let current, var track = current.track, incoming.track != nil, track.isValid,
              let edited = incoming.redactionRect, let stored = current.redactionRect,
              edited.width.isFinite, edited.height.isFinite, edited.minX.isFinite, edited.minY.isFinite,
              abs(edited.width) >= 1, abs(edited.height) >= 1 else { return incoming }
        var result = incoming
        if edited != stored, edited != current.editingView(at: time).redactionRect {
            track.setManualKeyframe(at: time, rect: edited.standardized)
        }
        result.track = track
        return result
    }

    // MARK: Track editing

    func applyTrack(_ track: RedactionTrack, to id: UUID, anchorTime: TimeInterval) {
        guard let annotation = annotations.first(where: { $0.id == id }), annotation.isTrackable else { return }
        var updated = annotation.withRedactionRect(track.editingRect(at: anchorTime))
        updated.track = track
        setAnnotations(annotations.map { $0.id == id ? updated : $0 },
                       actionName: annotation.track == nil ? "Track Redaction" : "Re-track Redaction")
    }

    /// Leaves the redaction fixed where it is shown now.
    func removeTracking(_ id: UUID) {
        guard let annotation = annotations.first(where: { $0.id == id }), annotation.track != nil else { return }
        var updated = editingView(annotation)
        updated.track = nil
        setAnnotations(annotations.map { $0.id == id ? updated : $0 }, actionName: "Remove Tracking")
    }

    /// Resolves the interval containing `time`. Keyframe resolution needs a manual keyframe inside the interval.
    @discardableResult
    func resolveTrackedInterval(_ id: UUID, at time: TimeInterval, as resolution: RedactionUncertainInterval.Resolution,
                                sourceDuration: TimeInterval) -> Bool {
        updateTrack(id, actionName: resolution == .fixedCover ? "Accept Fixed Cover" : "Resolve With Keyframes") {
            $0.resolveInterval(containing: time, as: resolution, visibleRange: $1, sourceDuration: sourceDuration)
        }
    }

    @discardableResult
    func reopenTrackedInterval(_ id: UUID, at time: TimeInterval) -> Bool {
        updateTrack(id, actionName: "Review Interval Again") { track, _ in track.reopenInterval(containing: time) }
    }

    @discardableResult
    func removeTrackedKeyframe(_ id: UUID, near time: TimeInterval) -> Bool {
        updateTrack(id, actionName: "Remove Keyframe") { track, _ in track.removeKeyframe(near: time) }
    }

    private func updateTrack(_ id: UUID, actionName: String,
                             _ change: (inout RedactionTrack, AnnotationTiming?) -> Bool) -> Bool {
        guard let annotation = annotations.first(where: { $0.id == id }), var track = annotation.track,
              change(&track, annotation.visibleRange) else { return false }
        var updated = annotation
        updated.track = track
        setAnnotations(annotations.map { $0.id == id ? updated : $0 }, actionName: actionName)
        return true
    }
}
