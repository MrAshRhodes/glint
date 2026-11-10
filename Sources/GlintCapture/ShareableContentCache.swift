import CoreGraphics
import Foundation
import os
import ScreenCaptureKit

/// A snapshot of what ScreenCaptureKit can capture (displays, applications and windows), kept between captures so a
/// hotkey does not wait for the query. It holds metadata only, never pixels: pixels are grabbed only for an explicit
/// capture (CONTRIBUTING.md).
final class ContentCache<Snapshot>: @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant

    struct Entry {
        let snapshot: Snapshot
        /// Different for every result, so a caller can tell whether the cache still holds the one it read.
        let serial: Int
        /// When the query began: the snapshot lists nothing that appeared after it.
        let startedAt: Instant
    }

    private struct InFlight {
        let generation: Int
        let task: Task<Entry, Error>
    }

    private struct State {
        var entry: Entry?
        var generation = 0
        var serial = 0
        var inFlight: InFlight?
    }

    private let lock = NSLock()
    private var state = State()
    private let query: @Sendable () async throws -> Snapshot
    let now: @Sendable () -> Instant

    init(now: @escaping @Sendable () -> Instant = { .now },
         query: @escaping @Sendable () async throws -> Snapshot) {
        self.now = now
        self.query = query
    }

    private func locked<Result>(_ body: (inout State) -> Result) -> Result {
        lock.withLock { body(&state) }
    }

    /// The kept snapshot, if there is one.
    var current: Entry? { locked { $0.entry } }

    /// Forgets the snapshot because what it described may have changed. A query that started before this call
    /// cannot put its result back, and no caller joins it.
    func invalidate() {
        locked {
            $0.generation += 1
            $0.entry = nil
            $0.inFlight = nil
        }
    }

    /// Forgets `stale` after a capture failed with it, unless a newer snapshot has replaced it already.
    func discard(_ stale: Entry) {
        locked { state in
            if state.entry?.serial == stale.serial { state.entry = nil }
        }
    }

    /// A snapshot from a query made now, which also becomes the kept one. A caller arriving while a query is under
    /// way waits for it instead of starting another, so what it gets may have begun earlier (see `Entry.startedAt`).
    func fresh() async throws -> Entry {
        let task = locked { state -> Task<Entry, Error> in
            let generation = state.generation
            if let inFlight = state.inFlight, inFlight.generation == generation { return inFlight.task }
            let startedAt = now()
            let task = Task<Entry, Error> {
                do {
                    return store(try await query(), generation: generation, startedAt: startedAt)
                } catch {
                    finishFailedQuery(generation: generation)
                    throw error
                }
            }
            state.inFlight = InFlight(generation: generation, task: task)
            return task
        }
        let entry = try await task.value
        try Task.checkCancellation()
        return entry
    }

    /// The snapshot for a request made at `requestedAt`: the kept one when `serves` accepts it, otherwise one queried
    /// for the request. `serves` is told whether the snapshot predates the request, which only then can lack a window
    /// that opened since. A query joined on the way began before the request, so it is offered to `serves` as well and
    /// replaced by a newer one if it cannot serve; no query that predates the request is still running by then.
    func snapshot(for requestedAt: Instant,
                  serves: (Entry, _ predatesRequest: Bool) -> Bool) async throws -> (entry: Entry, isCached: Bool) {
        if let kept = current {
            let predates = kept.startedAt < requestedAt
            if serves(kept, predates) { return (kept, predates) }
        }
        let queried = try await fresh()
        let predates = queried.startedAt < requestedAt
        if !predates || serves(queried, true) { return (queried, predates) }
        let newer = try await fresh()
        return (newer, newer.startedAt < requestedAt)
    }

    /// Fills an empty cache. A failure is not reported: the next capture queries for itself.
    func warm() async {
        guard current == nil else { return }
        _ = try? await fresh()
    }

    private func store(_ snapshot: Snapshot, generation: Int, startedAt: Instant) -> Entry {
        locked { state in
            state.serial += 1
            let entry = Entry(snapshot: snapshot, serial: state.serial, startedAt: startedAt)
            guard state.generation == generation else { return entry }
            state.entry = entry
            state.inFlight = nil
            return entry
        }
    }

    private func finishFailedQuery(generation: Int) {
        locked { state in
            if state.inFlight?.generation == generation { state.inFlight = nil }
        }
    }
}

/// The process-wide cache of ScreenCaptureKit's shareable content.
enum ShareableContentCache {
    typealias Entry = ContentCache<SCShareableContent>.Entry

    static let shared = ContentCache<SCShareableContent> { try await WindowEnumerator.shareableContent() }

    /// Dropped whenever the screens or the session may have changed, then refilled by `CapturePrewarmer`.
    static func invalidate() { shared.invalidate() }
}

/// What a snapshot says that decides whether it can stand in for a new query.
struct ContentFacts {
    static let unknownOwner: pid_t = -1

    /// Size in points of every display the snapshot lists.
    var displaySizes: [CGDirectDisplayID: CGSize] = [:]
    var ownApplicationListed = false
    /// Owning process of every window the snapshot lists.
    var windowOwners: [CGWindowID: pid_t] = [:]
}

extension ContentFacts {
    init(_ content: SCShareableContent, ownPID: pid_t) {
        displaySizes = Dictionary(content.displays.map { ($0.displayID, $0.frame.size) },
                                  uniquingKeysWith: { first, _ in first })
        ownApplicationListed = content.applications.contains { $0.processID == ownPID }
        windowOwners = Dictionary(content.windows.map { ($0.windowID, $0.owningApplication?.processID ?? Self.unknownOwner) },
                                  uniquingKeysWith: { first, _ in first })
    }
}

/// How a capture filter leaves Glint's windows out of the pixels.
enum ContentExclusion: Equatable {
    /// Everything of this application, including windows that opened after the snapshot.
    case ownApplication
    /// Exactly these windows of the snapshot.
    case windows(Set<CGWindowID>)
}

/// Whether a kept snapshot can serve a capture without a new query. A snapshot it cannot serve costs a query, never a
/// wrong capture.
enum ContentReuse {
    /// Every display the capture needs is listed, at the size it has now. A display that came, went or changed
    /// resolution since the snapshot is not.
    static func lists(_ displays: [DisplayInfo], in facts: ContentFacts) -> Bool {
        displays.allSatisfy { display in
            guard let size = facts.displaySizes[display.id] else { return false }
            return abs(size.width - display.frame.width) < 1 && abs(size.height - display.frame.height) < 1
        }
    }

    /// How a snapshot queried for this very capture leaves windows out. It lists every window that is on screen, so a
    /// named window it does not list is not on screen, and Glint's windows that open after it are still covered by
    /// excluding the application.
    static func exclusion(for options: CaptureOptions, in facts: ContentFacts, ownPID: pid_t) -> ContentExclusion {
        let namedAreGlints = options.excludedWindowIDs.allSatisfy { id in facts.windowOwners[id].map { $0 == ownPID } ?? true }
        if options.excludeOwnWindows, facts.ownApplicationListed, namedAreGlints { return .ownApplication }
        let listed = facts.windowOwners.filter { options.excludesWindow($0.key, pid: $0.value, ownPID: ownPID) }
        return .windows(Set(listed.keys))
    }

    /// How a kept snapshot leaves windows out; nil when it cannot do that reliably, because it cannot list a window
    /// that opened after it and so only excluding the application is safe for Glint's windows.
    /// `liveOwner` looks up the process that owns a window the snapshot does not list.
    static func cachedExclusion(for options: CaptureOptions, in facts: ContentFacts, ownPID: pid_t,
                                liveOwner: (CGWindowID) -> pid_t?) -> ContentExclusion? {
        let named = options.excludedWindowIDs
        if options.excludeOwnWindows {
            guard facts.ownApplicationListed,
                  named.allSatisfy({ (facts.windowOwners[$0] ?? liveOwner($0)) == ownPID }) else { return nil }
            return .ownApplication
        }
        guard named.allSatisfy({ facts.windowOwners[$0] != nil }) else { return nil }
        return .windows(named)
    }
}

/// Cache hits and misses as signpost events (subsystem `io.github.mrashrhodes.glint`, category `Capture`), so the
/// speed-up can be measured on real hardware.
enum ContentCacheSignposts {
    private static let signposter = OSSignposter(subsystem: "io.github.mrashrhodes.glint", category: "Capture")

    static func event(_ name: StaticString, _ detail: @autoclosure () -> String) {
        guard signposter.isEnabled else { return }
        let text = detail()
        signposter.emitEvent(name, "\(text, privacy: .public)")
    }
}
