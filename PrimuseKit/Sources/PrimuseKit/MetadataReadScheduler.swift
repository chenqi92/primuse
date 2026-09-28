import Foundation

/// A preference or thermal event can resize a live queue without cancelling
/// reads, replaying completed files, or waiting for a whole snapshot to drain.
@MainActor
public final class MetadataReadScheduler<Item: Sendable, Outcome: Sendable> {
    private enum Event: Sendable {
        case completed(Item, Outcome)
        case deferred(Int)
        case skipped
        case configurationChanged
        case cancelled
    }

    public private(set) var inFlightCount = 0
    private var signal: (@Sendable () -> Void)?

    public init() {}

    public func configurationChanged() { signal?() }

    @discardableResult
    public func run(
        items: [Item],
        limits: @escaping @MainActor () -> MetadataBackfillExecutionLimits,
        shouldRead: @escaping @MainActor (Item) -> Bool = { _ in true },
        shouldContinue: @escaping @MainActor () -> Bool = { true },
        priority: TaskPriority = .utility,
        fastPath: @escaping @MainActor @Sendable (Item) async -> Outcome? = { _ in nil },
        read: @escaping @MainActor @Sendable (Item) async -> Outcome,
        completed: @escaping @MainActor (Item, Outcome) async -> Void
    ) async -> Bool {
        let (events, continuation) = AsyncStream<Event>.makeStream()
        signal = { continuation.yield(.configurationChanged) }
        defer {
            signal = nil
            inFlightCount = 0
            continuation.finish()
        }
        var didCancel = false
        await withTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            var nextIndex = 0
            var deferredIndices: [Int] = []
            continuation.yield(.configurationChanged)
            for await event in events {
                guard !Task.isCancelled else { break }
                if case .cancelled = event { didCancel = true; break }
                if case .completed(let item, let outcome) = event {
                    inFlightCount -= 1
                    await completed(item, outcome)
                } else if case .deferred(let index) = event {
                    inFlightCount -= 1
                    deferredIndices.append(index)
                } else if case .skipped = event {
                    inFlightCount -= 1
                }
                guard shouldContinue() else { didCancel = true; break }
                let budget = limits()
                while !Task.isCancelled,
                      inFlightCount < budget.workerCount,
                      !deferredIndices.isEmpty || nextIndex < items.count {
                    let index: Int
                    if deferredIndices.isEmpty {
                        index = nextIndex
                        nextIndex += 1
                    } else {
                        index = deferredIndices.removeFirst()
                    }
                    let item = items[index]
                    guard shouldRead(item) else { continue }
                    inFlightCount += 1
                    let readWhenAllowed: @MainActor @Sendable () async -> Event = { [self] in
                        guard shouldRead(item) else { return .skipped }
                        // A reserved slot may have spent time throttling. Do
                        // not start I/O after a thermal pause or budget drop.
                        guard inFlightCount <= limits().workerCount else { return .deferred(index) }
                        let outcome = await read(item)
                        return Task.isCancelled ? .cancelled : .completed(item, outcome)
                    }
                    group.addTask(priority: priority) {
                        guard await shouldRead(item) else {
                            continuation.yield(.skipped)
                            return
                        }
                        if let outcome = await fastPath(item) {
                            continuation.yield(Task.isCancelled ? .cancelled : .completed(item, outcome))
                            return
                        }
                        if budget.interRequestDelay > 0 {
                            do {
                                try await Task.sleep(for: .seconds(budget.interRequestDelay))
                            } catch { return }
                        }
                        guard !Task.isCancelled else { return }
                        continuation.yield(await readWhenAllowed())
                    }
                }
                if nextIndex == items.count && deferredIndices.isEmpty && inFlightCount == 0 { break }
            }
        }
        return didCancel || Task.isCancelled
    }
}
