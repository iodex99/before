import Foundation

/// A task handle that any isolation is allowed to cancel — including `deinit`.
///
/// Under Swift 6 strict concurrency, `deinit` on a `@MainActor` type is
/// *nonisolated*: the compiler cannot prove which thread releases the last
/// reference, so it refuses to let `deinit` read main-actor-isolated state.
/// That collides with the one thing a view model most wants to do on the way
/// out — cancel the work it started:
///
/// ```swift
/// private var task: Task<Void, Never>?
/// deinit { task?.cancel() }   // error: main actor-isolated property
///                             // 'task' can not be referenced from a
///                             // nonisolated context
/// ```
///
/// `nonisolated(unsafe) var task` silences that, and is a genuine data race:
/// `deinit` can run on one thread while the owning actor is mid-assignment on
/// another. Putting the handle behind a lock removes the race instead of
/// hiding it, and leaves the isolation of everything else on the type alone.
///
/// Cancelling a `Task` is itself safe from any thread — only the *storage*
/// needed protecting.
public final class TaskHandle: @unchecked Sendable {

    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init() {}

    /// True between a `store` and the `cancel`/`clear` that follows it.
    ///
    /// This reports whether a task has been *adopted*, not whether it is still
    /// running — a task that ran to completion still reads as active until the
    /// owner clears it. Callers use it to avoid starting a second one.
    public var isActive: Bool {
        lock.withLock { task != nil }
    }

    /// Adopts `task`, cancelling whatever was held before it.
    ///
    /// Replacing rather than overwriting is what a retry needs: an abandoned
    /// task that is never cancelled keeps its continuation, and anything it
    /// captured, alive for as long as it chooses to run.
    public func store(_ task: Task<Void, Never>) {
        let previous: Task<Void, Never>? = lock.withLock {
            let existing = self.task
            self.task = task
            return existing
        }
        previous?.cancel()
    }

    /// Cancels the held task and forgets it. Idempotent, and safe to call from
    /// `deinit` or from any thread.
    public func cancel() {
        let existing: Task<Void, Never>? = lock.withLock {
            let existing = self.task
            self.task = nil
            return existing
        }
        existing?.cancel()
    }

    /// Forgets the held task *without* cancelling it, so `isActive` reads false
    /// and a later `store` is uncontested.
    ///
    /// For the case where the task has already finished on its own and
    /// cancelling it would be a no-op with a misleading name.
    public func clear() {
        lock.withLock { task = nil }
    }
}
