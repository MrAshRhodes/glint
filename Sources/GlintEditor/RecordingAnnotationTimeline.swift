import GlintCore
import SwiftUI

struct RecordingAnnotationTimeline: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var recording: RecordingEditorModel
    @ObservedObject var playback: RecordingPlayback
    @ObservedObject var actions: EditorActions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Annotation ranges · source seconds")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(editor.annotations.sorted { $0.z < $1.z }) { annotation in
                        RecordingAnnotationLane(editor: editor, recording: recording, playback: playback,
                                                actions: actions, annotation: annotation)
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
    @StateObject private var drag = TimelineDragState()

    private var start: TimeInterval { annotation.visibleRange?.start ?? 0 }
    private var end: TimeInterval { annotation.visibleRange?.end ?? recording.trim.sourceDuration }
    private var selected: Bool { editor.selection.contains(annotation.id) }
    private var outsideTrim: Bool { end <= recording.trim.start || start >= recording.trim.end }
    private var space: String { "annotation-timing-\(annotation.id)" }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                Text(annotation.timingLabel)
                    .lineLimit(1)
                    .frame(width: 110, height: 40, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .accessibilityLabel("Select \(annotation.timingLabel)")
            .accessibilityValue(outsideTrim ? "Outside trim" : (selected ? "Selected" : "Not selected"))
            .help(outsideTrim ? "\(annotation.timingLabel): outside the trimmed clip" : annotation.timingLabel)
            GeometryReader { geometry in
                // Hit targets sit outside the range, so even a one-frame range has two distinct handles.
                let layout = TimelineLayout(width: geometry.size.width, handleWidth: 80,
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
                    RoundedRectangle(cornerRadius: 3)
                        .fill((outsideTrim ? Color.secondary : Color.accentColor).opacity(selected ? 0.45 : 0.22))
                        .frame(width: max(layout.x(at: end) - layout.x(at: start), 1), height: 26)
                        .placed(atX: layout.x(at: start))
                        .allowsHitTesting(false)
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
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(annotation.timingLabel)
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
        let offset: CGFloat = isStart ? -40 : 0
        return RoundedRectangle(cornerRadius: 3)
            .fill(selected ? Color.accentColor : Color.secondary)
            .frame(width: 7, height: 26)
            .frame(width: 40, height: 40, alignment: isStart ? .trailing : .leading)
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
            .placed(atX: layout.x(at: time) + offset)
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
