import Foundation
import GRDB

/// 「专辑艺术家」列表在曲库目录上的那一份(6c 单元 4 U4b,S1 的专辑艺人那一支),与对目录里的可见专辑、可见艺人跑
/// `AlbumArtistIndexBuilder.build(...)` 得到的 `artists` 逐项相同 —— 成员、先后、专辑数,只当过专辑艺人的那几位
/// (「群星」)的名字与歌曲数(名下专辑的曲目合计)。也唱歌的人歌曲数照旧是他唱的歌(按页取时从艺人表读)。
///
/// 每行只留键与专辑数(两个 4 字节);只当过专辑艺人的那几位整项留着(通常几位到几百位)。按页物化
/// (`albumArtists(keys:in:)`)时拿曲目艺人那一行,换上这里数出的专辑数。
public struct LibraryAlbumArtistBrowse: Sendable, Equatable {
    /// 浏览顺序上的一行:曲目艺人是他的键(`artist.key`,大于 0);只当过专辑艺人的是 `-(他在 albumOnly 里的位置 + 1)`。
    public let keys: ContiguousArray<Int32>
    /// 同一行署名给他的可见专辑数。
    public let albumCounts: ContiguousArray<Int32>
    /// 只当过专辑艺人的那几位,专辑数、歌曲数都已经填好。
    public let albumOnly: [Artist]
    /// 按读音排(`LibraryAlbumArtistOrder.reading`)时的首字母分段,与 `keys` 一一对应;按专辑艺人列表的先后时为空。
    public let sections: [LibraryBrowseSection]
    public let revision: Int64
    /// 曲目艺人的键 → 他的专辑数(物化时换上)。
    let albumCountByKey: [Int32: Int32]

    public var count: Int { keys.count }

    public static let empty = LibraryAlbumArtistBrowse(
        keys: [], albumCounts: [], albumOnly: [], sections: [], revision: 0, albumCountByKey: [:]
    )
}

/// 「专辑艺术家」列表的先后。
public enum LibraryAlbumArtistOrder: Sendable, Hashable {
    /// 同 `visibleAlbumArtists`(`AlbumArtistIndexBuilder`:曲目艺人按艺人列表的先后,只当过专辑艺人的按名字归并进去)。
    /// Mac 的艺术家页、侧栏的数。
    case library
    /// 同 `LibraryArtistBrowseLayoutBuilder.layout(artists: visibleAlbumArtists, unknownArtistName:)`(按读音,
    /// 「未知艺术家」排最后,带首字母分段)。iPhone、iPad 的艺术家页。
    case reading(unknownArtistName: String?)
}

extension LibraryCatalog {
    /// 「专辑艺术家」列表。主线程外调用:按专辑墙的先后分块走一遍可见专辑(一块至多 `maxMaterializedRows` 张),
    /// 用参照实现同一条署名规则(`AlbumArtistCreditPolicy.resolvedCredits`)数每位署名者的专辑。
    public func albumArtistBrowse(order: LibraryAlbumArtistOrder = .library) throws -> LibraryAlbumArtistBrowse {
        let tracks = try visibleTrackArtistsForBrowse()
        var trackIndexByID: [String: Int] = [:]
        trackIndexByID.reserveCapacity(tracks.rows.count)
        for (index, row) in tracks.rows.enumerated() where trackIndexByID[row.id] == nil { trackIndexByID[row.id] = index }

        let configuration = groupingConfiguration.artistNames.normalized()
        let albumList = try albumKeys(visibleOnly: true)
        var albumCountByID: [String: Int] = [:]
        var songCountByID: [String: Int] = [:]
        var albumOnlyNameByID: [String: String] = [:]
        struct CreditKey: Hashable {
            let id: String
            let name: String?
            let sourceArtistNames: [String]?
        }
        var creditsByKey: [CreditKey: [(id: String, name: String?)]] = [:]
        for chunk in Self.chunks(of: Array(albumList.keys), size: LibraryScale.maxMaterializedRows) {
            for album in try albums(keys: chunk) {
                guard let originalID = album.artistID, !originalID.isEmpty else { continue }
                let key = CreditKey(id: originalID, name: album.artistName, sourceArtistNames: album.sourceArtistNames)
                let credits: [(id: String, name: String?)]
                if let cached = creditsByKey[key] {
                    credits = cached
                } else {
                    credits = AlbumArtistCreditPolicy.resolvedCredits(
                        for: album,
                        configuration: configuration,
                        isKnownTrackArtist: { trackIndexByID[$0] != nil },
                        knownTrackArtistName: { id in trackIndexByID[id].map { tracks.rows[$0].name } },
                        artistID: { LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey($0)) }
                    )
                    creditsByKey[key] = credits
                }
                for (id, name) in credits {
                    albumCountByID[id, default: 0] += 1
                    songCountByID[id, default: 0] += album.songCount
                    if trackIndexByID[id] == nil, albumOnlyNameByID[id] == nil, let name { albumOnlyNameByID[id] = name }
                }
            }
        }

        // 也唱歌的人:照艺人列表的先后;只当过专辑艺人的:按名字排好再逐个归并(同 `AlbumArtistIndexBuilder.merged`)。
        let shared = tracks.rows.indices.filter { albumCountByID[tracks.rows[$0].id] != nil }
        let albumOnly = albumOnlyNameByID
            .map { id, name in
                Artist(id: id, name: name, albumCount: albumCountByID[id] ?? 0, songCount: songCountByID[id] ?? 0)
            }
            .sorted(by: AlbumArtistIndexBuilder.precedes)
        enum Entry { case track(Int), albumOnly(Int) }
        var entries: [Entry] = []
        entries.reserveCapacity(shared.count + albumOnly.count)
        var start = 0
        for (onlyIndex, item) in albumOnly.enumerated() {
            var low = start
            var high = shared.count
            while low < high {
                let mid = (low + high) / 2
                let row = tracks.rows[shared[mid]]
                if AlbumArtistIndexBuilder.precedes(item, Artist(id: row.id, name: row.name)) { high = mid } else { low = mid + 1 }
            }
            entries.append(contentsOf: shared[start..<low].map(Entry.track))
            entries.append(.albumOnly(onlyIndex))
            start = low
        }
        entries.append(contentsOf: shared[start...].map(Entry.track))

        var sections: [LibraryBrowseSection] = []
        if case .reading(let unknownArtistName) = order {
            let trailing = LibraryCatalogDerivedFields.keyData(LibraryCollationPolicy.trailingKey)
            func sortKey(_ entry: Entry) -> (key: Data, name: String, id: String) {
                switch entry {
                case .track(let index):
                    let row = tracks.rows[index]
                    return (row.nameKey.count <= 1 || row.name == unknownArtistName ? trailing : row.nameKey, row.name, row.id)
                case .albumOnly(let index):
                    let artist = albumOnly[index]
                    let key = LibraryCatalogDerivedFields.keyData(LibraryCollationPolicy.key(for: artist.name))
                    return (key.count <= 1 || artist.name == unknownArtistName ? trailing : key, artist.name, artist.id)
                }
            }
            // 同 `LibraryArtistBrowseLayoutBuilder.layout`:读音键(分段、读音)、名字、id。
            let keyed = entries.map { (entry: $0, key: sortKey($0)) }.sorted { lhs, rhs in
                if lhs.key.key != rhs.key.key { return lhs.key.key.lexicographicallyPrecedes(rhs.key.key) }
                if lhs.key.name != rhs.key.name { return lhs.key.name < rhs.key.name }
                return lhs.key.id < rhs.key.id
            }
            entries = keyed.map(\.entry)
            sections = LibraryBrowseLayout<Artist>.sections(bucketIndices: keyed.map { Self.bucketIndex(of: $0.key.key) })
        }
        let rows: [AlbumArtistRow] = entries.map { entry in
            switch entry {
            case .track(let index): .track(tracks.rows[index].key, tracks.rows[index].id)
            case .albumOnly(let index): .albumOnly(index, albumOnly[index].id)
            }
        }
        return makeAlbumArtistBrowse(
            rows, albumOnly: albumOnly, albumCountByID: albumCountByID, revision: albumList.revision, sections: sections
        )
    }

    /// 按页物化「专辑艺术家」的几行(键见 `LibraryAlbumArtistBrowse.keys`)。不在这一份里的键跳过。
    public func albumArtists(keys: some Collection<Int32>, in browse: LibraryAlbumArtistBrowse) throws -> [Int32: Artist] {
        var result: [Int32: Artist] = [:]
        let trackKeys = keys.filter { $0 > 0 && browse.albumCountByKey[$0] != nil }
        for chunk in Self.chunks(of: trackKeys, size: LibraryScale.maxMaterializedRows) {
            let artists = try self.artists(keys: chunk, visibleCounts: true)
            // `artists(keys:)` 保持顺序、跳过不在的键:数目对得上就按位置对回键,否则一个个取。
            let pairs: [(Int32, Artist)] = artists.count == chunk.count
                ? Array(zip(chunk, artists))
                : try chunk.compactMap { key in try self.artists(keys: [key], visibleCounts: true).first.map { (key, $0) } }
            for (key, artist) in pairs {
                var entry = artist
                entry.albumCount = Int(browse.albumCountByKey[key] ?? 0)
                result[key] = entry
            }
        }
        for key in keys where key < 0 {
            let index = Int(-key) - 1
            if browse.albumOnly.indices.contains(index) { result[key] = browse.albumOnly[index] }
        }
        return result
    }

    private enum AlbumArtistRow {
        case track(Int32, String)
        case albumOnly(Int, String)
    }

    private func makeAlbumArtistBrowse(
        _ rows: [AlbumArtistRow], albumOnly: [Artist], albumCountByID: [String: Int], revision: Int64,
        sections: [LibraryBrowseSection]
    ) -> LibraryAlbumArtistBrowse {
        var keys = ContiguousArray<Int32>()
        var counts = ContiguousArray<Int32>()
        var countByKey: [Int32: Int32] = [:]
        keys.reserveCapacity(rows.count)
        counts.reserveCapacity(rows.count)
        for row in rows {
            switch row {
            case .track(let key, let id):
                let count = Int32(clamping: albumCountByID[id] ?? 0)
                keys.append(key)
                counts.append(count)
                countByKey[key] = count
            case .albumOnly(let index, let id):
                keys.append(-Int32(clamping: index + 1))
                counts.append(Int32(clamping: albumCountByID[id] ?? 0))
            }
        }
        return LibraryAlbumArtistBrowse(
            keys: keys, albumCounts: counts, albumOnly: albumOnly, sections: sections, revision: revision,
            albumCountByKey: countByKey
        )
    }

    /// 可见的曲目艺人(键、id、名字、读音键),按 `artistKeys(visibleOnly: true)` 的先后。
    private func visibleTrackArtistsForBrowse() throws -> (rows: [(key: Int32, id: String, name: String, nameKey: Data)], revision: Int64) {
        try reader.read { db in
            let revision = try Self.revision(in: db)
            let splits = try Self.visibleSplitsLibrary(in: db)
            let filter = splits
                ? """
                  WHERE artist.key IN (SELECT artistRef FROM artistSourceStat
                      WHERE kind = 0 AND sourceKey IN (\(Self.enabledSourcesSQL)))
                  """
                : ""
            var rows: [(key: Int32, id: String, name: String, nameKey: Data)] = []
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT key, id, name, nameKey FROM artist \(filter)
                ORDER BY name COLLATE \(LibraryCatalogSchema.localizedCollation), firstRowid, firstOrdinal
                """)
            while let row = try cursor.next() {
                rows.append((try Self.rowid32(row[0]), row[1], row[2], row[3]))
            }
            return (rows, revision)
        }
    }
}
