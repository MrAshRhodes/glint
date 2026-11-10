import os

@MainActor
enum OverlayPerformance {
    static let signposter = OSSignposter(subsystem: "io.github.mrashrhodes.glint", category: "SelectionOverlay")
    /// The `Capture` category of `CaptureSignposts` (GlintCore). This file also compiles on its own for
    /// Scripts/benchmark-overlay.sh, so it cannot import GlintCore; `SnapTargets` is the one capture interval it emits.
    private static let captureSignposter = OSSignposter(subsystem: "io.github.mrashrhodes.glint", category: "Capture")

    static func begin(_ name: StaticString) -> OSSignpostIntervalState? {
        guard signposter.isEnabled else { return nil }
        return signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState?, cancelled: Bool = false) {
        guard let state else { return }
        if cancelled {
            signposter.endInterval(name, state, "cancelled")
        } else {
            signposter.endInterval(name, state)
        }
    }

    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let interval = begin(name)
        defer { end(name, interval) }
        return try body()
    }

    /// Like `measure`, in the `Capture` category.
    static func measureCapture<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        guard captureSignposter.isEnabled else { return try body() }
        let state = captureSignposter.beginInterval(name, id: captureSignposter.makeSignpostID())
        defer { captureSignposter.endInterval(name, state) }
        return try body()
    }
}
