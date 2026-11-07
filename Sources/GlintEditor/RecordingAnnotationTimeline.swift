import GlintCore
import SwiftUI

struct RecordingAnnotationTimeline: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var recording: RecordingEditorModel
    @ObservedObject var playback: RecordingPlayback
    @ObservedObject var actions: EditorActions
    @ObservedObject var tracking: RedactionTrackingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Annotation ranges · source seconds")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(editor.annotations.sorted { $0.z < $1.z }) { annotation in
                        RecordingAnnotationLane(editor: editor, recording: recording, playback: playback,
                                                actions: actions, annotation: annotation,
                                                unresolved: recording.unresolvedRedactionIntervals.filter {
                                                    $0.annotationID == annotation.id
                                                })
                    }
                }
            }
            .frame(height: 82)
            .overlay {
                if editor.annotations.isEmpty {
                    Text("Add an annotation to choose when it appears.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            timingControls.frame(height: 32)
            RedactionTrackingControls(editor: editor, recording: recording, playback: playback,
                                      actions: actions, tracking: tracking)
                .frame(height: 30)
        }
        .disabled(recording.isExporting || recording.trim.sourceDuration <= 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Annotation timeline")
    }

    @ViewBuilder
    private var timingControls: some View {
        if editor.selectedAnnotations.count == 1, let annotation = editor.selectedAnnotations.first {
            HStack(spacing: 6) {
                boundaryField(annotation, isStart: true)
                boundaryField(annotation, isStart: false)
                Spacer(minLength: 0)
                Button("Whole clip") {
                    actions.commitEditing()
                    editor.showAnnotationsThroughout([annotation.id])
                }
                .buttonStyle(.borderless)
                .disabled(annotation.visibleRange == nil)
                .accessibilityLabel("Show selected annotation throughout the clip")
                .help("Remove the time limit, including any parts restored by trimming")
            }
            .font(.caption.monospacedDigit())
        } else {
            Text("Select one annotation to edit its range. Shift+I / Shift+O use the playhead.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func boundaryField(_ annotation: Annotation, isStart: Bool) -> some View {
        let value = Binding<Double>(
            get: {
                let current = editor.annotations.first { $0.id == annotation.id }?.visibleRange
                return isStart ? (current?.start ?? 0) : (current?.end ?? recording.trim.sourceDuration)
            },
            set: { setBoundary($0, annotation: annotation, isStart: isStart) }
        )
        return HStack(spacing: 4) {
            Text(isStart ? "From" : "To").foregroundStyle(.secondary)
            TextField(isStart ? "Annotation start in seconds" : "Annotation end in seconds",
                      value: value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .accessibilityLabel(isStart ? "Annotation start in seconds" : "Annotation end in seconds")
                .help("Time in the original recording; the end is exclusive")
            Button {
                setBoundary(playback.currentTime, annotation: annotation, isStart: isStart)
            } label: {
                Image(systemName: isStart ? "arrow.right.to.line" : "arrow.left.to.line")
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isStart ? "Start at playhead" : "End at playhead")
            .help(isStart ? "Start at playhead (Shift+I)" : "End at playhead (Shift+O)")
        }
    }

    private func setBoundary(_ time: TimeInterval, annotation: Annotation, isStart: Bool) {
        actions.commitEditing()
        playback.pause()
        editor.setAnnotationBoundary(time, isStart: isStart, ids: [annotation.id],
                                     sourceDuration: recording.trim.sourceDuration)
    }
}

private struct RecordingAnnotationLane: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var recording: RecordingEditorModel
    @ObservedObject var playback: RecordingPlayback
    @ObservedObject var actions: EditorActions
    let annotation: Annotation
    let unresolved: [UnresolvedRedactionInterval]
    @StateObject private var drag = TimelineDragState()

    private var start: TimeInterval { annotation.visibleRange?.start ?? 0 }
    private var end: TimeInterval { annotation.visibleRange?.end ?? recording.trim.sourceDuration }
    private var selected: Bool { editor.selection.contains(annotation.id) }
    private var outsideTrim: Bool { end <= recording.trim.start || start >= recording.trim.end }
    private var space: String { "annotation-timing-\(annotation.id)" }

    var body: some View {
        HStack(spacing: RecordingTimelineMetrics.spacing) {
            Button(action: select) {
                Image(systemName: annotation.timingSymbol)
                    .frame(width: RecordingTimelineMetrics.controlWidth, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .accessibilityLabel("Select \(annotation.timingLabel)")
            .accessibilityValue(outsideTrim ? "Outside trim" : (selected ? "Selected" : "Not selected"))
            .help(outsideTrim ? "\(annotation.timingLabel): outside the trimmed clip" : annotation.timingLabel)
            GeometryReader { geometry in
                // Hit targets sit outside the range, so even a one-frame range has two distinct handles.
                let layout = TimelineLayout(width: geometry.size.width, handleWidth: RecordingTimelineMetrics.handleWidth,
                                            duration: recording.trim.sourceDuration)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(GlintDesign.cardFill)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                        .onTapGesture { select() }
                    Rectangle().fill(Color.primary.opacity(0.08))
                        .frame(width: layout.x(at: recording.trim.start), height: 26)
                        .allowsHitTesting(false)
                    Rectangle().fill(Color.primary.opacity(0.08))
                        .frame(width: max(geometry.size.width - layout.x(at: recording.trim.end), 0), height: 26)
                        .placed(atX: layout.x(at: recording.trim.end))
                        .allowsHitTesting(false)
                    rangeBar(layout)
                    if let track = annotation.track { trackMarks(track, layout: layout) }
                    Rectangle().fill(Color.primary)
                        .frame(width: 1, height: 30)
                        .placed(atX: layout.x(at: playback.currentTime))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    handle(isStart: true, layout: layout)
                    handle(isStart: false, layout: layout)
                }
                .coordinateSpace(name: space)
            }
            .frame(height: 40)
            Text(String(format: "%.2f - %.2f s", start, end))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: RecordingTimelineMetrics.timeWidth, alignment: .trailing)
                .help("\(annotation.timingLabel): \(String(format: "%.2f to %.2f seconds", start, end)) in the original recording")
                .accessibilityHidden(true)
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(annotation.timingLabel)
    }

    private func rangeBar(_ layout: TimelineLayout) -> some View {
        Text(annotation.timingLabel)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: max(layout.x(at: end) - layout.x(at: start), 1), height: 26, alignment: .leading)
            .background((outsideTrim ? Color.secondary : Color.accentColor).opacity(selected ? 0.45 : 0.22),
                        in: RoundedRectangle(cornerRadius: 3))
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .onChanged { value in
                    if drag.rangeStart == nil {
                        select()
                        editor.beginInteraction()
                        drag.rangeStart = start
                    }
                    move(to: (drag.rangeStart ?? start) + layout.timeOffset(for: value.translation.width), live: true)
                }
                .onEnded { _ in
                    drag.rangeStart = nil
                    editor.endInteraction(actionName: "Move Annotation Timing")
                })
            .focusable(!recording.isExporting)
            .onMoveCommand { direction in
                switch direction {
                case .left: move(to: start - 0.1)
                case .right: move(to: start + 0.1)
                default: break
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(annotation.timingLabel) range")
            .accessibilityValue(String(format: "%.2f to %.2f seconds", start, end))
            .accessibilityHint("Move this annotation's time range without changing its duration")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: move(to: start + 0.1)
                case .decrement: move(to: start - 0.1)
                @unknown default: break
                }
            }
            .help("Drag to move the range; drag its edges to change the duration")
            .placed(atX: layout.x(at: start))
    }

    /// Keyframe ticks, plus a button for every interval that still needs review.
    @ViewBuilder
    private func trackMarks(_ track: RedactionTrack, layout: TimelineLayout) -> some View {
        ForEach(Array(track.keyframes.enumerated()), id: \.offset) { _, keyframe in
            Rectangle()
                .fill(keyframe.source == .manual ? Color.primary : Color.accentColor)
                .frame(width: keyframe.source == .manual ? 2 : 1, height: keyframe.source == .manual ? 14 : 6)
                .placed(atX: layout.x(at: keyframe.time))
                .offset(y: 10)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        ForEach(unresolved, id: \.self) { interval in
            let label = "Needs review: \(String(format: "%.2f to %.2f seconds", interval.start, interval.end))"
            Button {
                actions.commitEditing()
                playback.pause()
                editor.selection = [annotation.id]
                playback.seek(to: interval.start)
            } label: {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.orange.opacity(0.75))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.orange, lineWidth: 1))
                    .frame(width: max(layout.x(at: interval.end) - layout.x(at: interval.start), 4), height: 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(!recording.isExporting)
            .placed(atX: layout.x(at: interval.start))
            .offset(y: -10)
            .accessibilityLabel(label)
            .accessibilityHint("Moves the playhead to the first frame that needs review")
            .help("\(label). Tracking was unsure here; a large cover hides it until you review it.")
        }
    }

    private func move(to time: TimeInterval, live: Bool = false) {
        if !live { select() }
        editor.moveAnnotationRange(to: time, id: annotation.id,
                                   sourceDuration: recording.trim.sourceDuration, live: live)
    }

    private func select() {
        actions.commitEditing()
        playback.pause()
        editor.selection = [annotation.id]
        let lower = max(start, recording.trim.start)
        let upper = min(end, recording.trim.end)
        if lower < upper, playback.currentTime < lower || playback.currentTime >= upper {
            playback.seek(to: lower)
        }
    }

    private func handle(isStart: Bool, layout: TimelineLayout) -> some View {
        let time = isStart ? start : end
        let label = "\(annotation.timingLabel) \(isStart ? "start" : "end")"
        let offset = layout.x(at: time) - (isStart ? RecordingTimelineMetrics.handleWidth : 0)
        return RoundedRectangle(cornerRadius: 3)
            .fill(selected ? Color.accentColor : Color.secondary)
            .frame(width: 7, height: 26)
            .frame(width: RecordingTimelineMetrics.handleWidth, height: 40, alignment: isStart ? .trailing : .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .onChanged { value in
                    if drag.grab(isStart: isStart) == nil {
                        actions.commitEditing()
                        playback.pause()
                        editor.selection = [annotation.id]
                        editor.beginInteraction()
                        drag.setGrab(value.startLocation.x - layout.x(at: time), isStart: isStart)
                    }
                    let grab = drag.grab(isStart: isStart) ?? 0
                    set(layout.time(at: value.location.x - grab), isStart: isStart, live: true)
                }
                .onEnded { _ in
                    drag.setGrab(nil, isStart: isStart)
                    editor.endInteraction(actionName: "Change Annotation Timing")
                })
            .focusable(!recording.isExporting)
            .onMoveCommand { direction in
                switch direction {
                case .left: set(time - 0.1, isStart: isStart)
                case .right: set(time + 0.1, isStart: isStart)
                default: break
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(String(format: "%.2f seconds", time))
            .accessibilityHint("Adjust when this annotation \(isStart ? "appears" : "disappears") in the original recording")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: set(time + 0.1, isStart: isStart)
                case .decrement: set(time - 0.1, isStart: isStart)
                @unknown default: break
                }
            }
            .help("\(label): drag, or use Left and Right when focused")
            .placed(atX: offset)
            .offset(x: min(offset, 0))
    }

    private func set(_ time: TimeInterval, isStart: Bool, live: Bool = false) {
        if !live {
            actions.commitEditing()
            playback.pause()
            editor.selection = [annotation.id]
        }
        editor.setAnnotationBoundary(time, isStart: isStart, ids: [annotation.id],
                                     sourceDuration: recording.trim.sourceDuration, live: live)
    }
}

extension Annotation {
    var timingSymbol: String {
        switch kind {
        case .arrow, .line: return EditorTool.arrow.symbol
        case .rectangle, .ellipse: return EditorTool.shape.symbol
        case .pen: return EditorTool.pen.symbol
        case .highlighter: return EditorTool.highlighter.symbol
        case .text: return EditorTool.text.symbol
        case .counter: return EditorTool.counter.symbol
        case .blur, .pixelate, .redact: return EditorTool.redact.symbol
        case .spotlight: return "flashlight.on.fill"
        case .emoji: return "face.smiling"
        case .magnify: return EditorTool.zoom.symbol
        }
    }

    var timingLabel: String {
        switch kind {
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .pen: return "Pen"
        case .highlighter: return "Highlight"
        case .text(_, let text, _): return text.isEmpty ? "Text" : "Text: \(text.prefix(24))"
        case .counter(_, let number): return "Step \(number)"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .redact: return "Redaction"
        case .spotlight: return "Spotlight"
        case .emoji: return "Emoji"
        case .magnify: return "Zoom"
        }
    }
}
