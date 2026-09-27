import Foundation
import XCTest
@testable import BeforeKit

// =============================================================================
// TaskHandle.
//
// These tests exist because the thing being replaced — a plain
// `Task<Void, Never>?` on a `@MainActor` view model, cancelled in `deinit` —
// does not compile under Swift 6, and the two obvious workarounds are worse
// than the problem: dropping the `deinit` leaks the task, and
// `nonisolated(unsafe)` keeps the code and adds a data race.
//
// None of these assertions use a sleep or a timeout. Each one awaits the task
// it is making a claim about, so a cancellation that never propagates hangs and
// fails as a test timeout rather than passing on a lucky schedule.
// =============================================================================

/// Minimal thread-safe flag. The tasks under test run on the cooperative pool
/// while the assertions run on the test's own isolation.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// A `@MainActor` owner that cancels its work in `deinit` — the exact shape
/// that failed to compile in `SubscriptionManager` and `AnalysisFlowViewModel`.
/// If this type ever stops compiling, the reason `TaskHandle` exists is gone.
@MainActor
private final class Owner {
    private let work = TaskHandle()

    init(_ task: Task<Void, Never>) { work.store(task) }

    deinit { work.cancel() }
}

final class TaskHandleTests: XCTestCase {

    /// A task that finishes only once it has been cancelled.
    private func cancellationObserver(_ flag: Flag) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            flag.set()
        }
    }

    // MARK: - Lifecycle

    func testIsActiveTracksAdoption() async {
        let handle = TaskHandle()
        XCTAssertFalse(handle.isActive, "a fresh handle holds nothing")

        let task = Task<Void, Never> {}
        handle.store(task)
        XCTAssertTrue(handle.isActive)

        handle.cancel()
        XCTAssertFalse(handle.isActive, "cancel must forget the task, not just cancel it")
        await task.value
    }

    func testCancelPropagatesToTheStoredTask() async {
        let handle = TaskHandle()
        let observed = Flag()
        let task = cancellationObserver(observed)

        handle.store(task)
        handle.cancel()

        // Completes only because the task saw `Task.isCancelled`.
        await task.value
        XCTAssertTrue(observed.isSet)
    }

    func testCancelIsIdempotent() async {
        let handle = TaskHandle()
        let task = cancellationObserver(Flag())

        handle.store(task)
        handle.cancel()
        handle.cancel()
        handle.cancel()

        await task.value
        XCTAssertFalse(handle.isActive)
    }

    func testCancelOnAnEmptyHandleDoesNothing() {
        let handle = TaskHandle()
        handle.cancel()
        XCTAssertFalse(handle.isActive)
    }

    // MARK: - Replacement

    func testStoreCancelsWhatItReplaces() async {
        // The retry path stores a second task over the first. An uncancelled
        // first task keeps running, and keeps everything it captured alive.
        let handle = TaskHandle()
        let firstObserved = Flag()
        let first = cancellationObserver(firstObserved)

        handle.store(first)
        let second = Task<Void, Never> {}
        handle.store(second)

        await first.value
        XCTAssertTrue(firstObserved.isSet, "the replaced task was left running")

        await second.value
        XCTAssertFalse(second.isCancelled, "the replacement must not inherit the cancellation")
    }

    func testClearForgetsWithoutCancelling() async {
        let handle = TaskHandle()
        let ran = Flag()
        let task = Task<Void, Never> {
            await Task.yield()
            ran.set()
        }

        handle.store(task)
        handle.clear()
        XCTAssertFalse(handle.isActive)

        await task.value
        XCTAssertFalse(task.isCancelled, "clear must not cancel")
        XCTAssertTrue(ran.isSet)
    }

    // MARK: - The reason this type exists

    func testAMainActorOwnerCanCancelFromDeinit() async {
        let observed = Flag()
        let task = cancellationObserver(observed)

        await MainActor.run {
            var owner: Owner? = Owner(task)
            owner = nil
            XCTAssertNil(owner)
        }

        // Only the `deinit` could have cancelled this.
        await task.value
        XCTAssertTrue(observed.isSet)
    }
}
