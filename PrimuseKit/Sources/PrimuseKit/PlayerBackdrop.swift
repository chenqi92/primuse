import Foundation

/// 原生播放页的背景用什么。全屏效果打开时以全屏效果为准，这里只管原生播放页。
public enum PlayerBackdropSource: String, CaseIterable, Codable, Sendable {
    /// 封面取色的色场（一直以来的样子，默认）。
    case coverAmbient
    /// 当前封面做一次模糊铺满。
    case coverBlur
    /// 专辑文件夹里 back / rear / inside 开头的图片。
    case albumBack
    /// 用户自己选的图片（iPhone 从相册选，Mac 从文件选，Apple TV 由扫码直传带过来）。
    case customImages

    public static let defaultValue = PlayerBackdropSource.coverAmbient

    /// 这一档会在色场上面再铺一张图。
    public var showsImage: Bool { self != .coverAmbient }

    /// 轮播只对可能有多张图的来源有意义。
    public var supportsRotation: Bool {
        switch self {
        case .albumBack, .customImages: return true
        case .coverAmbient, .coverBlur: return false
        }
    }
}

/// 有多张图时怎么换。
public enum PlayerBackdropRotation: String, CaseIterable, Codable, Sendable {
    /// 一直用第一张。
    case fixed
    /// 每换一首歌换下一张。
    case perSong
    /// 按间隔定时换。
    case timed

    public static let defaultValue = PlayerBackdropRotation.fixed
}

/// 三端同步的那部分播放背景设置：来源、轮播方式与间隔。自选图片本身和它们的列表
/// 都只留在本机（`customImagesStorageKey`），不同设备各选各的；没有图片的设备选了
/// 「我的图片」就照旧显示封面取色。
public struct PlayerBackdropSettings: Codable, Equatable, Sendable {
    public static let storageKey = "primuse.player.backdrop.v1"
    /// 本机自选图片的 id 列表（不进 iCloud）。
    public static let customImagesStorageKey = "primuse.player.backdrop.customImages.v1"
    public static let intervalChoices = [15, 30, 60, 300, 600]
    public static let defaultIntervalSeconds = 60
    public static let maximumCustomImages = 20

    public static let `default` = PlayerBackdropSettings()

    public var source: PlayerBackdropSource
    public var rotation: PlayerBackdropRotation
    public var intervalSeconds: Int

    public init(
        source: PlayerBackdropSource = .defaultValue,
        rotation: PlayerBackdropRotation = .defaultValue,
        intervalSeconds: Int = PlayerBackdropSettings.defaultIntervalSeconds
    ) {
        self.source = source
        self.rotation = rotation
        self.intervalSeconds = Self.normalizedInterval(intervalSeconds)
    }

    private enum CodingKeys: String, CodingKey {
        case source, rotation, intervalSeconds
    }

    /// 解码从不失败：不认识的取值（更新版本多出来的来源等）按默认处理，免得一台旧设备
    /// 读到新值就把整份设置当坏数据。
    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        let rawSource = (try? container?.decodeIfPresent(String.self, forKey: .source)) ?? nil
        let rawRotation = (try? container?.decodeIfPresent(String.self, forKey: .rotation)) ?? nil
        let interval = (try? container?.decodeIfPresent(Int.self, forKey: .intervalSeconds)) ?? nil
        self.init(
            source: rawSource.flatMap(PlayerBackdropSource.init(rawValue:)) ?? .defaultValue,
            rotation: rawRotation.flatMap(PlayerBackdropRotation.init(rawValue:)) ?? .defaultValue,
            intervalSeconds: interval ?? Self.defaultIntervalSeconds
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source.rawValue, forKey: .source)
        try container.encode(rotation.rawValue, forKey: .rotation)
        try container.encode(intervalSeconds, forKey: .intervalSeconds)
    }

    public static func decode(_ data: Data?) -> PlayerBackdropSettings {
        guard let data, !data.isEmpty,
              let settings = try? JSONDecoder().decode(PlayerBackdropSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func encodedData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }

    /// 间隔只取几个固定档，别的值落到最近的一档（同样近取较短的）。
    public static func normalizedInterval(_ value: Int) -> Int {
        guard !intervalChoices.contains(value) else { return value }
        return intervalChoices.min { lhs, rhs in
            let left = abs(lhs - value)
            let right = abs(rhs - value)
            return left == right ? lhs < rhs : left < right
        } ?? defaultIntervalSeconds
    }

    /// 自选图片 id：64 位小写十六进制（内容哈希），去重、保序、限量。
    public static func sanitizedCustomImageIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in ids where LibraryArtworkContentIDPolicy.isValid(id) && seen.insert(id).inserted {
            result.append(id)
            if result.count == maximumCustomImages { break }
        }
        return result
    }

    /// 实际生效的来源：选了「我的图片」而这台设备上一张都没有时，退回封面取色。
    public func effectiveSource(hasCustomImages: Bool) -> PlayerBackdropSource {
        source == .customImages && !hasCustomImages ? .coverAmbient : source
    }
}

/// 轮播走到第几张。换歌与定时器只推进计数，挑哪一张由图片张数决定，这样图片列表
/// 增删之后不会越界，也不用重置。
public struct PlayerBackdropRotationState: Equatable, Sendable {
    public private(set) var step: Int
    public private(set) var songKey: String?

    public init(step: Int = 0, songKey: String? = nil) {
        self.step = step
        self.songKey = songKey
    }

    /// 播放页看到的当前歌。第一次记下时不算换歌；返回值表示要不要换图。
    public mutating func observeSong(_ key: String?, rotation: PlayerBackdropRotation) -> Bool {
        guard key != songKey else { return false }
        let hadSong = songKey != nil
        songKey = key
        guard rotation == .perSong, hadSong, key != nil else { return false }
        step &+= 1
        return true
    }

    /// 定时轮播到点。
    public mutating func timerFired(rotation: PlayerBackdropRotation) -> Bool {
        guard rotation == .timed else { return false }
        step &+= 1
        return true
    }

    public func index(count: Int, rotation: PlayerBackdropRotation) -> Int? {
        guard count > 0 else { return nil }
        guard rotation != .fixed else { return 0 }
        let wrapped = step % count
        return wrapped < 0 ? wrapped + count : wrapped
    }
}

/// 专辑封底认哪些文件：文件名以 back / rear / inside 开头的图片（`back.jpg`、
/// `Back Cover.png`、`rear-1.jpg`、`inside_2.jpg`），按 back、rear、inside 的顺序，
/// 同组按主文件名（数字按大小）排。`background.jpg`、`backup.png` 这类只是碰巧同前缀的
/// 不算：前缀后面紧跟字母时，只认 cover / side（`backcover`、`backside`）。
public enum AlbumBackArtworkPolicy {
    public static let namePrefixes = ["back", "rear", "inside"]
    private static let joinedSuffixes = ["cover", "side"]

    public static func isCandidate(_ fileName: String) -> Bool {
        prefixRank(of: fileName) != nil
    }

    /// 候选文件在 `names` 里的下标，好的在前；重复的文件名（大小写不同也算）只留第一个。
    public static func orderedCandidateIndices(names: [String]) -> [Int] {
        var seen = Set<String>()
        var ranked: [(index: Int, rank: Int, name: String)] = []
        for (index, name) in names.enumerated() {
            guard let rank = prefixRank(of: name),
                  seen.insert(name.lowercased()).inserted else { continue }
            ranked.append((index, rank, name))
        }
        func base(_ name: String) -> String {
            ((name as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        ranked.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            // 比主名不比整名：`back.jpg` 排在 `back 2.jpg` 前面。
            let order = base(lhs.name).compare(base(rhs.name), options: [.caseInsensitive, .numeric])
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.index < rhs.index
        }
        return ranked.map(\.index)
    }

    /// 歌在分碟子文件夹（`CD1`、`Disc 2`、`disk-3`、`第2张`）里时，封底常放在上一层的
    /// 专辑文件夹，这时两层都找；返回要列的目录，先近后远。
    public static func searchDirectories(forSongDirectory directory: String) -> [String] {
        let trimmed = trimmedTrailingSlashes(directory)
        guard !trimmed.isEmpty else { return ["/"] }
        let name = (trimmed as NSString).lastPathComponent
        guard isDiscFolderName(name) else { return [trimmed] }
        let parent = (trimmed as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != trimmed else { return [trimmed] }
        return [trimmed, parent]
    }

    public static func isDiscFolderName(_ name: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["cd", "disc", "disk"] where value.hasPrefix(prefix) {
            var rest = Substring(value.dropFirst(prefix.count))
            while let first = rest.first, first == " " || first == "-" || first == "_" || first == "." {
                rest = rest.dropFirst()
            }
            return !rest.isEmpty && rest.allSatisfy(isDigit)
        }
        // 第2张 / 第2碟 / 第2盘
        guard value.hasPrefix("\u{7B2C}"), let last = value.last, "\u{5F20}\u{789F}\u{76D8}".contains(last) else {
            return false
        }
        let digits = value.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        return !digits.isEmpty && digits.allSatisfy(isDigit)
    }

    private static func isDigit(_ character: Character) -> Bool {
        ("0"..."9").contains(character)
    }

    private static func prefixRank(of fileName: String) -> Int? {
        let name = (fileName as NSString).lastPathComponent
        let fileExtension = (name as NSString).pathExtension.lowercased()
        guard PrimuseConstants.supportedCoverExtensions.contains(fileExtension) else { return nil }
        let base = (name as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        for (rank, prefix) in namePrefixes.enumerated() where base.hasPrefix(prefix) {
            let rest = base.dropFirst(prefix.count)
            guard let first = rest.first else { return rank }
            if !first.isLetter { return rank }
            if joinedSuffixes.contains(where: { rest.hasPrefix($0) }) { return rank }
        }
        return nil
    }

    private static func trimmedTrailingSlashes(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

/// 图上叠的那层保护色：深色外观压黑、浅色外观提白，让文字和控件始终看得清。
/// 「氛围强度」越高，图露得越多。
public struct PlayerBackdropScrim: Equatable, Sendable {
    public let topOpacity: Double
    public let middleOpacity: Double
    public let bottomOpacity: Double

    public init(topOpacity: Double, middleOpacity: Double, bottomOpacity: Double) {
        self.topOpacity = topOpacity
        self.middleOpacity = middleOpacity
        self.bottomOpacity = bottomOpacity
    }
}

public enum PlayerBackdropScrimPolicy {
    public static func scrim(
        isLight: Bool,
        strength: Double,
        usesIncreasedContrast: Bool
    ) -> PlayerBackdropScrim {
        let value = min(max(strength.isFinite ? strength : 0.7, 0), 1)
        let faint: PlayerBackdropScrim
        let vivid: PlayerBackdropScrim
        if isLight {
            faint = PlayerBackdropScrim(topOpacity: 0.66, middleOpacity: 0.72, bottomOpacity: 0.84)
            vivid = PlayerBackdropScrim(topOpacity: 0.30, middleOpacity: 0.38, bottomOpacity: 0.58)
        } else {
            faint = PlayerBackdropScrim(topOpacity: 0.58, middleOpacity: 0.64, bottomOpacity: 0.80)
            vivid = PlayerBackdropScrim(topOpacity: 0.20, middleOpacity: 0.28, bottomOpacity: 0.54)
        }
        let boost = usesIncreasedContrast ? 0.14 : 0
        func mix(_ a: Double, _ b: Double) -> Double {
            min(0.92, a + (b - a) * value + boost)
        }
        return PlayerBackdropScrim(
            topOpacity: mix(faint.topOpacity, vivid.topOpacity),
            middleOpacity: mix(faint.middleOpacity, vivid.middleOpacity),
            bottomOpacity: mix(faint.bottomOpacity, vivid.bottomOpacity)
        )
    }
}

/// 预缩与解码的像素上限。自选图片导入时缩到屏幕长边，显示时不再按原图解码。
public enum PlayerBackdropPixelPolicy {
    public static let minimumPixel = 1_280
    public static let maximumPixel = 3_200
    /// Apple TV 与扫码直传带过去的图：1080p 电视画面的长边。
    public static let televisionPixel = 1_920
    /// 封面模糊只需要很小的底图，放大后看不出差别。
    public static let blurSourcePixel = 480

    /// 屏幕（或窗口）像素长边，夹在上下限之间，再向上取到 256 的整数倍，免得窗口尺寸
    /// 每变一点就重做一次。
    public static func storagePixel(forDisplayLongSide pixels: Double) -> Int {
        guard pixels.isFinite, pixels > 0 else { return 2_880 }
        let clamped = min(max(Int(pixels.rounded(.up)), minimumPixel), maximumPixel)
        let bucketed = (clamped + 255) / 256 * 256
        return min(bucketed, maximumPixel)
    }
}
