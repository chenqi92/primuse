import Foundation

/// 同一台设备上，每个飞牛源的每套凭据只维持一个登录会话，各功能共用。
///
/// 飞牛同一个 deviceId 只认最后一次登录：再登录一次，之前发出去的 token 立刻 401。网页端和
/// 社区客户端都是一台设备一个 deviceId、登录一次、所有功能共用这一个 token。Primuse 的曲库与
/// 歌单、播放、写回、连接诊断、各条线路是各自独立的客户端实例，以前各存各的 token，谁重新
/// 登录都会把别人挤掉：歌单明细翻到一半被挤掉就整份漏掉，电视上正在播的歌后面的分段也取不到。
///
/// 现在都从这里取 token：已有就直接用；同时要登录的等同一次登录；某个请求被服务端拒绝，只作废
/// 它用的那一个再登录一次，其余实例下次被拒时发现已经换过，直接改用新的。
public actor FnMusicSessionStore {
    public static let shared = FnMusicSessionStore()

    /// 同一个源、同一套凭据。凭据一改就是另一个会话，旧 token 不会被新凭据拿去用。
    public struct Account: Hashable, Sendable {
        let sourceID: String
        let username: String
        let passwordHash: String
        let accessCodeHash: String

        public init(sourceID: String, username: String, password: String, accessCode: String?) {
            self.sourceID = sourceID
            self.username = username
            passwordHash = FnMusicAPIProtocol.passwordHash(password)
            accessCodeHash = FnMusicAPIProtocol.passwordHash(accessCode ?? "")
        }
    }

    /// 登录请求走的线路。token 哪条线路都能用，但只合并同一条线路上正在进行的登录：
    /// 卡在一条不通的线路上的登录，不能拖着另一条线路的调用方一起等。
    public struct Route: Hashable, Sendable {
        let host: String?
        let port: Int?
        let useSSL: Bool
        let basePath: String?
        let connectionMode: FnMusicConnectionMode

        public init(
            host: String?,
            port: Int?,
            useSSL: Bool,
            basePath: String?,
            connectionMode: FnMusicConnectionMode
        ) {
            self.host = host
            self.port = port
            self.useSSL = useSSL
            self.basePath = basePath
            self.connectionMode = connectionMode
        }

        public init(source: MusicSource) {
            self.init(
                host: source.host,
                port: source.port,
                useSSL: source.useSsl,
                basePath: source.basePath,
                connectionMode: source.effectiveFnMusicConnectionMode
            )
        }
    }

    private struct PendingLogin {
        let id: UUID
        let task: Task<String, Error>
        var waiters: Int
    }

    private struct Entry {
        var token: String?
        var logins: [Route: PendingLogin] = [:]
        /// 各实例眼下拿着的 token，决定断开时能不能去服务端注销。
        var holders: [UUID: String] = [:]

        var isEmpty: Bool { token == nil && logins.isEmpty && holders.isEmpty }
    }

    private enum WaitOutcome: Sendable {
        case finished(Result<String, Error>)
        case abandoned
    }

    private var entries: [Account: Entry] = [:]

    public init() {}

    /// 这套凭据眼下的 token。已有就直接给；这条线路上正有登录在进行就等它；都没有才调用
    /// `login` 登录一次。调用方取消只影响自己，等着的调用方全走了才取消那次登录。
    public func token(
        for account: Account,
        route: Route,
        holder: UUID,
        login: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        var joinedForeignLogin = false
        while true {
            try Task.checkCancellation()
            if let token = entries[account]?.token {
                entries[account]?.holders[holder] = token
                return token
            }
            var entry = entries[account] ?? Entry()
            var pending: PendingLogin
            if let existing = entry.logins[route] {
                pending = existing
                joinedForeignLogin = true
            } else {
                pending = PendingLogin(id: UUID(), task: Task { try await login() }, waiters: 0)
                joinedForeignLogin = false
            }
            pending.waiters += 1
            entry.logins[route] = pending
            entries[account] = entry

            switch await Self.wait(for: pending.task) {
            case .abandoned:
                leave(account, route: route, loginID: pending.id)
                throw CancellationError()
            case .finished(let result):
                settle(account, route: route, loginID: pending.id, result: result)
                switch result {
                case .success(let token):
                    entries[account, default: Entry()].holders[holder] = token
                    return token
                case .failure(let error):
                    // 等的是别人发起的登录，它被发起方自己取消了：那不是这里的结论，自己登录一次。
                    if joinedForeignLogin, OperationCancellationPolicy.isCancellation(error) {
                        continue
                    }
                    throw error
                }
            }
        }
    }

    /// 用 `token` 的请求被服务端拒绝了。只在它仍是当前 token 时作废：别的实例可能已经
    /// 重新登录过，那份新的要留着。
    public func invalidate(_ account: Account, ifCurrent token: String) {
        guard entries[account]?.token == token else { return }
        entries[account]?.token = nil
    }

    /// 这个实例不再用它的 token 了。返回 true 表示没有别的实例还拿着同一个 token，调用方
    /// 可以去服务端注销，这里也一并忘掉；还有人在用就只摘掉这一个实例。
    @discardableResult
    public func release(_ account: Account, holder: UUID, token: String?) -> Bool {
        var entry = entries[account] ?? Entry()
        entry.holders[holder] = nil
        var isLastHolder = false
        if let token, !entry.holders.values.contains(token) {
            isLastHolder = true
            if entry.token == token { entry.token = nil }
        }
        entries[account] = entry.isEmpty ? nil : entry
        return isLastHolder
    }

    private func settle(_ account: Account, route: Route, loginID: UUID, result: Result<String, Error>) {
        // 第一个醒来的等待方负责落账，其余的看到登录已经摘掉就不再动。
        guard var entry = entries[account], entry.logins[route]?.id == loginID else { return }
        entry.logins[route] = nil
        if case .success(let token) = result { entry.token = token }
        entries[account] = entry.isEmpty ? nil : entry
    }

    private func leave(_ account: Account, route: Route, loginID: UUID) {
        guard var entry = entries[account],
              var pending = entry.logins[route],
              pending.id == loginID else { return }
        pending.waiters -= 1
        if pending.waiters > 0 {
            entry.logins[route] = pending
        } else {
            pending.task.cancel()
            entry.logins[route] = nil
        }
        entries[account] = entry.isEmpty ? nil : entry
    }

    /// 等登录结果，但调用方一取消就立刻返回，不陪着一个不响应取消的请求等下去。
    private nonisolated static func wait(for task: Task<String, Error>) async -> WaitOutcome {
        let race = CancellableResultRace<String>()
        let observer = Task { race.resolve(await task.result) }
        defer { observer.cancel() }
        do {
            let token = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { race.install($0) }
            } onCancel: {
                race.cancel()
            }
            return .finished(.success(token))
        } catch {
            return Task.isCancelled ? .abandoned : .finished(.failure(error))
        }
    }
}
