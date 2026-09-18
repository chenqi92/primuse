import Foundation

/// 作用在封面上的色调滤镜。海报的气质大半来自封面的颜色，换一张滤镜
/// 比换一套版式更能改变观感，代价也小得多。
public struct LyricPosterFilterID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public extension LyricPosterFilterID {
    /// 原图。
    static let original = LyricPosterFilterID("original")
    /// 胶片：降一点饱和、压一点高光、暖调。
    static let film = LyricPosterFilterID("film")
    /// 旧时光：褪色、发黄、低对比。
    static let faded = LyricPosterFilterID("faded")
    /// 暖褐。
    static let sepia = LyricPosterFilterID("sepia")
    /// 黑白。
    static let mono = LyricPosterFilterID("mono")
    /// 拍立得：高对比、冷阴影、明显暗角。
    static let instant = LyricPosterFilterID("instant")
}

/// 一张滤镜的参数。都是与具体图像框架无关的标量，App 层照着搭 Core Image
/// 链；策略层因此可以在没有图像框架的地方测。
public struct LyricPosterFilterSpec: Hashable, Sendable, Identifiable {
    public let id: LyricPosterFilterID
    public let nameKey: String
    /// 1 = 原样，0 = 全灰。
    public let saturation: Double
    /// 1 = 原样。
    public let contrast: Double
    /// 0 = 原样，正数提亮。
    public let brightness: Double
    /// 色温偏移，正数偏暖（黄），负数偏冷（蓝）。以 6500K 为原点的相对量。
    public let warmth: Double
    /// 棕褐色调的强度，0 表示不加。
    public let sepiaIntensity: Double
    /// 暗角强度，0…1。
    public let vignette: Double
    /// 颗粒强度，0…1。
    public let grain: Double
    public let order: Int

    public init(
        id: LyricPosterFilterID,
        nameKey: String,
        saturation: Double = 1,
        contrast: Double = 1,
        brightness: Double = 0,
        warmth: Double = 0,
        sepiaIntensity: Double = 0,
        vignette: Double = 0,
        grain: Double = 0,
        order: Int
    ) {
        self.id = id
        self.nameKey = nameKey
        self.saturation = saturation
        self.contrast = contrast
        self.brightness = brightness
        self.warmth = warmth
        self.sepiaIntensity = sepiaIntensity
        self.vignette = vignette
        self.grain = grain
        self.order = order
    }

    /// 完全不改变画面的滤镜不需要走一遍图像管线。
    public var isIdentity: Bool {
        saturation == 1
            && contrast == 1
            && brightness == 0
            && warmth == 0
            && sepiaIntensity == 0
            && vignette == 0
            && grain == 0
    }
}

public enum LyricPosterFilterCatalog {
    public static let all: [LyricPosterFilterSpec] = [
        LyricPosterFilterSpec(
            id: .original,
            nameKey: "lyric_poster_filter_original",
            order: 0
        ),
        LyricPosterFilterSpec(
            id: .film,
            nameKey: "lyric_poster_filter_film",
            saturation: 0.86,
            contrast: 1.06,
            brightness: -0.02,
            warmth: 320,
            vignette: 0.35,
            grain: 0.22,
            order: 1
        ),
        LyricPosterFilterSpec(
            id: .faded,
            nameKey: "lyric_poster_filter_faded",
            saturation: 0.62,
            contrast: 0.88,
            brightness: 0.06,
            warmth: 480,
            sepiaIntensity: 0.22,
            vignette: 0.28,
            grain: 0.3,
            order: 2
        ),
        LyricPosterFilterSpec(
            id: .sepia,
            nameKey: "lyric_poster_filter_sepia",
            saturation: 0.5,
            contrast: 1.02,
            warmth: 260,
            sepiaIntensity: 0.72,
            vignette: 0.3,
            grain: 0.18,
            order: 3
        ),
        LyricPosterFilterSpec(
            id: .mono,
            nameKey: "lyric_poster_filter_mono",
            saturation: 0,
            contrast: 1.14,
            brightness: -0.01,
            vignette: 0.32,
            grain: 0.2,
            order: 4
        ),
        LyricPosterFilterSpec(
            id: .instant,
            nameKey: "lyric_poster_filter_instant",
            saturation: 1.1,
            contrast: 1.18,
            brightness: 0.04,
            warmth: -180,
            vignette: 0.45,
            grain: 0.12,
            order: 5
        ),
    ]

    public static func spec(for id: LyricPosterFilterID) -> LyricPosterFilterSpec {
        all.first { $0.id == id } ?? all[0]
    }

    /// 存下来的偏好可能来自更早的版本，认不出就退回原图，而不是空着。
    public static func resolved(preferred: LyricPosterFilterID?) -> LyricPosterFilterSpec {
        guard let preferred, let match = all.first(where: { $0.id == preferred }) else {
            return all[0]
        }
        return match
    }
}
