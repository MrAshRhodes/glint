import AppKit
import SwiftUI
import Testing
@testable import GlintCore
@testable import GlintEditor

@Suite("Unified recording editor")
@MainActor
struct RecordingEditorUnificationTests {
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @Test func recordingUsesTheActualScreenshotChromeAndCanvas() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let video = try RecordingEditorFixture(); defer { video.cleanUp() }
        let recording = try await video.recording()
        let controller = RecordingEditorWindowController(recording: recording, services: video.services(),
                                                         preferences: f.preferences, presetStore: f.presets)
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let views = descendants(try #require(window.contentView))
        #expect(window === controller.editor.window)
        #expect(window is EditorWindow)
        #expect(window.titlebarAppearsTransparent && window.toolbarStyle == .unified)
        #expect(views.contains { $0 is NSHostingView<ToolStripView> })
        #expect(views.contains { $0 is NSHostingView<InspectorView> })
        #expect(views.contains { $0 is CanvasView })
        #expect(views.contains { $0 is NSHostingView<RecordingBarView> })
        #expect(!views.contains { $0 is NSHostingView<BottomBarView> })
        controller.playback.play()
        controller.editor.selectTool(.arrow)
        #expect(!controller.playback.isPlaying)
    }

    @Test func framesDoNotCreateUndoEntriesAndVideoCannotEnableAutomaticCroppingOrRedaction() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoBalance = true
        f.preferences.autoRedact = true
        let initialPreferences = f.preferences.lastRenderSettings
        var recognized = false
        let context = EditorContext(image: f.context.image, backingScale: 2, rawURL: nil, source: nil, isRecording: true)
        let model = EditorModel(context: context, preferences: f.preferences, presetStore: f.presets,
                                recognizeText: { _ in recognized = true; return [] })
        model.undoManager.groupsByEvent = false
        #expect(!model.settings.autoBalance)
        model.settings.autoBalance = true
        #expect(!model.settings.autoBalance)
        for time in 0..<20 { model.updateRecordingFrame(f.context.image, at: Double(time)) }
        await model.runAutoRedact()
        #expect(!recognized && model.annotations.isEmpty)
        #expect(!model.undoManager.canUndo)
        #expect(model.lastRedactSummary?.contains("whole clip") == true)
        #expect(f.preferences.autoBalance)
        #expect(f.preferences.lastRenderSettings == initialPreferences)
    }

    @Test func snapshotFreezesAnnotationsFramesAndBackgroundForEveryExportedFrame() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let context = EditorContext(image: f.context.image, backingScale: 2, rawURL: nil, source: nil, isRecording: true)
        let model = EditorModel(context: context, preferences: f.preferences, presetStore: f.presets)
        model.settings.windowFrame = WindowFrameSettings(style: .macOS, title: "Recording")
        model.settings.padding = 20
        model.settings.background = .solid(.red)
        model.updateLive([Annotation(kind: .redact(CGRect(x: 20, y: 20, width: 40, height: 30)),
                                     style: AnnotationStyle(color: .black))])
        let snapshot = model.recordingFrameRenderer()
        let expected = try model.renderFinal()
        model.settings.windowFrame = WindowFrameSettings()
        model.settings.padding = 0
        model.settings.background = .transparent
        model.updateLive([])
        let rendered = try snapshot(f.context.image, 0)
        #expect(rendered.pixelSize == expected.pixelSize)
        #expect(try #require(PixelBuffer(rendered)).data == #require(PixelBuffer(expected)).data)
        #expect(rendered.pixelSize != f.context.image.pixelSize)
        let replacement = try #require(GlintBitmap.makeContext(width: 100, height: 80))
        replacement.setFillColor(RGBAColor.black.cgColor)
        replacement.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        let next = try snapshot(#require(replacement.makeImage()), 1)
        #expect(next.pixelSize == rendered.pixelSize)
        #expect(try #require(PixelBuffer(next)).data != #require(PixelBuffer(rendered)).data)
    }

    @Test func exportReceivesOneImmutableRendererAndPreparedFilesExpireOnEdits() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let video = try RecordingEditorFixture(); defer { video.cleanUp() }
        let recording = try await video.recording()
        var calls = 0
        var services = video.services()
        services.export = { _, _, _, directory, _, renderer in
            calls += 1
            let render = try #require(renderer)
            let output = try render(f.context.image, 0)
            #expect(output.width > f.context.image.width)
            let url = directory.appendingPathComponent("clip.gif")
            try Data("styled-test-payload".utf8).write(to: url)
            return url
        }
        let controller = RecordingEditorWindowController(recording: recording, services: services,
                                                         preferences: f.preferences, presetStore: f.presets)
        controller.editor.model.settings.padding = 20
        #expect(controller.model.prepareFile() == nil)
        await controller.model.waitForExport()
        let prepared = try #require(controller.model.prepareFile())
        #expect(calls == 1)
        #expect(FileManager.default.fileExists(atPath: prepared.path))
        controller.editor.model.updateLive([Annotation(kind: .redact(CGRect(x: 1, y: 1, width: 20, height: 20)))])
        #expect(controller.model.prepareFile() == nil)
        await controller.model.waitForExport()
        #expect(calls == 2)
        controller.window?.close()
        #expect(!FileManager.default.fileExists(atPath: prepared.path))
        #expect(video.stagingLeftovers.isEmpty)
    }

    @Test func previewFramesReachTheSharedCompositorAndSeekingUpdatesPixels() async throws {
        let video = try RecordingEditorFixture(); defer { video.cleanUp() }
        let recording = try await video.recording()
        let playback = RecordingPlayback(url: recording.url, duration: recording.duration)
        defer { playback.shutdown() }
        var frame: CGImage?
        playback.onFrame = { image, _ in frame = image }
        await waitUntil(seconds: 60) { frame != nil || playback.frameProblem != nil }
        let first = try #require(frame)
        #expect(first.pixelSize == recording.pixelSize)
        frame = nil
        playback.seek(to: 1)
        await waitUntil(seconds: 60) { frame != nil || playback.frameProblem != nil }
        let second = try #require(frame)
        #expect(try #require(PixelBuffer(first)).data != #require(PixelBuffer(second)).data)
        #expect(playback.frameProblem == nil)
    }

    @Test func recordingShortcutsKeepToolsAndLeaveTextEditingAlone() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let video = try RecordingEditorFixture(); defer { video.cleanUp() }
        let controller = RecordingEditorWindowController(recording: try await video.recording(), services: video.services(),
                                                         preferences: f.preferences, presetStore: f.presets)
        defer { controller.window?.close() }
        func key(_ text: String, code: UInt16 = 0) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                             isARepeat: false, keyCode: code)!
        }
        #expect(controller.editor.handleShortcut(key("2")))
        #expect(controller.editor.model.tool == .arrow)
        #expect(controller.editor.handleShortcut(key(" ", code: 49)))
        #expect(controller.playback.isPlaying)
        controller.playback.pause()
        controller.playback.seek(to: 0.5)
        #expect(controller.editor.handleShortcut(key("i")))
        #expect(controller.model.trim.start == 0.5)
        controller.playback.seek(to: 1.5)
        #expect(controller.editor.handleShortcut(key("o")))
        #expect(controller.model.trim.end == 1.5)
        controller.playback.seek(to: 1)
        #expect(controller.editor.handleShortcut(key("", code: 123)))
        #expect(abs(controller.playback.currentTime - (1 - 1.0 / 30)) < 0.001)
        let window = try #require(controller.window)
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        window.contentView?.addSubview(text)
        #expect(window.makeFirstResponder(text))
        _ = window.performKeyEquivalent(with: key(" ", code: 49))
        #expect(!controller.playback.isPlaying, "Space belongs to the text editor, not the recording transport")
    }

    @Test func styledDimensionsIncludeFrameAndPadding() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let video = try RecordingEditorFixture(); defer { video.cleanUp() }
        let controller = RecordingEditorWindowController(recording: try await video.recording(), services: video.services(),
                                                         preferences: f.preferences, presetStore: f.presets)
        defer { controller.window?.close() }
        let model = controller.editor.model
        model.settings.padding = 20
        model.settings.windowFrame = WindowFrameSettings(style: .macOS)
        let expected = try model.renderFinal().pixelSize
        await waitUntil(seconds: 60) { controller.model.styledPixelSize == expected }
        #expect(controller.model.styledPixelSize == expected)
        #expect(controller.model.outputSize == controller.model.options.gif.maxWidth.outputSize(for: expected))
        controller.model.options.format = .mp4
        #expect(controller.model.outputSize.width == ceil(expected.width / 2) * 2)
        #expect(controller.model.outputSize.height == ceil(expected.height / 2) * 2)
    }
}
