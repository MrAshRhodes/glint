import GlintCore
import SwiftUI

/// Track, review and resolve the selected redaction. Tracking is an aid: the user still checks every frame.
struct RedactionTrackingControls: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var recording: RecordingEditorModel
    @ObservedObject var playback: RecordingPlayback
    @ObservedObject var actions: EditorActions
    @ObservedObject var tracking: RedactionTrackingModel

    private var selected: Annotation? {
        guard editor.selection.count == 1 else { return nil }
        return editor.selectedAnnotations.first.flatMap { $0.redactionRect == nil ? nil : $0 }
    }

    private var currentInterval: UnresolvedRedactionInterval? {
        guard let selected else { return nil }
        return recording.unresolvedRedactionIntervals.first {
            $0.annotationID == selected.id && $0.contains(playback.currentTime)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if tracking.isTracking {
                ProgressView(value: tracking.progress)
                    .frame(maxWidth: 160)
                    .accessibilityLabel("Redaction tracking progress")
                    .accessibilityValue("\(Int((tracking.progress * 100).rounded())) percent")
                Text("Tracking… \(Int((tracking.progress * 100).rounded()))%")
                    .monospacedDigit()
                    .fixedSize()
                Button("Cancel") { tracking.cancel() }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancel redaction tracking")
                    .help("Stop tracking; the redaction keeps its previous position")
                Spacer(minLength: 0)
            } else if let selected {
                controls(for: selected)
            } else {
                Text("Select a solid or pixelated redaction to track it as content moves.")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .font(.caption)
        .task { await tracking.loadFrameTimes() }
    }

    @ViewBuilder
    private func controls(for annotation: Annotation) -> some View {
        Button(annotation.track == nil ? "Track" : "Re-track") { track(annotation) }
            .buttonStyle(.borderless)
            .disabled(!annotation.isTrackable)
            .accessibilityLabel(annotation.track == nil ? "Track redaction" : "Track redaction again")
            .help(annotation.isTrackable
                  ? "Follow the content under this redaction from the current frame, on this Mac. "
                    + "Uncertain frames are flagged for review."
                  : "Blur can't be tracked because it doesn't hide content reliably. Use Solid or Pixelate.")
        frameButtons
        if annotation.track != nil {
            Button("Next flagged") { nextFlagged() }
                .buttonStyle(.borderless)
                .disabled(recording.unresolvedRedactionIntervals.isEmpty)
                .accessibilityLabel("Go to the next interval that needs review")
                .help("Jump to the next tracked-redaction interval that needs review (Shift+N)")
            if let interval = currentInterval {
                Button("Accept fixed cover") {
                    resolve(annotation, interval: interval, as: .fixedCover)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Accept a fixed cover for this interval")
                .help("Cover this interval with the large fail-safe rect, after you've checked it hides everything")
                Button("Resolve with keyframes") {
                    resolve(annotation, interval: interval, as: .keyframes)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Resolve this interval with your keyframes")
                .help("Move the redaction on frames in this interval to add keyframes, then resolve it")
            } else if let resolved = annotation.track?.interval(containing: playback.currentTime), resolved.isResolved {
                Button("Review again") {
                    editor.reopenTrackedInterval(annotation.id, at: playback.currentTime)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Mark this interval as needing review again")
                .help("Undo the resolution of this interval so export waits for it again")
            }
            Spacer(minLength: 0)
            Button("Remove tracking") {
                actions.commitEditing()
                editor.removeTracking(annotation.id)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove tracking from this redaction")
            .help("Keep the redaction fixed where it is shown now")
        } else {
            Spacer(minLength: 0)
            Text("You remain responsible for checking every frame.")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
        }
    }

    private var frameButtons: some View {
        HStack(spacing: 2) {
            Button { step(forward: false) } label: {
                Image(systemName: "chevron.left").frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .accessibilityLabel("Previous frame")
            .help("Show the previous frame (Left Arrow)")
            Button { step(forward: true) } label: {
                Image(systemName: "chevron.right").frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .accessibilityLabel("Next frame")
            .help("Show the next frame (Right Arrow)")
        }
        .buttonStyle(.borderless)
    }

    private func track(_ annotation: Annotation) {
        actions.commitEditing()
        playback.pause()
        tracking.track(annotation.id, editor: editor, sourceDuration: recording.trim.sourceDuration)
    }

    private func step(forward: Bool) {
        actions.commitEditing()
        playback.pause()
        let now = playback.currentTime
        let target = forward ? tracking.nextFrame(after: now) : tracking.previousFrame(before: now)
        playback.seek(to: target ?? (now + (forward ? 1 : -1) / 30))
    }

    private func nextFlagged() {
        actions.commitEditing()
        playback.pause()
        guard let interval = RedactionTrackingModel.nextFlagged(after: playback.currentTime,
                                                               in: recording.unresolvedRedactionIntervals) else { return }
        editor.selection = [interval.annotationID]
        playback.seek(to: interval.start)
    }

    private func resolve(_ annotation: Annotation, interval: UnresolvedRedactionInterval,
                         as resolution: RedactionUncertainInterval.Resolution) {
        actions.commitEditing()
        let done = editor.resolveTrackedInterval(annotation.id, at: playback.currentTime, as: resolution,
                                                 sourceDuration: recording.trim.sourceDuration)
        if !done, resolution == .keyframes {
            editor.statusMessage = "Move the redaction on at least one frame inside this interval first."
        }
    }
}
