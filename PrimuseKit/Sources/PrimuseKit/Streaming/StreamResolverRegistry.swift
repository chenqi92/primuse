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
    /// 这条线路刚证明过能连上:连接检查通过,或者播放 / 预取刚从它收到音频字节。
    /// 有效期内同一线路、同一网络代次上的解析不再先做 TCP 检查 —— 切歌时这一来一回
    /// 就是一两秒静音。换线路、换网络、`invalidateSession`、线路报网络错误都会让它作废。
    private struct RouteEvidence: Sendable {
        let candidate: SourceConnectionCandidate
        let routeGeneration: UInt64
        let validUntil: TimeInterval
    }
    private var routeEvidence: [String: RouteEvidence] = [:]
    /// 每个源的会话代次:resolver 里的会话被清掉(换线路、线路失败、`invalidateSession`)
    /// 后加一。提前解析好的流地址记着解析时的代次,起播时对不上就不拿来用。
    private var sessionEpochs: [String: UInt64] = [:]
    private let uptime: @Sendable () -> TimeInterval

    /// 提前解析的流(下一首在当前这首播放时就解析好),连同解析时所在的网络代次与会话代次。
    /// 起播前用 `routeGeneration()` 与 `sessionEpoch(for:)` 核对,都没变才用。
    public struct PreparedResolution: Sendable, Equatable {
        public let stream: ResolvedStream
        public let routeGeneration: UInt64
        public let sessionEpoch: UInt64
    }

    private struct RoutedResult<T: Sendable>: Sendable {
        let value: T
        let routeGeneration: UInt64
        let sessionEpoch: UInt64
    }

    public init(
        runtime: SourceConnectionRuntime = .shared,
        endpointProbe: @escaping SourceNetworkFailurePolicy.EndpointProbe = SourceConnectionPreflight.check,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.runtime = runtime
        self.endpointProbe = endpointProbe
        self.uptime = uptime
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
        map[.audiobookshelf] = AudiobookshelfStreamResolver()
        map[.synologyAudioStation] = SynologyAudioStationStreamResolver()
        map[.tingReader] = TingReaderStreamResolver()
        map[.ugreen] = ugreen
        // WebDAV / UPnP:tvOS 纯 HTTP 直连(Basic Auth / 直链),不再经中继。
        map[.webdav] = WebDavStreamResolver()
        map[.upnp] = UPnPStreamResolver()
        // 其余不可直连的源(SMB/NFS/FTP/SFTP/local)经 iPhone 局域网中继。
        let relay = RelayStreamResolver()
        for type in RelayStreamResolver.relayTypes { map[type] = relay }
        // 云盘:阿里/OneDrive/Dropbox/123/光鸭 直链直连;Google/115/Drime 经
        // resource loader 带播放头。
        for type in [MusicSourceType.aliyunDrive, .oneDrive, .dropbox, .pan123, .googleDrive,
                     .pan115, .drime, .guangya] {
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
    /// 电视端能播的类型。`appleMusicLibrary`(macOS iTunesLibrary 源)与 `fnos`
    /// 没有实现。`appleMusic` 不经本注册表:它是 DRM 流,由 MusicKit 的
    /// `ApplicationMusicPlayer` 直接播放(见 `AppleMusicTVPlaybackPolicy`),
    /// 所以 `supportedTypes` 里没有它,这里却要算可播。
    /// 新增源类型时,这里与 init 一起更新。
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

    /// 解析下一首的流,并记下解析时的网络代次与会话代次(见 `PreparedResolution`)。
    public func resolveForPreparation(for song: Song,
                                      source: MusicSource,
                                      credential: SourceCredential?) async throws -> PreparedResolution {
        guard let resolver = resolvers[source.type] else {
            throw StreamResolveError.unsupportedSourceType(source.type)
        }
        let result = try await routedOperation(source, resolver: resolver) { routedSource in
            try await resolver.resolve(
                for: song,
                source: routedSource,
                credential: credential
            )
        }
        return PreparedResolution(
            stream: result.value,
            routeGeneration: result.routeGeneration,
            sessionEpoch: result.sessionEpoch
        )
    }

    public func routeGeneration() async -> UInt64 {
        await runtime.routeGeneration()
    }

    public func sessionEpoch(for sourceID: String) -> UInt64 {
        sessionEpochs[sourceID] ?? 0
    }

    /// 播放或预取刚从这个源收到音频字节(2xx 响应里的数据)。字节到得了,线路就是通的,
    /// 和一次连接检查一样可靠:`PlaybackSourceAvailabilityPolicy.transferEvidenceLifetime`
    /// 内从这个源起播下一首不再先检查。只记在当前线路与网络代次上。
    public func recordTransfer(sourceID: String) async {
        let generation = await runtime.routeGeneration()
        guard let state = routedResolverStates[sourceID],
              state.routeGeneration == generation else { return }
        noteRouteEvidence(
            sourceID: sourceID,
            candidate: state.candidate,
            routeGeneration: generation,
            lifetime: PlaybackSourceAvailabilityPolicy.transferEvidenceLifetime
        )
    }

    public func invalidateSession(for source: MusicSource) async {
        await resolvers[source.type]?.invalidateSession(sourceID: source.id)
        routedResolverStates[source.id] = nil
        routeEvidence[source.id] = nil
        sessionEpochs[source.id, default: 0] &+= 1
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
        try await routedOperation(source, resolver: resolver, operation: operation).value
    }

    private func routedOperation<T: Sendable>(
        _ source: MusicSource,
        resolver: any StreamResolver,
        operation: @Sendable (MusicSource) async throws -> T
    ) async throws -> RoutedResult<T> {
        try Task.checkCancellation()
        guard source.connectionConfiguration != nil else {
            if routedResolverStates.removeValue(forKey: source.id) != nil {
                await resetResolverSession(sourceID: source.id, resolver: resolver)
            }
            let generation = await runtime.routeGeneration()
            let epoch = sessionEpoch(for: source.id)
            let value = try await operation(source)
            return RoutedResult(value: value, routeGeneration: generation, sessionEpoch: epoch)
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
                await resetResolverSession(sourceID: source.id, resolver: resolver)
                routedResolverStates[source.id] = RoutedResolverState(
                    candidate: candidate,
                    routeGeneration: routeGeneration
                )
            }

            var failedProbeGeneration: UInt64?
            do {
                if Self.requiresReachabilityProbe(source.type), candidate.kind != .vendorRemote {
                    guard let endpoint = candidate.endpoint else { throw URLError(.badURL) }
                    let generation = await runtime.routeGeneration()
                    if !hasRouteEvidence(sourceID: source.id, candidate: candidate, routeGeneration: generation) {
                        do {
                            try await endpointProbe(endpoint)
                        } catch {
                            failedProbeGeneration = generation
                            throw error
                        }
                        noteRouteEvidence(
                            sourceID: source.id,
                            candidate: candidate,
                            routeGeneration: generation,
                            lifetime: PlaybackSourceAvailabilityPolicy.reachableVerdictLifetime
                        )
                    }
                }
                let epoch = sessionEpoch(for: source.id)
                let result = try await operation(routedSource)
                try Task.checkCancellation()
                await runtime.record(candidate.kind, for: source.id)
                return RoutedResult(
                    value: result,
                    routeGeneration: routeGeneration,
                    sessionEpoch: epoch
                )
            } catch {
                lastError = error
                guard !Task.isCancelled,
                      SourceNetworkFailurePolicy.isNetworkFailure(error) else { throw error }
                // 线路报了网络错误,之前的连通证据不再算数;下面照旧另做一次独立检查。
                routeEvidence[source.id] = nil
                let currentGeneration = await runtime.routeGeneration()
                // This preflight already supplied independent transport evidence.
                // A service error or a changed network still needs a fresh probe.
                if failedProbeGeneration != currentGeneration {
                    guard await SourceNetworkFailurePolicy.endpointIsUnreachable(
                        candidate.endpoint, probe: endpointProbe
                    ) else { throw error }
                }
                guard !Task.isCancelled,
                      await runtime.routeGeneration() == currentGeneration else { throw error }
                await resetResolverSession(sourceID: source.id, resolver: resolver)
                routedResolverStates[source.id] = nil
                await runtime.recordFailure(
                    of: candidate.kind,
                    for: source.id,
                    reason: SourceRouteFailureReason.classify(error)
                )
            }
        }
        throw lastError
    }

    /// 清掉 resolver 里这个源的会话;会话代次在清完之后加一,清理期间解析出的地址也一并作废。
    private func resetResolverSession(sourceID: String, resolver: any StreamResolver) async {
        await resolver.invalidateSession(sourceID: sourceID)
        sessionEpochs[sourceID, default: 0] &+= 1
    }

    private func hasRouteEvidence(
        sourceID: String,
        candidate: SourceConnectionCandidate,
        routeGeneration: UInt64
    ) -> Bool {
        guard let evidence = routeEvidence[sourceID],
              evidence.candidate == candidate,
              evidence.routeGeneration == routeGeneration else { return false }
        return uptime() < evidence.validUntil
    }

    private func noteRouteEvidence(
        sourceID: String,
        candidate: SourceConnectionCandidate,
        routeGeneration: UInt64,
        lifetime: TimeInterval
    ) {
        let validUntil = uptime() + lifetime
        if let current = routeEvidence[sourceID],
           current.candidate == candidate,
           current.routeGeneration == routeGeneration,
           current.validUntil >= validUntil {
            return
        }
        routeEvidence[sourceID] = RouteEvidence(
            candidate: candidate,
            routeGeneration: routeGeneration,
            validUntil: validUntil
        )
    }

    private static func requiresReachabilityProbe(_ type: MusicSourceType) -> Bool {
        switch type {
        case .synology, .qnap, .ugreen, .fnMusic, .daoliyu, .songloft, .audiobookshelf, .synologyAudioStation,
             .tingReader, .webdav, .s3, .jellyfin, .emby, .plex,
             .subsonic, .navidrome, .airsonic, .gonic:
            return true
        default:
            return false
        }
    }
}
