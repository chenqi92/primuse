import Foundation
import PrimuseKit

/// iCloud 整库上传、Apple TV 直传(iCloud、局域网)发出去之前的整理(DL4):一页一页地做,不再把整份快照解码成每一首歌。
///
/// 整理做的事与 DL4 之前相同(以前的写法留在调试构建里逐字节对照,`…Reference`):
/// - 歌:iCloud 去掉本机源(`MusicSourceCloudSyncPolicy`)和这台设备关了 iCloud 同步的源的歌;局域网不过滤。
/// - 小状态:iCloud 时歌单成员、最近播放只留留下来的歌(占位条目照留),自动艺人头像目录只留还有歌的源。
/// - 随附的:留下的歌对应的歌词文件名(iCloud 只传这些歌词;DL4 起只记歌词目录里有的)、留下的歌数、是否还有可同步的源。
/// - 封面:先收用户上传的与歌自己选的(按预算),再按歌的顺序收专辑封面、歌的封面,最后收艺人封面;按内容去重。
/// - 编码:带封面整份不超过 60 MiB;放不下先丢「封面内容表」,再丢封面(留内容表),最后两样都丢、不超过 64 MiB;
///   再放不下就不传。
///
/// 以前整份解码、在内存里改完再整份编码:10 万首时峰值 1.3–1.4 GB malloc,返回之后还有约 0.9 GB 过两秒才放掉。
/// 现在歌按页(1000 首)解出来:第一遍过滤、记下上面那些整库的结论(歌单与最近播放里引用到的歌哪些留下了、
/// 留下的源、歌词文件名、用户选的封面、艺人),把留下的歌一页页编码写进临时文件;第二遍按同样的顺序收专辑与
/// 歌的封面;最后把小状态编好接在前面(`songs` 是最后一个键),按同样的四级退路判大小。歌的字节只编一次,
/// 每一级退路只换前面的小状态。内存里只有一页歌、小状态、封面(按预算)与上面那几样整库结论。
/// 读不了、写不进、取消:整理失败(nil),不交出缺页的快照;临时文件在每条路上都删掉。
extension MusicLibrary {
    /// 整理的两个大小上限(DL4 之前写死在整理里)。测试用小上限走到每一级退路。
    struct PortableSnapshotSizeLimits: Sendable {
        /// 带封面(或带封面内容表)时整份的上限。
        var encodedBytes = 60 * 1024 * 1024
        /// 封面、封面内容表都丢掉之后的最后一试。
        var withoutArtworkBytes = 64 * 1024 * 1024

        static let standard = PortableSnapshotSizeLimits()
    }

    /// The local snapshot stays metadata-only. Transport copies include bounded,
    /// content-deduplicated covers so tvOS can display artwork without the sender's cache.
    nonisolated static func preparePortableSnapshotDataIncludingArtworkAssets(
        _ data: Data,
        cloudSources: [MusicSource]? = nil,
        excludedSourceIDs: Set<String> = [],
        assetStore: MetadataAssetStore = .shared,
        maximumArtworkBytes: Int = portableArtworkBudgetBytes
    ) async -> PortableSnapshotTransferData? {
        await preparePortableSnapshotPageByPage(
            data,
            cloudSources: cloudSources,
            excludedSourceIDs: excludedSourceIDs,
            assetStore: assetStore,
            maximumArtworkBytes: maximumArtworkBytes,
            limits: .standard
        )
    }

    /// LAN pairing sends the library first and its covers afterwards in
    /// batches, so the covers are gathered on their own here with only a raw
    /// byte budget. Returns nil when the snapshot is unreadable or the task is
    /// cancelled.
    /// 与上传前的整理同样一页一页地收(DL4),不整份解码。
    nonisolated static func collectPortableArtwork(
        fromSnapshotData data: Data,
        assetStore: MetadataAssetStore = .shared,
        maximumRawBytes: Int = portableArtworkBudgetBytes,
        pageSize: Int = 1_000
    ) async -> PortableArtworkCollection? {
        let decoder = portableSnapshotDecoder()
        guard let reader = try? TopLevelJSONArrayReader(data: data, key: "songs"),
              let head = try? decoder.decode(Snapshot.self, from: reader.objectWithEmptyArray()) else { return nil }
        let collector = PortableArtworkCollector(
            assetStore: assetStore, maximumRawBytes: maximumRawBytes, maximumEncodedBytes: Int.max / 4
        )
        collector.includeUploadedCovers(head.artworkOverrides)
        var pages = reader.pages(maximumCount: pageSize)
        firstPass: while true {
            guard !Task.isCancelled else { return nil }
            switch nextSongPage(&pages, decoder: decoder, pass: 1) {
            case .unreadable: return nil
            case .end: break firstPass
            case .songs(let songs):
                for song in songs {
                    collector.includeSelectedCover(of: song)
                    collector.noteArtists(of: song)
                }
            }
        }
        guard await includeCachedCovers(reader: reader, pageSize: pageSize, decoder: decoder, collector: collector, keeps: nil),
              await collector.includeArtistCovers() else { return nil }
        return collector.collection
    }

    /// 上面那份整理的做法,两个上限与每页首数可以换(测试、规模夹具)。
    nonisolated static func preparePortableSnapshotPageByPage(
        _ data: Data,
        cloudSources: [MusicSource]?,
        excludedSourceIDs: Set<String>,
        assetStore: MetadataAssetStore,
        maximumArtworkBytes: Int,
        limits: PortableSnapshotSizeLimits,
        pageSize: Int = 1_000
    ) async -> PortableSnapshotTransferData? {
        guard !Task.isCancelled else { return nil }
        let decoder = portableSnapshotDecoder()
        guard let reader = try? TopLevelJSONArrayReader(data: data, key: "songs"),
              var snapshot = try? decoder.decode(Snapshot.self, from: reader.objectWithEmptyArray()) else { return nil }

        // 没有云端源列表时什么都不过滤(局域网),也就不是「只剩本机源」的那种曲库。
        let hasCloudEligibleSources = cloudSources?.contains(where: MusicSourceCloudSyncPolicy.isEligible) ?? true
        // 这台设备单独关了 iCloud 同步的源:扫描结果也不出设备。
        let excludedSongSources = cloudSources.map {
            MusicSourceCloudSyncPolicy.deviceLocalSourceIDs(in: $0).union(excludedSourceIDs)
        }
        // 歌单成员与最近播放引用到的歌(小状态,不随曲库):过滤之后只需要知道其中哪些留下了。
        var referencedSongIDs = Set<String>()
        if cloudSources != nil {
            for members in (snapshot.playlistSongIDs ?? [:]).values { referencedSongIDs.formUnion(members) }
            referencedSongIDs.formUnion(snapshot.recentPlaybackSongIDs ?? [])
        }
        func keeps(_ song: Song) -> Bool {
            excludedSongSources?.contains(song.sourceID) != true
        }

        let availableEncodedBytes = max(0, limits.encodedBytes - data.count - 512)
        let maximumRawArtworkBytes = min(max(0, maximumArtworkBytes), availableEncodedBytes * 3 / 4)
        let collector = PortableArtworkCollector(
            assetStore: assetStore, maximumRawBytes: maximumRawArtworkBytes, maximumEncodedBytes: availableEncodedBytes
        )
        collector.includeUploadedCovers(snapshot.artworkOverrides)

        // 第一遍:过滤,记下整库的结论,留下的歌编码写进临时文件(只编这一次)。
        let encoder = portableSnapshotEncoder()
        let songOutput = LibraryCatalogExportOutput(head: Data())
        var retainedCount = 0
        var retainedSourceIDs = Set<String>()
        var retainedReferencedSongIDs = Set<String>()
        var eligibleLyricsFileNames: Set<String>? = cloudSources == nil ? nil : []
        // 歌词名单只记歌词目录里此刻有的文件:上传随后就从这个目录按名单挑,名单之外的文件本来就不传。以前每首留下的
        // 歌都记一个名字(10 万首约 10 MB),现在随目录里的文件数,不随曲库。整理之后、挑歌词之前才写进目录的那几个
        // 文件这一次不传,下一次上传带上。
        let presentLyricsFileNames: Set<String> = cloudSources == nil ? [] : autoreleasepool {
            Set((try? FileManager.default.contentsOfDirectory(atPath: MetadataAssetStore.shared.lyricsDirectoryURL.path)) ?? [])
        }
        // 歌的字节已经超过最宽的上限时,前面接什么都放不下:不必编完。
        let largestLimit = max(limits.encodedBytes, limits.withoutArtworkBytes)
        var pages = reader.pages(maximumCount: pageSize)
        firstPass: while true {
            guard !Task.isCancelled else { return nil }
            let outcome: Bool? = autoreleasepool {
                switch nextSongPage(&pages, decoder: decoder, pass: 1) {
                case .unreadable: return nil
                case .end: return false
                case .songs(let songs):
                    let retained = songs.filter(keeps)
                    for song in retained {
                        retainedSourceIDs.insert(song.sourceID)
                        if referencedSongIDs.contains(song.id) { retainedReferencedSongIDs.insert(song.id) }
                        if eligibleLyricsFileNames != nil, !presentLyricsFileNames.isEmpty {
                            let expectedName = MetadataAssetStore.shared.expectedLyricsFileName(for: song.id)
                            if presentLyricsFileNames.contains(expectedName) { eligibleLyricsFileNames?.insert(expectedName) }
                            if let legacyName = song.lyricsFileName, LyricsSnapshotEncoder.isValidFileName(legacyName),
                               presentLyricsFileNames.contains(legacyName) {
                                eligibleLyricsFileNames?.insert(legacyName)
                            }
                        }
                        collector.includeSelectedCover(of: song)
                        collector.noteArtists(of: song)
                    }
                    guard !retained.isEmpty else { return true }
                    guard let batch = try? encoder.encode(retained), batch.count >= 2 else { return nil }
                    if retainedCount > 0 { songOutput.append(UInt8(ascii: ",")) }
                    songOutput.append(batch[(batch.startIndex + 1)..<(batch.endIndex - 1)])
                    retainedCount += retained.count
                    return true
                }
            }
            switch outcome {
            case nil: return nil
            case false?: break firstPass
            case true?:
                if songOutput.count > largestLimit {
                    plog("☁️ portable snapshot too large while encoding songs bytes>\(songOutput.count) songs>=\(retainedCount)")
                    return nil
                }
            }
        }
        let songBytes: Data
        do {
            // 一首都没留下(只有本机源的曲库):空的,不去映射一个空文件。
            songBytes = retainedCount == 0 ? Data() : try songOutput.finish()
        } catch {
            plog("☁️ portable snapshot preparation could not keep the encoded songs: \(error)")
            return nil
        }

        if cloudSources != nil {
            snapshot.automaticArtistArtworkCatalogs?.removeAll {
                !retainedSourceIDs.contains($0.sourceID)
            }
            if var playlistSongIDs = snapshot.playlistSongIDs {
                for playlistID in playlistSongIDs.keys {
                    playlistSongIDs[playlistID]?.removeAll {
                        !retainedReferencedSongIDs.contains($0) && !PlaylistPendingEntry.isPendingID($0)
                    }
                }
                snapshot.playlistSongIDs = playlistSongIDs
            }
            snapshot.recentPlaybackSongIDs?.removeAll {
                !retainedReferencedSongIDs.contains($0)
            }
        }

        // 第二遍:用户选的封面都定下之后,按歌的顺序收专辑封面与歌的封面,再收艺人封面。
        guard await includeCachedCovers(
            reader: reader, pageSize: pageSize, decoder: decoder, collector: collector, keeps: keeps
        ), await collector.includeArtistCovers() else { return nil }
        let artwork = collector.collection
        snapshot.artworkAssets = artwork.customAssets.isEmpty ? nil : artwork.customAssets
        snapshot.cachedArtworkAssets = artwork.cachedAssets.isEmpty ? nil : artwork.cachedAssets
        snapshot.artworkCacheReferences = artwork.references.isEmpty ? nil : artwork.references
        snapshot.coverContentSongIDs = artwork.coverContentSongIDs.isEmpty ? nil : artwork.coverContentSongIDs

        // 四级退路:每一级只换前面的小状态,歌的字节不变,整份大小 = 小状态(歌为空时)+ 歌的字节。
        var outputFailed = false
        func output(_ head: Snapshot, limit: Int) -> Data? {
            guard !outputFailed,
                  let encodedHead = try? encoder.encode(head),
                  encodedHead.count + songBytes.count <= limit else { return nil }
            let suffix = Data("\"songs\":[]}".utf8)
            guard encodedHead.count > suffix.count, encodedHead.suffix(suffix.count).elementsEqual(suffix),
                  [UInt8(ascii: "{"), UInt8(ascii: ",")].contains(encodedHead[encodedHead.endIndex - suffix.count - 1]) else {
                // `songs` 不再是最后一个键(以后加了排在它后面的键):接不上,不交出拼错的快照。
                plog("☁️ portable snapshot preparation: the snapshot head no longer ends with the songs array")
                outputFailed = true
                return nil
            }
            let assembled = LibraryCatalogExportOutput(head: Data(encodedHead[..<(encodedHead.endIndex - 2)]))
            assembled.append(songBytes)
            assembled.append(contentsOf: Array("]}".utf8))
            do {
                return try assembled.finish()
            } catch {
                plog("☁️ portable snapshot preparation could not write the prepared snapshot: \(error)")
                outputFailed = true
                return nil
            }
        }
        func transfer(_ data: Data, artworkBytes: Int) -> PortableSnapshotTransferData {
            PortableSnapshotTransferData(
                data: data,
                eligibleLyricsFileNames: eligibleLyricsFileNames,
                eligibleSongCount: retainedCount,
                artworkBytes: artworkBytes,
                hasCloudEligibleSources: hasCloudEligibleSources
            )
        }
        if let data = output(snapshot, limit: limits.encodedBytes) {
            return transfer(data, artworkBytes: artwork.rawBytes)
        }

        // 放不下时先丢封面内容表:它只是让别的设备少读几次文件,Apple TV 看得见的
        // 封面更要紧。
        let coverContentSongIDs = snapshot.coverContentSongIDs
        if coverContentSongIDs != nil {
            snapshot.coverContentSongIDs = nil
            if let data = output(snapshot, limit: limits.encodedBytes) {
                return transfer(data, artworkBytes: artwork.rawBytes)
            }
        }

        // Artwork is optional. Never fall back to the unfiltered raw snapshot
        // for CloudKit, because that would reintroduce device-local songs.
        snapshot.artworkAssets = nil
        snapshot.cachedArtworkAssets = nil
        snapshot.artworkCacheReferences = nil
        if let coverContentSongIDs {
            snapshot.coverContentSongIDs = coverContentSongIDs
            if let data = output(snapshot, limit: limits.encodedBytes) {
                return transfer(data, artworkBytes: 0)
            }
            snapshot.coverContentSongIDs = nil
        }
        guard let data = output(snapshot, limit: limits.withoutArtworkBytes) else { return nil }
        return transfer(data, artworkBytes: 0)
    }

    /// 第二遍:按歌的顺序(`keeps` 为 nil 时不过滤)收专辑封面与歌的封面。false:读不了或取消了。
    private nonisolated static func includeCachedCovers(
        reader: TopLevelJSONArrayReader,
        pageSize: Int,
        decoder: JSONDecoder,
        collector: PortableArtworkCollector,
        keeps: ((Song) -> Bool)?
    ) async -> Bool {
        var pages = reader.pages(maximumCount: pageSize)
        while true {
            guard !Task.isCancelled else { return false }
            switch nextSongPage(&pages, decoder: decoder, pass: 2) {
            case .unreadable: return false
            case .end: return true
            case .songs(let songs):
                for song in songs where keeps?(song) ?? true {
                    guard await collector.includeCachedCovers(of: song) else { return false }
                }
            }
        }
    }

    private enum PortableSnapshotSongPage {
        case songs([Song])
        case end
        case unreadable
    }

    /// 解出下一页歌;解码时留下的自动释放对象在这一页之内就放掉。
    private nonisolated static func nextSongPage(
        _ pages: inout TopLevelJSONArrayReader.Pages, decoder: JSONDecoder, pass: Int
    ) -> PortableSnapshotSongPage {
        let page: PortableSnapshotSongPage = autoreleasepool {
            do {
                guard let data = try pages.next() else { return .end }
                return .songs(try decoder.decode([Song].self, from: data))
            } catch {
                plog("☁️ portable snapshot page unreadable after \(pages.elementCount) songs: \(error)")
                return .unreadable
            }
        }
        #if DEBUG
        if case .songs = page { PortableSnapshotPreparationTesting.pageDidDecode?(pass, pages.elementCount) }
        #endif
        return page
    }

    private nonisolated static func portableSnapshotDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private nonisolated static func portableSnapshotEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

#if DEBUG
enum PortableSnapshotPreparationTesting {
    /// 测试:每解出一页歌调一次(第几遍、到这一页为止解出的首数)。取消任务、量内存都在这里插。
    nonisolated(unsafe) static var pageDidDecode: (@Sendable (_ pass: Int, _ songsDecoded: Int) -> Void)?
}
#endif
