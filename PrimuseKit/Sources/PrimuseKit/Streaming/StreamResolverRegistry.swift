import Foundation
import Network

private final class SourceConnectionProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private let connection: NWConnection

    init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Bool) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        connection.cancel()
        continuation.resume(returning: result)
    }
}

/// 按 `MusicSourceType` 派发到对应 `StreamResolver` 的注册表 —— tvOS 播放解析的统一入口。
/// Phase 1 只注册 Subsonic 家族;Phase 2 会注册 Synology / 媒体服务器 / 云盘 / S3。
/// 未注册的类型(原生库源 / 本地 / Apple Music)抛 `.unsupportedSourceType`。
public actor StreamResolverRegistry {
    public static let shared = StreamResolverRegistry()

    private var resolvers: [MusicSourceType: StreamResolver] = [:]
    private let cloudDriveResolver: CloudDriveStreamResolver
    private struct RoutedResolverState: Sendable {
        let candidate: SourceConnectionCandidate
        let routeGeneration: UInt64
    }
    private var routedResolverStates: [String: RoutedResolverState] = [:]

    public init() {
        // Phase 1:Subsonic 家族共用一个无状态 resolver。直接在 init 里建表
        // (actor init 是同步的,不能调用 actor-isolated 方法)。
        let subsonic = SubsonicStreamResolver()
        let synology = SynologyStreamResolver()
        let s3 = S3StreamResolver()
        let cloud = CloudDriveStreamResolver()
        cloudDriveResolver = cloud
        let baidu = BaiduPanStreamResolver()
        let media = MediaServerStreamResolver()
        let nas = NasHttpStreamResolver()
        let fnMusic = FnMusicStreamResolver()
        let daoLiYu = DaoLiYuStreamResolver()
        let ugreen = UgreenStreamResolver()
        var map: [MusicSourceType: StreamResolver] = [:]
        for type in [MusicSourceType.subsonic, .navidrome, .airsonic, .gonic] {
            map[type] = subsonic
        }
        map[.synology] = synology
        map[.s3] = s3
        for type in [MusicSourceType.jellyfin, .emby, .plex] {
            map[type] = media
        }
        map[.qnap] = nas
        map[.fnMusic] = fnMusic
        map[.daoliyu] = daoLiYu
        map[.ugreen] = ugreen
        // WebDAV / UPnP:tvOS 纯 HTTP 直连(Basic Auth / 直链),不再经中继。
        map[.webdav] = WebDavStreamResolver()
        map[.upnp] = UPnPStreamResolver()
        // 其余不可直连的源(SMB/NFS/FTP/SFTP/local/appleMusic)经 iPhone 局域网中继。
        let relay = RelayStreamResolver()
        for type in RelayStreamResolver.relayTypes { map[type] = relay }
        // 云盘:阿里/OneDrive/Dropbox/123 直链直连;Google/115/Drime 经 resource loader 带播放头。
        for type in [MusicSourceType.aliyunDrive, .oneDrive, .dropbox, .pan123, .googleDrive, .pan115, .drime] {
            map[type] = cloud
        }
        map[.baiduPan] = baidu   // list→fs_id→filemetas→CDN,播放带 UA(resource loader)
        resolvers = map
    }

    public func register(_ resolver: StreamResolver, for types: [MusicSourceType]) {
        for type in types { resolvers[type] = resolver }
    }

    public func resolver(for type: MusicSourceType) -> StreamResolver? { resolvers[type] }

    public func setCloudCredentialRefreshHandler(_ handler: CloudCredentialRefreshHandler?) async {
        await cloudDriveResolver.setCredentialRefreshHandler(handler)
    }

    public func listCloudDirectory(
        source: MusicSource,
        credential: SourceCredential?,
        path: String
    ) async throws -> [CloudDriveDirectoryEntry] {
        try await cloudDriveResolver.listDirectory(
            source: source,
            credential: credential,
            path: path
        )
    }

    /// 支持在 tvOS 上流式播放的源类型(已注册 resolver)。
    public var supportedTypes: Set<MusicSourceType> { Set(resolvers.keys) }

    /// `supportedTypes` 的同步可读版,供 UI(非 async 上下文)判断源能否在 TV 播放。
    /// 必须与 `init` 注册表保持一致:当前唯一没有 resolver 的是 `appleMusicLibrary`
    /// (macOS iTunesLibrary 源)。新增源类型时,这里与 init 一起更新。
    public nonisolated static let tvSupportedTypes: Set<MusicSourceType> =
        Set(MusicSourceType.allCases).subtracting([.appleMusicLibrary, .fnos])

    public func streamURL(for song: Song,
                          source: MusicSource,
                          credential: SourceCredential?) async throws -> URL {
        guard let resolver = resolvers[source.type] else {
            throw StreamResolveError.unsupportedSourceType(source.type)
        }
        return try await withRoutedSource(source, resolver: resolver) { routedSource in
            try await resolver.streamURL(
                for: song,
                source: routedSource,
                credential: credential
            )
        }
    }

    public func resolve(for song: Song,
                        source: MusicSource,
                        credential: SourceCredential?) async throws -> ResolvedStream {
        guard let resolver = resolvers[source.type] else {
            throw StreamResolveError.unsupportedSourceType(source.type)
        }
        return try await withRoutedSource(source, resolver: resolver) { routedSource in
            try await resolver.resolve(
                for: song,
                source: routedSource,
                credential: credential
            )
        }
    }

    public func invalidateSession(for source: MusicSource) async {
        await resolvers[source.type]?.invalidateSession(sourceID: source.id)
        routedResolverStates[source.id] = nil
        await SourceConnectionRuntime.shared.invalidate(sourceID: source.id)
    }

    /// 2FA:用一次性验证码登录并申请受信设备令牌(deviceId)。返回 nil 表示该源不返回令牌。
    public func loginForDeviceToken(source: MusicSource,
                                    credential: SourceCredential?,
                                    otp: String) async throws -> String? {
        guard let resolver = resolvers[source.type] else {
            throw StreamResolveError.unsupportedSourceType(source.type)
        }
        return try await withRoutedSource(source, resolver: resolver) { routedSource in
            try await resolver.loginForDeviceToken(
                source: routedSource,
                credential: credential,
                otp: otp
            )
        }
    }

    private func withRoutedSource<T: Sendable>(
        _ source: MusicSource,
        resolver: any StreamResolver,
        operation: @Sendable (MusicSource) async throws -> T
    ) async throws -> T {
        guard source.connectionConfiguration != nil else {
            if routedResolverStates.removeValue(forKey: source.id) != nil {
                await resolver.invalidateSession(sourceID: source.id)
            }
            return try await operation(source)
        }

        let candidates = await SourceConnectionRuntime.shared.orderedCandidates(for: source)
        guard candidates.isEmpty == false else {
            throw StreamResolveError.cannotBuildURL
        }
        let routeGeneration = await SourceConnectionRuntime.shared.routeGeneration()

        var lastError: Error = StreamResolveError.cannotBuildURL
        for candidate in candidates {
            let routedSource = source.applyingConnectionCandidate(candidate)
            if Self.requiresReachabilityProbe(source.type),
               candidate.kind != .vendorRemote,
               await tcpReachable(routedSource) == false {
                lastError = URLError(.cannotConnectToHost)
                await SourceConnectionRuntime.shared.recordFailure(
                    of: candidate.kind,
                    for: source.id
                )
                continue
            }

            let currentState = routedResolverStates[source.id]
            if currentState?.candidate != candidate
                || currentState?.routeGeneration != routeGeneration {
                await resolver.invalidateSession(sourceID: source.id)
                routedResolverStates[source.id] = RoutedResolverState(
                    candidate: candidate,
                    routeGeneration: routeGeneration
                )
            }

            do {
                let result = try await operation(routedSource)
                await SourceConnectionRuntime.shared.record(candidate.kind, for: source.id)
                return result
            } catch {
                lastError = error
                guard Self.canFailOver(
                    after: error,
                    from: candidate,
                    among: candidates
                ) else { throw error }
                await resolver.invalidateSession(sourceID: source.id)
                routedResolverStates[source.id] = nil
                await SourceConnectionRuntime.shared.recordFailure(
                    of: candidate.kind,
                    for: source.id
                )
            }
        }
        throw lastError
    }

    private func tcpReachable(_ source: MusicSource) async -> Bool {
        let rawHost = source.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard rawHost.isEmpty == false else { return false }

        let host: String
        if let components = URLComponents(string: rawHost), let parsed = components.host {
            host = parsed
        } else if let components = URLComponents(string: "http://\(rawHost)"),
                  let parsed = components.host {
            host = parsed
        } else {
            host = rawHost
        }
        let rawPort = source.port ?? (source.useSsl ? 443 : 80)
        guard let port = NWEndpoint.Port(rawValue: UInt16(rawPort)) else { return false }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let completion = SourceConnectionProbeCompletion(
                connection: connection,
                continuation: continuation
            )
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(true)
                case .failed, .cancelled:
                    completion.finish(false)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
                completion.finish(false)
            }
        }
    }

    private static func canFailOver(after error: Error) -> Bool {
        guard let streamError = error as? StreamResolveError else { return true }
        switch streamError {
        case .missingCredential, .authFailed, .needs2FA:
            return false
        case .unsupportedSourceType, .badServerResponse, .cannotBuildURL, .relayUnavailable:
            return true
        }
    }

    private static func canFailOver(
        after error: Error,
        from candidate: SourceConnectionCandidate,
        among candidates: [SourceConnectionCandidate]
    ) -> Bool {
        if canFailOver(after: error) { return true }
        return candidate.kind == .localAddress
            && candidates.contains { $0.kind != .localAddress }
    }

    private static func requiresReachabilityProbe(_ type: MusicSourceType) -> Bool {
        switch type {
        case .synology, .qnap, .ugreen, .fnMusic, .daoliyu,
             .webdav, .s3, .jellyfin, .emby, .plex,
             .subsonic, .navidrome, .airsonic, .gonic:
            return true
        default:
            return false
        }
    }
}
