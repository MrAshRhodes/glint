import AppKit
import GlintCore
import SwiftUI
import Testing
@testable import GlintEditor

@Suite("Recording bar", .serialized)
@MainActor
struct RecordingBarTests {
    private let actionLabels = ["Play recording", "GIF options", "Share recording", "Save recording as",
                                "Save recording", "Copy recording", "Close recording"]

    private func withBar(width: CGFloat = 660, duration: TimeInterval = 10,
                         appearance: NSAppearance.Name = .aqua,
                         configure: (EditorModel) -> Void = { _ in },
                         _ inspect: (NSHostingView<RecordingBarView>, RecordingEditorModel, RecordingPlayback, EditorActions) throws -> Void) throws {
        let fixture = try EditorFixture()
        defer { fixture.cleanUp() }
        let recordingFixture = try RecordingEditorFixture()
        defer { recordingFixture.cleanUp() }
        let video = try recordingFixture.paperRecording(duration: duration)
        let recording = RecordingEditorModel(recording: video, services: recordingFixture.services())
        let playback = RecordingPlayback(url: video.url, duration: duration)
        defer { playback.shutdown() }
        let actions = EditorActions()
        let app = NSApplication.shared
        let attributes = ["AXEnhancedUserInterface", "AXManualAccessibility"].map(NSAccessibility.Attribute.init(rawValue:))
        let previous = attributes.map { app.accessibilityAttributeValue($0) }
        for attribute in attributes { app.accessibilitySetValue(true, forAttribute: attribute) }
        defer {
            for (attribute, value) in zip(attributes, previous) {
                app.accessibilitySetValue(value, forAttribute: attribute)
            }
        }
        let size = CGSize(width: width, height: RecordingBarView.contentHeight + 2 * EditorChromeMetrics.shadowPadding)
        let context = EditorContext(image: fixture.context.image, backingScale: 2, rawURL: nil,
                                    source: nil, isRecording: true)
        let editor = EditorModel(context: context, preferences: fixture.preferences, presetStore: fixture.presets)
        configure(editor)
        let host = NSHostingView(rootView: RecordingBarView(editor: editor, recording: recording,
                                                          playback: playback, actions: actions))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        try inspect(host, recording, playback, actions)
    }

    private func descendants(of root: NSObject) -> [NSObject] {
        let children = (root.value(forKey: "accessibilityChildren") as? [NSObject]) ?? []
        return children.flatMap { [$0] + descendants(of: $0) }
    }

    private func node(_ label: String, in host: NSView) throws -> NSObject {
        try #require(descendants(of: host).first { $0.value(forKey: "accessibilityLabel") as? String == label },
                     "Missing accessible recording control: \(label)")
    }

    private func press(_ label: String, in host: NSView) throws {
        try perform("accessibilityPerformPress", on: label, in: host)
    }

    private func frame(_ label: String, in host: NSView) throws -> CGRect {
        let control = try node(label, in: host)
        let screen = try #require((control.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue)
        return try #require(host.window).convertFromScreen(screen)
    }

    private func drag(from start: CGPoint, to end: CGPoint, in host: NSView) throws {
        let window = try #require(host.window)
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let timestamp = ProcessInfo.processInfo.systemUptime
        let points: [(NSEvent.EventType, CGPoint)] = [(.leftMouseDown, start)]
            + (1...5).map { step in
                (.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * CGFloat(step) / 5,
                                           y: start.y + (end.y - start.y) * CGFloat(step) / 5))
            } + [(.leftMouseUp, end)]
        for (index, point) in points.enumerated() {
            let event = try #require(NSEvent.mouseEvent(with: point.0, location: point.1, modifierFlags: [],
                                                       timestamp: timestamp + Double(index) * 0.02,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       eventNumber: index, clickCount: 1, pressure: 1))
            NSApplication.shared.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
        }
    }

    private func perform(_ action: String, on label: String, in host: NSView) throws {
        let control = try node(label, in: host)
        let selector = NSSelectorFromString(action)
        try #require(control.responds(to: selector), "\(label) must expose \(action)")
        // SwiftUI nodes implement the Objective-C accessibility methods without adopting the public protocol.
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        let perform = unsafeBitCast(control.method(for: selector), to: Action.self)
        #expect(perform(control, selector), "\(label) must support \(action)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    @Test func controlsHaveAccessibleNamesAndStayInsideTheBarInBothAppearances() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width: CGFloat in [660, 940] {
                try withBar(width: width, appearance: appearance) { host, _, _, _ in
                    let window = try #require(host.window)
                    let hostFrame = host.convert(host.bounds, to: nil)
                    for label in actionLabels + ["Trim start in seconds", "Trim end in seconds",
                                                 "Adjust trim start", "Adjust trim end", "Export format",
                                                 "Trim start", "Trim end", "Playhead"] {
                        let control = try node(label, in: host)
                        let screen = try #require((control.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue)
                        let frame = window.convertFromScreen(screen)
                        #expect(frame.width > 0 && frame.height > 0, "\(label) has no hit target")
                        #expect(hostFrame.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                                "\(label) at \(frame) overflows the \(width)-point recording bar")
                    }
                }
            }
        }
    }

    @Test func exportButtonsUseSharedControllerActionsAndShareAnchor() throws {
        try withBar { host, _, _, actions in
            var invoked: [String] = []
            actions.copy = { invoked.append("copy") }
            actions.save = { invoked.append("save") }
            actions.saveAs = { invoked.append("saveAs") }
            actions.share = { invoked.append("share") }
            for label in ["Copy recording", "Save recording", "Save recording as", "Share recording"] {
                try press(label, in: host)
            }
            #expect(invoked == ["copy", "save", "saveAs", "share"])
            #expect(actions.shareAnchor?.window === host.window)
        }
    }

    @Test func longGIFRequiresExplicitFitAndDisablesExport() throws {
        try withBar(duration: 40) { host, recording, _, _ in
            #expect(recording.trim.duration == 40)
            #expect(!recording.canExport)
            _ = try node("Fit to limit", in: host)
            for label in ["Copy recording", "Save recording", "Share recording"] {
                let button = try node(label, in: host)
                #expect(button.value(forKey: "accessibilityEnabled") as? Bool == false)
            }
            try press("Fit to limit", in: host)
            #expect(recording.trim.duration == 30)
            #expect(recording.canExport)
        }
    }

    @Test func transportAndTrimAdjustmentsUseTheRecordingState() throws {
        try withBar { host, recording, playback, _ in
            try press("Play recording", in: host)
            #expect(playback.isPlaying)
            playback.pause()
            recording.setTrimStart(2)
            recording.setTrimEnd(8)
            host.layoutSubtreeIfNeeded()
            #expect(recording.trim.range == 2...8)
            #expect(playback.range == 2...8)
            try perform("accessibilityPerformIncrement", on: "Trim start", in: host)
            #expect(abs(recording.trim.start - 2.1) < 0.001)
            #expect(playback.range == recording.trim.range)
            try perform("accessibilityPerformDecrement", on: "Trim end", in: host)
            #expect(abs(recording.trim.end - 7.9) < 0.001)
            try press("Reset trim", in: host)
            #expect(recording.trim.isFullRange)
            #expect(playback.range == 0...10)
        }
    }

    @Test func annotationLanesExposeAdjustableRangesAndPlayheadActions() throws {
        var editor: EditorModel?
        try withBar(configure: { model in
            editor = model
            let annotation = model.makeAnnotation(.redact(CGRect(x: 0, y: 0, width: 20, height: 20)))
            model.updateLive([annotation])
            model.selection = [annotation.id]
        }) { host, recording, playback, _ in
            let model = try #require(editor)
            for label in ["Select Redaction", "Redaction start", "Redaction end", "Redaction range",
                          "Annotation start in seconds", "Annotation end in seconds",
                          "Start at playhead", "End at playhead"] {
                let control = try node(label, in: host)
                let frame = try #require((control.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue)
                #expect(frame.width > 0 && frame.height > 0)
                let local = try #require(host.window).convertFromScreen(frame)
                #expect(host.convert(host.bounds, to: nil).insetBy(dx: -0.5, dy: -0.5).contains(local))
            }
            try perform("accessibilityPerformIncrement", on: "Redaction start", in: host)
            #expect(model.annotations[0].visibleRange?.start == 0.1)
            try perform("accessibilityPerformDecrement", on: "Redaction end", in: host)
            #expect(model.annotations[0].visibleRange?.end == 9.9)
            playback.seek(to: 2)
            try press("Start at playhead", in: host)
            playback.seek(to: 8)
            try press("End at playhead", in: host)
            #expect(model.annotations[0].visibleRange == AnnotationTiming(start: 2, end: 8))
            try perform("accessibilityPerformIncrement", on: "Redaction range", in: host)
            #expect(model.annotations[0].visibleRange == AnnotationTiming(start: 2.1, end: 8.1))
            try perform("accessibilityPerformDecrement", on: "Redaction range", in: host)
            #expect(model.annotations[0].visibleRange == AnnotationTiming(start: 2, end: 8))
            #expect(recording.trim.isFullRange)
            #expect(descendants(of: host).contains {
                $0.value(forKey: "accessibilityValue") as? String
                    == "Time-limited redactions expose content outside their range. Check the whole clip before sharing."
            })
            try press("Show selected annotation throughout the clip", in: host)
            #expect(model.annotations[0].visibleRange == nil && !model.hasTimeLimitedRedactions)
        }
    }

    @Test func annotationHandlesRespondToMouseDrags() throws {
        var editor: EditorModel?
        try withBar(configure: { model in
            editor = model
            model.updateLive([model.makeAnnotation(.redact(.zero))])
        }) { host, recording, _, _ in
            let model = try #require(editor)
            let start = try frame("Redaction start", in: host)
            let end = try frame("Redaction end", in: host)
            let distance = (end.minX - start.maxX) / 5
            try drag(from: CGPoint(x: start.maxX - 3, y: start.midY),
                     to: CGPoint(x: start.maxX - 3 + distance, y: start.midY), in: host)
            let range = try #require(model.annotations[0].visibleRange)
            #expect(abs(range.start - 2) < 0.01)
            #expect(range.end == 10)
            let endHandle = try frame("Redaction end", in: host)
            try drag(from: CGPoint(x: endHandle.minX + 3, y: endHandle.midY),
                     to: CGPoint(x: endHandle.minX + 3 - distance, y: endHandle.midY), in: host)
            let resized = try #require(model.annotations[0].visibleRange)
            #expect(abs(resized.start - 2) < 0.01)
            #expect(abs(resized.end - 8) < 0.01)
            #expect(recording.trim.isFullRange)
        }
    }

    @Test func annotationLanesAlignWithTheTrimTimelineAtEveryWindowSize() throws {
        for width: CGFloat in [660, 940] {
            for duration: TimeInterval in [10, 600] {
                for partial in [false, true] {
                    let start = partial ? duration * 0.2 : 0
                    let end = partial ? duration * 0.8 : duration
                    try withBar(width: width, duration: duration, configure: { model in
                        var annotation = model.makeAnnotation(.redact(.zero))
                        annotation.visibleRange = partial ? AnnotationTiming(start: start, end: end) : nil
                        model.updateLive([annotation])
                    }) { host, recording, _, _ in
                        recording.setTrimStart(start)
                        recording.setTrimEnd(end)
                        host.layoutSubtreeIfNeeded()
                        let trimStart = try frame("Trim start", in: host)
                        let trimEnd = try frame("Trim end", in: host)
                        let laneStart = try frame("Redaction start", in: host)
                        let laneEnd = try frame("Redaction end", in: host)
                        let range = try frame("Redaction range", in: host)
                        #expect(abs(laneStart.maxX - trimStart.midX) < 0.5)
                        #expect(abs(laneEnd.minX - trimEnd.midX) < 0.5)
                        #expect(abs(range.minX - trimStart.midX) < 0.5)
                        #expect(abs(range.maxX - trimEnd.midX) < 0.5)
                        let selector = try frame("Select Redaction", in: host)
                        #expect(selector.maxX <= laneStart.minX + 0.5, "The selector and handle must not overlap")
                    }
                }
            }
        }
    }

    @Test func draggingAnnotationBodyMovesItsRangeAndUndoesInOneStep() throws {
        var editor: EditorModel?
        try withBar(configure: { model in
            editor = model
            var annotation = model.makeAnnotation(.redact(.zero))
            annotation.visibleRange = AnnotationTiming(start: 2, end: 6)
            model.updateLive([annotation])
            model.undoManager.removeAllActions()
            model.undoManager.groupsByEvent = false
        }) { host, recording, _, _ in
            let model = try #require(editor)
            let start = try frame("Redaction start", in: host)
            let end = try frame("Redaction end", in: host)
            let center = CGPoint(x: (start.maxX + end.minX) / 2, y: start.midY)
            model.undoManager.beginUndoGrouping()
            try drag(from: center, to: CGPoint(x: center.x + (end.minX - start.maxX) / 4,
                                               y: center.y), in: host)
            model.undoManager.endUndoGrouping()
            let moved = try #require(model.annotations[0].visibleRange)
            #expect(abs(moved.start - 3) < 0.01)
            #expect(abs(moved.end - 7) < 0.01)
            #expect(recording.trim.isFullRange)
            #expect(model.canUndo)
            if model.canUndo { model.undoManager.undo() }
            #expect(model.annotations[0].visibleRange == AnnotationTiming(start: 2, end: 6))
            #expect(!model.canUndo)
        }
    }

    @Test func draggingWholeClipKeepsItWholeUntilAHandleIsResized() throws {
        var editor: EditorModel?
        try withBar(configure: { model in
            editor = model
            model.updateLive([model.makeAnnotation(.redact(.zero))])
            model.undoManager.removeAllActions()
        }) { host, _, _, _ in
            let model = try #require(editor)
            let range = try frame("Redaction range", in: host)
            try drag(from: CGPoint(x: range.midX, y: range.midY),
                     to: CGPoint(x: range.midX + 80, y: range.midY), in: host)
            #expect(model.annotations[0].visibleRange == nil)
            #expect(model.selection == [model.annotations[0].id])
            #expect(!model.canUndo)
        }
    }
}
