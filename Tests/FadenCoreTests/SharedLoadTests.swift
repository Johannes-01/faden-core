import Foundation
import Testing
@testable import FadenCore

actor LoadCounter {
    private(set) var count = 0
    func bump() -> Int {
        count += 1
        return count
    }
}

@Suite struct SharedLoadTests {
    /// A waiter cancelled during a slow load (e.g. the speech-model download) stops waiting at once; the
    /// load keeps running and serves the next caller without loading again.
    @Test func aCancelledWaiterStopsWaitingWhileTheLoadGoesOn() async throws {
        let gate = Gate()  // its wait ignores cancellation, like a download
        let counter = LoadCounter()
        let shared = SharedLoad<Int> {
            _ = await counter.bump()
            await gate.wait()
            return 42
        }

        let waiter = Task { try await shared.value() }
        await gate.waitForArrivals(1)
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        waiter.cancel()
        // Only so a waiter that ignores the cancel can't hang the suite.
        let safety = Task {
            try await Task.sleep(for: .seconds(3))
            await gate.open()
        }
        let result = await waiter.result
        let waited = clock.now - cancelledAt
        safety.cancel()

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(waited < .seconds(1))  // returned while the load was still going
        await gate.open()
        #expect(try await shared.value() == 42)
        #expect(await counter.count == 1)
    }

    @Test func aWaiterCancelledBeforeItStartsThrowsAtOnce() async throws {
        let shared = SharedLoad<Int> { 7 }
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await shared.value()
        }
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(try await shared.value() == 7)
    }

    @Test func aFailedLoadIsTriedAgainByTheNextCaller() async throws {
        struct Offline: Error {}
        let counter = LoadCounter()
        let shared = SharedLoad<Int> {
            if await counter.bump() == 1 { throw Offline() }
            return 5
        }

        await #expect(throws: Offline.self) { try await shared.value() }
        #expect(try await shared.value() == 5)
        #expect(await counter.count == 2)
    }
}
