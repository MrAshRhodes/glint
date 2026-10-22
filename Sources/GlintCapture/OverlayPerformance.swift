import os

@MainActor
enum OverlayPerformance {
    static let signposter = OSSignposter(subsystem: "io.github.mrashrhodes.glint", category: "SelectionOverlay")

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
}
