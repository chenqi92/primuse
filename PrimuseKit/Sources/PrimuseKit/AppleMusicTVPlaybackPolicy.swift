import Foundation

/// MusicKit 的授权状态,抽成不依赖框架的形式,便于在没有 MusicKit 的环境里断言。
public enum AppleMusicAuthorizationState: String, Sendable, Equatable, CaseIterable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

/// Apple TV 上把一首歌交给 MusicKit `ApplicationMusicPlayer` 播放的判定。
///
/// 与 iPhone / Mac 的差别只在触发方式:手机端有「搜索页直接点目录里的歌」这条
/// 绕开 `play(song:)` 的入口,所以要靠通知解耦、并自建一套 requestID 代次;
/// 电视端所有播放都必须经过 `TVPlaybackCoordinator.play(songID:requestID:)`,
/// 那个 requestID 本身就是代次,不需要再加一层。移交要做的事是一样的:
/// 自家引擎先停、音频会话让出去、再把 MusicKit 的状态回灌成本机播放状态。
public enum AppleMusicTVPlaybackPolicy {
    /// 这首歌是否要交给系统播放器。Apple Music 是 DRM 流,既不能按字节读,
    /// 也不能经 iPhone 中继转发,只有 MusicKit 自己能播。
    public static func usesSystemPlayer(sourceType: MusicSourceType, sourceID: String) -> Bool {
        sourceType == .appleMusic || sourceID == AppleMusicLibraryIdentity.sourceID
    }

    /// `Song.filePath` 里存的就是 MusicKit 的 item ID(见 `toPrimuseSong`)。
    public static func itemID(fromFilePath filePath: String) -> String? {
        let trimmed = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 该 item 要用资料库查询还是目录查询。`i.` 开头是资料库地址。
    public static func usesUserLibraryLookup(itemID: String) -> Bool {
        AppleMusicItemLookupPolicy.shouldUseUserLibrary(
            itemID: itemID,
            confirmedLocalFileIDs: []
        )
    }

    public enum Readiness: Equatable, Sendable {
        /// 可以开播。
        case ready
        /// 还没问过用户,应当发起授权请求。
        case needsAuthorization
        /// 用户拒绝过,只能去系统设置里改。
        case denied
        /// 被家长控制等策略限制。
        case restricted
        /// 已授权但没有可播放目录内容的订阅。
        case needsSubscription
    }

    /// - Parameters:
    ///   - canPlayCatalogContent: `MusicSubscription.canPlayCatalogContent`。
    ///   - playbackSource: 该 item 解析出的来源。资料库里用户自己导入的文件
    ///     不需要订阅,不能被订阅检查挡住。
    public static func readiness(
        authorization: AppleMusicAuthorizationState,
        canPlayCatalogContent: Bool,
        playbackSource: AppleMusicPlaybackSource
    ) -> Readiness {
        switch authorization {
        case .notDetermined: return .needsAuthorization
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: break
        }
        guard AppleMusicSubscriptionGatePolicy.requiresCatalogCapability(for: playbackSource) else {
            return .ready
        }
        return canPlayCatalogContent ? .ready : .needsSubscription
    }

    /// 移交给系统播放器之前,本机引擎必须先停到什么程度。
    /// 光调 `pause()` 不够:AVPlayer 仍持有音频会话,MusicKit 起播时两边会抢。
    public static let requiresLocalEngineStop = true

    /// MusicKit 不开放音频抽头,系统播放器接管时拿不到实时频谱。
    /// 沉浸模式里依赖频谱的主题要据此退回静态表现,而不是画一排恒零的柱子。
    public static let providesRealtimeSpectrum = false
}
