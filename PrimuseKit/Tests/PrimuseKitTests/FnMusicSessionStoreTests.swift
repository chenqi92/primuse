import Foundation
import Testing
@testable import PrimuseKit

@Suite("Feiniu shared login session")
struct FnMusicSessionStoreTests {
    private let account = FnMusicSessionStore.Account(
        sourceID: "source", username: "qa", password: "test", accessCode: nil
    )
    private let lan = FnMusicSessionStore.Route(
        host: "192.168.0.2", port: 5666, useSSL: false, basePath: nil, connectionMode: .address
    )
    private let remote = FnMusicSessionStore.Route(
        host: "nas", port: nil, useSSL: true, basePath: nil, connectionMode: .fnConnect
    )

    @Test func concurrentCallersOnOneRouteShareOneLogin() async throws {
        let store = FnMusicSessionStore()
        let logins = LoginCounter()
        let login: @Sendable () async throws -> String = {
            let count = await logins.increment()
            try await Task.sleep(for: .milliseconds(50))
            return "token-\(count)"
        }
        async let first = store.token(for: account, route: lan, holder: UUID(), login: login)
        async let second = store.token(for: account, route: lan, holder: UUID(), login: login)
        let tokens = try await [first, second]
        #expect(tokens == ["token-1", "token-1"])
        #expect(await logins.count == 1)
        // 已有 token 时后来的调用方直接用，不再登录。
        #expect(try await store.token(for: account, route: remote, holder: UUID(), login: login) == "token-1")
        #expect(await logins.count == 1)
    }

    /// 卡在一条线路上的登录不拖着另一条线路的调用方一起等。
    @Test func aLoginStuckOnOneRouteDoesNotHoldBackAnotherRoute() async throws {
        let store = FnMusicSessionStore()
        let stuck = Task {
            try await store.token(for: account, route: lan, holder: UUID()) {
                try await Task.sleep(for: .seconds(30))
                return "lan"
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let started = Date()
        let token = try await store.token(for: account, route: remote, holder: UUID()) { "remote" }
        #expect(token == "remote")
        #expect(Date().timeIntervalSince(started) < 5)
        stuck.cancel()
    }

    @Test func onlyTheCurrentTokenIsInvalidated() async throws {
        let store = FnMusicSessionStore()
        let logins = LoginCounter()
        let login: @Sendable () async throws -> String = { "token-\(await logins.increment())" }
        #expect(try await store.token(for: account, route: lan, holder: UUID(), login: login) == "token-1")
        await store.invalidate(account, ifCurrent: "token-1")
        #expect(try await store.token(for: account, route: lan, holder: UUID(), login: login) == "token-2")
        // 另一个实例晚到的拒绝针对的是旧 token，不能把刚换上的新 token 也作废。
        await store.invalidate(account, ifCurrent: "token-1")
        #expect(try await store.token(for: account, route: lan, holder: UUID(), login: login) == "token-2")
        #expect(await logins.count == 2)
    }

    @Test func oneWaiterLeavingDoesNotCancelTheLoginOthersStillWaitFor() async throws {
        let store = FnMusicSessionStore()
        let login: @Sendable () async throws -> String = {
            try await Task.sleep(for: .milliseconds(200))
            return "token"
        }
        let leaving = Task { try await store.token(for: account, route: lan, holder: UUID(), login: login) }
        try await Task.sleep(for: .milliseconds(20))
        let staying = Task { try await store.token(for: account, route: lan, holder: UUID(), login: login) }
        try await Task.sleep(for: .milliseconds(20))
        leaving.cancel()
        await #expect(throws: CancellationError.self) { try await leaving.value }
        #expect(try await staying.value == "token")
    }

    @Test func theLastWaiterLeavingCancelsTheLogin() async throws {
        let store = FnMusicSessionStore()
        let observed = LoginCounter()
        let waiter = Task {
            try await store.token(for: account, route: lan, holder: UUID()) {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await observed.increment()
                    throw error
                }
                return "token"
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        for _ in 0..<100 {
            if await observed.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await observed.count == 1)
        // 下一个调用方重新登录，而不是拿到那次被取消的结果。
        #expect(try await store.token(for: account, route: lan, holder: UUID()) { "fresh" } == "fresh")
    }

    /// 等的是别人发起的登录、它被发起方那边取消了：自己再登录一次，而不是跟着失败。
    @Test func aJoinedLoginCancelledByItsStarterIsRetriedWithTheWaitersOwnLogin() async throws {
        let store = FnMusicSessionStore()
        let starter = Task {
            try await store.token(for: account, route: lan, holder: UUID()) {
                try await Task.sleep(for: .milliseconds(100))
                throw CancellationError()
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let joined = try await store.token(for: account, route: lan, holder: UUID()) { "own" }
        #expect(joined == "own")
        _ = try? await starter.value
    }

    @Test func onlyTheLastHolderMayLogTheSessionOut() async throws {
        let store = FnMusicSessionStore()
        let playback = UUID()
        let writeback = UUID()
        let logins = LoginCounter()
        let login: @Sendable () async throws -> String = { "token-\(await logins.increment())" }
        _ = try await store.token(for: account, route: lan, holder: playback, login: login)
        _ = try await store.token(for: account, route: lan, holder: writeback, login: login)

        #expect(await store.release(account, holder: writeback, token: "token-1") == false)
        #expect(try await store.token(for: account, route: lan, holder: writeback, login: login) == "token-1")
        #expect(await store.release(account, holder: writeback, token: nil) == false)
        #expect(await store.release(account, holder: playback, token: "token-1") == true)
        // 注销过的会话不再发给别人。
        #expect(try await store.token(for: account, route: lan, holder: UUID(), login: login) == "token-2")
    }

    @Test func differentCredentialsNeverShareASession() async throws {
        let store = FnMusicSessionStore()
        let changed = FnMusicSessionStore.Account(
            sourceID: "source", username: "qa", password: "changed", accessCode: nil
        )
        _ = try await store.token(for: account, route: lan, holder: UUID()) { "old" }
        #expect(try await store.token(for: changed, route: lan, holder: UUID()) { "new" } == "new")
    }
}

private actor LoginCounter {
    private(set) var count = 0

    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }
}
