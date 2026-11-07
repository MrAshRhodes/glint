import AppKit
import GlintCore
import SwiftUI

/// Recording-specific controls below the shared screenshot editor canvas.
struct RecordingBarView: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var recording: RecordingEditorModel
    @ObservedObject var playback: RecordingPlayback
    @ObservedObject var actions: EditorActions
    @ObservedObject var tracking: RedactionTrackingModel
    static let contentHeight: CGFloat = 354

    @StateObject private var presentation = RecordingBarPresentation()

    var body: some View {
        GlintGlassContainer(spacing: 4) {
            VStack(spacing: 4) {
                VStack(spacing: 4) {
                    transport.frame(height: 46)
                    trimAndFormat.frame(height: 32)
                    RecordingAnnotationTimeline(editor: editor, recording: recording, playback: playback,
                                                actions: actions, tracking: tracking)
                        .frame(height: 178)
                    status.frame(height: 22)
                }
                .padding(6)
                .glintGlassPanel()
                exportRow.frame(height: EditorChromeMetrics.bottomBarHeight)
            }
        }
        .padding(EditorChromeMetrics.shadowPadding)
        .onChange(of: recording.trim, initial: true) { _, trim in
            playback.apply(range: trim.range, sourceDuration: trim.sourceDuration)
        }
    }

    private var transport: some View {
        HStack(spacing: RecordingTimelineMetrics.spacing) {
            Button { playback.togglePlayback() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: RecordingTimelineMetrics.controlWidth, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(playback.isPlaying ? "Pause recording" : "Play recording")
            .help("Play or pause the trimmed recording (Space)")

            RecordingTimelineView(model: recording, playback: playback)
                .disabled(recording.isExporting)

            Text("\(GIFLimits.format(seconds: max(playback.currentTime - recording.trim.start, 0))) / \(GIFLimits.format(seconds: recording.trim.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: RecordingTimelineMetrics.timeWidth, alignment: .trailing)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(GIFLimits.format(seconds: max(playback.currentTime - recording.trim.start, 0))) of \(GIFLimits.format(seconds: recording.trim.duration))")
                .help("Elapsed time within the trimmed recording")
        }
    }

    private var trimAndFormat: some View {
        HStack(spacing: 10) {
            trimControl(isStart: true)
            trimControl(isStart: false)
            Button {
                recording.setTrimStart(0)
                recording.setTrimEnd(recording.trim.sourceDuration)
            } label: {
                Image(systemName: "arrow.counterclockwise").frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(recording.trim.isFullRange)
            .accessibilityLabel("Reset trim")
            .help("Use the whole recording")
            Spacer(minLength: 0)
            Picker("Export format", selection: $recording.options.format) {
                ForEach(RecordingFileFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Export format")
            .help("Choose GIF or MP4")
            if recording.options.format == .gif {
                Button { presentation.showsGIFOptions.toggle() } label: {
                    Label("GIF options", systemImage: "slider.horizontal.3")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("GIF options")
                .help("GIF frame rate and maximum width")
                .popover(isPresented: $presentation.showsGIFOptions) { gifOptions }
            }
        }
        .disabled(recording.isExporting)
    }

    private func trimControl(isStart: Bool) -> some View {
        let label = isStart ? "Trim start in seconds" : "Trim end in seconds"
        let value = Binding<Double>(
            get: { isStart ? recording.trim.start : recording.trim.end },
            set: { isStart ? recording.setTrimStart($0) : recording.setTrimEnd($0) }
        )
        return HStack(spacing: 5) {
            Text(isStart ? "Start" : "End").foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 66)
                .accessibilityLabel(label)
                .help("Enter seconds to two decimal places")
            Stepper(label, onIncrement: { value.wrappedValue += 0.1 },
                    onDecrement: { value.wrappedValue -= 0.1 })
                .labelsHidden()
                .fixedSize()
                .accessibilityElement(children: .contain)
                .accessibilityLabel(isStart ? "Adjust trim start" : "Adjust trim end")
                .accessibilityValue(String(format: "%.2f seconds", value.wrappedValue))
                .help("Adjust by 0.1 seconds")
        }
        .font(.caption.monospacedDigit())
    }

    private var gifOptions: some View {
        VStack(alignment: .leading, spacing: GlintDesign.rowSpacing) {
            Text("GIF options").font(.headline)
            Picker("Frame rate", selection: $recording.options.gif.framesPerSecond) {
                ForEach(GIFLimits.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
            }
            .accessibilityLabel("GIF frame rate")
            Picker("Maximum width", selection: $recording.options.gif.maxWidth) {
                ForEach(GIFMaxWidth.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .accessibilityLabel("GIF maximum width")
            Text("Up to \(GIFLimits.format(seconds: GIFLimits.maxDuration(framesPerSecond: recording.options.gif.framesPerSecond))) at this frame rate. Longer selections are never shortened automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
        .disabled(recording.isExporting)
    }

    @ViewBuilder
    private var status: some View {
        if case .running(let fraction) = recording.exportState {
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .accessibilityLabel("Recording export progress")
                Text(recording.statusText ?? "Exporting…")
                    .font(.caption.monospacedDigit())
                    .fixedSize()
                Button("Cancel") { recording.cancelExport() }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancel recording export")
            }
        } else if !recording.blockingRedactionIntervals.isEmpty {
            let count = recording.blockingRedactionIntervals.count
            let message = "\(count) tracked-redaction interval\(count == 1 ? " needs" : "s need") review before export."
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).accessibilityHidden(true)
                Text(message + " You remain responsible for checking every frame.")
                    .font(.caption)
                    .lineLimit(1)
                    .help(message + " Flagged frames use a large cover until you accept it or add keyframes. "
                          + "Tracking is an aid: you remain responsible for checking every frame.")
                    .accessibilityLabel(message + " You remain responsible for checking every frame.")
                Spacer(minLength: 0)
                Button("Review next") {
                    actions.commitEditing()
                    playback.pause()
                    if let next = RedactionTrackingModel.nextFlagged(after: playback.currentTime,
                                                                    in: recording.blockingRedactionIntervals) {
                        editor.selection = [next.annotationID]
                        playback.seek(to: next.start)
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Review the next tracked-redaction interval")
                .help("Jump to the next interval that needs review (Shift+N)")
            }
        } else if let issue = recording.gifLimitIssue {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).accessibilityHidden(true)
                Text("GIF limit: \(GIFLimits.format(seconds: issue.maxDuration)) at \(recording.options.gif.framesPerSecond) fps")
                    .font(.caption)
                    .lineLimit(1)
                    .help(issue.message)
                    .accessibilityLabel(issue.message)
                Spacer(minLength: 0)
                Button("Fit to limit") { recording.fitToGIFLimit() }
                    .buttonStyle(.borderless)
                    .help("Shorten the trim end to fit \(GIFLimits.format(seconds: issue.maxDuration)); keep the start")
            }
        } else {
            HStack(spacing: 8) {
                if editor.hasTimeLimitedRedactions {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).accessibilityHidden(true)
                }
                Text(statusDescription)
                    .lineLimit(1)
                    .help(statusDescription)
                Spacer(minLength: 0)
                Text([recording.outputSizeText, recording.estimatedSizeText].compactMap { $0 }.joined(separator: " · "))
                    .lineLimit(1)
                    .help("Output dimensions and approximate GIF file size. Actual size depends on the recording.")
                    .layoutPriority(-1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var statusDescription: String {
        if let problem = recording.sourceProblem ?? playback.frameProblem ?? editor.statusMessage { return problem }
        if let message = tracking.message { return message }
        if editor.hasTimeLimitedRedactions {
            return "Time-limited redactions expose content outside their range. Check the whole clip before sharing."
        }
        return recording.statusText ?? "Annotations cover the whole clip unless you adjust their ranges."
    }

    private var exportRow: some View {
        HStack(spacing: 8) {
            DragThumbnail(model: editor, actions: actions)
                .frame(width: DragSourceView.thumbnailWidth + 2 * DragSourceView.thumbnailInset, height: 36)
                .allowsHitTesting(recording.canExport)
                .opacity(recording.canExport ? 1 : 0.4)
                .accessibilityLabel("Drag recording to share")
                .help("Drag the exported \(recording.options.format.displayName) into another app or Finder")
                .padding(6)
                .glintGlass(in: RoundedRectangle(cornerRadius: EditorChromeMetrics.bottomBarCornerRadius, style: .continuous))
            Spacer(minLength: 0)
            if recording.canRetry || actions.retryExport != nil {
                Button("Retry") {
                    if let retry = actions.retryExport { retry() } else { recording.retry() }
                }
                .glintGlassButtonStyle()
                .disabled(!recording.canExport)
                .accessibilityLabel("Retry recording export")
                .help("Retry using your current edits")
            }
            Button { actions.share() } label: {
                Label("Share", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
            }
            .glintGlassButtonStyle()
            .background(RecordingShareAnchor(actions: actions))
            .disabled(!recording.canExport)
            .accessibilityLabel("Share recording")
            .help("Share the exported recording")
            Button { actions.saveProject() } label: {
                Label("Save as Project…", systemImage: "doc.badge.plus").labelStyle(.iconOnly)
            }
            .glintGlassButtonStyle()
            .disabled(recording.sourceProblem != nil)
            .accessibilityLabel("Save recording as project")
            .help("Save as Project (⌥⌘S): keep the recording editable")
            Button("Save As…") { actions.saveAs() }
                .glintGlassButtonStyle()
                .disabled(!recording.canExport)
                .accessibilityLabel("Save recording as")
                .help("Save As (⇧⌘S)")
            Button("Save") { actions.save() }
                .glintGlassButtonStyle()
                .disabled(!recording.canExport)
                .accessibilityLabel("Save recording")
                .help("Save (⌘S)")
            Button { actions.copy() } label: {
                HStack(spacing: 5) {
                    Text("Copy")
                    Text("⌘C").font(.caption).opacity(0.8)
                }
            }
            .glintGlassButtonStyle(prominent: true)
            .disabled(!recording.canExport)
            .accessibilityLabel("Copy recording")
            .help("Copy the exported \(recording.options.format.displayName) (⌘C)")
            Button { actions.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .glintGlass(in: Circle())
            .accessibilityLabel("Close recording")
            .help("Close (⌘W)")
        }
        .controlSize(.large)
    }
}

private final class RecordingBarPresentation: ObservableObject {
    @Published var showsGIFOptions = false
}

private struct RecordingShareAnchor: NSViewRepresentable {
    let actions: EditorActions

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        actions.shareAnchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { actions.shareAnchor = view }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
