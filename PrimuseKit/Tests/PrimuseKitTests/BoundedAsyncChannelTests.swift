import Testing
@testable import PrimuseKit

/// Records how far a producer got, so a test can tell "suspended" from "slow".
private actor SendProgress {
    private(set) var completed = 0
    private(set) var failure: Error?

    func didComplete() { completed += 1 }
    func didFail(_ error: Error) { failure = error }

    func isCancellation() -> Bool {
        guard let failure else { return false }
        return failure is CancellationError
    }
}

@Suite("Bounded async channel")
struct BoundedAsyncChannelTests {
    @Test("Elements arrive in send order")
    func preservesOrder() async throws {
        let channel = BoundedAsyncChannel<Int>(capacity: 4) { continuation in
            Task {
                for value in 0..<12 {
                    try await continuation.send(value)
                }
                continuation.finish()
            }
        }

        var received: [Int] = []
        for try await value in channel {
            received.append(value)
        }

        #expect(received == Array(0..<12))
    }

    @Test("A producer suspends at capacity and resumes when one element is taken")
    func suspendsAtCapacity() async throws {
        let progress = SendProgress()
        let capacity = 3
        let channel = BoundedAsyncChannel<Int>(capacity: capacity) { continuation in
            Task {
                do {
                    for value in 0..<(capacity + 1) {
                        try await continuation.send(value)
                        await progress.didComplete()
                    }
                } catch {
                    await progress.didFail(error)
                }
            }
        }
        var iterator = channel.makeAsyncIterator()

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await progress.completed == capacity)
        #expect(await progress.isCancellation() == false)

        #expect(try await iterator.next() == 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await progress.completed == capacity + 1)
        withExtendedLifetime(channel) {}
    }

    @Test("A blocked send throws once the consumer is gone")
    func consumerTerminationUnblocksSend() async throws {
        let progress = SendProgress()

        // Both the channel and its iterator have to go out of scope for the
        // underlying stream to see the consumer disappear.
        func consumeOnceThenDrop() async throws {
            let channel = BoundedAsyncChannel<Int>(capacity: 2) { continuation in
                Task {
                    do {
                        for value in 0..<64 {
                            try await continuation.send(value)
                            await progress.didComplete()
                        }
                    } catch {
                        await progress.didFail(error)
                    }
                }
            }
            var iterator = channel.makeAsyncIterator()
            _ = try await iterator.next()
        }

        try await consumeOnceThenDrop()
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(await progress.isCancellation())
        #expect(await progress.completed < 64)
    }

    @Test("A cancelled consumer task also unblocks the producer")
    func cancelledConsumerUnblocksSend() async throws {
        let progress = SendProgress()

        // The consuming task owns the only live reference to the channel, so
        // cancelling it also tears the underlying stream down.
        func consumeUntilCancelled() async throws {
            let channel = BoundedAsyncChannel<Int>(capacity: 2) { continuation in
                Task {
                    do {
                        for value in 0..<64 {
                            try await continuation.send(value)
                            await progress.didComplete()
                        }
                    } catch {
                        await progress.didFail(error)
                    }
                }
            }
            let consumer = Task {
                for try await _ in channel {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
            consumer.cancel()
            _ = try? await consumer.value
        }

        try await consumeUntilCancelled()
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(await progress.isCancellation())
        #expect(await progress.completed < 64)
    }

    @Test("finish(throwing:) reaches the consumer")
    func propagatesFailure() async throws {
        struct DecodeFailure: Error, Equatable {}
        let channel = BoundedAsyncChannel<Int>(capacity: 2) { continuation in
            continuation.yield(7)
            continuation.finish(throwing: DecodeFailure())
        }

        var iterator = channel.makeAsyncIterator()
        #expect(try await iterator.next() == 7)
        await #expect(throws: DecodeFailure.self) {
            _ = try await iterator.next()
        }
    }

    @Test("finish() after N sends still delivers all N, then nil")
    func deliversEverythingBeforeFinish() async throws {
        let total = 40
        let channel = BoundedAsyncChannel<Int>(capacity: 8) { continuation in
            Task {
                for value in 0..<total {
                    try await continuation.send(value)
                }
                continuation.finish()
            }
        }

        var iterator = channel.makeAsyncIterator()
        var received: [Int] = []
        while let value = try await iterator.next() {
            received.append(value)
        }

        #expect(received == Array(0..<total))
        #expect(try await iterator.next() == nil)
    }

    @Test("Cancelling the producer task makes a blocked send throw CancellationError")
    func producerCancellationThrows() async throws {
        let progress = SendProgress()
        var producer: Task<Void, Never>?
        let channel = BoundedAsyncChannel<Int>(capacity: 1) { continuation in
            producer = Task {
                do {
                    for value in 0..<16 {
                        try await continuation.send(value)
                        await progress.didComplete()
                    }
                } catch {
                    await progress.didFail(error)
                }
            }
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        producer?.cancel()
        await producer?.value

        #expect(await progress.isCancellation())
        #expect(await progress.completed <= 1)
        // Keep the channel alive so termination cannot be the reason it threw.
        withExtendedLifetime(channel) {}
    }

    @Test("A slow consumer loses nothing across 1000 sends at capacity 8")
    func losesNothingUnderBackpressure() async throws {
        let total = 1000
        let channel = BoundedAsyncChannel<Int>(capacity: 8) { continuation in
            Task {
                for value in 0..<total {
                    try await continuation.send(value)
                }
                continuation.finish()
            }
        }

        var received: [Int] = []
        for try await value in channel {
            received.append(value)
            if value % 100 == 0 {
                await Task.yield()
            }
        }

        #expect(received.count == total)
        #expect(received == Array(0..<total))
    }
}
