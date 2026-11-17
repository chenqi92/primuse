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
    /// 歌曲自己的静态封面：没有可用的动态素材时，合成一张壁纸式铺满的静止画面给锁屏全屏用。
    case coverImage

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var token: String {
        switch self {
        case .songVideo: "song"
        case .albumVideo: "album"
        case .serviceMaterial: "service"
        case .customAnimation: "custom"
        case .coverImage: "cover"
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
    /// 「锁屏全屏封面」：封面像壁纸一样铺满锁屏（方形素材合成 3:4、静态封面合成静止画面）。
    public var fullScreenArtworkEnabled: Bool
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
        fullScreenArtworkEnabled: Bool = true,
        content: LockScreenMotionArtworkContent,
        materialIsLocal: Bool = true,
        unmeteredOnly: Bool,
        isOnUnmeteredNetwork: Bool
    ) {
        self.systemSupportsAnimatedArtwork = systemSupportsAnimatedArtwork
        self.animatedArtworkEnabled = animatedArtworkEnabled
        self.lockScreenEnabled = lockScreenEnabled
        self.fullScreenArtworkEnabled = fullScreenArtworkEnabled
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

    /// 没有动态素材时，静态封面能不能合成一张铺满锁屏的 3:4 静止画面。只看「锁屏全屏封面」：
    /// 封面本来就在本机（锁屏方块封面用的就是它），不受「动态专辑封面」两个开关和「仅 Wi-Fi」管。
    public static func permitsStillWallpaper(_ context: LockScreenMotionArtworkContext) -> Bool {
        context.systemSupportsAnimatedArtwork
            && context.fullScreenArtworkEnabled
            && context.content == .music
    }

    /// 素材放进哪些位置、怎么放。系统只认 1:1 和 3:4 两个位置，画幅不对的素材会被它退回静态封面。
    /// 3:4 素材只放 3:4 位；方形素材原样放 1:1 位，设备有 3:4 位、而且能合成（开着「锁屏全屏封面」）时
    /// 再按壁纸铺法合成一份 3:4（见 `LockScreenWallpaperLayout`）放 3:4 位——锁屏只拿 3:4 那份铺满全屏。
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

    /// 合成的 3:4 壁纸版（方形动态素材、静态封面）：构图（可见宽度、尺寸、取景位置、构图版本）变了也是新 ID。
    public static func artworkID(
        kind: MotionArtworkMaterialKind,
        contentKey: String,
        wallpaper layout: LockScreenWallpaperLayout
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
        layout: LockScreenWallpaperLayout
    ) -> String {
        "\(tallCompositionCachePrefix)\(sanitized(contentKey))-\(layout.signature).mp4"
    }

    /// 静态封面合成的 3:4 静止视频。和动态素材分开命名：自选动图本身也是一张封面，
    /// 两条路按同一份文件合成时不能撞成一个缓存。
    public static func stillWallpaperCacheName(
        contentKey: String,
        layout: LockScreenWallpaperLayout
    ) -> String {
        "\(stillWallpaperCachePrefix)\(sanitized(contentKey))-\(layout.signature).mp4"
    }

    /// 锁屏缓存目录里按需转出来的视频（动图转码、方形合成 3:4、静态封面合成）的文件名前缀，清理旧缓存时按它认。
    public static let conversionCachePrefixes = ["animation-", tallCompositionCachePrefix, stillWallpaperCachePrefix]
    private static let tallCompositionCachePrefix = "tall-"
    private static let stillWallpaperCachePrefix = "still-"

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
    /// 方形素材按壁纸铺法合成 3:4 放进 3:4 位。
    case squareInTall

    public var slot: MotionCoverAspect {
        switch self {
        case .original(let aspect): aspect
        case .squareInTall: .tall
        }
    }
}

/// 画面里值得留在看得见的区域里的一块（人脸、主要物体）。坐标是占整幅宽高的比例，原点在左上角。
public struct LockScreenWallpaperRegion: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var confidence: Double

    public init(x: Double, y: Double, width: Double, height: Double, confidence: Double = 1) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.confidence = confidence
    }
}

/// 铺满锁屏时尽量放到可见区域正中的那一点。坐标是占素材宽高的比例，原点在左上角。
public struct LockScreenWallpaperFocus: Equatable, Sendable {
    public static let center = LockScreenWallpaperFocus(x: 0.5, y: 0.5)

    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = Self.clamped(x)
        self.y = Self.clamped(y)
    }

    /// 按画面里的显著区域取景：各块中心按「面积 × 置信度」加权平均；没有能用的区域就取正中。
    public init(regions: [LockScreenWallpaperRegion]) {
        var totalWeight = 0.0
        var sumX = 0.0
        var sumY = 0.0
        for region in regions {
            guard [region.x, region.y, region.width, region.height, region.confidence].allSatisfy(\.isFinite),
                  region.width > 0, region.height > 0, region.confidence > 0 else { continue }
            let weight = region.width * region.height * region.confidence
            totalWeight += weight
            sumX += (region.x + region.width / 2) * weight
            sumY += (region.y + region.height / 2) * weight
        }
        guard totalWeight > 0 else {
            self = .center
            return
        }
        self.init(x: sumX / totalWeight, y: sumY / totalWeight)
    }

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.5
    }
}

/// 封面放进锁屏 3:4 位时的构图：像设成壁纸那样铺满整个锁屏。
///
/// 锁屏拿 3:4 那份按屏幕宽高比居中裁两侧再铺满整屏（iPhone 竖屏约 0.46，3:4 画面左右各裁掉近两成）。
/// 素材等比放大到盖满看得见的那一段：方形封面高度占满整屏、两侧裁掉一半左右，看得见的那一段对准
/// 画面主体（`LockScreenWallpaperFocus`），人脸、主要物体不被裁出去。锁屏看不见的两侧边角素材可能
/// 盖不到，那里垫一层同一素材的模糊底：系统万一不按这个比例裁，露出来的也是同色的底而不是黑边。
/// 像素坐标以左上角为原点。
public struct LockScreenWallpaperLayout: Equatable, Sendable {
    /// 构图常量改了就加一，缓存和 artworkID 跟着换新。1 是「模糊底 + 完整方形」，2 起是铺满。
    public static let compositionVersion = 2
    /// 拿不到屏幕尺寸时按 iPhone 竖屏的宽高比（19.5:9 约 0.46）。
    public static let fallbackVisibleWidthRatio = 0.46
    /// 垫底的模糊标准差，按画面宽度的比例：糊到只剩色块。
    public static let backgroundBlurFraction = 0.05
    /// 垫底的亮度乘数（CoreImage 线性光下乘，看上去约暗两成）。
    public static let backgroundBrightness = 0.6

    /// 3:4 画面的像素尺寸。
    public let width: Int
    public let height: Int
    /// 素材缩放后的尺寸与左上角位置；可以是负数，伸到画面外的部分裁掉。
    public let imageWidth: Int
    public let imageHeight: Int
    public let imageX: Int
    public let imageY: Int
    /// 锁屏裁完以后看得见的宽度占画面高度的千分比。
    public let visibleWidthPermille: Int
    public let focus: LockScreenWallpaperFocus

    /// - Parameters:
    ///   - sourceWidth/sourceHeight: 素材的像素尺寸。看得见的那一段里素材不放大，画面高度跟着它定，
    ///     长边不超过 `maximumLongEdge`。
    ///   - visibleWidthRatio: 屏幕竖屏宽 ÷ 高；nil 或不合理时用 `fallbackVisibleWidthRatio`。
    ///     比 3:4 还宽的屏幕（iPad）锁屏不裁两侧，按整幅宽算。
    ///   - focus: 取景点，放到看得见的那一段正中；靠边时收回到不露边为止。
    public init?(
        sourceWidth: Double,
        sourceHeight: Double,
        visibleWidthRatio: Double?,
        focus: LockScreenWallpaperFocus = .center,
        maximumLongEdge: Int = MotionCoverImportLimits.maximumLongEdge
    ) {
        guard sourceWidth.isFinite, sourceHeight.isFinite, sourceWidth >= 16, sourceHeight >= 16 else { return nil }
        let requested = visibleWidthRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? Self.fallbackVisibleWidthRatio
        let ratio = min(MotionCoverAspect.tall.ratio, max(0.3, requested))
        // 画面高度按「看得见的那一段里素材不放大」反推：素材要同时盖满整高和 ratio × 高的宽度。
        let fittedHeight = min(sourceHeight, sourceWidth / ratio)
        let size = MotionCoverAspect.tall.renderSize(
            sourceWidth: fittedHeight * MotionCoverAspect.tall.ratio,
            sourceHeight: fittedHeight,
            maximumLongEdge: maximumLongEdge
        )
        guard size.width > 0, size.height > 0 else { return nil }
        let canvasWidth = Double(size.width)
        let canvasHeight = Double(size.height)
        let visibleWidth = min(canvasWidth, ratio * canvasHeight)
        let scale = max(canvasHeight / sourceHeight, visibleWidth / sourceWidth)
        let scaledWidth = Self.roundedUp(sourceWidth * scale)
        let scaledHeight = Self.roundedUp(sourceHeight * scale)

        // 水平：取景点放到画面中线，再收回到看得见的那一段两边都还有素材为止。
        let visibleLeft = Int(((canvasWidth - visibleWidth) / 2).rounded(.down))
        let visibleRight = Int(((canvasWidth + visibleWidth) / 2).rounded(.up))
        let lowestX = visibleRight - scaledWidth
        let highestX = visibleLeft
        let desiredX = Int((canvasWidth / 2 - focus.x * Double(scaledWidth)).rounded())
        let x = lowestX <= highestX ? min(max(desiredX, lowestX), highestX) : (lowestX + highestX) / 2
        // 垂直：素材至少和画面一样高，同样对准取景点、上下不露边。
        let desiredY = Int((canvasHeight / 2 - focus.y * Double(scaledHeight)).rounded())
        let y = min(max(desiredY, size.height - scaledHeight), 0)

        width = size.width
        height = size.height
        imageWidth = scaledWidth
        imageHeight = scaledHeight
        imageX = x
        imageY = y
        visibleWidthPermille = Int((ratio * 1_000).rounded())
        self.focus = focus
    }

    /// 素材盖满整个画面时不用垫模糊底。
    public var coversCanvas: Bool {
        imageX <= 0 && imageY <= 0 && imageX + imageWidth >= width && imageY + imageHeight >= height
    }

    /// 写进缓存文件名和 artworkID 的构图标识。
    public var signature: String {
        "wall\(Self.compositionVersion)-r\(visibleWidthPermille)-\(width)x\(height)-\(imageWidth)x\(imageHeight)o\(imageX)_\(imageY)"
    }

    /// 向上取整，但浮点误差（比如 1080.0000001）不多算一像素。
    private static func roundedUp(_ value: Double) -> Int {
        Int((value - 0.001).rounded(.up))
    }
}
