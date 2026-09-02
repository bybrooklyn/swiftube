import Foundation

// MARK: - withTimeout
//
// The pipeline had two "timeouts" guarding cold-start latency, both written as:
//
//     await withTaskGroup(of: Void.self) { group in
//         group.addTask { await work() }
//         group.addTask { try? await Task.sleep(nanoseconds: N) }
//         _ = await group.next(); group.cancelAll()
//     }
//
// Neither timed anything out. `withTaskGroup` awaits **all** its children before
// returning, and `cancelAll()` only sets a cancellation flag — work that never
// checks `Task.isCancelled` runs to completion regardless. Both pieces of work
// guarded here are exactly that: `BotGuardClient.token` blocks on a
// `DispatchSemaphore` inside a continuation, and `BotGuardWebViewRunner.prepare`
// awaits an unstructured task whose only bound is a 45-second safety timer.
//
// So the "2 s safety net" on the first-frame path could wait through a full cold
// BotGuard pipeline, and the "up to 6 s" wait in the retry race could wait 45.

/// Waits up to `seconds` for `work`, then returns whether or not it finished.
///
/// `work` is started **detached and is not cancelled on timeout** — deliberately.
/// Everything this guards is warming a cache (a PO token, an attestation
/// handshake) that the next attempt will want, so abandoning the wait should not
/// abandon the work. It also means the caller's own cancellation does not
/// propagate into `work`; the wait itself is bounded by `seconds` regardless.
///
/// - Returns: `true` if `work` finished within the budget, `false` on timeout.
@discardableResult
public func withTimeout(
    seconds: Double,
    _ work: @escaping @Sendable () async -> Void
) async -> Bool {
    let box = TimeoutBox()
    Task.detached(priority: .userInitiated) {
        await work()
        await box.settle(true)
    }
    Task.detached(priority: .utility) {
        try? await Task.sleep(for: .seconds(seconds))
        await box.settle(false)
    }
    return await box.wait()
}

/// Single-shot rendezvous: whichever of the two racers settles first wins, and a
/// waiter that arrives after the fact still gets the answer.
private actor TimeoutBox {

    private var outcome: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func settle(_ value: Bool) {
        guard outcome == nil else { return }
        outcome = value
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: value)
        }
    }

    func wait() async -> Bool {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            // `settle` runs on this actor too, so there is no window in which
            // both the check above and this assignment miss each other.
            self.waiter = continuation
        }
    }
}
