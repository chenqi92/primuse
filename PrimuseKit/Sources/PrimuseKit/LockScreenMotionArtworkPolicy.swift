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

    /// 素材放进哪些位置、怎么放。系统只认 1:1 和 3:4 两个位置，画幅不对的素材会被它退回静态封面。
    /// 3:4 素材只放 3:4 位；方形素材原样放 1:1 位，设备有 3:4 位、而且能合成时再合成一份 3:4
    /// （见 `LockScreenSquareInTallLayout`）放 3:4 位——锁屏只拿 3:4 那份铺满全屏。
    public static func renditions(
        for aspect: MotionCoverAspect,
        supported: Set<MotionCoverAspect>,
        canComposeTall: Bool
    ) -> [LockScreenMotionArtworkRendition] {
        var result: [LockScreenMotionArtworkRendition] = []
        if supported.contains(aspect) { result.append(.original(aspect)) }
        if aspect == .square, canComposeTall, supported.contains(.tall) { result.append(.squareInTall) }
        return result
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

    /// 方形素材合成的 3:4 版：构图（可见宽度、尺寸、构图版本）变了也是新 ID。
    public static func artworkID(
        kind: MotionArtworkMaterialKind,
        contentKey: String,
        squareInTall layout: LockScreenSquareInTallLayout
    ) -> String {
        "primuse.motion.v1.\(kind.token).\(layout.signature).\(sanitized(contentKey))"
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

    /// 方形素材（视频或动图）合成的 3:4 视频在缓存目录里的文件名：内容或构图任一变了都是另一个文件。
    public static func tallCompositionCacheName(
        contentKey: String,
        layout: LockScreenSquareInTallLayout
    ) -> String {
        "\(tallCompositionCachePrefix)\(sanitized(contentKey))-\(layout.signature).mp4"
    }

    /// 锁屏缓存目录里按需转出来的视频（动图转码、方形合成 3:4）的文件名前缀，清理旧缓存时按它认。
    public static let conversionCachePrefixes = ["animation-", tallCompositionCachePrefix]
    private static let tallCompositionCachePrefix = "tall-"

    private static func sanitized(_ key: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(key.map { allowed.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "_" : String(cleaned.prefix(96))
    }
}

/// 一段素材放进系统的哪个位置、以什么形式。
public enum LockScreenMotionArtworkRendition: Equatable, Sendable {
    /// 原样放进同画幅的位置。
    case original(MotionCoverAspect)
    /// 方形素材合成成 3:4 放进 3:4 位。
    case squareInTall

    public var slot: MotionCoverAspect {
        switch self {
        case .original(let aspect): aspect
        case .squareInTall: .tall
        }
    }
}

/// 方形动态封面放进锁屏 3:4 位时的构图。
///
/// 锁屏拿 3:4 那份按屏幕宽高比居中裁两侧再铺满整屏（iPhone 竖屏约 0.46，3:4 画面左右各裁掉近两成），
/// 直接把方形裁成 3:4 会被裁掉一半以上。所以底层是同一素材放大铺满、模糊并压暗，上层是完整的方形素材，
/// 宽度正好等于裁完以后看得见的那一段，垂直方向略偏上。像素坐标以左上角为原点。
public struct LockScreenSquareInTallLayout: Equatable, Sendable {
    /// 构图常量（位置、模糊、压暗）改了就加一，缓存和 artworkID 跟着换新。
    public static let compositionVersion = 1
    /// 拿不到屏幕尺寸时按 iPhone 竖屏的宽高比（19.5:9 约 0.46）。
    public static let fallbackVisibleWidthRatio = 0.46
    /// 方形中心放在画面高度 38% 处。iPhone 上方形占高度约 46%，于是落在 15%～61%：
    /// 顶上一小段让锁屏时钟压在封面上沿（系统本来就这样叠），底下留出约四成高度给
    /// 歌名、进度条、播放键和手电筒/相机两个按钮，不让控件盖住封面主体。
    public static let foregroundCenterFraction = 0.38
    /// 底层模糊的标准差，按画面宽度的比例：糊到只剩色块，看不出原图细节、不和上层抢。
    public static let backgroundBlurFraction = 0.05
    /// 底层亮度乘数（CoreImage 线性光下乘，看上去约暗两成）：压暗一点，让上层方形和系统白字
    /// 都从背景里浮出来。
    public static let backgroundBrightness = 0.6

    /// 3:4 画面的像素尺寸。
    public let width: Int
    public let height: Int
    /// 上层方形的边长与左上角位置。
    public let foregroundSide: Int
    public let foregroundX: Int
    public let foregroundY: Int
    /// 锁屏裁完以后看得见的宽度占画面高度的千分比。
    public let visibleWidthPermille: Int

    /// - Parameters:
    ///   - sourceSide: 方形素材的边长（像素）。上层方形不放大到超过它，画面高度也跟着它定，
    ///     长边不超过 `maximumLongEdge`。
    ///   - visibleWidthRatio: 屏幕竖屏宽 ÷ 高；nil 或不合理时用 `fallbackVisibleWidthRatio`。
    ///     比 3:4 还宽的屏幕（iPad）锁屏不裁两侧，按整幅宽算。
    public init?(
        sourceSide: Double,
        visibleWidthRatio: Double?,
        maximumLongEdge: Int = MotionCoverImportLimits.maximumLongEdge
    ) {
        guard sourceSide.isFinite, sourceSide >= 16 else { return nil }
        let requested = visibleWidthRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? Self.fallbackVisibleWidthRatio
        let ratio = min(MotionCoverAspect.tall.ratio, max(0.3, requested))
        // 画面高度按「上层方形不放大」反推：方形边长 = 可见宽度 = ratio × 高度。
        let size = MotionCoverAspect.tall.renderSize(
            sourceWidth: sourceSide / ratio * MotionCoverAspect.tall.ratio,
            sourceHeight: sourceSide / ratio,
            maximumLongEdge: maximumLongEdge
        )
        guard size.width > 0, size.height > 0 else { return nil }
        width = size.width
        height = size.height
        // 边长取偶数，左右留白对称、编码器也不用补像素。
        let side = min(width, Int((ratio * Double(height)).rounded())) / 2 * 2
        guard side > 0 else { return nil }
        foregroundSide = side
        foregroundX = (width - side) / 2
        let top = Int((Self.foregroundCenterFraction * Double(height) - Double(side) / 2).rounded())
        foregroundY = min(max(0, top), height - side)
        visibleWidthPermille = Int((ratio * 1_000).rounded())
    }

    /// 写进缓存文件名和 artworkID 的构图标识。
    public var signature: String {
        "sqtall\(Self.compositionVersion)-r\(visibleWidthPermille)-\(width)x\(height)"
    }
}
