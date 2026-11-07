import GlintCore
import SwiftUI

/// Inspector controls for a recording's click highlights and cursor emphasis.
struct PresentationInspectorContent: View {
    @ObservedObject var presentation: RecordingPresentationModel
    /// The playhead, in source seconds, for removing the click under it.
    let time: TimeInterval

    private var clicks: ClickHighlightStyle { presentation.settings.clicks }
    private var cursor: CursorEmphasis { presentation.settings.cursor }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !presentation.hasPointerData {
                Text("No pointer was recorded with this video. Zoom still works from the timeline.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            clickControls
            Divider()
            cursorControls
        }
        .disabled(!presentation.hasPointerData)
    }

    // MARK: Clicks

    @ViewBuilder
    private var clickControls: some View {
        Toggle("Highlight clicks", isOn: Binding(get: { clicks.enabled }, set: { presentation.setClicksEnabled($0) }))
            .toggleStyle(.checkbox)
            .disabled(!presentation.hasClicks)
            .help(presentation.hasClicks ? "Draw a ripple where each click happened" : "No clicks were recorded")
        if clicks.enabled {
            HStack {
                ColorPicker("Left", selection: colorBinding({ clicks.leftColor }) { color in
                    presentation.setClickStyle { $0.leftColor = color }
                }, supportsOpacity: false)
                ColorPicker("Right", selection: colorBinding({ clicks.rightColor }) { color in
                    presentation.setClickStyle { $0.rightColor = color }
                }, supportsOpacity: false)
            }
            slider("Ripple size", value: clicks.size, range: 16...120, format: { "\(Int($0.rounded())) px" }) { value in
                presentation.setClickStyle { $0.size = value }
            }
            slider("Ripple duration", value: clicks.duration, range: 0.2...2,
                   format: { String(format: "%.1f s", $0) }) { value in
                presentation.setClickStyle { $0.duration = value }
            }
            HStack {
                Button("Remove Click at Playhead") {
                    if let click = presentation.click(near: time) { presentation.removeClick(click.id) }
                }
                .disabled(presentation.click(near: time) == nil)
                .help("Hide the highlight of the click nearest the playhead")
                if !clicks.removed.isEmpty {
                    Button("Restore All") { presentation.restoreClicks() }
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: Cursor

    @ViewBuilder
    private var cursorControls: some View {
        Toggle("Halo", isOn: Binding(get: { cursor.halo }, set: { on in presentation.setCursor { $0.halo = on } }))
            .toggleStyle(.checkbox)
            .help("A soft glow around the pointer")
        if cursor.halo {
            ColorPicker("Halo colour", selection: colorBinding({ cursor.haloColor }) { color in
                presentation.setCursor { $0.haloColor = color }
            }, supportsOpacity: true)
        }
        Toggle("Spotlight", isOn: Binding(get: { cursor.spotlight },
                                          set: { on in presentation.setCursor { $0.spotlight = on } }))
            .toggleStyle(.checkbox)
            .help("Dim everything except the area around the pointer")
        if cursor.halo || cursor.spotlight {
            slider("Radius", value: cursor.radius, range: 16...240, format: { "\(Int($0.rounded())) px" }) { value in
                presentation.setCursor { $0.radius = value }
            }
        }
        Group {
            Toggle("Hide pointer", isOn: Binding(get: { cursor.hidden },
                                                 set: { on in presentation.setCursor { $0.hidden = on } }))
                .toggleStyle(.checkbox)
            slider("Pointer size", value: cursor.scale, range: 0.5...4, format: { String(format: "%.1f×", $0) }) { value in
                presentation.setCursor { $0.scale = value }
            }
            .disabled(cursor.hidden)
        }
        .disabled(!presentation.pointerIsEditable)
        if presentation.hasPointerData, !presentation.pointerIsEditable {
            Text("The pointer is part of this recording. Turn on Editable pointer in Preferences → Capture before recording to resize or hide it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A slider whose drag is one undo step.
    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, format: @escaping (Double) -> String,
                        set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Slider(value: Binding(get: { value }, set: set), in: range) { editing in
                if editing { presentation.beginInteraction() } else { presentation.endInteraction(actionName: title) }
            }
            .accessibilityLabel(title)
            .accessibilityValue(format(value))
        }
    }
}
