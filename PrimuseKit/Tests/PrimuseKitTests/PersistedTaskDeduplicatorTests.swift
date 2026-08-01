import Foundation
import Testing
@testable import PrimuseKit

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

private actor PersistedTaskInvocationCounter {
    private(set) var operationCount = 0
    private(set) var persistenceCount = 0

    func recordOperation() { operationCount += 1 }
    func recordPersistence() { persistenceCount += 1 }
}

private struct RotatingToken: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
}

private actor FailableDurableTokenStore {
    private var token: RotatingToken
    private var failuresRemaining: Int

    init(token: RotatingToken, failuresRemaining: Int) {
        self.token = token
        self.failuresRemaining = failuresRemaining
    }

    func persist(_ newToken: RotatingToken) throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw PersistedTaskTestError.persistenceFailed
        }
        token = newToken
    }

    func read() -> RotatingToken { token }
}

private enum PersistedTaskTestError: Error {
    case persistenceFailed
}

@Suite("Persisted task deduplication")
struct PersistedTaskDeduplicatorTests {
    @Test("Followers observe the creator's persistence failure")
    func followersObservePersistenceFailure() async {
        let coordinator = PersistedTaskDeduplicator<String>()
        let operationGate = AsyncTestGate()
        let counter = PersistedTaskInvocationCounter()

        func startRefresh() -> Task<Bool, Never> {
            Task {
                do {
                    _ = try await coordinator.run(
                        operation: {
                            await counter.recordOperation()
                            await operationGate.wait()
                            return "rotated-token"
                        },
                        persist: { _ in
                            await counter.recordPersistence()
                            throw PersistedTaskTestError.persistenceFailed
                        }
                    )
                    return false
                } catch PersistedTaskTestError.persistenceFailed {
                    return true
                } catch {
                    return false
                }
            }
        }

        let creator = startRefresh()
        while await counter.operationCount == 0 { await Task.yield() }
        let follower = startRefresh()
        try? await Task.sleep(for: .milliseconds(50))
        await operationGate.open()

        #expect(await creator.value)
        #expect(await follower.value)
        #expect(await counter.operationCount == 1)
        #expect(await counter.persistenceCount == 1)
    }

    @Test("A failed rotated-token write is retried without another refresh")
    func rotatedTokenPersistenceRecovery() async {
        let coordinator = PersistedTaskDeduplicator<RotatingToken>()
        let oldToken = RotatingToken(
            accessToken: "access-old",
            refreshToken: "refresh-old"
        )
        let rotatedToken = RotatingToken(
            accessToken: "access-new",
            refreshToken: "refresh-new"
        )
        let durableStore = FailableDurableTokenStore(
            token: oldToken,
            failuresRemaining: 1
        )
        let counter = PersistedTaskInvocationCounter()

        do {
            _ = try await coordinator.run(
                operation: {
                    await counter.recordOperation()
                    return rotatedToken
                },
                persist: { token in
                    await counter.recordPersistence()
                    try await durableStore.persist(token)
                }
            )
            Issue.record("Expected the first persistence attempt to fail")
        } catch PersistedTaskTestError.persistenceFailed {
            // The caller observes that the rotated token is not yet durable.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await durableStore.read() == oldToken)

        let recovered: RotatingToken
        do {
            recovered = try await coordinator.retryPersistence(
                of: rotatedToken,
                persist: { token in
                    await counter.recordPersistence()
                    try await durableStore.persist(token)
                }
            )
        } catch {
            Issue.record("Unexpected persistence retry error: \(error)")
            return
        }

        #expect(recovered == rotatedToken)
        #expect(await counter.operationCount == 1)
        #expect(await counter.persistenceCount == 2)

        // A newly-created manager would read the durable store after restart.
        // It must see the rotated refresh token, not the invalidated old one.
        let tokenAfterRestart = await durableStore.read()
        #expect(tokenAfterRestart == rotatedToken)
        #expect(tokenAfterRestart.refreshToken == "refresh-new")
    }
}
