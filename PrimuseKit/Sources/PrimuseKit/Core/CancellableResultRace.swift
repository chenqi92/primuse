import Foundation

/// Resolves a callback/cancellation race exactly once, including cancellation
/// that arrives before the checked continuation has been installed.
public final class CancellableResultRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pendingResult: Result<Value, any Error>?
    private var resolved = false

    public init() {}

    public var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolved
    }

    public func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    @discardableResult
    public func resolve(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return false
        }
        resolved = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }

    @discardableResult
    public func cancel() -> Bool {
        resolve(.failure(CancellationError()))
    }
}
