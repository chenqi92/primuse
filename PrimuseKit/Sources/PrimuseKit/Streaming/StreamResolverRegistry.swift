import Foundation

/// 按 `MusicSourceType` 派发到对应 `StreamResolver` 的注册表 —— tvOS 播放解析的统一入口。
/// Phase 1 只注册 Subsonic 家族;Phase 2 会注册 Synology / 媒体服务器 / 云盘 / S3。
/// 未注册的类型(原生库源 / 本地 / Apple Music)抛 `.unsupportedSourceType`。
public actor StreamResolverRegistry {
    public static let shared = StreamResolverRegistry()

    private var resolvers: [MusicSourceType: StreamResolver] = [:]

    public init() {
        // Phase 1:Subsonic 家族共用一个无状态 resolver。直接在 init 里建表
        // (actor init 是同步的,不能调用 actor-isolated 方法)。
        let subsonic = SubsonicStreamResolver()
        let synology = SynologyStreamResolver()
        let s3 = S3StreamResolver()
        let cloud = CloudDriveStreamResolver()
        let baidu = BaiduPanStreamResolver()
        let media = MediaServerStreamResolver()
        let nas = NasHttpStreamResolver()
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
        for type in [MusicSourceType.qnap, .fnos] {
            map[type] = nas
        }
        map[.ugreen] = ugreen
        // 云盘:阿里/OneDrive/Dropbox/123 直链直连;Google/115 经 resource loader 带播放头。
        for type in [MusicSourceType.aliyunDrive, .oneDrive, .dropbox, .pan123, .googleDrive, .pan115] {
            map[type] = cloud
        }
        map[.baiduPan] = baidu   // list→fs_id→filemetas→CDN,播放带 UA(resource loader)
        resolvers = map
    }

    public func register(_ resolver: StreamResolver, for types: [MusicSourceType]) {
        for type in types { resolvers[type] = resolver }
    }

    public func resolver(for type: MusicSourceType) -> StreamResolver? { resolvers[type] }

    /// 支持在 tvOS 上流式播放的源类型(已注册 resolver)。
    public var supportedTypes: Set<MusicSourceType> { Set(resolvers.keys) }

    public func streamURL(for song: Song,
                          source: MusicSource,
                          credential: SourceCredential?) async throws -> URL {
        guard let resolver = resolvers[source.type] else {
            throw StreamResolveError.unsupportedSourceType(source.type)
        }
        return try await resolver.streamURL(for: song, source: source, credential: credential)
    }

    public func resolve(for song: Song,
                        source: MusicSource,
                        credential: SourceCredential?) async throws -> ResolvedStream {
        guard let resolver = resolvers[source.type] else {
            throw StreamResolveError.unsupportedSourceType(source.type)
        }
        return try await resolver.resolve(for: song, source: source, credential: credential)
    }

    public func invalidateSession(for source: MusicSource) async {
        await resolvers[source.type]?.invalidateSession(sourceID: source.id)
    }
}
