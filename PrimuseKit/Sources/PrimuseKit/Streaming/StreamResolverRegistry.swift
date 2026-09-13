import Foundation
import Network

/// 按 `MusicSourceType` 派发到对应 `StreamResolver` 的注册表 —— tvOS 播放解析的统一入口。
/// Phase 1 只注册 Subsonic 家族;Phase 2 会注册 Synology / 媒体服务器 / 云盘 / S3。
/// 未注册的类型(原生库源 / 本地 / Apple Music)抛 `.unsupportedSourceType`。
public actor StreamResolverRegistry {
    public static let shared = StreamResolverRegistry()

    private let runtime: SourceConnectionRuntime
    private let endpointProbe: SourceNetworkFailurePolicy.EndpointProbe
    private var resolvers: [MusicSourceType: StreamResolver] = [:]
    private let cloudDriveResolver: CloudDriveStreamResolver
    private struct RoutedResolverState: Sendable {
        let candidate: SourceConnectionCandidate
        let routeGeneration: UInt64
    }
    private var routedResolverStates: [String: RoutedResolverState] = [:]

    public init(
        runtime: SourceConnectionRuntime = .shared,
        endpointProbe: @escaping SourceNetworkFailurePolicy.EndpointProbe = SourceConnectionPreflight.check
    ) {
        self.runtime = runtime
        self.endpointProbe = endpointProbe
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
        map[.songloft] = SongloftStreamResolver()
        map[.ugreen] = ugreen
        // WebDAV / UPnP:tvOS 纯 HTTP 直连(Basic Auth / 直链),不再经中继。
        map[.webdav] = WebDavStreamResolver()
        map[.upnp] = UPnPStreamResolver()
        // 其余不可直连的源(SMB/NFS/FTP/SFTP/local)经 iPhone 局域网中继。
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
    /// 必须与 `init` 注册表保持一致。没有 resolver 的是 `appleMusicLibrary`
    /// (macOS iTunesLibrary 源)与 `appleMusic`:后者要由 MusicKit 的
    /// `ApplicationMusicPlayer` 播放,电视端尚未接入,也无法经中继转发。
    /// 新增源类型时,这里与 init 一起更新。
    public nonisolated static let tvSupportedTypes: Set<MusicSourceType> =
        Set(MusicSourceType.allCases).subtracting([.appleMusicLibrary, .appleMusic, .fnos])

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
        await runtime.invalidate(sourceID: source.id)
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
        try Task.checkCancellation()
        guard source.connectionConfiguration != nil else {
            if routedResolverStates.removeValue(forKey: source.id) != nil {
                await resolver.invalidateSession(sourceID: source.id)
            }
            return try await operation(source)
        }

        let candidates = await runtime.orderedCandidates(for: source)
        guard candidates.isEmpty == false else {
            throw StreamResolveError.cannotBuildURL
        }
        let routeGeneration = await runtime.routeGeneration()

        var lastError: Error = StreamResolveError.cannotBuildURL
        for candidate in candidates {
            try Task.checkCancellation()
            let routedSource = source.applyingConnectionCandidate(candidate)
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
                if Self.requiresReachabilityProbe(source.type), candidate.kind != .vendorRemote {
                    guard let endpoint = candidate.endpoint else { throw URLError(.badURL) }
                    try await endpointProbe(endpoint)
                }
                let result = try await operation(routedSource)
                try Task.checkCancellation()
                await runtime.record(candidate.kind, for: source.id)
                return result
            } catch {
                lastError = error
                guard !Task.isCancelled,
                      SourceNetworkFailurePolicy.isNetworkFailure(error),
                      await SourceNetworkFailurePolicy.endpointIsUnreachable(
                        candidate.endpoint, probe: endpointProbe
                      ) else { throw error }
                await resolver.invalidateSession(sourceID: source.id)
                routedResolverStates[source.id] = nil
                await runtime.recordFailure(
                    of: candidate.kind,
                    for: source.id
                )
            }
        }
        throw lastError
    }

    private static func requiresReachabilityProbe(_ type: MusicSourceType) -> Bool {
        switch type {
        case .synology, .qnap, .ugreen, .fnMusic, .daoliyu, .songloft,
             .webdav, .s3, .jellyfin, .emby, .plex,
             .subsonic, .navidrome, .airsonic, .gonic:
            return true
        default:
            return false
        }
    }
}
