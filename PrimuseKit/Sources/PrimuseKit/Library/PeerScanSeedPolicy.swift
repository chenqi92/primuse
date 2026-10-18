import Foundation

/// 另一台设备已经读好标签的一首歌。
///
/// 同一个账号下的 iPhone、iPad、Mac 扫同一个音乐源时,歌曲 id 都由「源 id + 路径」
/// 算出来,一样的文件就是一样的 id。别的设备读过的那一行,只要文件没变,本机直接拿来
/// 用就不必再读一遍文件。
public struct PeerScanSeed: Codable, Sendable, Equatable {
    public var song: Song
    /// 那台设备上这首歌内嵌封面的内容哈希(封面按内容去重存放时的 sha256)。
    /// 封面是原样从文件里抽出来存的,同一个文件在每台设备上算出来的都一样。
    public var coverContentKey: String?

    public init(song: Song, coverContentKey: String? = nil) {
        self.song = song
        self.coverContentKey = coverContentKey
    }
}

/// 扫描或补读用上了别的设备读好的一行。补读服务据此把这首歌记成「标签已检查」,
/// 并安排封面与歌词:封面按内容分组、一组只读一首;那台设备有内嵌歌词而本机没有时,
/// 等到播放这首歌才读一次文件。
public struct PeerScanSeedAdoption: Sendable, Equatable {
    public enum Cover: Sendable, Equatable {
        /// 本机已经有封面(旁边的封面文件,或本机已存着同一份内容)。
        case resolved
        /// 那台设备有这张内嵌封面,本机还没有这份内容。
        case pending(String)
        /// 说不清,交给本机照常读。
        case unknown
    }

    public var songID: String
    public var cover: Cover
    public var cachedLyrics: Bool

    public init(songID: String, cover: Cover, cachedLyrics: Bool) {
        self.songID = songID
        self.cover = cover
        self.cachedLyrics = cachedLyrics
    }
}

/// 别的设备读好的标签什么时候能用、几台设备都读过时用哪一份、怎么并进本机这一行。
///
/// 标签是文件内容决定的:同一个文件谁读到的都一样,所以这里没有「谁覆盖谁」,只有
/// 「谁已经读完」。本机读过的行不会被换掉;用户手改过的行不拿来当答案,本机手改过的
/// 字段也始终留本机的。
public enum PeerScanSeedPolicy {
    /// 快照落盘的时间只到整秒,文件系统和服务器给的修改时间常带小数秒。
    public static let modificationTimeTolerance: TimeInterval = 1

    /// 那台设备真的读过文件:有时长,也读到了音频流参数。只有时长不够 —— DTS 的
    /// 裸行会先填一个估算的时长。手改过的行装的不是文件里的值,也不能用;CUE 分轨
    /// 和串流描述文件由扫描器自己从清单文件生成,不走这条路。
    public static func isUsableSeed(_ song: Song) -> Bool {
        song.duration > 0
            && (song.sampleRate != nil || song.bitRate != nil)
            && song.userMetadataEditedAt == nil
            && song.fileSize > 0
            && !song.filePath.isEmpty
            && song.cueSheetPath == nil
            && !song.isStreamDescriptor
    }

    /// 本机这次列出来的文件和那台设备读的是不是同一份字节:大小必须一样;两边都有
    /// 版本号时版本号要一样;两边都有修改时间时差不能到一秒。
    public static func fingerprintMatches(
        size: Int64,
        modifiedDate: Date?,
        revision: String?,
        seed: Song
    ) -> Bool {
        guard size > 0, seed.fileSize == size else { return false }
        if let revision, let seedRevision = seed.revision, revision != seedRevision {
            return false
        }
        if let modifiedDate, let seedDate = seed.lastModified,
           abs(modifiedDate.timeIntervalSince(seedDate)) >= modificationTimeTolerance {
            return false
        }
        return true
    }

    public static func fingerprintMatches(_ song: Song, seed: Song) -> Bool {
        song.sourceID == seed.sourceID
            && song.filePath == seed.filePath
            && fingerprintMatches(
                size: song.fileSize,
                modifiedDate: song.lastModified,
                revision: song.revision,
                seed: seed
            )
    }

    /// 读得有多全。几台设备都读过同一首时取最全的那份。
    public static func completeness(_ seed: PeerScanSeed) -> Int {
        let song = seed.song
        let present: [Bool] = [
            song.albumTitle?.isEmpty == false,
            song.artistName?.isEmpty == false,
            song.albumArtistName?.isEmpty == false,
            song.trackNumber != nil,
            song.discNumber != nil,
            song.year != nil,
            song.genre?.isEmpty == false,
            song.sampleRate != nil,
            song.bitRate != nil,
            song.bitDepth != nil,
            song.audioCodec != nil,
            song.effectiveBitDepth != nil,
            song.replayGainTrackGain != nil,
            seed.coverContentKey != nil,
            song.lyricsFileName?.isEmpty == false,
        ]
        return present.reduce(0) { $0 + ($1 ? 1 : 0) }
    }

    /// 几台设备的结果并成一份。`perDevice` 按上传时间从新到旧排;同一首歌取读得
    /// 最全的,一样全取较新那台的。
    public static func merged(_ perDevice: [[PeerScanSeed]]) -> [String: PeerScanSeed] {
        var result: [String: PeerScanSeed] = [:]
        var scores: [String: Int] = [:]
        for seeds in perDevice {
            for seed in seeds where isUsableSeed(seed.song) {
                let id = seed.song.id
                let score = completeness(seed)
                if let existing = scores[id], existing >= score { continue }
                result[id] = seed
                scores[id] = score
            }
        }
        return result
    }

    /// 把那台设备读好的标签并到本机这一行上。文件位置、大小、修改时间、版本号、加入
    /// 时间和旁边的封面/歌词/MV 文件以本机这次列出来的为准;专辑、艺人的派生 id 交给
    /// 本机曲库重算。封面缓存不在本机,由调用方另行处理。歌词缓存名由歌曲 id 决定、各
    /// 设备一样,所以留着:它说明文件里有歌词,本机播放时再读,再转给别的设备时也不丢。
    public static func adopting(_ seed: Song, onto base: Song) -> Song {
        var result = seed
        result.filePath = base.filePath
        result.sourceID = base.sourceID
        if base.fileSize > 0 { result.fileSize = base.fileSize }
        result.lastModified = base.lastModified ?? seed.lastModified
        result.revision = base.revision ?? seed.revision
        result.dateAdded = base.dateAdded
        result.albumID = nil
        result.artistID = nil
        result.coverArtFileName = base.coverArtFileName
        result.lyricsFileName = base.lyricsFileName
            ?? (hasCachedLyrics(seed) ? seed.lyricsFileName : nil)
        result.mvPath = base.mvPath
        result.artistArtworkFileName = base.artistArtworkFileName
        result.userMetadataEditedAt = nil
        return result
    }

    /// 封面在本机怎么办。
    public enum CoverDisposition: Equatable, Sendable {
        /// 本机这次列到了旁边的封面文件,照旧用它。
        case sidecar
        /// 那台设备有内嵌封面,内容哈希已知:本机已有这份内容就直接指过去,
        /// 没有的话同一张封面只读一首。
        case content(String)
        /// 说不清,留给本机自己读。那台设备的行里没有封面,可能是文件里没有,也可能
        /// 它自己也是从别的设备拿来、还没读过封面,不能当成「没有」。
        case unknown
    }

    public static func coverDisposition(seed: PeerScanSeed, base: Song) -> CoverDisposition {
        if base.coverArtFileName?.isEmpty == false { return .sidecar }
        if let key = seed.coverContentKey, isContentKey(key) { return .content(key) }
        return .unknown
    }

    /// 那台设备的歌词在它自己的缓存里(内嵌歌词或刮到的),不是旁边的歌词文件。
    public static func hasCachedLyrics(_ seed: Song) -> Bool {
        guard let name = seed.lyricsFileName, !name.isEmpty else { return false }
        return !name.contains("/")
    }

    /// 快照里的「封面内容 → 歌曲 id」反过来查。
    public static func coverContentKeys(
        bySongIDFrom groups: [String: [String]]?
    ) -> [String: String] {
        guard let groups else { return [:] }
        var result: [String: String] = [:]
        for (key, songIDs) in groups where isContentKey(key) {
            for songID in songIDs { result[songID] = key }
        }
        return result
    }

    /// 只认 64 位小写十六进制,别的东西不会被拼进本机的文件路径。
    public static func isContentKey(_ key: String) -> Bool {
        key.utf8.count == 64
            && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// 本机存着的一台设备的结果要不要重下:那台设备传了新快照,或者存盘时扔掉的源里
    /// 有本机现在要用的(删掉又恢复的源)。`excludedAtInstall` 为 nil 是旧版本的存法:
    /// 只留了 `legacyKeptSourceIDs` 里的源,本机后来才有的源不在里面。
    public static func needsReinstall(
        storedModifiedAt: Date?,
        uploadedModifiedAt: Date,
        excludedAtInstall: Set<String>?,
        legacyKeptSourceIDs: Set<String>,
        wanted: Set<String>
    ) -> Bool {
        guard let storedModifiedAt else { return true }
        if abs(storedModifiedAt.timeIntervalSince(uploadedModifiedAt)) >= modificationTimeTolerance {
            return true
        }
        if let excludedAtInstall {
            return !wanted.isDisjoint(with: excludedAtInstall)
        }
        return !wanted.isSubset(of: legacyKeptSourceIDs)
    }

    /// 本机后来删掉(或认出用不上)的源,存着的那份不必等那台设备传新快照才清。清掉的
    /// 要并进 `excludedAtInstall`,删掉又恢复时 `needsReinstall` 才知道要重下;旧版本的
    /// 存法没有这份记录可记,不清。
    public static func sourcesToDrop(
        storedSourceIDs: [String],
        excludedAtInstall: Set<String>?,
        scope: PeerScanSeedScope
    ) -> Set<String> {
        guard excludedAtInstall != nil else { return [] }
        return Set(storedSourceIDs).intersection(scope.excluded)
    }
}

/// 一次整理别的设备结果的范围。
public struct PeerScanSeedScope: Sendable, Equatable {
    /// 本机现在要借用的源。
    public var wanted: Set<String>
    /// 本机认得、确定用不上的源:标签不靠读文件的、只在本机的、删掉的。其余的源(包括
    /// 本机还没收到同步的)存盘时都留着,加源、启用源时不用为它把整份快照重下一遍。
    public var excluded: Set<String>

    public init(wanted: Set<String>, excluded: Set<String>) {
        self.wanted = wanted
        self.excluded = excluded
    }

    /// `isEligible` 判断一个源能不能借用别的设备的结果(停用的也照样判断)。
    public static func make(
        sources: [MusicSource],
        deletedSourceIDs: Set<String>,
        isEligible: (MusicSource) -> Bool
    ) -> PeerScanSeedScope {
        var wanted = Set<String>()
        var usable = Set<String>()
        var excluded = deletedSourceIDs
        for source in sources {
            if !source.isDeleted, isEligible(source) {
                usable.insert(source.id)
                if source.isEnabled { wanted.insert(source.id) }
            } else {
                excluded.insert(source.id)
            }
        }
        // 删掉又恢复的源还留着删除记录。
        excluded.subtract(usable)
        return PeerScanSeedScope(wanted: wanted, excluded: excluded)
    }

    public func including(_ sourceID: String) -> PeerScanSeedScope {
        var scope = self
        scope.wanted.insert(sourceID)
        scope.excluded.remove(sourceID)
        return scope
    }
}
