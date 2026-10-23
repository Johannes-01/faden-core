import Foundation
import Synchronization

/// Loads a value once for every caller, e.g. the speech model (its download and first load). A caller
/// cancelled while waiting stops waiting at once and throws `CancellationError`; the load itself goes on
/// and serves later callers. A failed load is started again by the next caller.
public actor SharedLoad<Value: Sendable> {
    private let load: @Sendable () async throws -> Value
    private var task: Task<Value, any Error>?

    public init(_ load: @escaping @Sendable () async throws -> Value) {
        self.load = load
    }

    public func value() async throws -> Value {
        let task = self.task ?? Task { [load] in try await load() }
        self.task = task
        do {
            return try await Self.wait(for: task)
        } catch is CancellationError where Task.isCancelled {
            throw CancellationError()  // only this caller gave up; the load continues
        } catch {
            if self.task == task { self.task = nil }  // let a later call retry, e.g. after a failed download
            throw error
        }
    }

    /// `task`'s value, or `CancellationError` as soon as the calling task is cancelled.
    private static func wait(for task: Task<Value, any Error>) async throws -> Value {
        let once = ResumeOnce<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.install(continuation)
                Task { once.resume(with: await task.result) }
            }
        } onCancel: {
            once.resume(with: .failure(CancellationError()))
        }
    }
}

/// Resumes a continuation exactly once, with whichever result comes first, even if that result arrives
/// before the continuation is installed.
private final class ResumeOnce<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var pending: Result<Value, any Error>?
        var done = false
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let ready: Result<Value, any Error>? = state.withLock {
            guard !$0.done else { return nil }
            if let pending = $0.pending {
                $0.done = true
                return pending
            }
            $0.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(with: ready) }
    }

    func resume(with result: Result<Value, any Error>) {
        let waiting: CheckedContinuation<Value, any Error>? = state.withLock {
            guard !$0.done else { return nil }
            guard let continuation = $0.continuation else {
                if $0.pending == nil { $0.pending = result }
                return nil
            }
            $0.done = true
            $0.continuation = nil
            return continuation
        }
        waiting?.resume(with: result)
    }
}
