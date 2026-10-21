import AppKit
import Foundation

// CLI flags (--version, --diagnose, --render ...) run headless and exit before any UI starts.
if let code = MainActor.assumeIsolated({ CommandLine_.run(Array(CommandLine.arguments.dropFirst())) }) { exit(code) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
