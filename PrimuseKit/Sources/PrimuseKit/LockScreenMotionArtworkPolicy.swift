import Foundation

/// 交给系统「正在播放」（锁屏全屏封面等）的动态封面素材，按优先级从高到低。
/// 只用已经在本机的素材：不为锁屏去下载，也不在切歌时等素材。
public enum MotionArtworkMaterialKind: Int, CaseIterable, Comparable, Sendable {
    /// 用户给这首歌指定的视频。
    case songVideo = 0
    /// 用户给专辑指定的视频（单曲自己没设时跟随）。
    case albumVideo
    /// 用户自己配置的动态封面服务返回、已经缓存到本机的素材。
    case serviceMaterial
    /// 自选的 GIF 等动图：标签编辑里给歌曲选的、专辑封面上传的。
    case customAnimation

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var token: String {
        switch self {
        case .songVideo: "song"
        case .albumVideo: "album"
        case .serviceMaterial: "service"
        case .customAnimation: "custom"
        }
    }
}

public enum MotionArtworkMaterialSelection {
    /// 候选按优先级排好（同一级保持原来的先后）：前面的读不出、不是动图或画幅系统不收，再试后面的。
    public static func ordered<Candidate>(
        _ candidates: [Candidate],
        kind: (Candidate) -> MotionArtworkMaterialKind
    ) -> [Candidate] {
        candidates.enumerated()
            .sorted { lhs, rhs in
                let left = kind(lhs.element)
                let right = kind(rhs.element)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }
}

/// 正在播放的是什么。只有曲库里的音乐发动态封面：电台、有声书、播客没有动态封面，
/// MV 本身就是画面，Apple Music 的歌由系统播放器自己发「正在播放」。
public enum LockScreenMotionArtworkContent: Sendable {
    case music
    case musicVideo
    case liveRadio
    case spokenWord
    case podcast
    case appleMusic
}

public struct LockScreenMotionArtworkContext: Equatable, Sendable {
    /// 系统版本够（iOS / iPadOS / macOS 26 起）且这台设备有可用的动态封面位置。
    public var systemSupportsAnimatedArtwork: Bool
    /// 「动态专辑封面」总开关。
    public var animatedArtworkEnabled: Bool
    /// 「锁屏显示动态封面」。
    public var lockScreenEnabled: Bool
    public var content: LockScreenMotionArtworkContent
    /// 素材是不是都已经在本机。
    public var materialIsLocal: Bool
    /// 「仅通过 Wi-Fi 下载原始封面」。
    public var unmeteredOnly: Bool
    public var isOnUnmeteredNetwork: Bool

    public init(
        systemSupportsAnimatedArtwork: Bool,
        animatedArtworkEnabled: Bool,
        lockScreenEnabled: Bool,
        content: LockScreenMotionArtworkContent,
        materialIsLocal: Bool = true,
        unmeteredOnly: Bool,
        isOnUnmeteredNetwork: Bool
    ) {
        self.systemSupportsAnimatedArtwork = systemSupportsAnimatedArtwork
        self.animatedArtworkEnabled = animatedArtworkEnabled
        self.lockScreenEnabled = lockScreenEnabled
        self.content = content
        self.materialIsLocal = materialIsLocal
        self.unmeteredOnly = unmeteredOnly
        self.isOnUnmeteredNetwork = isOnUnmeteredNetwork
    }
}

public enum LockScreenMotionArtworkPolicy {
    /// `MPMediaItemAnimatedArtwork` 从 iOS / iPadOS / macOS 26 起才有。
    public static let minimumMajorVersion = 26

    public static func operatingSystemSupportsAnimatedArtwork(majorVersion: Int) -> Bool {
        majorVersion >= minimumMajorVersion
    }

    public static func permitsPublishing(_ context: LockScreenMotionArtworkContext) -> Bool {
        guard context.systemSupportsAnimatedArtwork,
              context.animatedArtworkEnabled,
              context.lockScreenEnabled,
              context.content == .music else { return false }
        // 「仅 Wi-Fi」管的是下载：已经在本机的素材照常用，跟 App 里离线播放已缓存的动画一致。
        if !context.materialIsLocal, context.unmeteredOnly, !context.isOnUnmeteredNetwork {
            return false
        }
        return true
    }

    /// 系统只认 1:1 和 3:4 两个位置，画幅不对的素材会被它退回静态封面，所以干脆不发。
    /// 方形素材只放 1:1 位置，不拉伸也不裁成 3:4。
    public static func slot(
        for aspect: MotionCoverAspect,
        supported: Set<MotionCoverAspect>
    ) -> MotionCoverAspect? {
        supported.contains(aspect) ? aspect : nil
    }

    /// 系统靠 artworkID 判断封面换没换：同一段素材（同一张专辑的歌）用同一个 ID，系统不必重新要；
    /// 素材内容、来源或画幅变了就是新 ID。
    public static func artworkID(
        kind: MotionArtworkMaterialKind,
        contentKey: String,
        aspect: MotionCoverAspect
    ) -> String {
        "primuse.motion.v1.\(kind.token).\(aspect.rawValue).\(sanitized(contentKey))"
    }

    /// 动图转出来的视频在缓存目录里的文件名：内容、画幅、尺寸任一变了都是另一个文件。
    public static func conversionCacheName(
        contentKey: String,
        aspect: MotionCoverAspect,
        width: Int,
        height: Int
    ) -> String {
        "animation-\(sanitized(contentKey))-\(aspect.rawValue)-\(width)x\(height).mp4"
    }

    private static func sanitized(_ key: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(key.map { allowed.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "_" : String(cleaned.prefix(96))
    }
}
