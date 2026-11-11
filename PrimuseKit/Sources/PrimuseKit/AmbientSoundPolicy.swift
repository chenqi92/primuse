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
