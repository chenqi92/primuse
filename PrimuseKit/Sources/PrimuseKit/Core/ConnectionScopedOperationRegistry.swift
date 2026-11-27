import Foundation

/// Owns cancellable operations for exactly one connection generation.
/// Closing a generation forms a latch: registrations that race or arrive
/// afterward are cancelled immediately, while a stale close cannot affect a
/// newer connection.
public final class ConnectionScopedOperationRegistry: @unchecked Sendable {
    public struct Generation: Hashable, Sendable {
        fileprivate let value: UInt64
    }

    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: Generation?
    private var actions: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    /// Opens a fresh generation and cancels any operations left behind by a
    /// previous generation before returning its token.
    @discardableResult
    public func open() -> Generation {
        lock.lock()
        nextGeneration &+= 1
        let generation = Generation(value: nextGeneration)
        activeGeneration = generation
        let stale = Array(actions.values)
        actions.removeAll()
        lock.unlock()
        stale.forEach { $0() }
        return generation
    }

    /// Returns an ID only when the supplied generation is still open. A
    /// rejected registration is cancelled synchronously and is never retained.
    @discardableResult
    public func register(
        for generation: Generation,
        _ action: @escaping @Sendable () -> Void
    ) -> UUID? {
        let id = UUID()
        lock.lock()
        guard activeGeneration == generation else {
            lock.unlock()
            action()
            return nil
        }
        actions[id] = action
        lock.unlock()
        return id
    }

    public func unregister(_ id: UUID) {
        lock.lock()
        actions[id] = nil
        lock.unlock()
    }

    public func isActive(_ generation: Generation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == generation
    }

    /// Closes only the matching generation. Every retained operation is
    /// cancelled exactly once; later registrations for that token cancel
    /// themselves immediately.
    @discardableResult
    public func close(_ generation: Generation) -> Int {
        lock.lock()
        guard activeGeneration == generation else {
            lock.unlock()
            return 0
        }
        activeGeneration = nil
        let pending = Array(actions.values)
        actions.removeAll()
        lock.unlock()
        pending.forEach { $0() }
        return pending.count
    }

    public var activeOperationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return actions.count
    }
}
