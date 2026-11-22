import CryptoKit
import Foundation

public enum TVScanMode: String, Sendable {
    case full
    case incremental

    public static var incrementalTitle: String {
        PMString("ext.tv.scan.incremental")
    }

    public static var incrementalBody: String {
        PMString("ext.tv.scan.incrementalBody")
    }

    public func savedDirectories(previous: [String], scanned: [String], sourceType: MusicSourceType) -> [String] {
        SourceDirectorySelectionPolicy.normalizedSelections(
            self == .incremental ? previous + scanned : scanned, for: sourceType
        )
    }
}

/// 资料库「文件夹」页在电视上「重新扫描此文件夹」的换算。电视扫完不留扫描索引,
/// 所以只做按「/」分层、歌的文件路径就是连接器列目录用的原始写法的源:从文件夹里
/// 一首歌(`LibraryFolderRescanAnchor`)的路径往上数几层就是要列的目录,不去反解
/// 文件夹页归一化过的节点路径。NFS 的路径整段编码过、ID 寻址网盘的路径是条目 id,都不在此列。
public enum TVFolderRescanPolicy {
    public static func supports(_ type: MusicSourceType) -> Bool {
        type.supportsFolderRescan
            && type.libraryFolderPathSemantics == .hierarchical
            && type != .nfs
    }

    /// 这首歌所在目录再往上 `levelsAbove` 层。路径不是「/」开头、或往上越过了根,答 nil。
    public static func directory(containingFilePath path: String, levelsAbove: Int) -> String? {
        guard levelsAbove >= 0, path.hasPrefix("/") else { return nil }
        var current = path
        for _ in 0...levelsAbove {
            guard current != "/", let slash = current.lastIndex(of: "/") else { return nil }
            let parent = String(current[..<slash])
            current = parent.isEmpty ? "/" : parent
        }
        return current
    }

    /// 这首歌在不在这个目录(含子目录)下。只比原始路径前缀,不做大小写或编码归一:
    /// 对不上的行算子树外、原样保留,宁可漏删也不错删。
    public static func contains(filePath: String, inDirectory directory: String) -> Bool {
        guard directory.hasPrefix("/") else { return false }
        if directory == "/" { return filePath.hasPrefix("/") }
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return filePath.hasPrefix(prefix)
    }
}

/// Pure policy shared by the tvOS streaming scanner and its regression tests.
/// Keeping identity, batching and re-scan reconciliation here prevents the TV
/// catalogue from drifting from the generic connector scanner.
public enum TVScanPipelinePolicy {
    public static let publicationBatchSize = 20

    /// A failed TOC read is not evidence that the image's tracks disappeared.
    /// Keep their last verified metadata and revision until a successful scan replaces them.
    public static func sacdScanCandidates(
        parsedTracks: [Song],
        previousTracks: [Song],
        readFailed: Bool
    ) -> [Song] {
        if !parsedTracks.isEmpty { return parsedTracks }
        guard readFailed else { return [] }
        return previousTracks.filter(\.isDiscImageTrack).map { previous in
            var retained = previous
            retained.id = canonicalSongID(previous.id)
            return retained
        }
    }

    /// 扫描中途把攒下的行交给曲库的门槛。扫描器每 20 首发布一批;远端读标签慢到
    /// 一首一秒时,原来「满 200 首或隔 1.5 秒」的规则等于每批都提交一次,每次都要
    /// 过一遍整库。按数量或时间上限合并,数据库写入与整库维护都降到十几秒一次。
    public static let intermediateCommitSongCount = 200
    public static let intermediateCommitInterval: TimeInterval = 15

    public static func shouldCommitIntermediateBatch(
        pendingCount: Int,
        secondsSinceLastCommit: TimeInterval
    ) -> Bool {
        guard pendingCount > 0 else { return false }
        return pendingCount >= intermediateCommitSongCount
            || secondsSinceLastCommit >= intermediateCommitInterval
    }

    public static func songID(
        sourceID: String,
        path: String,
        providerID: String? = nil,
        usesStableProviderIdentity: Bool = false
    ) -> String {
        let itemIdentity = SourceSongIdentityMaterialPolicy.itemIdentity(
            path: path,
            providerID: providerID,
            usesStableProviderIdentity: usesStableProviderIdentity
        )
        return hash32("\(sourceID):\(itemIdentity)")
    }

    public static func cueSongID(
        sourceID: String,
        path: String,
        providerID: String? = nil,
        usesStableProviderIdentity: Bool = false,
        cuePath: String,
        trackNumber: Int,
        imageTrackKey: String? = nil
    ) -> String {
        let itemIdentity = SourceSongIdentityMaterialPolicy.itemIdentity(
            path: path,
            providerID: providerID,
            usesStableProviderIdentity: usesStableProviderIdentity
        )
        return hash32(
            "\(sourceID):\(itemIdentity)#cue:\(cuePath)#track:\(imageTrackKey ?? String(trackNumber))"
        )
    }

    /// Server clients historically returned a full SHA-256 string. Their
    /// material is already correct, so truncating to the first 16 digest bytes
    /// produces the same ID as the generic scanner without re-keying by a
    /// different input.
    public static func canonicalSongID(_ value: String) -> String {
        let lowercased = value.lowercased()
        guard lowercased.count == 64,
              lowercased.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else {
            return value
        }
        return String(lowercased.prefix(32))
    }

    public static func hash32(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Removes duplicate roots while preserving the user's order. Descendant
    /// paths are deliberately retained: opaque provider IDs do not encode
    /// ancestry, and the scanner's global scheduled-directory set safely
    /// collapses an overlapping child once the parent lists it.
    public static func normalizedScanRoots(_ roots: [String]) -> [String] {
        var seen: Set<String> = []
        return roots.compactMap { raw in
            let root = normalizedPath(raw)
            guard seen.insert(root).inserted else { return nil }
            return root
        }
    }

    public static func batches<Element>(
        _ elements: [Element],
        size: Int = publicationBatchSize
    ) -> [[Element]] {
        guard size > 0, !elements.isEmpty else { return [] }
        return stride(from: 0, to: elements.count, by: size).map { offset in
            Array(elements[offset..<min(offset + size, elements.count)])
        }
    }

    /// Builds the Phase-A record shown immediately on TV. An unchanged file
    /// keeps its previously enriched technical metadata, while a replaced file
    /// starts from the new skeleton. Both paths preserve explicit user edits
    /// and the original library insertion date.
    public static func reconciledSkeleton(
        existing: Song?,
        candidate: Song
    ) -> Song {
        guard let existing else { return candidate }

        let contentChanged = contentChanged(
            existing: existing,
            candidate: candidate
        )
        var result: Song
        if contentChanged {
            result = SongUserMetadataPolicy.preservingUserEdits(
                from: existing,
                in: candidate
            )
        } else {
            result = ISOAlbumMetadataPolicy.refreshingIdentity(of: existing, from: candidate)
            result.id = candidate.id
            result.filePath = candidate.filePath
            result.sourceID = candidate.sourceID
            result.contentMetadata = SongContentMetadata.merging(previous: existing.contentMetadata, incoming: candidate.contentMetadata)
            if !candidate.isStreamDescriptor {
                result.fileFormat = candidate.fileFormat
                result.fileSize = candidate.fileSize
            }
            result.lastModified = candidate.lastModified
            if !candidate.isStreamDescriptor {
                result.revision = candidate.revision ?? existing.revision
            }
            result.cueSheetPath = candidate.cueSheetPath
            result.cueStartTime = candidate.cueStartTime
            result.cueEndTime = candidate.cueEndTime
            if candidate.isCueTrack, !candidate.isDiscImageTrack, existing.userMetadataEditedAt == nil,
               let sheetYear = candidate.year, sheetYear > 0 {
                result.year = sheetYear
            }
            result.sacdTrackNumber = candidate.sacdTrackNumber
            result.isoAudioTrack = candidate.isoAudioTrack
            result.lyricsFileName = adoptedSidecarLyrics(existing: existing.lyricsFileName,
                                                         listed: candidate.lyricsFileName)
            // 能读 CUE 增益之前扫进来、或 .cue 后来才写进增益的分轨,沿用旧行时也带上。
            result.adoptCueSheetReplayGain(from: candidate)
            if let video = candidate.mvPath { result.mvPath = video }
        }
        result.dateAdded = existing.dateAdded
        return result
    }

    /// A strong unchanged-content signal plus a useful prior duration lets a
    /// resumed/incremental scan avoid reopening the remote file. Skeleton-only
    /// rows have duration zero and are retried on the next scan.
    public static func canReuseMetadata(existing: Song?, candidate: Song) -> Bool {
        guard let existing else { return false }
        if candidate.isStreamDescriptor {
            return STRMRevision.wrapperMatches(
                songRevision: existing.revision,
                wrapperRevision: candidate.revision,
                wrapperSize: candidate.fileSize,
                wrapperModifiedDate: candidate.lastModified
            )
        }
        guard existing.duration > 0 else { return false }
        // 还不知道 M4A 里装的是 AAC 还是 ALAC 的行再读一次; 读过会记在歌上
        // (认不出也记), 下一次扫描照常复用。
        guard existing.isStandaloneMusicVideo || !ContainerAudioCodecPolicy.isUnread(
            format: existing.fileFormat,
            audioCodec: existing.audioCodec
        ) else { return false }
        let hasStableRevision = existing.revision?.isEmpty == false
            && candidate.revision?.isEmpty == false
        let hasStableModifiedDate = existing.lastModified != nil
            && candidate.lastModified != nil
        guard hasStableRevision || hasStableModifiedDate else { return false }
        return !contentChanged(existing: existing, candidate: candidate)
    }

    public static func normalizedPath(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "/" }
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private static func contentChanged(existing: Song, candidate: Song) -> Bool {
        if candidate.isStreamDescriptor,
           STRMRevision.wrapperMatches(
            songRevision: existing.revision,
            wrapperRevision: candidate.revision,
            wrapperSize: candidate.fileSize,
            wrapperModifiedDate: candidate.lastModified
           ) {
            return false
        }
        return ServerSongCatalogMergePolicy.contentChanged(
            existing: existing,
            incoming: candidate
        ) || cueSheetTextChanged(existing: existing, candidate: candidate)
    }

    /// 后来才放进文件夹的歌词(同名 .lrc、CUE 分轨歌词)记到沿用的旧行上:重扫的读标签放在扫描之后,
    /// 只按库里这一行记的引用去读,不记就永远读不到。原来没有歌词、或者记的本来就是文件夹里的歌词
    /// 文件时才换;本机缓存的歌词(手动挑的、从内嵌标签读出的)不动。
    static func adoptedSidecarLyrics(existing: String?, listed: String?) -> String? {
        guard let listed, !listed.isEmpty else { return existing }
        guard let existing, !existing.isEmpty else { return listed }
        let isFolderFile = existing.hasPrefix("/") && !existing.contains("://")
        return isFolderFile ? listed : existing
    }

    /// 只改了 .cue 里这一轨的曲名、艺术家、专辑名、专辑艺术家或轨号,整轨音频没动:文件的大小和
    /// 修改时间看不出来,和手机、Mac 的扫描器一样按 CUE 给出的值比。CUE 没写、读标签时补上的字段
    /// 不算变化(不然这类专辑每次重扫都要重读);专辑艺术家只在 CUE 明写了整张的 PERFORMER 时才比;
    /// 手动改过标签的分轨以用户改的为准,也不算。
    static func cueSheetTextChanged(existing: Song, candidate: Song) -> Bool {
        guard candidate.isCueTrack, !candidate.isDiscImageTrack,
              existing.userMetadataEditedAt == nil else { return false }
        func value(_ text: String?) -> String? {
            guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }
        func changed(_ old: String?, _ new: String?) -> Bool {
            guard let new = value(new) else { return false }
            return value(old) != new
        }
        let placeholderTitle = candidate.trackNumber.map { PMString("cue_track_title_format", $0) }
        let titleChanged = candidate.title != placeholderTitle && changed(existing.title, candidate.title)
        let sheetAlbumArtist = value(candidate.albumArtistName) == value(candidate.artistName)
            ? nil : candidate.albumArtistName
        return titleChanged
            || changed(existing.artistName, candidate.artistName)
            || changed(existing.albumTitle, candidate.albumTitle)
            || changed(existing.albumArtistName, sheetAlbumArtist)
            || (candidate.trackNumber != nil && existing.trackNumber != candidate.trackNumber)
    }
}

/// 扫描读标签的一段统计窗口:远端请求的次数、字节、耗时与失败,和每首歌从开始读到
/// 读完的总耗时。两者相减大致就是解析标签、写封面歌词与排队等待的时间。
/// 只做累加与汇总,日志由调用方按窗口打印。
public struct TVScanReadStatistics: Sendable, Equatable {
    public private(set) var requests = 0
    public private(set) var bytes: Int64 = 0
    public private(set) var requestSeconds: [Double] = []
    public private(set) var failures = 0
    public private(set) var timeouts = 0
    public private(set) var songs = 0
    public private(set) var reusedSongs = 0
    public private(set) var songSeconds: Double = 0

    public init() {}

    public mutating func recordRequest(bytes: Int, seconds: Double) {
        requests += 1
        self.bytes += Int64(max(0, bytes))
        requestSeconds.append(max(0, seconds))
    }

    public mutating func recordFailure(timedOut: Bool, seconds: Double) {
        failures += 1
        if timedOut { timeouts += 1 }
        requestSeconds.append(max(0, seconds))
    }

    public mutating func recordSong(seconds: Double, reused: Bool) {
        songs += 1
        if reused { reusedSongs += 1 }
        songSeconds += max(0, seconds)
    }

    public mutating func merge(_ other: TVScanReadStatistics) {
        requests += other.requests
        bytes += other.bytes
        requestSeconds.append(contentsOf: other.requestSeconds)
        failures += other.failures
        timeouts += other.timeouts
        songs += other.songs
        reusedSongs += other.reusedSongs
        songSeconds += other.songSeconds
    }

    public var networkSeconds: Double { requestSeconds.reduce(0, +) }

    /// 最近邻取法的分位数(0...1);没有样本时为 0。
    public func requestPercentile(_ fraction: Double) -> Double {
        guard !requestSeconds.isEmpty else { return 0 }
        let sorted = requestSeconds.sorted()
        let clamped = min(max(fraction, 0), 1)
        let index = min(sorted.count - 1, Int((clamped * Double(sorted.count)).rounded(.up)) - 1)
        return sorted[max(0, index)]
    }

    /// 每首真正读过的歌(不含复用检查记录的)平均用了多少毫秒。
    public var averageReadSongMilliseconds: Int {
        let read = songs - reusedSongs
        return read > 0 ? Int(songSeconds / Double(read) * 1000) : 0
    }
}
