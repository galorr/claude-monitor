import Foundation

public struct TimeoutError: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "timed out" }
}

/// Fails with `TimeoutError` if `operation` has not finished in time. Unlike a task group,
/// it does not wait for an operation that ignores cancellation.
public func withTimeout<T: Sendable>(_ timeout: Duration,
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = ResumeOnce<T>()
    return try await withCheckedThrowingContinuation { continuation in
        gate.set(continuation)
        let work = Task {
            do { gate.resume(with: .success(try await operation())) } catch { gate.resume(with: .failure(error)) }
        }
        Task {
            try? await Task.sleep(for: timeout)
            gate.resume(with: .failure(TimeoutError()))
            work.cancel()
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func set(_ c: CheckedContinuation<T, Error>) {
        lock.withLock { continuation = c }
    }

    func resume(with result: Result<T, Error>) {
        let c: CheckedContinuation<T, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: result)
    }
}
