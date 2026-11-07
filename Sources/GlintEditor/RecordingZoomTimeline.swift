import GlintCore
import SwiftUI

/// Zoom segments and recorded clicks on the source clock, below the annotation timeline.
struct RecordingZoomTimeline: View {
    @ObservedObject var presentation: RecordingPresentationModel
    @ObservedObject var recording: RecordingEditorModel
    @ObservedObject var playback: RecordingPlayback
    @ObservedObject var actions: EditorActions
    @StateObject private var drag = TimelineDragState()
    private let space = "zoom-timeline"

    private var duration: TimeInterval { recording.trim.sourceDuration }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Zoom · source seconds").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if presentation.hasClicks {
                    Text(clickSummary).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .font(.caption)
            lane.frame(height: 40)
            controls.frame(height: 28)
        }
        .disabled(recording.isExporting || duration <= 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zoom timeline")
    }

    private var clickSummary: String {
        let removed = presentation.settings.clicks.removed.count
        let kept = presentation.clicks.count - removed
        return removed > 0 ? "\(kept) clicks (\(removed) removed)" : "\(kept) clicks"
    }

    // MARK: Lane

    private var lane: some View {
        HStack(spacing: RecordingTimelineMetrics.spacing) {
            Button(action: addZoom) {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: RecordingTimelineMetrics.controlWidth, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add zoom at playhead")
            .help("Add a zoom at the playhead")
            GeometryReader { geometry in
                let layout = TimelineLayout(width: geometry.size.width, handleWidth: RecordingTimelineMetrics.handleWidth,
                                            duration: duration)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(GlintDesign.cardFill)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                        .onTapGesture { presentation.selectedZoomID = nil }
                    Rectangle().fill(Color.primary.opacity(0.08))
                        .frame(width: layout.x(at: recording.trim.start), height: 26)
                        .allowsHitTesting(false)
                    Rectangle().fill(Color.primary.opacity(0.08))
                        .frame(width: max(geometry.size.width - layout.x(at: recording.trim.end), 0), height: 26)
                        .placed(atX: layout.x(at: recording.trim.end))
                        .allowsHitTesting(false)
                    ForEach(presentation.settings.zooms) { zoom in
                        bar(zoom, layout: layout)
                    }
                    ForEach(presentation.clicks) { click in
                        clickMark(click, layout: layout)
                    }
                    Rectangle().fill(Color.primary)
                        .frame(width: 1, height: 30)
                        .placed(atX: layout.x(at: playback.currentTime))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    if let zoom = presentation.selectedZoom {
                        handle(zoom, isStart: true, layout: layout)
                        handle(zoom, isStart: false, layout: layout)
                    }
                }
                .coordinateSpace(name: space)
            }
            .frame(height: 40)
            Text(rangeText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: RecordingTimelineMetrics.timeWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .font(.caption)
    }

    private var rangeText: String {
        guard let zoom = presentation.selectedZoom else {
            let count = presentation.settings.zooms.count
            return count == 1 ? "1 zoom" : "\(count) zooms"
        }
        return String(format: "%.2f - %.2f s", zoom.start, zoom.end)
    }

    private func bar(_ zoom: ZoomSegment, layout: TimelineLayout) -> some View {
        let selected = zoom.id == presentation.selectedZoomID
        let outsideTrim = zoom.end <= recording.trim.start || zoom.start >= recording.trim.end
        return Text(String(format: "%.1f×", zoomFactor(zoom)))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(width: max(layout.x(at: zoom.end) - layout.x(at: zoom.start), 1), height: 26, alignment: .leading)
            .background((outsideTrim ? Color.secondary : Color.accentColor).opacity(selected ? 0.45 : 0.22),
                        in: RoundedRectangle(cornerRadius: 3))
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .onChanged { value in
                    if drag.rangeStart == nil {
                        select(zoom)
                        presentation.beginInteraction()
                        drag.rangeStart = zoom.start
                    }
                    presentation.moveZoom(to: (drag.rangeStart ?? zoom.start) + layout.timeOffset(for: value.translation.width),
                                          id: zoom.id, sourceDuration: duration)
                }
                .onEnded { _ in
                    drag.rangeStart = nil
                    presentation.endInteraction(actionName: "Move Zoom")
                })
            .focusable(!recording.isExporting)
            .onMoveCommand { direction in
                switch direction {
                case .left: presentation.moveZoom(to: zoom.start - 0.1, id: zoom.id, sourceDuration: duration)
                case .right: presentation.moveZoom(to: zoom.start + 0.1, id: zoom.id, sourceDuration: duration)
                default: break
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Zoom range")
            .accessibilityValue(String(format: "%.2f to %.2f seconds", zoom.start, zoom.end))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: presentation.moveZoom(to: zoom.start + 0.1, id: zoom.id, sourceDuration: duration)
                case .decrement: presentation.moveZoom(to: zoom.start - 0.1, id: zoom.id, sourceDuration: duration)
                @unknown default: break
                }
            }
            .help("Drag to move the zoom; select it to change its edges and area")
            .placed(atX: layout.x(at: zoom.start))
    }

    private func zoomFactor(_ zoom: ZoomSegment) -> CGFloat {
        let fitted = ZoomSegment.fitted(zoom.rect, in: presentation.frameSize)
        return fitted.width > 0 ? presentation.frameSize.width / fitted.width : 1
    }

    private func clickMark(_ click: ClickEvent, layout: TimelineLayout) -> some View {
        let removed = presentation.settings.clicks.removed.contains(click.id)
        return Circle()
            .strokeBorder(removed ? Color.secondary : Color.primary, lineWidth: 1)
            .background(Circle().fill(removed ? Color.clear : (click.button == .right ? Color.orange : Color.yellow)))
            .frame(width: 7, height: 7)
            .offset(y: 13)
            .placed(atX: layout.x(at: click.time) - 3.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func handle(_ zoom: ZoomSegment, isStart: Bool, layout: TimelineLayout) -> some View {
        let time = isStart ? zoom.start : zoom.end
        let label = "Zoom \(isStart ? "start" : "end")"
        let offset = layout.x(at: time) - (isStart ? RecordingTimelineMetrics.handleWidth : 0)
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .frame(width: 7, height: 26)
            .frame(width: RecordingTimelineMetrics.handleWidth, height: 40, alignment: isStart ? .trailing : .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .onChanged { value in
                    if drag.grab(isStart: isStart) == nil {
                        actions.commitEditing()
                        playback.pause()
                        presentation.beginInteraction()
                        drag.setGrab(value.startLocation.x - layout.x(at: time), isStart: isStart)
                    }
                    let grab = drag.grab(isStart: isStart) ?? 0
                    presentation.setZoomBoundary(layout.time(at: value.location.x - grab), isStart: isStart,
                                                 id: zoom.id, sourceDuration: duration)
                }
                .onEnded { _ in
                    drag.setGrab(nil, isStart: isStart)
                    presentation.endInteraction(actionName: "Change Zoom Timing")
                })
            .focusable(!recording.isExporting)
            .onMoveCommand { direction in
                switch direction {
                case .left: setBoundary(time - 0.1, zoom: zoom, isStart: isStart)
                case .right: setBoundary(time + 0.1, zoom: zoom, isStart: isStart)
                default: break
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(String(format: "%.2f seconds", time))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: setBoundary(time + 0.1, zoom: zoom, isStart: isStart)
                case .decrement: setBoundary(time - 0.1, zoom: zoom, isStart: isStart)
                @unknown default: break
                }
            }
            .help("\(label): drag, or use Left and Right when focused")
            .placed(atX: offset)
            .offset(x: min(offset, 0))
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        if let zoom = presentation.selectedZoom {
            HStack(spacing: 6) {
                boundaryField(zoom, isStart: true)
                boundaryField(zoom, isStart: false)
                Spacer(minLength: 0)
                Toggle(isOn: $presentation.editingArea) {
                    Label("Area", systemImage: "viewfinder")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Edit zoom area")
                .help("Show the whole frame and drag the zoom area on the canvas")
                Button(role: .destructive) {
                    presentation.deleteZoom(zoom.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete zoom")
                .help("Delete this zoom")
            }
            .font(.caption.monospacedDigit())
        } else {
            Text("Add a zoom at the playhead, then select it to choose its area and timing.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func boundaryField(_ zoom: ZoomSegment, isStart: Bool) -> some View {
        let value = Binding<Double>(
            get: {
                let current = presentation.settings.zooms.first { $0.id == zoom.id } ?? zoom
                return isStart ? current.start : current.end
            },
            set: { setBoundary($0, zoom: zoom, isStart: isStart) }
        )
        return HStack(spacing: 4) {
            Text(isStart ? "From" : "To").foregroundStyle(.secondary)
            TextField(isStart ? "Zoom start in seconds" : "Zoom end in seconds",
                      value: value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .accessibilityLabel(isStart ? "Zoom start in seconds" : "Zoom end in seconds")
                .help("Time in the original recording")
            Button {
                setBoundary(playback.currentTime, zoom: zoom, isStart: isStart)
            } label: {
                Image(systemName: isStart ? "arrow.right.to.line" : "arrow.left.to.line")
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isStart ? "Zoom starts at playhead" : "Zoom ends at playhead")
            .help(isStart ? "Start the zoom at the playhead" : "End the zoom at the playhead")
        }
    }

    private func setBoundary(_ time: TimeInterval, zoom: ZoomSegment, isStart: Bool) {
        actions.commitEditing()
        playback.pause()
        presentation.selectedZoomID = zoom.id
        presentation.setZoomBoundary(time, isStart: isStart, id: zoom.id, sourceDuration: duration)
    }

    private func select(_ zoom: ZoomSegment) {
        actions.commitEditing()
        playback.pause()
        presentation.selectedZoomID = zoom.id
        let lower = max(zoom.start, recording.trim.start), upper = min(zoom.end, recording.trim.end)
        if lower < upper, playback.currentTime < lower || playback.currentTime >= upper {
            playback.seek(to: lower)
        }
    }

    private func addZoom() {
        actions.commitEditing()
        playback.pause()
        presentation.addZoom(at: playback.currentTime, sourceDuration: duration)
    }
}
