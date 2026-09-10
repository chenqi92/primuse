import Foundation

/// A value that a `KeyedRunRegistry` can cancel on behalf of its owner.
/// Implemented by the small record types services store per key (usually a
/// wrapper around a `Task` plus the run's target/metadata).
public protocol KeyedRunCancellable {
    func cancelRun()
}

extension Task: KeyedRunCancellable {
    public func cancelRun() { cancel() }
}

/// Registry of at most one in-flight run per key, where every registration
/// carries its own identity.
///
/// 单纯用 `[Key: Task]` 记账时, 一个「已经被取消但还没退出」的旧任务在
/// 收尾 (`defer`) 时会把同一个 key 下的**替代任务**一起删掉 —— 之后谁都
/// 找不到那个替代任务, 既取消不了也保护不住它正在写的文件。带 run 身份
/// 的记账让收尾只对「自己那一次」生效: `finish(key:runID:)` 只有在当前
/// 登记仍是同一个 run 时才移除。
public struct KeyedRunRegistry<Value> {
    public struct Run {
        public let id: UUID
        public let value: Value

        public init(id: UUID, value: Value) {
            self.id = id
            self.value = value
        }
    }

    private var runs: [String: Run] = [:]

    public init() {}

    public var isEmpty: Bool { runs.isEmpty }

    public var count: Int { runs.count }

    public var keys: [String] { Array(runs.keys) }

    public var values: [Value] { runs.values.map(\.value) }

    public func run(forKey key: String) -> Run? { runs[key] }

    public func value(forKey key: String) -> Value? { runs[key]?.value }

    /// Registers `value` under `key`, replacing any current registration, and
    /// returns the identity the owner must hand back to `finish(key:runID:)`.
    /// Pass `id` when the run has to know its own identity before it can be
    /// registered (a task whose `defer` finishes its own registration).
    /// Cancelling the replaced run is the caller's decision.
    @discardableResult
    public mutating func register(key: String, value: Value, id: UUID = UUID()) -> UUID {
        runs[key] = Run(id: id, value: value)
        return id
    }

    /// Removes the registration only when it still belongs to `runID`, so a
    /// stale run's teardown can never drop its replacement. Returns the removed
    /// value, or `nil` when the key already belongs to another run.
    @discardableResult
    public mutating func finish(key: String, runID: UUID) -> Value? {
        guard runs[key]?.id == runID else { return nil }
        return runs.removeValue(forKey: key)?.value
    }

    @discardableResult
    public mutating func remove(key: String) -> Value? {
        runs.removeValue(forKey: key)?.value
    }

    @discardableResult
    public mutating func removeAll(where shouldRemove: (String) -> Bool) -> [Value] {
        let matched = runs.keys.filter(shouldRemove)
        return matched.compactMap { runs.removeValue(forKey: $0)?.value }
    }
}

extension KeyedRunRegistry where Value: KeyedRunCancellable {
    /// Cancels the run registered under `key` without unregistering it: the
    /// run's own teardown removes its entry once it observes the cancellation.
    public func cancel(key: String) {
        cancellableRuns(matching: { $0 == key }).forEach { $0.cancelRun() }
    }

    /// Cancels every matching run, leaving the registrations in place.
    public func cancelAll(where shouldCancel: (String) -> Bool = { _ in true }) {
        cancellableRuns(matching: shouldCancel).forEach { $0.cancelRun() }
    }

    /// Cancels every matching run and unregisters it immediately. Use this when
    /// the owner must not hand the run out again (scope change, source removal).
    @discardableResult
    public mutating func cancelAndRemoveAll(
        where shouldRemove: (String) -> Bool = { _ in true }
    ) -> [Value] {
        let removed = removeAll(where: shouldRemove)
        removed.forEach { $0.cancelRun() }
        return removed
    }

    private func cancellableRuns(matching predicate: (String) -> Bool) -> [Value] {
        keys.filter(predicate).compactMap { value(forKey: $0) }
    }
}
