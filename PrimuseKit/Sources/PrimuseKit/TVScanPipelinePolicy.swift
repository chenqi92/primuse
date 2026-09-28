import CryptoKit
import Foundation

/// Pure policy shared by the tvOS streaming scanner and its regression tests.
/// Keeping identity, batching and re-scan reconciliation here prevents the TV
/// catalogue from drifting from the generic connector scanner.
public enum TVScanPipelinePolicy {
    public static let publicationBatchSize = 20

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
        trackNumber: Int
    ) -> String {
        let itemIdentity = SourceSongIdentityMaterialPolicy.itemIdentity(
            path: path,
            providerID: providerID,
            usesStableProviderIdentity: usesStableProviderIdentity
        )
        return hash32(
            "\(sourceID):\(itemIdentity)#cue:\(cuePath)#track:\(trackNumber)"
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
            result = existing
            result.id = candidate.id
            result.filePath = candidate.filePath
            result.sourceID = candidate.sourceID
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
        )
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
