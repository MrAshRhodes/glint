import os

/// Signposts for the capture path beyond the selection overlay: global hotkey, permission and content queries, pixel
/// grab, raw write, render, encode, pasteboard and thumbnail, then the editor's first preview, copy and drag. They
/// share the overlay's subsystem (`io.github.mrashrhodes.glint`) under the `Capture` category; CONTRIBUTING.md
/// explains how to collect and read them.
///
/// Metadata is limited to a trigger, a mode label and durations. Never record cursor or window coordinates, window
/// titles, file paths or image content. A handle is `nil` when signposts are disabled, so an unobserved call costs a
/// flag check.
public enum CaptureSignposts {
    static let signposter = OSSignposter(subsystem: "io.github.mrashrhodes.glint", category: "Capture")

    /// What started a capture; recorded on `CaptureTotal`.
    public enum Trigger: String, Sendable { case hotkey, menu, url, timer }

    /// How an interval ended. Only `completed` intervals are latency samples.
    public enum Outcome: Sendable, Equatable {
        case completed, cancelled, failed

        /// Cancellation, however it surfaces, versus a real failure.
        public init(error: any Error) { self = error is CancellationError ? .cancelled : .failed }

        fileprivate var label: String? {
            switch self {
            case .completed: nil
            case .cancelled: "cancelled"
            case .failed: "failed"
            }
        }
    }

    /// An open interval. `Sendable`, so it can cross actors and detached tasks without exposing `os`.
    public struct Interval: Sendable {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
    }

    public static func begin(_ name: StaticString) -> Interval? {
        guard signposter.isEnabled else { return nil }
        return Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()))
    }

    /// Ends an interval started by one of the `begin` functions; a `nil` handle is ignored.
    public static func end(_ interval: Interval?, _ outcome: Outcome = .completed) {
        guard let interval else { return }
        if let label = outcome.label {
            signposter.endInterval(interval.name, interval.state, "\(label, privacy: .public)")
        } else {
            signposter.endInterval(interval.name, interval.state)
        }
    }

    /// Times `body`, ending the interval as `cancelled` or `failed` if it throws.
    public static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let interval = begin(name)
        do {
            let result = try body()
            end(interval)
            return result
        } catch {
            end(interval, Outcome(error: error))
            throw error
        }
    }

    public static func measure<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let interval = begin(name)
        do {
            let result = try await body()
            end(interval)
            return result
        } catch {
            end(interval, Outcome(error: error))
            throw error
        }
    }

    /// `CaptureTotal`: the whole capture task, tagged with what started it and which mode. It includes the time the
    /// user spends choosing, so read latency from the stage intervals, not from its duration.
    public static func beginCapture(trigger: Trigger, mode: String) -> Interval? {
        guard signposter.isEnabled else { return nil }
        let state = signposter.beginInterval(
            "CaptureTotal", id: signposter.makeSignpostID(),
            "trigger=\(trigger.rawValue, privacy: .public) mode=\(mode, privacy: .public)")
        return Interval(name: "CaptureTotal", state: state)
    }

    /// `QueueDelay`: from the hotkey callback's arrival to the main actor handling it. `eventAgeSeconds` is how long
    /// the key event had already existed when the callback ran, read from Carbon's own event clock.
    public static func beginQueueDelay(eventAgeSeconds: Double) -> Interval? {
        guard signposter.isEnabled else { return nil }
        let state = signposter.beginInterval(
            "QueueDelay", id: signposter.makeSignpostID(),
            "eventAgeMs=\(eventAgeSeconds * 1000, format: .fixed(precision: 3), privacy: .public)")
        return Interval(name: "QueueDelay", state: state)
    }
}
