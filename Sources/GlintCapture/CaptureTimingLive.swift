import CoreGraphics
import Foundation
import GlintCore

extension CaptureTiming.Environment {
    @MainActor
    static var live: CaptureTiming.Environment {
        CaptureTiming.Environment(
            permission: { ScreenRecordingPermission.state },
            diagnose: { await CaptureDiagnostics.run() },
            makeRunner: { CaptureTiming.LiveRunner(allowScreenCapture: $0) },
            launchColdProbe: { await CaptureTiming.launchColdProbe(allowScreenCapture: $0) }
        )
    }
}

extension CaptureTiming {
    /// The real capture-to-export calls. Pixels are only read when `allowScreenCapture` is set.
    @MainActor
    final class LiveRunner: StageRunner {
        private let allowScreenCapture: Bool
        private let options: CaptureOptions
        private var content: ImageGrabber.ScreenContent?
        private var grabbed: (image: CGImage, scale: CGFloat)?
        private var synthetic: CGImage?

        init(allowScreenCapture: Bool) {
            self.allowScreenCapture = allowScreenCapture
            var options = CaptureOptions()
            options.allowScreencaptureFallback = false
            self.options = options
        }

        // Built outside the timed execution, on every path that ends up rendering it: no consent, no permission,
        // or a grab that failed.
        func prepare(for stage: Stage) async {
            if stage == .renderAndEncode, grabbed == nil, synthetic == nil { synthetic = ExportTiming.syntheticFrame() }
        }

        var frame: Report.Frame {
            if let grabbed {
                return Report.Frame(width: grabbed.image.width, height: grabbed.image.height, source: "display")
            }
            return Report.Frame(width: ExportTiming.syntheticWidth, height: ExportTiming.syntheticHeight, source: "synthetic")
        }

        func run(_ stage: Stage) async throws {
            switch stage {
            case .shareableContent:
                content = try await ImageGrabber.ScreenContent.current(options: options)
            case .displayGrab:
                guard allowScreenCapture else { throw CaptureError.permissionDenied }
                let displays = WindowEnumerator.displays()
                guard let content, let display = displays.first(where: \.isMain) ?? displays.first else {
                    throw CaptureError.noDisplay
                }
                let grab = try await content.grab(display.frame, display: display, options: options)
                grabbed = (grab.image, grab.scale)
            case .selectionSnapshot:
                _ = WindowEnumerator.selectionSnapshot()
            case .renderAndEncode:
                if let grabbed {
                    _ = try ExportTiming.renderAndEncode(grabbed.image, backingScale: grabbed.scale)
                } else if let synthetic {
                    _ = try ExportTiming.renderAndEncode(synthetic)
                } else {
                    throw CaptureError.failed("no frame")
                }
            }
        }
    }

    /// One new Glint process that runs every stage once and reports the timings, or nil when it fails or hangs.
    static func launchColdProbe(allowScreenCapture: Bool, timeout: Duration = .seconds(60)) async -> [Stage: Double]? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--timing-probe"] + (allowScreenCapture ? ["--allow-screen-capture"] : [])
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let deadline = ContinuousClock.now + timeout
        var timedOut = false
        while process.isRunning {
            if ContinuousClock.now >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        process.waitUntilExit()
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        guard !timedOut, process.terminationStatus == 0 else { return nil }
        return parseProbeOutput(data)
    }
}
