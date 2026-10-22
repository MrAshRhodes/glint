import AppKit
import Testing
@testable import Glint

@Suite("URL capture consent")
@MainActor
struct URLCaptureHandlerTests {
    @Test(arguments: ["capture-area", "capture-window", "capture-fullscreen", "capture-text", "repeat-last"])
    func urlRoutingRequiresFreshConsentForEveryMode(action: String) throws {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        let modes: [String: CapturePipeline.Mode] = [
            "capture-area": .area, "capture-window": .window, "capture-fullscreen": .fullscreen,
            "capture-text": .text, "repeat-last": .repeatLast,
        ]
        let expected = try #require(modes[action])
        let url = try #require(URL(string: "glint://\(action)?approved=true&confirm=false"))
        var response = NSApplication.ModalResponse.alertFirstButtonReturn
        var prompts: [String] = []
        var starts: [CapturePipeline.Mode] = []
        delegate.urlCaptureHandler = URLCaptureHandler(services: .init(
            confirm: {
                #expect(starts.isEmpty)
                prompts.append($0.rawValue)
                return response
            },
            isCaptureBusy: { false },
            startCapture: { starts.append($0) },
            reject: { Issue.record("An idle request must reach confirmation") }
        ))

        delegate.application(application, open: [url])
        #expect(prompts == [action])
        #expect(starts.isEmpty)

        response = .alertSecondButtonReturn
        delegate.application(application, open: [url])
        #expect(prompts == [action, action])
        #expect(starts == [expected])

        starts.removeAll()
        response = .alertFirstButtonReturn
        delegate.application(application, open: [url])
        #expect(prompts == [action, action, action])
        #expect(starts.isEmpty)
    }

    @Test func onlyExplicitApprovalStartsCapture() {
        let deniedResponses: [NSApplication.ModalResponse] = [
            .alertFirstButtonReturn, .alertThirdButtonReturn, .cancel, .abort, .stop,
        ]
        for response in deniedResponses {
            let handler = URLCaptureHandler(services: .init(
                confirm: { _ in response },
                isCaptureBusy: { false },
                startCapture: { _ in Issue.record("A non-affirmative response started capture") },
                reject: { Issue.record("An idle request must reach confirmation") }
            ))
            #expect(handler.handle(action: "capture-fullscreen"))
        }
    }

    @Test func reentrantRequestsAreRejectedAndNotReplayed() {
        var prompts = 0
        var rejections = 0
        var starts: [CapturePipeline.Mode] = []
        var reenter: (() -> Void)?
        let handler = URLCaptureHandler(services: .init(
            confirm: { _ in
                prompts += 1
                #expect(starts.isEmpty)
                reenter?()
                return .alertSecondButtonReturn
            },
            isCaptureBusy: { false },
            startCapture: { starts.append($0) },
            reject: { rejections += 1 }
        ))
        reenter = { [weak handler] in
            #expect(handler?.handle(action: "capture-text") == true)
        }

        #expect(handler.handle(action: "capture-fullscreen"))
        #expect(prompts == 1)
        #expect(rejections == 1)
        #expect(starts == [.fullscreen])

        reenter = nil
        starts.removeAll()
        #expect(handler.handle(action: "capture-text"))
        #expect(prompts == 2)
        #expect(starts == [.text])
    }

    @Test func busyRequestsAreRejectedBeforePromptAndAfterApproval() {
        var busy = true
        var prompts = 0
        var rejections = 0
        var starts = 0
        var becomesBusyDuringPrompt = true
        let handler = URLCaptureHandler(services: .init(
            confirm: { _ in
                prompts += 1
                busy = becomesBusyDuringPrompt
                return .alertSecondButtonReturn
            },
            isCaptureBusy: { busy },
            startCapture: { _ in starts += 1 },
            reject: { rejections += 1 }
        ))

        #expect(handler.handle(action: "capture-area"))
        #expect(prompts == 0)
        #expect(rejections == 1)
        #expect(starts == 0)

        busy = false
        #expect(handler.handle(action: "capture-window"))
        #expect(prompts == 1)
        #expect(rejections == 2)
        #expect(starts == 0)

        busy = false
        becomesBusyDuringPrompt = false
        #expect(handler.handle(action: "repeat-last"))
        #expect(prompts == 2)
        #expect(starts == 1)
    }

    @Test func batchURLsCannotShareApprovalOrQueueDuringCapture() throws {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        let first = try #require(URL(string: "glint://capture-fullscreen"))
        let second = try #require(URL(string: "glint://repeat-last"))
        var busy = false
        var prompts = 0
        var rejections = 0
        var starts: [CapturePipeline.Mode] = []
        delegate.urlCaptureHandler = URLCaptureHandler(services: .init(
            confirm: { _ in prompts += 1; return .alertSecondButtonReturn },
            isCaptureBusy: { busy },
            startCapture: { starts.append($0); busy = true },
            reject: { rejections += 1 }
        ))

        delegate.application(application, open: [first, second])
        #expect(prompts == 1)
        #expect(starts == [.fullscreen])
        #expect(rejections == 1)

        busy = false
        #expect(starts == [.fullscreen])
        delegate.application(application, open: [second])
        #expect(prompts == 2)
        #expect(starts == [.fullscreen, .repeatLast])
    }

    @Test func cancellingOneBatchURLDoesNotAuthorizeTheNext() throws {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        let first = try #require(URL(string: "glint://capture-fullscreen"))
        let second = try #require(URL(string: "glint://capture-text"))
        var prompts: [URLCaptureHandler.Action] = []
        var starts: [CapturePipeline.Mode] = []
        delegate.urlCaptureHandler = URLCaptureHandler(services: .init(
            confirm: {
                prompts.append($0)
                return prompts.count == 1 ? .alertFirstButtonReturn : .alertSecondButtonReturn
            },
            isCaptureBusy: { false },
            startCapture: { starts.append($0) },
            reject: { Issue.record("An idle request must reach confirmation") }
        ))

        delegate.application(application, open: [first, second])
        #expect(prompts == [.fullscreen, .text])
        #expect(starts == [.text])
    }

    @Test(arguments: ["glint://CAPTURE-FULLSCREEN", "glint:capture-fullscreen", "glint:/capture-fullscreen"])
    func existingActionNormalizationStillRequiresConsent(string: String) throws {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        var prompts: [URLCaptureHandler.Action] = []
        delegate.urlCaptureHandler = URLCaptureHandler(services: .init(
            confirm: { prompts.append($0); return .alertFirstButtonReturn },
            isCaptureBusy: { false },
            startCapture: { _ in Issue.record("A cancelled URL started capture") },
            reject: { Issue.record("An idle request must reach confirmation") }
        ))
        delegate.application(application, open: [try #require(URL(string: string))])
        #expect(prompts == [.fullscreen])
    }

    @Test func nonCaptureActionsAreNotConsumedAndOtherSchemesDoNotCapture() throws {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        let handler = URLCaptureHandler(services: .init(
            confirm: { _ in Issue.record("A non-capture URL requested confirmation"); return .abort },
            isCaptureBusy: { Issue.record("A non-capture URL checked capture state"); return false },
            startCapture: { _ in Issue.record("A non-capture URL started capture") },
            reject: { Issue.record("A non-capture URL was rejected as a capture") }
        ))
        delegate.urlCaptureHandler = handler
        for action in ["open", "preset", "preferences", "capture-unknown", ""] {
            #expect(!handler.handle(action: action))
        }
        for string in ["https://capture-fullscreen", "other://capture-text", "glint://open", "glint://preset"] {
            delegate.application(application, open: [try #require(URL(string: string))])
        }
    }

    @Test func nativeAlertDefaultsToCancelAndExplainsOneTimeConsent() {
        _ = NSApplication.shared
        for action in URLCaptureHandler.Action.allCases {
            let alert = URLCaptureHandler.confirmationAlert(for: action)
            alert.layout()
            #expect(alert.messageText == "Allow \(action.title)?")
            #expect(alert.informativeText.contains("external app or link"))
            #expect(alert.informativeText.contains("raw history"))
            #expect(alert.informativeText.contains("clipboard"))
            #expect(alert.informativeText.contains("one capture only"))
            #expect(alert.buttons.map(\.title) == ["Cancel", "Allow Capture"])
            #expect(alert.buttons.map(\.keyEquivalent) == ["\r", ""])
            #expect(alert.window.defaultButtonCell === alert.buttons[0].cell)
            #expect(!alert.showsSuppressionButton)
        }
    }
}
