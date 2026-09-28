import CryptoKit
import Foundation

/// 同一台设备上，每个音乐源的每套凭据只维持一个登录会话，各功能共用。
///
/// 飞牛与 Jellyfin 都只认同一个设备号最后一次登录：再登录一次，之前发出去的 token 立刻失效。
/// 它们的网页端和官方客户端都是一台设备一个设备号、登录一次、所有功能共用那一个 token。
/// Primuse 的曲库与歌单、播放、写回、连接诊断、各条线路是各自独立的客户端实例，以前各存各的
/// token，谁重新登录都会把别人挤掉：歌单明细翻到一半被挤掉就整份漏掉，电视上正在播的歌后面的
/// 分段也取不到。
///
/// 现在都从这里取：已有就直接用；同时要登录的等同一次登录；某个请求被服务端拒绝，只作废它用的
/// 那一个再登录一次，其余实例下次被拒时发现已经换过，直接改用新的。
public actor SourceLoginSessionStore {
    public static let shared = SourceLoginSessionStore()

    /// 登录拿到的凭证。Jellyfin/Emby 还要带上用户 ID，飞牛没有。
    public struct Session: Hashable, Sendable {
        public let token: String
        public let userID: String?

        public init(token: String, userID: String? = nil) {
            self.token = token
            self.userID = userID
        }
    }

    /// 同一个源、同一套凭据。凭据一改就是另一个会话，旧 token 不会被新凭据拿去用。
    public struct Account: Hashable, Sendable {
        let sourceID: String
        let username: String
        let credentialHash: String

        /// `qualifiers` 放其余会改变登录结果的东西（飞牛的访问码、媒体服务器的种类）。
        public init(sourceID: String, username: String, secret: String, qualifiers: [String] = []) {
            self.sourceID = sourceID
            self.username = username
            let material = ([secret] + qualifiers).joined(separator: "\u{0}")
            credentialHash = SHA256.hash(data: Data(material.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    /// 登录请求走的线路。token 哪条线路都能用，但只合并同一条线路上正在进行的登录：
    /// 卡在一条不通的线路上的登录，不能拖着另一条线路的调用方一起等。
    public struct Route: Hashable, Sendable {
        let host: String?
        let port: Int?
        let useSSL: Bool
        let basePath: String?
        let variant: String

        public init(host: String?, port: Int?, useSSL: Bool, basePath: String?, variant: String = "") {
            self.host = host
            self.port = port
            self.useSSL = useSSL
            self.basePath = basePath
            self.variant = variant
        }

        public init(source: MusicSource) {
            self.init(
                host: source.host,
                port: source.port,
                useSSL: source.useSsl,
                basePath: source.basePath,
                variant: source.type == .fnMusic ? source.effectiveFnMusicConnectionMode.rawValue : ""
            )
        }

        /// 已经拼好的服务地址（媒体服务器按它区分线路）。
        public init(endpoint: URL) {
            self.init(host: endpoint.absoluteString, port: nil, useSSL: endpoint.scheme == "https", basePath: nil)
        }
    }

    private struct PendingLogin {
        let id: UUID
        let task: Task<Session, Error>
        var waiters: Int
    }

    private struct Entry {
        var session: Session?
        var logins: [Route: PendingLogin] = [:]
        /// 各实例眼下拿着的 token，决定断开时能不能去服务端注销。
        var holders: [UUID: String] = [:]

        var isEmpty: Bool { session == nil && logins.isEmpty && holders.isEmpty }
    }

    private enum WaitOutcome: Sendable {
        case finished(Result<Session, Error>)
        case abandoned
    }

    private var entries: [Account: Entry] = [:]

    public init() {}

    /// 这套凭据眼下的会话。已有就直接给；这条线路上正有登录在进行就等它；都没有才调用
    /// `login` 登录一次。调用方取消只影响自己，等着的调用方全走了才取消那次登录。
    public func session(
        for account: Account,
        route: Route,
        holder: UUID,
        login: @escaping @Sendable () async throws -> Session
    ) async throws -> Session {
        var joinedForeignLogin = false
        while true {
            try Task.checkCancellation()
            if let session = entries[account]?.session {
                entries[account]?.holders[holder] = session.token
                return session
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
                case .success(let session):
                    entries[account, default: Entry()].holders[holder] = session.token
                    return session
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

    /// 只需要 token 的调用方（飞牛）用这个。
    public func token(
        for account: Account,
        route: Route,
        holder: UUID,
        login: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await session(for: account, route: route, holder: holder) {
            Session(token: try await login())
        }.token
    }

    /// 用 `token` 的请求被服务端拒绝了。只在它仍是当前 token 时作废：别的实例可能已经
    /// 重新登录过，那份新的要留着。
    public func invalidate(_ account: Account, ifCurrent token: String) {
        guard entries[account]?.session?.token == token else { return }
        entries[account]?.session = nil
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
            if entry.session?.token == token { entry.session = nil }
        }
        entries[account] = entry.isEmpty ? nil : entry
        return isLastHolder
    }

    private func settle(_ account: Account, route: Route, loginID: UUID, result: Result<Session, Error>) {
        // 第一个醒来的等待方负责落账，其余的看到登录已经摘掉就不再动。
        guard var entry = entries[account], entry.logins[route]?.id == loginID else { return }
        entry.logins[route] = nil
        if case .success(let session) = result { entry.session = session }
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
    private nonisolated static func wait(for task: Task<Session, Error>) async -> WaitOutcome {
        let race = CancellableResultRace<Session>()
        let observer = Task { race.resolve(await task.result) }
        defer { observer.cancel() }
        do {
            let session = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { race.install($0) }
            } onCancel: {
                race.cancel()
            }
            return .finished(.success(session))
        } catch {
            return Task.isCancelled ? .abandoned : .finished(.failure(error))
        }
    }
}

/// Jellyfin / Emby / Plex 认的设备号：每台设备、每个源一个，同一个源的各功能共用。
///
/// 以前是 `primuse-<源 ID>`，而源经 iCloud 同步，iPhone、Mac、Apple TV 就成了同一台「设备」：
/// Jellyfin 对同一用户同一设备号只留最后一次登录，几台设备互相踢下线。Emby 还会注销同一设备号
/// 下别的用户的 token，所以不同源（可能是不同账号）也不能共用一个号。
public enum MediaServerDeviceIdentity {
    private static let seedDefaultsKey = "com.primuse.media-server.device-seed.v1"
    private static let seedLock = NSLock()

    public static func deviceID(sourceID: String, defaults: UserDefaults = .standard) -> String {
        let material = "\(installationSeed(defaults: defaults)):\(sourceID)"
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return "primuse-" + digest.prefix(32)
    }

    /// 服务器设备列表里显示的名字。
    public static var deviceName: String {
        #if os(tvOS)
        return "Apple TV"
        #elseif os(macOS)
        return "Mac"
        #else
        return "iOS"
        #endif
    }

    private static func installationSeed(defaults: UserDefaults) -> String {
        seedLock.lock()
        defer { seedLock.unlock() }
        if let stored = defaults.string(forKey: seedDefaultsKey), stored.count == 32 {
            return stored
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(generated, forKey: seedDefaultsKey)
        return generated
    }
}
