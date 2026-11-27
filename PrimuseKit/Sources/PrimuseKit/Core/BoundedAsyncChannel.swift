import Foundation

/// Thread-safe box for the caller-supplied termination handler.
///
/// The channel always owns the underlying stream's termination callback, so a
/// caller-installed handler has to live next to it instead of replacing it.
private final class ChannelTerminationHandlerStorage<Handler>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: Handler?

    func get() -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    func set(_ newHandler: Handler?) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }
}

/// Credit counter bounding the number of elements that have been enqueued but
/// not yet handed to the consumer.
///
/// A producer takes one credit before enqueuing and the consumer returns it
/// after receiving an element, so a producer that outruns its consumer
/// suspends instead of polling.
private actor BoundedAsyncChannelCreditGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let capacity: Int
    private var available: Int
    private var waiters: [Waiter] = []
    /// Cancellation can land before the waiter is registered; remember those
    /// ids so the matching `acquire` fails instead of suspending forever.
    private var cancelledWaiterIDs: Set<UUID> = []
    private var isTerminated = false

    init(capacity: Int) {
        let bounded = max(1, capacity)
        self.capacity = bounded
        self.available = bounded
    }

    /// Takes one credit, suspending while none is available.
    nonisolated func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await acquireCredit(id: id)
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func acquireCredit(id: UUID) async throws {
        if isTerminated { throw CancellationError() }
        if cancelledWaiterIDs.remove(id) != nil { throw CancellationError() }
        if available > 0 {
            available -= 1
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters.append(Waiter(id: id, continuation: continuation))
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard !isTerminated else { return }
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            cancelledWaiterIDs.insert(id)
        }
    }

    /// Returns one credit, handing it straight to the longest-waiting producer.
    func release() {
        guard !isTerminated else { return }
        if waiters.isEmpty {
            // Elements enqueued through `yield` never took a credit, so cap the
            // counter to keep the in-flight bound intact.
            available = min(available + 1, capacity)
        } else {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
        }
    }

    /// Drains the gate so every blocked producer wakes and throws.
    func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        let pending = waiters
        waiters.removeAll()
        cancelledWaiterIDs.removeAll()
        for waiter in pending {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    /// Termination callbacks arrive synchronously; hop onto the actor to drain.
    nonisolated func terminateSoon() {
        Task { await self.terminate() }
    }
}

/// A lossless, bounded async channel.
///
/// `AsyncThrowingStream` is unbounded by default and its `yield` is
/// synchronous, so a producer that outruns its consumer either grows without
/// limit or — with `.bufferingOldest`/`.bufferingNewest` — drops elements. The
/// usual workaround is to retry a dropped element on a timer, which wakes the
/// producer many times a second for as long as the consumer is parked.
///
/// `BoundedAsyncChannel` keeps the underlying stream unbounded and instead
/// gates the producer with a credit counter sized to `capacity`: `send`
/// suspends until the consumer has actually taken an element. Nothing is
/// dropped, memory stays bounded, and an idle producer stays asleep.
///
/// Exactly one consumer is supported, matching `AsyncThrowingStream`.
public struct BoundedAsyncChannel<Element: Sendable>: AsyncSequence, Sendable {
    /// Why the channel stopped delivering elements.
    public enum Termination: Sendable {
        case finished
        case cancelled
    }

    /// The producer side of the channel.
    public final class Continuation: Sendable {
        fileprivate typealias Handler = @Sendable (Termination) -> Void

        private let base: AsyncThrowingStream<Element, Error>.Continuation
        private let gate: BoundedAsyncChannelCreditGate
        fileprivate let handlerStorage: ChannelTerminationHandlerStorage<Handler>

        fileprivate init(
            base: AsyncThrowingStream<Element, Error>.Continuation,
            gate: BoundedAsyncChannelCreditGate,
            handlerStorage: ChannelTerminationHandlerStorage<Handler>
        ) {
            self.base = base
            self.gate = gate
            self.handlerStorage = handlerStorage
        }

        /// Enqueues an element without waiting for a credit.
        ///
        /// Use this only when the caller already holds a credit for the
        /// element, or for a final flush right before `finish()`. Because it
        /// bypasses the gate it can push the in-flight count past `capacity`;
        /// the gate re-clamps itself as the consumer drains.
        public func yield(_ element: Element) {
            _ = base.yield(element)
        }

        /// Waits for a credit, then enqueues the element.
        ///
        /// Throws `CancellationError` if the sending task is cancelled or the
        /// channel has already terminated.
        public func send(_ element: Element) async throws {
            try await gate.acquire()
            if case .terminated = base.yield(element) {
                throw CancellationError()
            }
        }

        /// Ends the channel successfully. Already-enqueued elements are still
        /// delivered before the consumer sees `nil`.
        public func finish() {
            base.finish()
        }

        /// Ends the channel, optionally delivering `error` to the consumer.
        public func finish(throwing error: Error?) {
            base.finish(throwing: error)
        }

        /// Called when the channel finishes or the consumer goes away.
        public var onTermination: (@Sendable (Termination) -> Void)? {
            get { handlerStorage.get() }
            set { handlerStorage.set(newValue) }
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        /// `AsyncThrowingStream.AsyncIterator` is a struct; boxing it keeps a
        /// single shared cursor no matter how the iterator is copied around.
        private final class IteratorBox: @unchecked Sendable {
            var base: AsyncThrowingStream<Element, Error>.AsyncIterator

            init(_ base: AsyncThrowingStream<Element, Error>.AsyncIterator) {
                self.base = base
            }
        }

        private let box: IteratorBox
        private let gate: BoundedAsyncChannelCreditGate

        fileprivate init(
            base: AsyncThrowingStream<Element, Error>.AsyncIterator,
            gate: BoundedAsyncChannelCreditGate
        ) {
            self.box = IteratorBox(base)
            self.gate = gate
        }

        public mutating func next() async throws -> Element? {
            do {
                guard let element = try await box.base.next() else {
                    await gate.terminate()
                    return nil
                }
                await gate.release()
                return element
            } catch {
                await gate.terminate()
                throw error
            }
        }
    }

    private let stream: AsyncThrowingStream<Element, Error>
    private let gate: BoundedAsyncChannelCreditGate

    /// Creates a channel that keeps at most `capacity` elements in flight.
    public init(capacity: Int, _ build: (Continuation) -> Void) {
        let gate = BoundedAsyncChannelCreditGate(capacity: capacity)
        let handlerStorage = ChannelTerminationHandlerStorage<Continuation.Handler>()
        var baseContinuation: AsyncThrowingStream<Element, Error>.Continuation!
        let stream = AsyncThrowingStream<Element, Error> { continuation in
            baseContinuation = continuation
        }
        baseContinuation.onTermination = { reason in
            // Producers blocked on a credit must wake as soon as either side
            // goes away, otherwise `send` would hang past the channel's life.
            gate.terminateSoon()
            let termination: Termination
            switch reason {
            case .cancelled: termination = .cancelled
            default: termination = .finished
            }
            handlerStorage.get()?(termination)
        }
        self.stream = stream
        self.gate = gate
        build(
            Continuation(
                base: baseContinuation,
                gate: gate,
                handlerStorage: handlerStorage
            )
        )
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: stream.makeAsyncIterator(), gate: gate)
    }
}
