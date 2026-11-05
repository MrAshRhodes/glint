import AppKit
import Testing
@testable import GlintCapture

// Builds the control bar offscreen: no window is shown and nothing is captured.
@Suite("Recording controls")
@MainActor
struct RecordingControlsTests {
    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview -> [T] in
            (subview as? T).map { [$0] + descendants(of: subview, as: type) } ?? descendants(of: subview, as: type)
        }
    }

    private func button(titled title: String, in view: NSView) -> NSButton? {
        descendants(of: view, as: NSButton.self).first { $0.title == title }
    }

    private func layOut(_ bar: RecordingBarView) {
        bar.frame = NSRect(origin: .zero, size: bar.preferredSize)
        bar.layoutSubtreeIfNeeded()
    }

    @Test func readyBarOffersEveryCountdownAndThePickedSize() throws {
        let bar = RecordingBarView()
        bar.showReady(sizeText: "640 × 360")
        layOut(bar)

        let control = try #require(descendants(of: bar, as: NSSegmentedControl.self).first)
        #expect((0..<control.segmentCount).map { control.label(forSegment: $0) } == ["None", "3s", "5s", "10s"])
        #expect(control.selectedSegment == 0)
        let labels = descendants(of: bar, as: NSTextField.self).map(\.stringValue)
        #expect(labels.contains("640 × 360"))
        #expect(bar.preferredSize.width > 200 && bar.preferredSize.height > 24)
    }

    @Test func recordButtonReportsTheChosenCountdown() throws {
        let bar = RecordingBarView()
        bar.showReady(sizeText: "640 × 360")
        layOut(bar)
        var chosen: [RecordingCountdownChoice] = []
        bar.onRecord = { chosen.append($0) }
        let control = try #require(descendants(of: bar, as: NSSegmentedControl.self).first)
        let record = try #require(button(titled: "Record", in: bar))

        record.performClick(nil)
        control.selectedSegment = 2
        record.performClick(nil)
        control.selectedSegment = 3
        record.performClick(nil)

        #expect(chosen == [.none, .five, .ten])
    }

    @Test func cancelAndStopButtonsReachTheSession() throws {
        let bar = RecordingBarView()
        bar.showReady(sizeText: "640 × 360")
        layOut(bar)
        var cancels = 0, stops = 0
        bar.onCancel = { cancels += 1 }
        bar.onStop = { stops += 1 }

        try #require(button(titled: "Cancel", in: bar)).performClick(nil)
        try #require(button(titled: "Stop", in: bar)).performClick(nil)

        #expect(cancels == 1 && stops == 1)
    }

    @Test func eachPhaseShowsOnlyItsOwnControls() throws {
        let bar = RecordingBarView()
        bar.showReady(sizeText: "100 × 100")
        let ready = bar.preferredSize
        let control = try #require(descendants(of: bar, as: NSSegmentedControl.self).first)
        #expect(!control.isHiddenOrHasHiddenAncestor)

        bar.showCountdown(remaining: 3)
        #expect(control.isHiddenOrHasHiddenAncestor)
        #expect(descendants(of: bar, as: NSTextField.self).contains { $0.stringValue == "Starts in 3…" })

        bar.showRecording(elapsed: "00:07")
        #expect(descendants(of: bar, as: NSTextField.self).contains { $0.stringValue == "00:07" })
        bar.updateElapsed("00:08")
        #expect(descendants(of: bar, as: NSTextField.self).contains { $0.stringValue == "00:08" })
        #expect(bar.preferredSize.width < ready.width)
    }

    // MARK: Chrome, keyboard and accessibility

    private final class Options {
        var value = RecordingDisplayOptions()
    }

    private func chrome(_ options: Options = Options(), glass: Bool = false) -> RecordingChromeEnvironment {
        RecordingChromeEnvironment(displayOptions: { options.value }, announce: { _ in }, supportsLiquidGlass: glass)
    }

    private func keyEvent(_ keyCode: UInt16, characters: String = "", flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    @Test func returnRecordsEscapeCancelsAndCommandPeriodStops() {
        let bar = RecordingBarView(chrome: chrome())
        #expect(bar.recordButton.keyEquivalent == "\r")
        #expect(bar.cancelButton.keyEquivalent == "\u{1b}")
        #expect(bar.countdownCancelButton.keyEquivalent == "\u{1b}")
        // Return must not stop a recording by accident while the bar still has keyboard focus.
        #expect(bar.stopButton.keyEquivalent == "." && bar.stopButton.keyEquivalentModifierMask == .command)
    }

    @Test func theKeyEquivalentsReachTheSessionThroughTheWindow() throws {
        let bar = RecordingBarView(chrome: chrome())
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 600, height: 44)),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = bar
        bar.showReady(sizeText: "640 × 360")
        layOut(bar)
        var events: [String] = []
        bar.onRecord = { _ in events.append("record") }
        bar.onCancel = { events.append("cancel") }
        bar.onStop = { events.append("stop") }

        #expect(window.performKeyEquivalent(with: try keyEvent(36, characters: "\r")))
        #expect(window.performKeyEquivalent(with: try keyEvent(53, characters: "\u{1b}")))
        bar.showRecording(elapsed: "00:01")
        layOut(bar)
        #expect(window.performKeyEquivalent(with: try keyEvent(47, characters: ".", flags: .command)))
        #expect(events == ["record", "cancel", "stop"])
    }

    @Test func everyControlHasALabelAHelpTextAndATooltip() throws {
        let bar = RecordingBarView(chrome: chrome())
        for button in [bar.recordButton, bar.cancelButton, bar.countdownCancelButton, bar.stopButton] {
            #expect(!(button.accessibilityLabel() ?? "").isEmpty)
            #expect(!(button.accessibilityHelp() ?? "").isEmpty)
            #expect(!(button.toolTip ?? "").isEmpty)
        }
        #expect(bar.stopButton.accessibilityLabel() == "Stop recording")

        let control = bar.countdownControl
        #expect(!(control.accessibilityLabel() ?? "").isEmpty)
        #expect(!(control.accessibilityHelp() ?? "").isEmpty)
        #expect((0..<control.segmentCount).map { control.toolTip(forSegment: $0) }
                == ["No countdown", "3 seconds", "5 seconds", "10 seconds"])
        #expect(bar.accessibilityLabel() == "Screen recording controls")
    }

    private func spoken(_ value: Any?) -> String? { value as? String }

    @Test func elapsedTimeAndSizeAreReadableAloud() {
        let bar = RecordingBarView(chrome: chrome())
        bar.showReady(sizeText: "640 × 360")
        let size: NSTextField? = descendants(of: bar, as: NSTextField.self).first { $0.stringValue == "640 × 360" }
        let sizeValue = spoken(size?.accessibilityValue())
        #expect(sizeValue == "640 by 360 points")

        bar.showRecording(elapsed: "01:05", spoken: "1 minute, 5 seconds")
        #expect(bar.elapsedLabel.accessibilityLabel() == "Elapsed time")
        let first = spoken(bar.elapsedLabel.accessibilityValue())
        #expect(first == "1 minute, 5 seconds")
        bar.updateElapsed("01:06", spoken: "1 minute, 6 seconds")
        let second = spoken(bar.elapsedLabel.accessibilityValue())
        #expect(second == "1 minute, 6 seconds")
        bar.updateElapsed("01:07")
        let third = spoken(bar.elapsedLabel.accessibilityValue())
        #expect(third == "01:07")
    }

    @Test func theCountdownIsSpokenInFull() {
        let bar = RecordingBarView(chrome: chrome())
        bar.showCountdown(remaining: 5)
        let label: NSTextField? = descendants(of: bar, as: NSTextField.self).first { $0.stringValue == "Starts in 5…" }
        let value = spoken(label?.accessibilityValue())
        #expect(value == "Recording starts in 5")
    }

    @Test func theBarIsAlwaysFortyFourPointsHighAndEveryButtonIsBigEnoughToHit() {
        let bar = RecordingBarView(chrome: chrome())
        for show in [{ bar.showReady(sizeText: "640 × 360") }, { bar.showCountdown(remaining: 3) },
                     { bar.showRecording(elapsed: "00:01") }] {
            show()
            layOut(bar)
            #expect(bar.preferredSize.height == RecordingChromeTokens.barHeight)
        }
        bar.showReady(sizeText: "640 × 360")
        layOut(bar)
        for button in [bar.recordButton, bar.cancelButton, bar.stopButton] {
            #expect(button.fittingSize.height >= RecordingChromeTokens.minimumHitTarget)
            #expect(button.fittingSize.width >= RecordingChromeTokens.minimumHitTarget)
        }
    }

    @Test func buttonsUseTheStyleOfTheSystemAndOnlyRecordIsTinted() {
        let bar = RecordingBarView(chrome: chrome(glass: false))
        #expect([bar.recordButton, bar.cancelButton, bar.stopButton].allSatisfy { $0.bezelStyle == .rounded })
        #expect(bar.recordButton.bezelColor == .systemRed)
        #expect(bar.cancelButton.bezelColor == nil && bar.stopButton.bezelColor == nil)

        let glass = RecordingBarView(chrome: chrome(glass: true))
        let expected = RecordingButtonStyle.bezelStyle(supportsLiquidGlass: true)
        #expect(glass.recordButton.bezelStyle == expected && glass.cancelButton.bezelStyle == expected)
    }

    @Test func theRecordingDotPulsesUnlessReduceMotionIsOn() {
        let options = Options()
        let bar = RecordingBarView(chrome: chrome(options))
        #expect(bar.dot.isPulsing)
        #expect(!bar.dot.isAccessibilityElement())

        options.value.reduceMotion = true
        bar.refreshChrome()
        #expect(!bar.dot.isPulsing)

        options.value.reduceMotion = false
        bar.refreshChrome()
        #expect(bar.dot.isPulsing)

        options.value.reduceMotion = true
        #expect(!RecordingBarView(chrome: chrome(options)).dot.isPulsing)
    }

    @Test func theSurfaceFollowsReduceTransparencyAndIncreaseContrastLive() {
        let options = Options()
        let bar = RecordingBarView(chrome: chrome(options))
        #expect(bar.chromeStyle.surface == .material)
        #expect(bar.surfaceView is NSVisualEffectView)

        options.value.reduceTransparency = true
        bar.refreshChrome()
        #expect(bar.chromeStyle.surface == .opaque)
        #expect(!(bar.surfaceView is NSVisualEffectView))

        options.value.increaseContrast = true
        bar.refreshChrome()
        #expect(bar.chromeStyle.strongBorder)

        options.value = RecordingDisplayOptions()
        bar.refreshChrome()
        #expect(bar.chromeStyle == RecordingChromeStyle.resolve(supportsLiquidGlass: false, options: options.value))
    }

    @Test func theBarPanelStaysOutOfTheRecordingAndTheRecordedApp() {
        let panel = RecordingBarPanel(chrome: chrome())
        #expect(panel.sharingType == .none)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.level.rawValue > NSWindow.Level.floating.rawValue)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.isOpaque && panel.backgroundColor == .clear && panel.hasShadow)
        #expect(panel.accessibilityLabel() == "Screen recording controls")
    }

    @Test func escapeCancelsOnlyBeforeTheRecordingStarts() {
        let panel = RecordingBarPanel(chrome: chrome())
        var cancels = 0
        panel.onCancel = { cancels += 1 }
        panel.apply(.ready(sizeText: "100 × 100"))
        panel.cancelOperation(nil)
        panel.apply(.countdown(remaining: 3))
        panel.cancelOperation(nil)
        #expect(cancels == 2)
        panel.apply(.recording(elapsed: "00:01", spoken: "1 second"))
        panel.cancelOperation(nil)
        #expect(cancels == 2)
    }

    @Test func arrowKeysOnTheReadyBarNudgeTheRegion() throws {
        let panel = RecordingBarPanel(chrome: chrome())
        panel.apply(.ready(sizeText: "100 × 100"))
        var nudges: [(RegionNudge, CGFloat)] = []
        panel.onNudge = { nudges.append(($0, $1)) }

        panel.keyDown(with: try keyEvent(123))
        panel.keyDown(with: try keyEvent(124, flags: .shift))
        panel.keyDown(with: try keyEvent(125, flags: .option))
        panel.keyDown(with: try keyEvent(126, flags: [.option, .shift]))

        #expect(nudges.map(\.0) == [.moveLeft, .moveRight, .taller, .shorter])
        #expect(nudges.map(\.1) == [1, 10, 1, 10])
    }

    @Test func theFrameIsDescribedAndAdjustableThroughVoiceOver() throws {
        let frame = RecordingFrameView()
        frame.region = CGRect(x: 10, y: 20, width: 640, height: 360)
        frame.mode = .adjusting
        frame.refreshAccessibility()
        var nudges: [RegionNudge] = []
        frame.onNudge = { nudges.append($0) }

        let role: NSAccessibility.Role? = frame.accessibilityRole()
        let label: String? = frame.accessibilityLabel()
        let value = spoken(frame.accessibilityValue())
        let help: String = frame.accessibilityHelp() ?? ""
        #expect(frame.isAccessibilityElement())
        #expect(role == .group)
        #expect(label == "Recording area")
        #expect(value == "640 by 360 points")
        #expect(!help.isEmpty)

        let actions: [NSAccessibilityCustomAction] = try #require(frame.accessibilityCustomActions())
        let names: [String] = actions.map { $0.name }
        let expectedNames: [String] = RegionNudge.allCases.map { $0.title }
        #expect(names == expectedNames)
        let wider = try #require(actions.first { $0.name == "Make wider" })
        let handler = try #require(wider.handler)
        let performed = handler()
        #expect(performed)
        #expect(nudges == [.wider])

        frame.mode = .recording
        frame.refreshAccessibility()
        let recordingValue = spoken(frame.accessibilityValue())
        let remaining: [NSAccessibilityCustomAction] = frame.accessibilityCustomActions() ?? []
        let recordingHelp: String? = frame.accessibilityHelp()
        #expect(recordingValue == "640 by 360 points, recording")
        #expect(remaining.isEmpty)
        #expect(recordingHelp == nil)
    }

    @Test func theFramePanelOnlyTakesTheMouseWhileItIsBeingAdjusted() {
        let panel = RecordingFramePanel(primaryHeight: 900, displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let region = CGRect(x: 100, y: 100, width: 400, height: 300)
        panel.setRegion(region, mode: .adjusting)
        #expect(!panel.ignoresMouseEvents)
        panel.setRegion(region, mode: .locked)
        #expect(panel.ignoresMouseEvents)
        panel.setRegion(region, mode: .recording)
        #expect(panel.ignoresMouseEvents && panel.sharingType == .none && !panel.canBecomeKey)
    }

    @Test func theCountdownPanelIsGlassThatNeverTakesInput() {
        let options = Options()
        let panel = RecordingCountdownPanel(chrome: chrome(options))
        #expect(panel.ignoresMouseEvents && panel.sharingType == .none && !panel.canBecomeKey)
        #expect(panel.chromeStyle.surface == .material)
        options.value.reduceTransparency = true
        panel.refreshChrome()
        #expect(panel.chromeStyle.surface == .opaque)
        #expect(panel.accessibilityLabel() == "Countdown")
    }
}
