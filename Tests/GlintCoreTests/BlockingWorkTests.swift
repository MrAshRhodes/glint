import Foundation
import Testing
@testable import GlintCore

@Suite("Blocking work", .timeLimit(.minutes(1)))
struct BlockingWorkTests {
    private enum Failure: Error { case expected }

    @Test func returnsValuesAndPropagatesErrors() async throws {
        let value = try await BlockingWork.run { _ in 42 }
        #expect(value == 42)
        await #expect(throws: Failure.expected) {
            try await BlockingWork.run { _ in throw Failure.expected }
        }
    }

    @Test func cancellationHandlersRunOnceIncludingLateRegistration() {
        let cancellation = BlockingWork.Cancellation()
        var calls = 0
        cancellation.onCancel {
            #expect(cancellation.isCancelled)
            calls += 1
        }
        cancellation.cancel()
        cancellation.cancel()
        cancellation.onCancel { calls += 1 }
        #expect(calls == 2)
        #expect(throws: CancellationError.self) { try cancellation.check() }
    }

    @Test func cancellationUnblocksWorkAndRejectsItsResult() async {
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            try await BlockingWork.run { cancellation in
                let signal = DispatchSemaphore(value: 0)
                cancellation.onCancel { signal.signal() }
                started.continuation.yield(())
                started.continuation.finish()
                signal.wait()
                return 42
            }
        }
        for await _ in started.stream { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func alreadyCancelledTasksDoNotStartWork() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BlockingWork.run { _ in throw Failure.expected }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func blockingReadersLeaveCooperativeTasksAbleToProgress() async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    try await BlockingWork.run { _ in
                        let signal = DispatchSemaphore(value: 0)
                        Task { signal.signal() }
                        return signal.wait(timeout: .now() + 5) == .success
                    }
                }
            }
            for try await completed in group { #expect(completed) }
        }
    }
}
