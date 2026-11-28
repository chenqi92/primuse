import CryptoKit
import Foundation
import PrimuseKit

/// iCloud / Apple TV 传输随快照带的封面(有上限、按内容去重),拆成能一页一页喂的几步(DL4)。
///
/// 结果与 DL4 之前的 `collectPortableArtwork(songs:…)`(调试构建里留着 `collectPortableArtworkReference`)相同:
/// 1. `includeUploadedCovers`,然后对留下的每首歌按顺序 `includeSelectedCover`、`noteArtists`:用户上传的封面
///    (新的在前)与歌自己选的封面先占预算;
/// 2. 第一步全部做完之后,留下的歌再按同一顺序 `includeCachedCovers`:专辑封面、歌自己的封面(缓存的、内嵌的、旧引用);
/// 3. `includeArtistCovers`:艺人封面,按缓存文件名排序。
/// 每一步的判断、预算的扣法与以前逐行相同;以前整库的歌要先解码成一个数组,艺人要对整库调一次专辑与艺人分组,
/// 现在只留随艺人数增长的艺人表(`ArtistThumbnailAccumulator`)。查文件、转封面时产生的自动释放对象就地放掉:
/// 以前它们攒在协作线程上,整理返回之后才陆续释放。
final class PortableArtworkCollector {
    private let assetStore: MetadataAssetStore
    private let maximumRawBytes: Int
    private let maximumEncodedBytes: Int
    private var usedBytes = 0
    private var usedEncodedBytes = 0
    private var assets: [String: Data] = [:]
    private var cachedAssets: [String: Data] = [:]
    private var references: [String: String] = [:]
    // crash-pattern: allow song-id-collection-property 内嵌封面有内容哈希的歌才进这张表,它本身就是传输快照(上限 60 MiB)里的一个键
    private var coverContentSongIDs: [String: [String]] = [:]
    private var preparedContent: [String: String] = [:]
    private var attemptedContent = Set<String>()
    private var visitedFiles = PortableCoverFileNameSet()
    private var artworkBudgetExhausted = false
    private var artists: LibraryGroupingReference.ArtistThumbnailAccumulator

    init(assetStore: MetadataAssetStore, maximumRawBytes: Int, maximumEncodedBytes: Int) {
        self.assetStore = assetStore
        self.maximumRawBytes = maximumRawBytes
        self.maximumEncodedBytes = maximumEncodedBytes
        artists = .init(
            configuration: ArtistNameConfiguration.load(from: .standard),
            unknownArtist: String(localized: "unknown_artist")
        )
    }

    var collection: MusicLibrary.PortableArtworkCollection {
        MusicLibrary.PortableArtworkCollection(
            customAssets: assets,
            cachedAssets: cachedAssets,
            references: references,
            rawBytes: usedBytes,
            coverContentSongIDs: coverContentSongIDs
        )
    }

    /// 第 1 步,在所有歌之前:用户上传的封面,按更新时间从新到旧。
    func includeUploadedCovers(_ artworkOverrides: [LibraryArtworkOverride]?) {
        let uploaded = (artworkOverrides ?? [])
            .filter { $0.mode == .uploaded }
            .sorted { $0.updatedAt > $1.updatedAt }
        for contentID in uploaded.compactMap(\.uploadedContentID) {
            includeCustomCover(contentID)
        }
    }

    /// 第 1 步,留下的歌按顺序:歌自己选的封面。
    func includeSelectedCover(of song: Song) {
        guard let reference = song.coverArtFileName, StoredArtworkOrigin.resolve(reference) == .selected,
              let contentID = StoredArtworkOrigin.contentID(reference) else { return }
        includeCustomCover(contentID)
    }

    /// 第 1 步,留下的歌按顺序:登记它的艺人(第 3 步按艺人 id 与头像引用找艺人封面)。
    func noteArtists(of song: Song) {
        artists.include(song)
    }

    private func includeCustomCover(_ contentID: String) {
        guard assets[contentID] == nil,
              let artworkData = autoreleasepool(invoking: { assetStore.customArtworkData(contentID: contentID) }),
              usedBytes <= maximumRawBytes - artworkData.count else {
            return
        }
        let encodedBytes = ((artworkData.count + 2) / 3) * 4 + contentID.utf8.count + 6
        guard encodedBytes <= maximumEncodedBytes - usedEncodedBytes else { return }
        assets[contentID] = artworkData
        usedBytes += artworkData.count
        usedEncodedBytes += encodedBytes
    }

    /// 第 2 步,第 1 步做完之后留下的歌再按顺序走一遍。false:任务取消了。
    func includeCachedCovers(of song: Song) async -> Bool {
        // Iterate only retained songs: CloudKit excludes device-local media and
        // must also exclude the ordinary covers belonging solely to that media.
        if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) { return false }
        if let albumID = song.albumID, !albumID.isEmpty {
            let name = "album/" + assetStore.expectedCoverFileName(for: "album_\(albumID)")
            await includeCachedCover(named: name, as: name)
        }
        if let reference = song.coverArtFileName, StoredArtworkOrigin.resolve(reference) == .selected,
           let contentID = StoredArtworkOrigin.contentID(reference), assets[contentID] != nil {
            return true
        }
        let name = assetStore.expectedCoverFileName(for: song.id)
        let sourceName: String
        if StoredArtworkOrigin.resolve(song.coverArtFileName) == .selected,
           let reference = song.coverArtFileName {
            sourceName = reference
        } else if let identity = autoreleasepool(invoking: { assetStore.coverContentIdentifier(named: name) }) {
            if identity.hasPrefix(MusicLibrary.coverContentIdentityPrefix) {
                let key = String(identity.dropFirst(MusicLibrary.coverContentIdentityPrefix.count))
                if PeerScanSeedPolicy.isContentKey(key) {
                    coverContentSongIDs[key, default: []].append(song.id)
                }
            }
            sourceName = name
        } else if let legacy = song.coverArtFileName, assetStore.isLegacyLocalRef(legacy) {
            sourceName = legacy
        } else {
            return true
        }
        await includeCachedCover(named: sourceName, as: name)
        return true
    }

    /// 第 3 步:艺人封面,按缓存文件名排序。false:任务取消了。
    func includeArtistCovers() async -> Bool {
        for name in artistCacheNames().sorted() {
            guard !Task.isCancelled else { return false }
            await includeCachedCover(named: name, as: name)
        }
        return !Task.isCancelled
    }

    /// 与 `MusicLibrary.portableArtistCacheNames(songs:assetStore:)` 同一套名字:艺人 id,有头像引用时再加 id + 引用。
    private func artistCacheNames() -> Set<String> {
        var names = Set<String>()
        for artist in artists.artists {
            var cacheIDs = [artist.id]
            if let reference = artist.thumbnailPath, !reference.isEmpty {
                cacheIDs.append(artist.id + "\u{1F}" + reference)
            }
            for id in cacheIDs {
                names.insert("artist/" + assetStore.expectedCoverFileName(for: "artist_\(id)"))
            }
        }
        return names
    }

    private func includeCachedCover(named sourceName: String, as destinationName: String) async {
        guard references[destinationName] == nil,
              visitedFiles.insert(destinationName),
              let cacheIdentity = autoreleasepool(invoking: { assetStore.coverContentIdentifier(named: sourceName) })
        else { return }
        let sourceID = cacheIdentity.hasPrefix("sha256:") ? cacheIdentity : sourceName + ":" + cacheIdentity
        let referenceBytes = destinationName.utf8.count + 64 + 6
        guard referenceBytes <= maximumEncodedBytes - usedEncodedBytes else { return }
        if let contentID = preparedContent[sourceID] {
            references[destinationName] = contentID
            usedEncodedBytes += referenceBytes
            return
        }
        // A cover that cannot fit the remaining budget must not be
        // decoded again for every track on the same album.
        guard !artworkBudgetExhausted,
              usedBytes < maximumRawBytes,
              attemptedContent.insert(sourceID).inserted else { return }
        let startedAt = ContinuousClock.now
        guard let cover = autoreleasepool(invoking: {
            assetStore.preparePortableCover(named: sourceName, contentIdentifier: sourceID)
        }) else { return }
        if cover.requiredProcessing {
            // Cold exports can encounter thousands of distinct covers.
            // Yield between conversions and leave CPU time for playback.
            do {
                try await Task.sleep(for: max(.milliseconds(20), startedAt.duration(to: .now)))
            } catch { return }
        }
        guard !Task.isCancelled else { return }
        let image = cover.data
        let contentID = autoreleasepool {
            SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        }
        if cachedAssets[contentID] == nil {
            let encodedBytes = ((image.count + 2) / 3) * 4 + contentID.utf8.count + 6
            guard image.count <= maximumRawBytes - usedBytes,
                  encodedBytes + referenceBytes <= maximumEncodedBytes - usedEncodedBytes else {
                artworkBudgetExhausted = true
                return
            }
            cachedAssets[contentID] = image
            usedBytes += image.count
            usedEncodedBytes += encodedBytes
        }
        preparedContent[sourceID] = contentID
        references[destinationName] = contentID
        usedEncodedBytes += referenceBytes
    }
}

/// 收封面时走过的缓存文件名(专辑、歌、艺人各一个),一首歌一个,以前存成字符串。这些名字都是
/// `[album/|artist/]<32 位小写十六进制>.jpg`:存成 16 字节加一个前缀标记,与字符串一一对应,
/// 占的内存约为字符串的四分之一;别的写法照旧存字符串。
struct PortableCoverFileNameSet {
    private struct Key: Hashable {
        let kind: UInt8
        let high: UInt64
        let low: UInt64
    }

    private var keys = Set<Key>()
    private var others = Set<String>()

    /// 新名字为 true(与 `Set.insert(_:).inserted` 相同)。
    mutating func insert(_ name: String) -> Bool {
        guard let key = Self.key(name) else { return others.insert(name).inserted }
        return keys.insert(key).inserted
    }

    var count: Int { keys.count + others.count }

    private static func key(_ name: String) -> Key? {
        var utf8 = Substring(name).utf8
        let kind: UInt8
        if utf8.starts(with: "album/".utf8) {
            kind = 1
            utf8 = utf8.dropFirst(6)
        } else if utf8.starts(with: "artist/".utf8) {
            kind = 2
            utf8 = utf8.dropFirst(7)
        } else {
            kind = 0
        }
        guard utf8.count == 36, utf8.suffix(4).elementsEqual(".jpg".utf8) else { return nil }
        var high: UInt64 = 0
        var low: UInt64 = 0
        for (offset, byte) in utf8.prefix(32).enumerated() {
            let digit: UInt64
            switch byte {
            case 48...57: digit = UInt64(byte - 48)
            case 97...102: digit = UInt64(byte - 87)
            default: return nil
            }
            if offset < 16 {
                high = high << 4 | digit
            } else {
                low = low << 4 | digit
            }
        }
        return Key(kind: kind, high: high, low: low)
    }
}
