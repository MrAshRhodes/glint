import CoreGraphics
import Foundation
import Testing
@testable import GlintCapture

private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    @discardableResult func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

/// Moves one second each time the cache reads it, so every query starts at a time of its own.
private final class SteppingClock: @unchecked Sendable {
    private let origin = ContinuousClock.now
    private let lock = NSLock()
    private var ticks = 0

    func now() -> ContinuousClock.Instant {
        lock.withLock {
            ticks += 1
            return origin + .seconds(ticks)
        }
    }

    func at(_ seconds: Double) -> ContinuousClock.Instant { origin + .seconds(seconds) }
}

@Suite("Shareable content cache", .timeLimit(.minutes(1)))
struct ShareableContentCacheTests {
    private struct QueryFailure: Error {}

    @Test func freshQueriesEveryTimeAndKeepsTheLatest() async throws {
        let queries = Tally()
        let cache = ContentCache<Int> { queries.increment() }
        #expect(cache.current == nil)

        let first = try await cache.fresh()
        #expect(first.snapshot == 1)
        #expect(cache.current?.serial == first.serial)

        let second = try await cache.fresh()
        #expect(second.snapshot == 2)
        #expect(second.serial != first.serial)
        #expect(cache.current?.snapshot == 2)
        #expect(queries.count == 2)
    }

    @MainActor
    @Test func callersArrivingDuringAQueryShareIt() async throws {
        let queries = Tally()
        let started = AsyncGate(), release = AsyncGate()
        let cache = ContentCache<Int> {
            let number = queries.increment()
            await started.open()
            await release.wait()
            return number
        }
        let first = Task { try await cache.fresh() }
        await started.wait()
        let second = Task { try await cache.fresh() }
        // Both callers run on the main actor, in the order they were made, so the second has reached the cache by the
        // time this test is back, and the query it joined is still held up.
        for _ in 0..<10 { await Task.yield() }
        await release.open()

        let firstEntry = try await first.value
        let secondEntry = try await second.value
        #expect(queries.count == 1)
        #expect(firstEntry.serial == secondEntry.serial)
        #expect(firstEntry.startedAt == secondEntry.startedAt)
    }

    @Test func aQueryDroppedByInvalidationIsNotKept() async throws {
        let queries = Tally()
        let started = AsyncGate(), release = AsyncGate()
        let cache = ContentCache<Int> {
            let number = queries.increment()
            if number == 1 {
                await started.open()
                await release.wait()
            }
            return number
        }
        let stale = Task { try await cache.fresh() }
        await started.wait()
        cache.invalidate()
        await release.open()

        // Whoever waited for the dropped query still gets its answer, but the cache stays empty.
        let dropped = try await stale.value
        #expect(dropped.snapshot == 1)
        #expect(cache.current == nil)

        let next = try await cache.fresh()
        #expect(next.snapshot == 2)
        #expect(queries.count == 2)
        #expect(cache.current?.serial == next.serial)
    }

    @Test func aCallerAfterInvalidationDoesNotJoinTheDroppedQueryNorLosesToIt() async throws {
        let queries = Tally()
        let started = AsyncGate(), release = AsyncGate()
        let cache = ContentCache<Int> {
            let number = queries.increment()
            if number == 1 {
                await started.open()
                await release.wait()
            }
            return number
        }
        let stale = Task { try await cache.fresh() }
        await started.wait()
        cache.invalidate()

        let newer = try await cache.fresh()
        #expect(newer.snapshot == 2)

        await release.open()
        let dropped = try await stale.value
        #expect(dropped.snapshot == 1)
        // The query that ended last must not replace the one started after the invalidation.
        #expect(cache.current?.serial == newer.serial)
        #expect(queries.count == 2)
    }

    @Test func discardingDropsOnlyTheSnapshotItWasGiven() async throws {
        let cache = ContentCache<Int> { 0 }
        let first = try await cache.fresh()
        cache.discard(first)
        #expect(cache.current == nil)

        let second = try await cache.fresh()
        cache.discard(first)
        #expect(cache.current?.serial == second.serial)

        cache.discard(second)
        #expect(cache.current == nil)
    }

    @Test func aKeptSnapshotThatServesIsReusedWithoutAQuery() async throws {
        let clock = SteppingClock(), queries = Tally()
        let cache = ContentCache<Int>(now: { clock.now() }) { queries.increment() }
        let kept = try await cache.fresh()

        var offered: [Bool] = []
        let result = try await cache.snapshot(for: clock.at(10)) { _, predatesRequest in
            offered.append(predatesRequest)
            return true
        }
        #expect(result.entry.serial == kept.serial)
        #expect(result.isCached)
        #expect(offered == [true])
        #expect(queries.count == 1)
    }

    @Test func aKeptSnapshotThatBeganAfterTheRequestIsOfferedAsNotPredatingIt() async throws {
        let clock = SteppingClock(), queries = Tally()
        let cache = ContentCache<Int>(now: { clock.now() }) { queries.increment() }
        let kept = try await cache.fresh()

        var offered: [Bool] = []
        let result = try await cache.snapshot(for: clock.at(0.5)) { _, predatesRequest in
            offered.append(predatesRequest)
            return true
        }
        #expect(result.entry.serial == kept.serial)
        #expect(!result.isCached)
        #expect(offered == [false])
        #expect(queries.count == 1)
    }

    @Test func aKeptSnapshotThatCannotServeIsReplacedByAQueryForTheRequest() async throws {
        let clock = SteppingClock(), queries = Tally()
        let cache = ContentCache<Int>(now: { clock.now() }) { queries.increment() }
        let kept = try await cache.fresh()

        let result = try await cache.snapshot(for: clock.at(1.5)) { _, _ in false }
        #expect(result.entry.serial != kept.serial)
        #expect(result.entry.snapshot == 2)
        #expect(!result.isCached)
        #expect(cache.current?.serial == result.entry.serial)
        #expect(queries.count == 2)
    }

    @Test func aSnapshotQueriedAfterTheRequestIsUsedWithoutAskingWhetherItServes() async throws {
        let clock = SteppingClock(), queries = Tally()
        let cache = ContentCache<Int>(now: { clock.now() }) { queries.increment() }

        var offered: [Bool] = []
        let result = try await cache.snapshot(for: clock.at(0)) { _, predatesRequest in
            offered.append(predatesRequest)
            return false
        }
        #expect(result.entry.snapshot == 1)
        #expect(!result.isCached)
        #expect(offered.isEmpty)
        #expect(queries.count == 1)
    }

    @Test func aQueryThatBeganBeforeTheRequestIsKeptWhenItServes() async throws {
        let clock = SteppingClock(), queries = Tally()
        let cache = ContentCache<Int>(now: { clock.now() }) { queries.increment() }

        // The only query began at 1 s, before the request at 5 s, as if the call had joined one already running.
        var offered: [Bool] = []
        let result = try await cache.snapshot(for: clock.at(5)) { _, predatesRequest in
            offered.append(predatesRequest)
            return true
        }
        #expect(result.entry.snapshot == 1)
        #expect(result.isCached)
        #expect(offered == [true])
        #expect(queries.count == 1)
    }

    @Test func aQueryThatBeganBeforeTheRequestIsReplacedWhenItCannotServe() async throws {
        let clock = SteppingClock(), queries = Tally()
        let cache = ContentCache<Int>(now: { clock.now() }) { queries.increment() }

        // The first query began at 1 s, before the request at 1.5 s; the one that replaces it began at 2 s.
        var offered: [Bool] = []
        let result = try await cache.snapshot(for: clock.at(1.5)) { _, predatesRequest in
            offered.append(predatesRequest)
            return false
        }
        #expect(result.entry.snapshot == 2)
        #expect(!result.isCached)
        #expect(offered == [true])
        #expect(queries.count == 2)
        #expect(cache.current?.serial == result.entry.serial)
    }

    @Test func aFailedQueryIsNotKeptAndTheNextCallerQueriesAgain() async throws {
        let queries = Tally()
        let cache = ContentCache<Int> {
            let number = queries.increment()
            if number == 1 { throw QueryFailure() }
            return number
        }
        await #expect(throws: QueryFailure.self) { try await cache.fresh() }
        #expect(cache.current == nil)

        let retried = try await cache.fresh()
        #expect(retried.snapshot == 2)
        #expect(queries.count == 2)
    }

    @Test func warmingFillsAnEmptyCacheOnlyAndSwallowsFailures() async {
        let queries = Tally()
        let cache = ContentCache<Int> {
            let number = queries.increment()
            if number == 1 { throw QueryFailure() }
            return number
        }
        await cache.warm()
        #expect(cache.current == nil)
        #expect(queries.count == 1)

        await cache.warm()
        #expect(cache.current?.snapshot == 2)

        await cache.warm()
        #expect(queries.count == 2)
    }

    @Test func aCancelledCallerStopsWaitingButTheQueryStillFillsTheCache() async throws {
        let started = AsyncGate(), release = AsyncGate()
        let cache = ContentCache<Int> {
            await started.open()
            await release.wait()
            return 5
        }
        let caller = Task { try await cache.fresh() }
        await started.wait()
        caller.cancel()
        await release.open()

        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(cache.current?.snapshot == 5)
    }
}

@Suite("Shareable content reuse")
struct ContentReuseTests {
    private let own: pid_t = 42
    private let other: pid_t = 7

    private func display(_ id: CGDirectDisplayID, width: CGFloat = 1440, height: CGFloat = 900) -> DisplayInfo {
        DisplayInfo(id: id, frame: CGRect(x: 0, y: 0, width: width, height: height),
                    scale: 2, name: "Display \(id)", isMain: id == 1)
    }

    private func facts(ownListed: Bool = true, owners: [CGWindowID: pid_t] = [:]) -> ContentFacts {
        ContentFacts(displaySizes: [:], ownApplicationListed: ownListed, windowOwners: owners)
    }

    private func options(keepingOwnWindows: Bool = false, named: Set<CGWindowID> = []) -> CaptureOptions {
        var options = CaptureOptions()
        options.excludeOwnWindows = !keepingOwnWindows
        options.excludedWindowIDs = named
        return options
    }

    @Test func aSnapshotListsADisplayOnlyAtItsCurrentSize() {
        let facts = ContentFacts(displaySizes: [1: CGSize(width: 1440, height: 900),
                                                2: CGSize(width: 1920, height: 1080)])
        #expect(ContentReuse.lists([display(1)], in: facts))
        #expect(ContentReuse.lists([display(1), display(2, width: 1920, height: 1080)], in: facts))
        // A display that was plugged in, or whose resolution changed, since the snapshot.
        #expect(!ContentReuse.lists([display(3)], in: facts))
        #expect(!ContentReuse.lists([display(1), display(3)], in: facts))
        #expect(!ContentReuse.lists([display(1, width: 1280, height: 800)], in: facts))
        #expect(!ContentReuse.lists([display(2, width: 1920, height: 1081)], in: facts))
        // Rounding below a point is not a change.
        #expect(ContentReuse.lists([display(1, width: 1440.4, height: 899.6)], in: facts))
    }

    @Test func aFreshSnapshotThatListsGlintExcludesItsApplication() {
        let result = ContentReuse.exclusion(for: options(), in: facts(owners: [10: own, 11: other]), ownPID: own)
        #expect(result == .ownApplication)
    }

    @Test func aFreshSnapshotThatDoesNotListGlintExcludesItsWindowsOneByOne() {
        let result = ContentReuse.exclusion(for: options(), in: facts(ownListed: false, owners: [10: own, 11: other, 12: own]),
                                            ownPID: own)
        #expect(result == .windows([10, 12]))
    }

    @Test func aNamedWindowOfAnotherApplicationIsExcludedByIDAlongsideGlintsOwn() {
        let result = ContentReuse.exclusion(for: options(named: [11]), in: facts(owners: [10: own, 11: other, 12: other]),
                                            ownPID: own)
        #expect(result == .windows([10, 11]))
    }

    @Test func aNamedWindowTheSnapshotDoesNotListIsNotOnScreenAndChangesNothing() {
        let result = ContentReuse.exclusion(for: options(named: [99]), in: facts(owners: [10: own]), ownPID: own)
        #expect(result == .ownApplication)
    }

    @Test func keepingGlintInTheCaptureExcludesOnlyTheNamedWindowsTheSnapshotLists() {
        let snapshot = facts(owners: [10: own, 11: other])
        #expect(ContentReuse.exclusion(for: options(keepingOwnWindows: true, named: [11, 99]), in: snapshot, ownPID: own)
            == .windows([11]))
        #expect(ContentReuse.exclusion(for: options(keepingOwnWindows: true), in: snapshot, ownPID: own) == .windows([]))
    }

    @Test func aKeptSnapshotExcludesGlintByApplicationOnlyWhenItListsIt() {
        let listed = ContentReuse.cachedExclusion(for: options(), in: facts(ownListed: true), ownPID: own) { _ in nil }
        #expect(listed == ContentExclusion.ownApplication)
        // Windows Glint opened since cannot be named, so a snapshot without the application cannot be reused.
        let unlisted = ContentReuse.cachedExclusion(for: options(), in: facts(ownListed: false, owners: [10: own]),
                                                    ownPID: own) { _ in nil }
        #expect(unlisted == nil)
    }

    @Test func aNamedWindowOfAnotherApplicationRulesOutExcludingByApplication() {
        let snapshot = facts(owners: [10: own, 11: other])
        let glints = ContentReuse.cachedExclusion(for: options(named: [10]), in: snapshot, ownPID: own) { _ in nil }
        #expect(glints == ContentExclusion.ownApplication)
        let foreign = ContentReuse.cachedExclusion(for: options(named: [11]), in: snapshot, ownPID: own) { _ in nil }
        #expect(foreign == nil)
    }

    @Test func aNamedWindowOpenedSinceTheSnapshotIsLookedUpLive() {
        let snapshot = facts(owners: [10: own])
        var lookups: [CGWindowID] = []
        let glints = ContentReuse.cachedExclusion(for: options(named: [10, 20]), in: snapshot, ownPID: own) {
            lookups.append($0)
            return own
        }
        #expect(glints == ContentExclusion.ownApplication)
        // Only the window the snapshot lacks is looked up.
        #expect(lookups == [20])

        let foreign = ContentReuse.cachedExclusion(for: options(named: [20]), in: snapshot, ownPID: own) { _ in other }
        #expect(foreign == nil)
        let gone = ContentReuse.cachedExclusion(for: options(named: [20]), in: snapshot, ownPID: own) { _ in nil }
        #expect(gone == nil)
    }

    @Test func aKeptSnapshotThatKeepsGlintInTheCaptureNeedsEveryNamedWindowListed() {
        let snapshot = facts(owners: [10: own, 11: other])
        let both = ContentReuse.cachedExclusion(for: options(keepingOwnWindows: true, named: [10, 11]), in: snapshot,
                                                ownPID: own) { _ in nil }
        #expect(both == ContentExclusion.windows([10, 11]))
        let missing = ContentReuse.cachedExclusion(for: options(keepingOwnWindows: true, named: [10, 99]), in: snapshot,
                                                   ownPID: own) { _ in own }
        #expect(missing == nil)
        let none = ContentReuse.cachedExclusion(for: options(keepingOwnWindows: true), in: snapshot, ownPID: own) { _ in nil }
        #expect(none == ContentExclusion.windows([]))
    }
}
