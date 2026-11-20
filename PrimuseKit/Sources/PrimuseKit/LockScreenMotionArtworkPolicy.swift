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

/// 封面里找到的主体：人脸和主要物体。
///
/// 只用来判断「居中裁会不会把主体裁出去」，不用来定中心。显著性检测的框又松又偏（注意力显著性的框
/// 普遍偏左，对称的标志、正中的人像都会被拉向一边），按框的中心取景，好好的居中构图就被挪歪了。
/// 人脸框最准：有像样的人脸就只认人脸，没有才认物体。
public struct LockScreenWallpaperSubjects: Equatable, Sendable {
    public static let none = LockScreenWallpaperSubjects()
    /// 比最大那张脸小这么多的脸（背景里的路人）不算主体。
    static let faceAreaShare = 0.3
    /// 「面积 × 置信度」不到最大那块这么多的物体（反光点、角落的小字）不算主体。
    static let objectWeightShare = 0.25
    /// 主体四周至少留出的边，占整幅的比例。
    static let minimumMargin = 0.04
    /// 人脸再按自己的大小多留一圈，别贴着画面边。
    static let faceMarginShare = 0.15

    public var faces: [LockScreenWallpaperRegion]
    public var objects: [LockScreenWallpaperRegion]

    public init(faces: [LockScreenWallpaperRegion] = [], objects: [LockScreenWallpaperRegion] = []) {
        self.faces = faces
        self.objects = objects
    }

    /// 要整块留在画面里的范围（含留边、裁到 0～1）；没有能用的主体就是 nil。
    var keptBounds: (x: ClosedRange<Double>, y: ClosedRange<Double>)? {
        let usableFaces = faces.compactMap(Self.usable)
        if let largest = usableFaces.map({ $0.width * $0.height }).max() {
            let kept = usableFaces.filter { $0.width * $0.height >= largest * Self.faceAreaShare }
            return Self.bounds(of: kept, marginShare: Self.faceMarginShare)
        }
        let usableObjects = objects.compactMap(Self.usable)
        guard let heaviest = usableObjects.map(Self.weight).max() else { return nil }
        let kept = usableObjects.filter { Self.weight($0) >= heaviest * Self.objectWeightShare }
        return Self.bounds(of: kept, marginShare: 0)
    }

    /// 裁到 0～1 以后还有面积、置信度为正的区域才算。
    private static func usable(_ region: LockScreenWallpaperRegion) -> LockScreenWallpaperRegion? {
        guard [region.x, region.y, region.width, region.height, region.confidence].allSatisfy(\.isFinite),
              region.confidence > 0 else { return nil }
        let minX = max(0, region.x), maxX = min(1, region.x + region.width)
        let minY = max(0, region.y), maxY = min(1, region.y + region.height)
        guard maxX > minX, maxY > minY else { return nil }
        return LockScreenWallpaperRegion(
            x: minX, y: minY, width: maxX - minX, height: maxY - minY, confidence: region.confidence
        )
    }

    private static func weight(_ region: LockScreenWallpaperRegion) -> Double {
        region.width * region.height * region.confidence
    }

    private static func bounds(
        of regions: [LockScreenWallpaperRegion],
        marginShare: Double
    ) -> (x: ClosedRange<Double>, y: ClosedRange<Double>)? {
        guard let minX = regions.map(\.x).min(),
              let maxX = regions.map({ $0.x + $0.width }).max(),
              let minY = regions.map(\.y).min(),
              let maxY = regions.map({ $0.y + $0.height }).max() else { return nil }
        let marginX = max(minimumMargin, marginShare * (maxX - minX))
        let marginY = max(minimumMargin, marginShare * (maxY - minY))
        return (max(0, minX - marginX)...min(1, maxX + marginX), max(0, minY - marginY)...min(1, maxY + marginY))
    }
}

/// 铺满锁屏时放到画面正中的那一点。坐标是占素材宽高的比例，原点在左上角。
public struct LockScreenWallpaperFocus: Equatable, Sendable {
    public static let center = LockScreenWallpaperFocus(x: 0.5, y: 0.5)

    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = Self.clamped(x)
        self.y = Self.clamped(y)
    }

    /// 一条边上的取景。`window` 是画面占素材的比例，返回画面中心在素材上的位置：
    /// 从正中出发，主体放得进画面就挪到刚好整块放进为止，原来的构图尽量不动；
    /// 主体比画面还宽、怎么都放不全时，画面留在主体范围里、尽量靠正中。
    static func windowCenter(keeping kept: ClosedRange<Double>?, window: Double) -> Double {
        guard let kept, window.isFinite, window > 0, window < 1 else { return 0.5 }
        let half = window / 2
        let lower: Double
        let upper: Double
        if kept.upperBound - kept.lowerBound <= window {
            lower = kept.upperBound - half
            upper = kept.lowerBound + half
        } else {
            lower = kept.lowerBound + half
            upper = kept.upperBound - half
        }
        return min(max(0.5, lower), upper)
    }

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.5
    }
}

/// 封面放进锁屏 3:4 位时的构图：像设成壁纸那样铺满整个锁屏。
///
/// 素材等比放大到盖满画面：方形封面高度占满，两侧各裁掉一成多。锁屏按屏幕宽度显示整张 3:4 画面
/// （#460 的真机截图：iPhone 上看得见的正好是整张画面的宽度，并没有再按屏幕宽高比裁两侧），
/// 所以取景以整张画面为准：默认居中、保留原来的构图，只有人脸或主要物体会被裁出去时才挪，
/// 挪到刚好整块放进为止（`LockScreenWallpaperSubjects`）。比画面窄的素材盖不满两侧，那里垫一层
/// 同一素材的模糊底，至少保证按屏幕宽高比算的那一段里没有空边。像素坐标以左上角为原点。
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
    /// 按屏幕宽高比算的那一段宽度占画面高度的千分比。
    public let visibleWidthPermille: Int
    /// 放到画面正中的那一点（占素材宽高的比例）。
    public let focus: LockScreenWallpaperFocus

    /// - Parameters:
    ///   - sourceWidth/sourceHeight: 素材的像素尺寸。看得见的那一段里素材不放大，画面高度跟着它定，
    ///     长边不超过 `maximumLongEdge`。
    ///   - visibleWidthRatio: 屏幕竖屏宽 ÷ 高；nil 或不合理时用 `fallbackVisibleWidthRatio`。
    ///     比 3:4 还宽的屏幕（iPad）按整幅宽算。
    ///   - subjects: 画面里的人脸和主要物体，取景时尽量不裁掉它们。
    public init?(
        sourceWidth: Double,
        sourceHeight: Double,
        visibleWidthRatio: Double?,
        subjects: LockScreenWallpaperSubjects = .none,
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

        // 取景以整张画面为准：从正中出发，只为放进主体才挪。
        let kept = subjects.keptBounds
        let focus = LockScreenWallpaperFocus(
            x: LockScreenWallpaperFocus.windowCenter(keeping: kept?.x, window: canvasWidth / Double(scaledWidth)),
            y: LockScreenWallpaperFocus.windowCenter(keeping: kept?.y, window: canvasHeight / Double(scaledHeight))
        )
        // 水平：素材盖得满画面就不露边；比画面窄时退回到按屏幕宽高比算的那一段不露边。
        let desiredX = Int((canvasWidth / 2 - focus.x * Double(scaledWidth)).rounded())
        let lowestX: Int
        let highestX: Int
        if scaledWidth >= size.width {
            lowestX = size.width - scaledWidth
            highestX = 0
        } else {
            lowestX = Int(((canvasWidth + visibleWidth) / 2).rounded(.up)) - scaledWidth
            highestX = Int(((canvasWidth - visibleWidth) / 2).rounded(.down))
        }
        let x = lowestX <= highestX ? min(max(desiredX, lowestX), highestX) : (lowestX + highestX) / 2
        // 垂直：素材至少和画面一样高，上下不露边。
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
