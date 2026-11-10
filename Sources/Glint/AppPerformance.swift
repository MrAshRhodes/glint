import Darwin
import Foundation
import os

/// Signposts for launch and idle work, so launch-to-shortcut-ready, Settings construction, updater setup,
/// menu opening and polling can be measured separately (CONTRIBUTING.md, "Profiling launch and idle work").
/// Nothing is recorded unless a collector is attached, and no paths, shortcuts or user content are attached.
enum AppPerformance {
    private static let subsystem = "io.github.mrashrhodes.glint"
    static let launch = OSSignposter(subsystem: subsystem, category: "Launch")
    static let idle = OSSignposter(subsystem: subsystem, category: "IdleWork")

    /// Times `body` as an interval named `name` in `signposter`.
    static func measure<T>(_ name: StaticString, in signposter: OSSignposter = launch, _ body: () throws -> T) rethrows -> T {
        guard signposter.isEnabled else { return try body() }
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    /// Marks a launch milestone with the time since the process was created.
    static func milestone(_ name: StaticString) {
        guard launch.isEnabled, let elapsed = millisecondsSinceProcessStart() else { return }
        launch.emitEvent(name, id: launch.makeSignpostID(), "\(elapsed, format: .fixed(precision: 1)) ms since process start")
    }

    static func millisecondsSinceProcessStart(now: Date = Date()) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&query, UInt32(query.count), &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        let startedAt = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        return (now.timeIntervalSince1970 - startedAt) * 1000
    }
}
