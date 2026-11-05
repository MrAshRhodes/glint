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
        let host = NSHostingView(rootView: RecordingBarView(editor: fixture.model(), recording: recording,
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
}
