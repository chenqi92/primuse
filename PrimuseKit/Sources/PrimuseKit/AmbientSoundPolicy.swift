import Foundation

/// 设置里的「单独归类环境音」。默认开;关掉后不做任何环境音识别,这些曲目全部按普通音乐处理,
/// 手动归属和目录标签照旧记着,重新打开后恢复。本机设置,不跟着修正记录同步。
public enum AmbientSoundPreferences {
    public static let enabledKey = "primuse.library.separatesAmbientSounds.v1"
    public static let defaultEnabled = true

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: enabledKey)
    }
}

/// 环境音怎么放:一段声音要一直放下去,不是一首接一首的歌。
public enum AmbientSoundPlaybackPolicy {
    /// 进入环境音时的随机与循环:不随机、单曲循环。音乐自己的设置由 `ListeningPlayModeLedger` 挂起,
    /// 回到音乐时还回去。
    public static let playMode = ListeningPlayMode(shuffleEnabled: false, repeatMode: .one)

    /// 环境音页顶上那一行快捷定时(分钟);nil 是不限时。
    public static let quickTimerMinutes: [Int?] = [15, 30, 60, nil]

    /// 全屏播放闲置多久进休憩层(时钟加声音名的那块安静画面)。音乐要连续五分钟没人碰;
    /// 环境音进全屏本来就是要一块安静的屏,几秒就进。
    public static let fullscreenRestDelayForAmbient: TimeInterval = 4
    public static let fullscreenRestDelayForMusic: TimeInterval = 5 * 60

    public static func fullscreenRestDelay(isAmbient: Bool) -> TimeInterval {
        isAmbient ? fullscreenRestDelayForAmbient : fullscreenRestDelayForMusic
    }

    /// 单曲循环时首尾直接接上:不看「无缝播放」「淡入淡出」开没开,也不和自己交叉混合。
    public static func forcesSeamlessLoop(space: ListeningSpace?, repeatMode: RepeatMode) -> Bool {
        space == .ambient && repeatMode == .one
    }
}

/// 环境音页上的一组声音:同一张专辑,或同一个目录里的几条。
public struct AmbientSoundGroup: Identifiable, Equatable, Sendable {
    public let id: String
    /// 专辑名或目录名;nil 是认不出专辑也认不出目录的那几条。
    public let title: String?
    /// 组里的声音,按碟号、曲号、标题排好。
    public let songIDs: [String]

    public init(id: String, title: String?, songIDs: [String]) {
        self.id = id
        self.title = title
        self.songIDs = songIDs
    }
}

/// 把环境音按专辑 / 目录分成几组,一组一段标题,组里每条是一张声音卡。
/// 组按标题排(不分大小写、按数字大小比),认不出来的那一组放最后。
public enum AmbientSoundGrouping {
    public static let looseGroupID = "loose"

    public static func groups(for songs: [Song]) -> [AmbientSoundGroup] {
        guard !songs.isEmpty else { return [] }
        var order: [String] = []
        var titles: [String: String?] = [:]
        var members: [String: [Song]] = [:]
        for song in songs {
            let (id, title) = key(for: song)
            if members[id] == nil {
                order.append(id)
                titles[id] = title
            }
            members[id, default: []].append(song)
        }
        let groups = order.map { id in
            AmbientSoundGroup(
                id: id,
                title: titles[id] ?? nil,
                songIDs: (members[id] ?? []).sorted(by: precedes).map(\.id)
            )
        }
        return groups.sorted { lhs, rhs in
            switch (lhs.title, rhs.title) {
            case (nil, nil): return lhs.id < rhs.id
            case (nil, _): return false
            case (_, nil): return true
            case let (left?, right?):
                let order = left.localizedStandardCompare(right)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
        }
    }

    /// 专辑(有专辑 ID 和专辑名)优先;没有时按所在目录;路径里看不出目录的(按条目 ID 寻址的源)归到最后一组。
    static func key(for song: Song) -> (id: String, title: String?) {
        if let albumID = song.albumID, !albumID.isEmpty,
           let album = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            return ("album:" + albumID, album)
        }
        let path = song.filePath
        if let slash = path.lastIndex(of: "/"), slash != path.startIndex {
            let folder = String(path[..<slash])
            let name = folder.split(separator: "/").last.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty {
                return ("folder:" + song.sourceID + "\u{1F}" + folder, name)
            }
        }
        return (looseGroupID, nil)
    }

    private static func precedes(_ lhs: Song, _ rhs: Song) -> Bool {
        let leftDisc = lhs.discNumber ?? 1
        let rightDisc = rhs.discNumber ?? 1
        if leftDisc != rightDisc { return leftDisc < rightDisc }
        switch (lhs.trackNumber, rhs.trackNumber) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        let order = lhs.title.localizedStandardCompare(rhs.title)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
}

/// 资料库「环境音」分类:默认收着,第一次有了环境音时亮出来一次(`LibrarySectionLayoutPolicy`),
/// 之后收不收照用户的来。首页那颗「环境音」胶囊跟着这个分类的显隐走。
public enum AmbientSoundLibrarySection {
    public static let rawValue = "ambient"
    /// 已经存过隐藏集合的人:新分类先补进隐藏集合,别在没有环境音时凭空多出一行。
    public static let defaultHiddenMigrationKey = "primuse.library.ambientDefaultHidden.v1"
    /// 第一次识别到环境音时亮出过一次。
    public static let revealedKey = "primuse.library.ambientRevealed.v1"

    /// 首页胶囊、搜索分组、资料库入口要不要出现:总开关开着、真有环境音、资料库分类没收起。
    public static func isReachable(separatesAmbient: Bool, hasContent: Bool, sectionHidden: Bool) -> Bool {
        separatesAmbient && hasContent && !sectionHidden
    }
}

/// 一段环境音没有封面时画成什么样:按声音名认一个最贴切的图标(雨、雷、海浪、溪水、风、风扇、火、鸟、夜、
/// 咖啡馆、列车、几种噪音),底色是和它相配的一段柔和渐变;认不出来的按声音挑一种自然色,同一段声音每次都一样。
public enum AmbientSoundMotif: String, CaseIterable, Sendable {
    case storm, rain, ocean, water, fan, wind, fire, forest, night, cafe, train
    case whiteNoise, pinkNoise, brownNoise
    case leafTeal, leafSage, leafSlate, leafDusk

    /// SF Symbol 名。
    public var symbol: String {
        switch self {
        case .storm: "cloud.bolt.rain.fill"
        case .rain: "cloud.rain.fill"
        case .ocean: "water.waves"
        case .water: "drop.fill"
        case .fan: "fan.fill"
        case .wind: "wind"
        case .fire: "flame.fill"
        case .forest: "bird.fill"
        case .night: "moon.stars.fill"
        case .cafe: "cup.and.saucer.fill"
        case .train: "tram.fill"
        case .whiteNoise, .pinkNoise, .brownNoise: "waveform"
        case .leafTeal, .leafSage, .leafSlate, .leafDusk: "leaf.fill"
        }
    }

    /// 渐变上端、下端(0xRRGGBB)。下端都够深,压在上面的白字看得清。
    public var colors: (top: UInt32, bottom: UInt32) {
        switch self {
        case .storm: (0x5B6390, 0x1D2038)
        case .rain: (0x4F7FB0, 0x1F3556)
        case .ocean: (0x2F9DB2, 0x0D4862)
        case .water: (0x4CB3C4, 0x175E70)
        case .fan: (0x8C9AB0, 0x394255)
        case .wind: (0x8DB0BE, 0x355564)
        case .fire: (0xE0823C, 0x742418)
        case .forest: (0x62A56B, 0x1E4B2C)
        case .night: (0x6150A0, 0x1B1536)
        case .cafe: (0xB4845F, 0x47291D)
        case .train: (0x7D899A, 0x2C323E)
        case .whiteNoise: (0xA3B2C6, 0x46546A)
        case .pinkNoise: (0xD88AA6, 0x74304E)
        case .brownNoise: (0xA87C5B, 0x4B3122)
        case .leafTeal: (0x3FA7A0, 0x125B59)
        case .leafSage: (0x7EA488, 0x2D553E)
        case .leafSlate: (0x6D86B2, 0x26395F)
        case .leafDusk: (0x9A86C2, 0x3B2C64)
        }
    }

    /// 按名字认:先看声音名,再看专辑名、流派;都认不出来就按 `seed`(条目 ID)挑一种自然色。
    public static func motif(title: String, album: String?, genre: String?, seed: String) -> AmbientSoundMotif {
        for text in [title, album, genre].compactMap({ $0 }) {
            if let motif = recognized(in: text) { return motif }
        }
        let fallbacks: [AmbientSoundMotif] = [.leafTeal, .leafSage, .leafSlate, .leafDusk]
        // 不用 hashValue:每次启动的随机种子不同,同一段声音的颜色会变。
        var hash: UInt32 = 2_166_136_261
        for byte in seed.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return fallbacks[Int(hash % UInt32(fallbacks.count))]
    }

    /// 关键词按先后比:雷雨先于雨,列车先于雨(train 里有 rain),风扇先于风,几种噪音先于泛指的「噪音」。
    private static let keywords: [(AmbientSoundMotif, [String])] = [
        (.storm, ["thunder", "storm", "雷", "暴风雨", "暴雨"]),
        (.train, ["train", "rail", "subway", "火车", "列车", "地铁"]),
        (.rain, ["rain", "drizzle", "雨"]),
        (.ocean, ["ocean", "sea", "wave", "surf", "beach", "tide", "海", "浪", "潮"]),
        (.water, ["stream", "river", "creek", "brook", "waterfall", "water", "drip", "溪", "河", "瀑布", "流水", "水滴", "水"]),
        (.fan, ["fan", "air conditioner", "dryer", "风扇", "空调", "吹风"]),
        (.wind, ["wind", "breeze", "风"]),
        (.fire, ["fire", "campfire", "flame", "火", "篝火", "壁炉"]),
        (.forest, ["forest", "bird", "jungle", "woods", "森林", "鸟", "林"]),
        (.night, ["night", "cricket", "insect", "frog", "夜", "虫", "蛙"]),
        (.cafe, ["cafe", "café", "coffee", "library", "咖啡", "图书馆"]),
        (.pinkNoise, ["pink noise", "pinknoise", "粉红噪", "粉噪", "粉紅噪"]),
        (.brownNoise, ["brown noise", "brownnoise", "brownian", "棕噪", "褐噪"]),
        (.whiteNoise, ["white noise", "whitenoise", "noise", "白噪", "噪音", "噪声"]),
    ]

    private static func recognized(in text: String) -> AmbientSoundMotif? {
        let lowered = text.lowercased()
        guard !lowered.isEmpty else { return nil }
        let words = lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for (motif, keys) in keywords where keys.contains(where: { matches($0, in: lowered, words: words) }) {
            return motif
        }
        return nil
    }

    /// 英文按词比:三个字母以内的词要整词相同(sea 不认 season),更长的认词头(waves、rainfall、fireplace);
    /// 带空格的词组和中日韩文字按子串比。
    private static func matches(_ key: String, in lowered: String, words: [String]) -> Bool {
        let isPlainASCIIWord = key.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.lowercaseLetters.contains($0) }
        guard isPlainASCIIWord else { return lowered.contains(key) }
        if key.count <= 3 { return words.contains(key) }
        return words.contains { $0.hasPrefix(key) }
    }
}
