import AppKit
import GlintCore
import SwiftUI

/// The whole recording, with a trim handle at each end of the selected range and a movable playhead.
struct RecordingTimelineView: View {
    @ObservedObject var model: RecordingEditorModel
    @ObservedObject var playback: RecordingPlayback
    @StateObject private var drag = TimelineDragState()

    private let handleWidth: CGFloat = 24
    private let height: CGFloat = 46
    private let step: TimeInterval = 0.1
    private let space = "recording-timeline"

    var body: some View {
        GeometryReader { geometry in
            let layout = TimelineLayout(width: geometry.size.width, handleWidth: handleWidth,
                                        duration: model.trim.sourceDuration)
            ZStack(alignment: .leading) {
                track
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space)).onChanged { value in
                        playback.seek(to: layout.time(at: value.location.x))
                    })
                selection(layout)
                playhead(layout)
                handle(isStart: true, layout: layout)
                handle(isStart: false, layout: layout)
            }
            .coordinateSpace(name: space)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Trim timeline")
        }
        .frame(height: height)
    }

    private var track: some View {
        RoundedRectangle(cornerRadius: GlintDesign.controlCornerRadius, style: .continuous)
            .fill(GlintDesign.cardFill)
            .overlay(RoundedRectangle(cornerRadius: GlintDesign.controlCornerRadius, style: .continuous)
                .strokeBorder(GlintDesign.hairline, lineWidth: 0.5))
            .contentShape(Rectangle())
            .help("Click or drag to scrub the recording; drag the accent handles to trim")
    }

    private func selection(_ layout: TimelineLayout) -> some View {
        let start = layout.x(at: model.trim.start)
        let end = layout.x(at: model.trim.end)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.accentColor.opacity(0.22))
            .frame(width: max(end - start, 0), height: height - 6)
            .allowsHitTesting(false)
            .placed(atX: start)
    }

    private func playhead(_ layout: TimelineLayout) -> some View {
        Capsule()
            .fill(Color.primary)
            .frame(width: 2, height: height - 10)
            .shadow(color: .black.opacity(0.35), radius: 1)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playhead")
            .accessibilityValue(GIFLimits.format(seconds: playback.currentTime))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: playback.seek(to: playback.currentTime + 0.5)
                case .decrement: playback.seek(to: playback.currentTime - 0.5)
                @unknown default: break
                }
            }
            .placed(atX: layout.x(at: min(max(playback.currentTime, model.trim.start), model.trim.end)) - 1)
    }

    private func handle(isStart: Bool, layout: TimelineLayout) -> some View {
        let time = isStart ? model.trim.start : model.trim.end
        let drag = drag
        let label = isStart ? "Trim start" : "Trim end"
        let set: (TimeInterval) -> Void = { isStart ? model.setTrimStart($0) : model.setTrimEnd($0) }
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: 14, height: height)
            .overlay(Capsule().fill(Color.white.opacity(0.9)).frame(width: 2, height: 16))
            .frame(width: handleWidth, height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .onChanged { value in
                    let grab = drag.grab(isStart: isStart) ?? value.startLocation.x - layout.x(at: time)
                    drag.setGrab(grab, isStart: isStart)
                    set(layout.time(at: value.location.x - grab))
                }
                .onEnded { _ in drag.setGrab(nil, isStart: isStart) })
            .focusable(!model.isExporting)
            .onMoveCommand { direction in
                switch direction {
                case .left: set(time - step)
                case .right: set(time + step)
                default: break
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(GIFLimits.format(seconds: time))
            .accessibilityHint(isStart ? "Adjust to change where the export starts" : "Adjust to change where the export ends")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: set(time + step)
                case .decrement: set(time - step)
                @unknown default: break
                }
            }
            .help(label)
            .placed(atX: layout.x(at: time) - handleWidth / 2)
    }
}

extension View {
    /// Layout-based positioning keeps the focus ring and accessibility frame with the visible handle.
    func placed(atX x: CGFloat) -> some View {
        padding(.leading, max(x, 0)).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Remember the grab offset so handles don't jump to the pointer at the start of a drag.
final class TimelineDragState: ObservableObject {
    private var startGrab: CGFloat?
    private var endGrab: CGFloat?

    func grab(isStart: Bool) -> CGFloat? { isStart ? startGrab : endGrab }

    func setGrab(_ value: CGFloat?, isStart: Bool) {
        if isStart { startGrab = value } else { endGrab = value }
    }
}

/// Handle centres span the track minus one handle width, keeping both edge handles inside the track.
struct TimelineLayout: Equatable {
    let width: CGFloat
    let handleWidth: CGFloat
    let duration: TimeInterval

    private var usableWidth: CGFloat { max(width - handleWidth, 1) }

    func x(at time: TimeInterval) -> CGFloat {
        guard duration > 0 else { return handleWidth / 2 }
        return handleWidth / 2 + CGFloat(min(max(time / duration, 0), 1)) * usableWidth
    }

    func time(at x: CGFloat) -> TimeInterval {
        guard duration > 0 else { return 0 }
        return min(max(Double((x - handleWidth / 2) / usableWidth), 0), 1) * duration
    }
}
