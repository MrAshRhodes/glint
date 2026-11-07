import Foundation

/// Runs synchronous, blocking work such as `AVAssetReader.copyNextSampleBuffer()` on a Dispatch thread.
///
/// Blocking Swift's cooperative threads can starve the tasks those reads wait for.
public enum BlockingWork {
    /// Cancellation of the awaiting task, visible to the blocking work, which has no task of its own.
    public final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var handlers: [() -> Void] = []

        public var isCancelled: Bool { lock.withLock { cancelled } }

        public func check() throws {
            if isCancelled { throw CancellationError() }
        }

        /// Runs `handler` once on cancellation, at once if already cancelled. Use it to interrupt a blocking call.
        public func onCancel(_ handler: @escaping () -> Void) {
            let runNow = lock.withLock {
                if cancelled { return true }
                handlers.append(handler)
                return false
            }
            if runNow { handler() }
        }

        func cancel() {
            let pending: [() -> Void] = lock.withLock {
                guard !cancelled else { return [] }
                cancelled = true
                defer { handlers = [] }
                return handlers
            }
            pending.forEach { $0() }
        }
    }

    /// Transfers exclusive access to the work's captured state until it returns.
    /// Cancellation handlers must be safe to run concurrently with the work.
    public static func run<T>(qos: DispatchQoS.QoSClass = .userInitiated,
                              _ work: @escaping (Cancellation) throws -> T) async throws -> T {
        let cancellation = Cancellation()
        let box = UncheckedBox(work)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UncheckedBox<T>, Error>) in
                DispatchQueue.global(qos: qos).async {
                    continuation.resume(with: Result {
                        try cancellation.check()
                        let value = try box.value(cancellation)
                        try cancellation.check()
                        return UncheckedBox(value)
                    })
                }
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// State is transferred to the worker and back while the caller is suspended.
    private struct UncheckedBox<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }
}
