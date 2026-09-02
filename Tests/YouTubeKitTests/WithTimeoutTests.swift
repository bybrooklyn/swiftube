import Foundation
import Testing
@testable import YouTubeCore

// `withTimeout` exists because the shape it replaces does not time out. The
// first test here is the whole point: work that ignores cancellation must not be
// able to hold the caller past the budget. Written against the old task-group
// form it would hang for the full two seconds of `work` rather than returning
// after 0.2 s.

@Suite("withTimeout")
struct WithTimeoutTests {

    /// Work that finishes fast and honours nothing.
    @Test("returns true when the work finishes inside the budget")
    func finishesInsideBudget() async {
        let finished = await withTimeout(seconds: 5) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(finished)
    }

    @Test("returns false when the work outlasts the budget")
    func timesOut() async {
        let finished = await withTimeout(seconds: 0.2) {
            try? await Task.sleep(for: .seconds(2))
        }
        #expect(!finished)
    }

    /// The case the helper was written for. `Task.sleep` throws on cancellation,
    /// so it is *not* representative of BotGuard's semaphore-blocking mint — this
    /// uses a busy-ish wait that never checks `Task.isCancelled`.
    @Test("returns on time even when the work cannot be cancelled")
    func timesOutOnUncancellableWork() async {
        let start = ContinuousClock.now
        let finished = await withTimeout(seconds: 0.2) {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < deadline {
                // No cancellation check, on purpose.
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let elapsed = start.duration(to: .now)
        #expect(!finished)
        #expect(elapsed < .seconds(1.5),
                "withTimeout waited \(elapsed) for uncancellable work on a 0.2 s budget")
    }

    @Test("does not return before the budget when the work is slower")
    func waitsForTheWholeBudget() async {
        let start = ContinuousClock.now
        _ = await withTimeout(seconds: 0.3) {
            try? await Task.sleep(for: .seconds(5))
        }
        #expect(start.duration(to: .now) >= .milliseconds(250))
    }

    @Test("the work keeps running after a timeout")
    func workSurvivesTheTimeout() async {
        // Abandoning the wait must not abandon the cache warming — that is the
        // reason the work is detached rather than cancelled.
        let flag = CompletionFlag()
        let finished = await withTimeout(seconds: 0.1) {
            try? await Task.sleep(for: .milliseconds(400))
            await flag.set()
        }
        #expect(!finished)
        #expect(await flag.value == false, "work should still be in flight at this point")
        try? await Task.sleep(for: .milliseconds(700))
        #expect(await flag.value, "work was abandoned instead of left running")
    }

    @Test("a zero budget still settles rather than hanging")
    func zeroBudgetSettles() async {
        let finished = await withTimeout(seconds: 0) {
            try? await Task.sleep(for: .seconds(1))
        }
        #expect(!finished)
    }

    @Test("concurrent waits do not interfere")
    func concurrentWaitsAreIndependent() async {
        async let fast = withTimeout(seconds: 5) { try? await Task.sleep(for: .milliseconds(20)) }
        async let slow = withTimeout(seconds: 0.2) { try? await Task.sleep(for: .seconds(2)) }
        let results = await (fast, slow)
        #expect(results.0)
        #expect(!results.1)
    }
}

private actor CompletionFlag {
    private(set) var value = false
    func set() { value = true }
}
