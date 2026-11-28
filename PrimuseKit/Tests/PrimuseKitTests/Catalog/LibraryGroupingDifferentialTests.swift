import Foundation
import GRDB
import Testing
@testable import PrimuseKit

/// 目录的增量分组维护与参照实现(`LibraryGroupingReference` 等,原 `MusicLibrary` 的整库算法)
/// 在整库上的结果逐项一致。每一步随机操作之后都比一遍;种子可复现,失败时打印种子与步数。
@Suite("Library grouping differential", .serialized)
struct LibraryGroupingDifferentialTests {
    static let unknownArtist = "Unknown Artist"

    // MARK: - Reference model (the app pipeline over the whole library)

    struct Model {
        var songs: [Song] = []
        var configuration = LibraryGroupingConfiguration(unknownArtist: LibraryGroupingDifferentialTests.unknownArtist)
        var disabled: Set<String> = []
        var folderParents: [String: [String: String]] = [:]

        mutating func upsert(_ song: Song) {
            if let index = songs.firstIndex(where: { $0.id == song.id }) { songs[index] = song } else { songs.append(song) }
        }

        mutating func delete(_ id: String) { songs.removeAll { $0.id == id } }
    }

    struct FolderRow: Hashable {
        let sourceID: String
        let path: String
        let parent: String?
        let songCount: Int
    }

    struct Snapshot: Equatable {
        var albums: [Album]
        var artists: [Artist]
        var visibleAlbums: [Album]
        var visibleArtists: [Artist]
        var albumArtists: [Artist]
        var genres: [String]
        var kinds: [String: Int]
        var effectiveAlbumIDs: [String: String]
        var books: [String: String]
        var bookTitles: [String: String]
        var visibleCounts: [String: Int]
        var allCounts: [String: Int]
        var albumArtwork: [String: String]
        var artistArtwork: [String: String]
        var folders: Set<FolderRow>
        /// 可见专辑自动认出的发行类别(RC-a)。
        var releaseCategories: [String: [String]] = [:]
        /// 按发行类别筛的可见专辑(带一份固定的手动选择),每种类别一组。
        var releaseCategoryAlbums: [String: [String]] = [:]
        /// 「不列只有单曲、EP 的人」留下的专辑艺人(同一份手动选择)。
        var fullReleaseAlbumArtists: [String] = []

        /// 可见专辑的时长由各源小计相加,与逐首累加只差浮点舍入;其余字段逐位相等。
        static func roundedDurations(_ albums: [Album]) -> [Album] {
            albums.map { album in
                var copy = album
                copy.totalDuration = (album.totalDuration * 1_000).rounded() / 1_000
                return copy
            }
        }
    }

    /// 两边各自按可见专辑 id 排好后定下同一份「手动选择」:每四张里第二张手动改成单曲 / EP,第四张改成专辑 + 现场。
    static func releaseOverrides(_ albumIDs: [String]) -> [String: Set<AlbumReleaseCategory>] {
        var overrides: [String: Set<AlbumReleaseCategory>] = [:]
        for (index, id) in albumIDs.sorted().enumerated() {
            if index % 4 == 1 { overrides[id] = [.singleEP] } else if index % 4 == 3 { overrides[id] = [.album, .live] }
        }
        return overrides
    }

    static func names(_ categories: Set<AlbumReleaseCategory>) -> [String] { categories.map(\.rawValue).sorted() }

    static func referenceSnapshot(_ model: Model) -> Snapshot {
        let configuration = model.configuration
        let folders = AlbumArtistFolderIndex(parentsBySource: model.folderParents)
        let inferred = LibraryGroupingReference.inferredAlbumArtists(
            for: model.songs, folders: folders, configuration: configuration.artistNames
        )
        let derived = LibraryGroupingReference.computeAlbumsAndArtists(
            songs: model.songs, configuration: configuration.artistNames, folders: folders,
            inferredAlbumArtists: inferred, unknownArtist: unknownArtist
        )
        // App:整库派生后把每首的 albumID 纠正到分组结果。
        let corrected = model.songs.map { song -> Song in
            guard let albumID = derived.albumIDCorrections[song.id] else { return song }
            var copy = song
            copy.albumID = albumID
            return copy
        }
        let visibleSongs = corrected.filter { !model.disabled.contains($0.sourceID) }
        let lookups = LibraryGroupingReference.makeVisibleLookups(
            songs: visibleSongs, artistNameConfiguration: configuration.artistNames,
            spokenWordClassification: configuration.classification, unknownArtist: unknownArtist
        )
        let separate = lookups.spokenWordSongIDs.union(lookups.collectionOnlySongIDs).union(lookups.ambientSongIDs)
        let musicSongs = visibleSongs.filter { !separate.contains($0.id) }
        let visible = LibraryGroupingReference.visibleAlbumsAndArtists(
            albums: derived.albums, artists: derived.artists, visibleSongs: visibleSongs, musicSongs: musicSongs,
            disabledSourceIDs: model.disabled, splitsMusic: !separate.isEmpty,
            musicArtistIDs: lookups.musicArtistIDs, songIDsByArtistID: lookups.songIDsByArtistID
        )
        let albumArtistIndex = AlbumArtistIndexBuilder.build(
            albums: visible.albums, trackArtists: visible.artists, trackArtistsByID: visible.artistByID,
            configuration: configuration.artistNames,
            artistID: { LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey($0)) }
        )
        let genres = LibraryGenreIndexBuilder.build(from: musicSongs, alsoSplitting: configuration.genreSeparators).genres
            .map { "\($0.id)|\($0.name)|\($0.songCount)|\($0.albumCount)" }
        var kinds: [String: Int] = [:]
        for song in visibleSongs {
            if lookups.collectionOnlySongIDs.contains(song.id) { kinds[song.id] = 4 }
            else if lookups.podcastSongIDs.contains(song.id) { kinds[song.id] = 2 }
            else if lookups.spokenWordSongIDs.contains(song.id) { kinds[song.id] = 1 }
            else if lookups.ambientSongIDs.contains(song.id) { kinds[song.id] = 3 }
            else { kinds[song.id] = 0 }
        }
        var books: [String: String] = [:]
        var bookTitles: [String: String] = [:]
        for (kind, members) in [(1, visibleSongs.filter { kinds[$0.id] == 1 }), (2, visibleSongs.filter { kinds[$0.id] == 2 })] {
            guard !members.isEmpty else { continue }
            let placement = SpokenWordBookGrouping.bookPlacement(for: members.map { SpokenWordBookItem(song: $0) })
            for (songID, bookID) in placement.bookIDs {
                books[songID] = "\(kind):\(bookID):\(placement.displayTitles[songID] ?? "")"
            }
            for bookID in Set(placement.bookIDs.values) {
                bookTitles["\(kind):\(bookID)"] = placement.groupTitles[bookID] ?? ""
            }
        }
        var effective: [String: String] = [:]
        for song in corrected {
            // 没有专辑身份的歌:目录里是 NULL,参照实现保留填 ID 时的 nil。
            if let albumID = song.albumID, song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                effective[song.id] = albumID
            }
        }
        var folderCounts: [String: [String: Int]] = [:]
        var folderSet = Set<FolderRow>()
        for song in model.songs {
            folderCounts[song.sourceID, default: [:]][AlbumArtistInferencePolicy.directory(ofPath: song.filePath), default: 0] += 1
        }
        for (sourceID, counts) in folderCounts {
            var paths = Set<String>()
            for path in counts.keys {
                var current: String? = path
                while let value = current, paths.insert(value).inserted { current = GroupingMaintenance.parentFolder(of: value) }
            }
            for path in paths {
                folderSet.insert(FolderRow(sourceID: sourceID, path: path, parent: GroupingMaintenance.parentFolder(of: path),
                                           songCount: counts[path] ?? 0))
            }
        }
        // 发行类别:App 在可见集那一趟里数标签、再按可见专辑定下(`LibraryReleaseCategoryIndex` 读的那一份)。
        var release = lookups.releaseMetadataIndex
        release.prepare(albums: visible.albums)
        let overrides = releaseOverrides(visible.albums.map(\.id))
        var releaseCategories: [String: [String]] = [:]
        for album in visible.albums { releaseCategories[album.id] = names(release.categories(albumID: album.id)) }
        var releaseCategoryAlbums: [String: [String]] = [:]
        for category in AlbumReleaseCategory.allCases {
            releaseCategoryAlbums[category.rawValue] = visible.albums
                .filter { (overrides[$0.id] ?? release.categories(albumID: $0.id)).contains(category) }.map(\.id).sorted()
        }
        let visibleAlbumByID = Dictionary(visible.albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let fullReleaseAlbumArtists = AlbumArtistReleaseFilter.artists(
            albumArtistIndex.artists, albumIDsByArtistID: albumArtistIndex.albumIDsByArtistID
        ) { albumID in
            guard let album = visibleAlbumByID[albumID] else { return false }
            let chosen = overrides[albumID]
            return AlbumArtistReleaseFilter.countsAsFullRelease(
                categories: chosen ?? release.categories(albumID: albumID), isManualChoice: chosen != nil,
                songCount: album.songCount
            )
        }.map(\.id)
        return Snapshot(
            albums: derived.albums, artists: derived.artists,
            visibleAlbums: Snapshot.roundedDurations(visible.albums), visibleArtists: visible.artists,
            albumArtists: albumArtistIndex.artists, genres: genres, kinds: kinds, effectiveAlbumIDs: effective,
            books: books, bookTitles: bookTitles,
            visibleCounts: lookups.countBySourceID,
            allCounts: LibraryGroupingReference.makeSongCountsBySourceID(corrected),
            albumArtwork: LibraryGroupingReference.makePreferredArtworkSongLookup(songs: visibleSongs),
            artistArtwork: lookups.preferredArtworkSongIDByArtistID, folders: folderSet,
            releaseCategories: releaseCategories, releaseCategoryAlbums: releaseCategoryAlbums,
            fullReleaseAlbumArtists: fullReleaseAlbumArtists
        )
    }

    /// 「专辑艺术家」从 `albumArtistBrowse` 按页取出来的整份(U4b);按读音排的那一份与对它跑的
    /// `LibraryArtistBrowseLayoutBuilder`(iPhone 艺术家页的排法)逐项、逐段相同。
    static func browsedAlbumArtists(_ catalog: LibraryCatalog) throws -> [Artist] {
        let browse = try catalog.albumArtistBrowse()
        let byKey = try catalog.albumArtists(keys: browse.keys, in: browse)
        let artists = browse.keys.compactMap { byKey[$0] }
        #expect(artists.count == browse.count)
        #expect(browse.albumCounts.map(Int.init) == artists.map(\.albumCount))
        let reading = try catalog.albumArtistBrowse(order: .reading(unknownArtistName: unknownArtist))
        let readingByKey = try catalog.albumArtists(keys: reading.keys, in: reading)
        let layout = LibraryArtistBrowseLayoutBuilder.layout(artists: artists, unknownArtistName: unknownArtist)
        #expect(reading.keys.compactMap { readingByKey[$0] } == layout.items)
        #expect(reading.sections == layout.sections)
        return artists
    }

    /// 艺人页两排专辑(详情页):对 `artistAlbumShelfCandidates` 的候选跑 `partition`,与对整份可见专辑跑的相同
    /// (署名用参照实现的专辑艺人索引)。也唱歌的人与只当过专辑艺人的都比。
    static func checkArtistShelves(_ catalog: LibraryCatalog, albums: [Album], artists: [Artist]) throws {
        let index = try catalog.albumArtistIndexForReference()
        let known = Set(artists.map(\.id))
        for artist in artists + index.artists.filter({ !known.contains($0.id) }) {
            let displayName = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let songRows = try catalog.artistSongRowList(artistID: artist.id).rowids
            let songAlbumIDs = Set(try catalog.songs(rowids: songRows).compactMap(\.albumID))
            let candidates = try catalog.artistAlbumShelfCandidates(
                artistID: artist.id, displayName: displayName, songAlbumIDs: songAlbumIDs
            )
            let expected = ArtistAlbumShelfPolicy.partition(
                albums: albums, artistID: artist.id, displayName: displayName, songAlbumIDs: songAlbumIDs,
                isCredited: { index.albumIDsByArtistID[artist.id]?.contains($0.id) == true }
            )
            let actual = ArtistAlbumShelfPolicy.partition(
                albums: candidates.albums, artistID: artist.id, displayName: displayName, songAlbumIDs: songAlbumIDs,
                isCredited: { candidates.creditedAlbumIDs.contains($0.id) }
            )
            #expect(actual == expected, "shelves of \(artist.name)")
        }
    }

    static func catalogSnapshot(_ catalog: LibraryCatalog) throws -> Snapshot {
        let albums = try catalog.albums(keys: catalog.albumKeys(visibleOnly: false).keys, visibleCounts: false)
        let artists = try catalog.artists(keys: catalog.artistKeys(visibleOnly: false).keys, visibleCounts: false)
        let visibleAlbumKeys = try catalog.albumKeys(visibleOnly: true).keys
        let visibleAlbums = try catalog.albums(keys: visibleAlbumKeys, visibleCounts: true)
        let visibleArtists = try catalog.artists(keys: catalog.artistKeys(visibleOnly: true).keys, visibleCounts: true)
        let genres = try catalog.genres().map { "\($0.id)|\($0.name)|\($0.songCount)|\($0.albumCount)" }
        let albumArtists = try browsedAlbumArtists(catalog)
        #expect(albumArtists == (try catalog.albumArtistIndexForReference().artists))
        try checkArtistShelves(catalog, albums: visibleAlbums, artists: visibleArtists)
        let visibleCounts = try catalog.songCountsBySource(.visible)
        let allCounts = try catalog.songCountsBySource(.everything)
        let releaseCategories = try #require(try catalog.albumReleaseCategories(), "release categories are complete").mapValues(names)
        let overrides = releaseOverrides(visibleAlbums.map(\.id))
        let albumIDByKey = Dictionary(zip(visibleAlbumKeys, visibleAlbums.map(\.id)), uniquingKeysWith: { first, _ in first })
        var releaseCategoryAlbums: [String: [String]] = [:]
        for category in AlbumReleaseCategory.allCases {
            let keys = try #require(try catalog.albumKeys(inReleaseCategory: category, overrides: overrides))
            releaseCategoryAlbums[category.rawValue] = keys.map { albumIDByKey[$0] ?? "key \($0)" }.sorted()
        }
        let fullReleaseIDs = try #require(try catalog.albumArtistIDsWithFullReleases(overrides: overrides))
        let fullReleaseAlbumArtists = albumArtists.filter { fullReleaseIDs.contains($0.id) }.map(\.id)
        return try catalog.pool.read { db in
            var kinds: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT s.id, s.kind FROM song s JOIN source ON source.key = s.sourceKey WHERE source.enabled = 1
                """) { kinds[row[0]] = row[1] }
            var effective: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT s.id, a.id FROM song s JOIN album a ON a.key = s.effectiveAlbumRef") {
                effective[row[0]] = row[1]
            }
            var books: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT s.id, b.kind, b.bookID, coalesce(b.displayTitle, '') FROM songBook b JOIN song s ON s.rowid = b.songRowid
                WHERE b.bookID IS NOT NULL
                """) {
                books[row[0]] = "\(row[1] as Int):\(row[2] as String):\(row[3] as String)"
            }
            var bookTitles: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT kind, id, coalesce(title, '') FROM book") {
                bookTitles["\(row[0] as Int):\(row[1] as String)"] = row[2]
            }
            var albumArtwork: [String: String] = [:]
            for albumID in try String.fetchAll(db, sql: """
                SELECT DISTINCT a.id FROM song s JOIN album a ON a.key = s.effectiveAlbumRef
                WHERE s.sourceKey IN (SELECT key FROM source WHERE enabled = 1)
                """) {
                albumArtwork[albumID] = try String.fetchOne(db, sql: """
                    SELECT id FROM song WHERE effectiveAlbumRef = (SELECT key FROM album WHERE id = ?)
                    AND sourceKey IN (SELECT key FROM source WHERE enabled = 1)
                    ORDER BY \(LibraryCatalog.artworkFallbackOrder) LIMIT 1
                    """, arguments: [albumID])
            }
            var artistArtwork: [String: String] = [:]
            for artistID in try String.fetchAll(db, sql: """
                SELECT DISTINCT r.id FROM songArtistLookup l JOIN artistRef r ON r.ref = l.artistRef
                JOIN song s ON s.rowid = l.songRowid
                WHERE s.sourceKey IN (SELECT key FROM source WHERE enabled = 1)
                """) {
                artistArtwork[artistID] = try String.fetchOne(db, sql: """
                    SELECT id FROM song WHERE rowid IN (SELECT songRowid FROM songArtistLookup
                        WHERE artistRef = (SELECT ref FROM artistRef WHERE id = ?))
                    AND sourceKey IN (SELECT key FROM source WHERE enabled = 1) ORDER BY \(LibraryCatalog.artworkFallbackOrder) LIMIT 1
                    """, arguments: [artistID])
            }
            var folderRows: [Int64: (source: String, parent: Int64, name: String, odd: String, count: Int)] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT f.key, source.id, f.parentKey, f.name, f.oddPath, f.songCount FROM folder f
                JOIN source ON source.key = f.sourceKey
                """) {
                folderRows[row[0]] = (row[1], row[2], row[3], row[4], row[5])
            }
            func path(_ key: Int64) -> String {
                guard let row = folderRows[key] else { return "?" }
                if !row.odd.isEmpty { return row.odd }
                return row.parent == 0 ? row.name : GroupingMaintenance.joinFolder(path(row.parent), row.name)
            }
            var folders = Set<FolderRow>()
            for (key, row) in folderRows {
                folders.insert(FolderRow(sourceID: row.source, path: path(key),
                                         parent: row.parent == 0 ? nil : path(row.parent), songCount: row.count))
            }
            return Snapshot(
                albums: albums, artists: artists, visibleAlbums: Snapshot.roundedDurations(visibleAlbums),
                visibleArtists: visibleArtists, albumArtists: albumArtists,
                genres: genres, kinds: kinds, effectiveAlbumIDs: effective, books: books, bookTitles: bookTitles,
                visibleCounts: visibleCounts, allCounts: allCounts,
                albumArtwork: albumArtwork, artistArtwork: artistArtwork, folders: folders,
                releaseCategories: releaseCategories, releaseCategoryAlbums: releaseCategoryAlbums,
                fullReleaseAlbumArtists: fullReleaseAlbumArtists
            )
        }
    }

    static func describeDifference(_ lhs: Snapshot, _ rhs: Snapshot) -> String {
        var parts: [String] = []
        func check<T: Equatable>(_ name: String, _ a: T, _ b: T) {
            if a != b { parts.append("\(name):\n  catalog   \(a)\n  reference \(b)") }
        }
        check("albums", lhs.albums, rhs.albums)
        check("artists", lhs.artists, rhs.artists)
        check("visibleAlbums", lhs.visibleAlbums, rhs.visibleAlbums)
        check("visibleArtists", lhs.visibleArtists, rhs.visibleArtists)
        check("albumArtists", lhs.albumArtists, rhs.albumArtists)
        check("genres", lhs.genres, rhs.genres)
        check("kinds", lhs.kinds, rhs.kinds)
        check("effectiveAlbumIDs", lhs.effectiveAlbumIDs, rhs.effectiveAlbumIDs)
        check("books", lhs.books, rhs.books)
        check("bookTitles", lhs.bookTitles, rhs.bookTitles)
        check("visibleCounts", lhs.visibleCounts, rhs.visibleCounts)
        check("allCounts", lhs.allCounts, rhs.allCounts)
        check("albumArtwork", lhs.albumArtwork, rhs.albumArtwork)
        check("artistArtwork", lhs.artistArtwork, rhs.artistArtwork)
        check("folders", lhs.folders, rhs.folders)
        check("releaseCategories", lhs.releaseCategories, rhs.releaseCategories)
        check("releaseCategoryAlbums", lhs.releaseCategoryAlbums, rhs.releaseCategoryAlbums)
        check("fullReleaseAlbumArtists", lhs.fullReleaseAlbumArtists, rhs.fullReleaseAlbumArtists)
        return parts.joined(separator: "\n")
    }

    // MARK: - Random library operations

    static let sources = ["nas", "smb", "server", "drive", "local"]
    static let albumTitles = ["鸣潮 原声带", "Greatest Hits", "Greatest Hits ", "greatest hits", "叶惠美", "OST", "Live", "Dune 01", "三体 第12集", "Untitled",
                              "Summer (EP)", "Hits - Single", "Live at Budokan", "十周年演唱会"]
    /// 发行类型标签(RC-a):认得出的、认不出的、空的、两种并存的。
    static let releaseTypes = ["Album", "Single", "EP", "Live", "单曲", "Compilation", "", "album; live", "迷你专辑"]
    static let artistPool = [
        "周杰伦", "Taylor Swift", "RAF Camora", "RAF Camora feat. Bonez MC", "Bonez MC", "A & B", "A", "B",
        "陈奕迅;王菲", "王菲", "AC/DC", "Various Artists", "鸣潮先约电台", "Composer Y", "Label X", "Artist C", "",
        // 同一个艺人(分组键相同)的不同写法:艺人名取首次署名的写法。
        "taylor swift", "TAYLOR  SWIFT", "Ｂｏｎｅｚ MC", "Beyoncé", "Beyonce", "王菲 & 陈奕迅",
    ]

    /// 艺人图:普通文件名,或扫描生成的「自动艺人图」(按艺人名给图;合唱曲给每个艺人各一张)。
    static func artistArtwork(_ rng: inout CatalogTestRandom) -> String? {
        guard rng.chance(25) else { return nil }
        if rng.chance(40) { return "artist\(rng.int(0...2)).jpg" }
        let names = (0..<rng.int(1...3)).map { _ in rng.pick(["Taylor Swift", "王菲", "Bonez MC", "A", "B", "Beyonce", "nobody"]) }
        return AutomaticArtistArtworkReference.make(entries: names.map { name in
            .init(normalizedArtistName: SourceArtistArtworkCatalog.normalizedArtistName(name),
                  reference: "auto/\(name).jpg", cacheDiscriminator: "c\(rng.int(0...3))")
        })
    }
    static let genrePool = ["Pop", "Rock/Pop", "Jazz; Blues", "有声书", "Audiobook", "Podcast", "Ambient", "相声", "pop", "Ｐｏｐ"]
    static let directories = ["Music/OST", "Music/OST/CD 2", "Music/Pop", "Music/Hits", "有声书/三体", "有声书/Dune", "", "Music"]

    static func makeSong(_ rng: inout CatalogTestRandom, serial: Int, configuration: LibraryGroupingConfiguration) -> Song {
        let source = rng.pick(sources)
        let directory = rng.pick(directories)
        let isCue = rng.chance(8)
        let fileName = isCue ? "album.ape" : "\(String(format: "%02d", rng.int(1...12))) track\(serial).\(rng.pick(["flac", "mp3", "m4b", "m4a"]))"
        let path: String
        switch source {
        case "server": path = "/songs/\(serial)"          // 按条目 id 寻址,路径里没有文件夹
        case "drive": path = "item-\(serial)"             // 网盘条目 id,文件夹来自扫描索引
        default: path = directory.isEmpty ? fileName : "\(directory)/\(fileName)"
        }
        var song = Song(
            id: "song-\(serial)",
            title: rng.chance(10) ? "Intro" : "Title \(rng.int(0...40))",
            albumTitle: rng.chance(85) ? rng.pick(albumTitles) : nil,
            artistName: rng.chance(92) ? rng.pick(artistPool) : nil,
            albumArtistName: rng.chance(45) ? rng.pick(artistPool) : nil,
            trackNumber: rng.maybe(80) { $0.int(1...12) },
            discNumber: rng.maybe(30) { $0.int(1...2) },
            duration: Double(rng.int(0...600)) + 0.25,
            fileFormat: rng.pick([.flac, .mp3, .m4a]),
            filePath: path,
            sourceID: source,
            genre: rng.maybe(70) { $0.pick(genrePool) },
            year: rng.maybe(60) { $0.pick([1999, 2021, 2026]) },
            dateAdded: Date(timeIntervalSinceReferenceDate: Double(serial)),
            coverArtFileName: rng.chance(40) ? "cover\(rng.int(0...3)).jpg" : nil,
            artistArtworkFileName: artistArtwork(&rng),
            cueSheetPath: isCue ? "\(directory)/album.cue" : nil,
            cueStartTime: isCue ? Double(rng.int(0...3_000)) : nil,
            cueEndTime: isCue ? Double(rng.int(3_001...6_000)) : nil,
            userMetadataEditedAt: rng.chance(5) ? Date(timeIntervalSinceReferenceDate: 1) : nil,
            // 服务器专辑主要在按条目寻址的源;有文件夹的源里偶尔也有(它们按标题、不按文件夹推断)。
            serverCatalogAlbum: rng.chance(source == "server" ? 70 : 6)
                ? ServerCatalogAlbumReference(id: rng.chance(10) ? " " : "al-\(rng.int(0...4))",
                                              taggedArtist: rng.maybe(40) { $0.pick(artistPool) })
                : nil
        )
        if rng.chance(15) { song.sourceArtistNames = [rng.pick(artistPool), rng.pick(artistPool)] }
        if rng.chance(25) { song.contentMetadata = SongContentMetadata(releaseType: rng.pick(releaseTypes)) }
        fill(&song, configuration: configuration)
        return song
    }

    /// App 入库时逐首填 id(不带整库推断),目录与参照实现拿到的是同一首歌。
    static func fill(_ song: inout Song, configuration: LibraryGroupingConfiguration) {
        LibraryGroupingReference.fillDerivedIDs(
            &song, configuration: configuration.artistNames, unknownArtist: unknownArtist
        )
    }

    /// 改分组输入时 App 先按新配置重填每首的 id,再整库重建。
    static func refill(_ model: inout Model, catalog: LibraryCatalog) throws {
        var changed: [Song] = []
        for index in model.songs.indices {
            var song = model.songs[index]
            fill(&song, configuration: model.configuration)
            if song != model.songs[index] { changed.append(song) }
            model.songs[index] = song
        }
        try catalog.apply(upserts: changed)
        try catalog.setGroupingConfiguration(model.configuration)
    }

    static func randomStep(_ rng: inout CatalogTestRandom, model: inout Model, catalog: LibraryCatalog, serial: inout Int) throws -> String {
        let roll = rng.int(0...99)
        switch roll {
        case 0..<35:
            let songs = (0..<rng.int(1...8)).map { _ -> Song in
                serial += 1
                return makeSong(&rng, serial: serial, configuration: model.configuration)
            }
            songs.forEach { model.upsert($0) }
            try catalog.apply(upserts: songs)
            return "add \(songs.count)"
        case 35..<48 where !model.songs.isEmpty:
            let ids = (0..<rng.int(1...3)).map { _ in rng.pick(model.songs).id }
            ids.forEach { model.delete($0) }
            try catalog.apply(upserts: [], deletingIDs: ids)
            return "delete \(ids)"
        case 48..<70 where !model.songs.isEmpty:
            var edited: [Song] = []
            for _ in 0..<rng.int(1...4) {
                var song = rng.pick(model.songs)
                switch rng.int(0...9) {
                case 0: song.albumTitle = rng.chance(85) ? rng.pick(albumTitles) : nil
                case 1: song.artistName = rng.pick(artistPool)
                case 2: song.albumArtistName = rng.chance(60) ? rng.pick(artistPool) : nil
                case 3: song.year = rng.maybe(60) { $0.pick([1999, 2021, 2026]) }
                case 4: song.genre = rng.maybe(70) { $0.pick(genrePool) }
                case 5: song.trackNumber = rng.maybe(80) { $0.int(1...12) }
                case 6: song.artistArtworkFileName = artistArtwork(&rng)
                case 7: song.duration = rng.chance(10) ? -1 : Double(rng.int(0...600)) + Double(rng.int(0...999)) / 1_000
                case 8: song.sourceArtistNames = rng.maybe(40) { [$0.pick(artistPool), $0.pick(artistPool)] }
                default: song.coverArtFileName = rng.chance(50) ? "cover\(rng.int(0...3)).jpg" : nil
                }
                fill(&song, configuration: model.configuration)
                model.upsert(song)
                edited.append(song)
            }
            try catalog.apply(upserts: edited)
            return "edit \(edited.map(\.id))"
        case 70..<78 where !model.songs.isEmpty:
            var song = rng.pick(model.songs)
            guard song.sourceID != "server", song.sourceID != "drive" else { return "skip move" }
            song.filePath = "\(rng.pick(directories.filter { !$0.isEmpty }))/moved-\(song.id).flac"
            fill(&song, configuration: model.configuration)
            model.upsert(song)
            try catalog.apply(upserts: [song])
            return "move \(song.id)"
        case 78..<84:
            let source = rng.pick(sources)
            let enable = model.disabled.contains(source)
            if enable { model.disabled.remove(source) } else { model.disabled.insert(source) }
            try catalog.setSourceEnabled(enable, sourceID: source)
            return "\(enable ? "enable" : "disable") \(source)"
        case 84..<90:
            var artistNames = model.configuration.artistNames
            switch rng.int(0...3) {
            case 0: artistNames.mergesCollaborativeAlbums.toggle()
            case 1: artistNames.mergesSameNamedAlbums.toggle()
            case 2: artistNames.separators = rng.chance(50) ? [";", "/", "、", "&"] : ArtistNameConfiguration.defaultValue.separators
            default: artistNames.protectedNames = rng.chance(50) ? ["AC/DC", "A & B"] : ["AC/DC"]
            }
            model.configuration.artistNames = artistNames.normalized()
            try refill(&model, catalog: catalog)
            return "artist configuration"
        case 90..<95:
            var classification = model.configuration.classification
            switch rng.int(0...2) {
            case 0: if let song = model.songs.randomElement(using: &rng.system) { classification.collectionOnlySongIDs.formSymmetricDifference([song.id]) }
            case 1: if let song = model.songs.randomElement(using: &rng.system) {
                classification.overrides[song.id] = rng.pick(ListeningContentKind.allCases)
            }
            default: classification.separatesAmbient.toggle()
            }
            model.configuration.classification = classification
            if rng.chance(30) { model.configuration.genreSeparators = model.configuration.genreSeparators.isEmpty ? .slash : [] }
            try catalog.setGroupingConfiguration(model.configuration)
            return "classification"
        default:
            // 网盘源的文件夹来自扫描索引:按条目 id 给出父文件夹(一部分条目暂不知道)。
            var parents: [String: String] = [:]
            for song in model.songs where song.sourceID == "drive" && rng.chance(80) {
                parents[song.filePath] = "folder-\(rng.int(0...2))"
            }
            model.folderParents["drive"] = parents.isEmpty ? nil : parents
            try catalog.setFolderParents(sourceID: "drive", parents: parents.isEmpty ? nil : parents)
            return "folder parents \(parents.count)"
        }
    }

    static func run(seed: UInt64, steps: Int) throws {
        var rng = CatalogTestRandom(seed: seed)
        var model = Model()
        let temporary = try TemporaryCatalog()
        try temporary.catalog.setGroupingConfiguration(model.configuration)
        var serial = 0
        var actions: [String: Int] = [:]
        var last: Snapshot?
        for step in 0..<steps {
            let action = try randomStep(&rng, model: &model, catalog: temporary.catalog, serial: &serial)
            actions[String(action.prefix { $0 != " " }), default: 0] += 1
            let expected = referenceSnapshot(model)
            let actual = try catalogSnapshot(temporary.catalog)
            if actual != expected {
                Issue.record("seed \(seed) step \(step) after \(action):\n\(describeDifference(actual, expected))")
                return
            }
            last = expected
        }
        if let last {
            let kinds = Dictionary(grouping: last.kinds.values, by: { $0 }).mapValues(\.count)
            print("🧪 grouping-diff seed=\(seed) steps=\(steps) songs=\(model.songs.count) albums=\(last.albums.count) "
                + "visibleAlbums=\(last.visibleAlbums.count) artists=\(last.artists.count) visibleArtists=\(last.visibleArtists.count) "
                + "albumArtists=\(last.albumArtists.count) genres=\(last.genres.count) books=\(Set(last.books.values).count) "
                + "folders=\(last.folders.count) inferred=\(last.effectiveAlbumIDs.count) kinds=\(kinds.sorted { $0.key < $1.key }) "
                + "actions=\(actions.sorted { $0.key < $1.key })")
        }
    }

    static var stepsPerSeed: Int {
        ProcessInfo.processInfo.environment["PRIMUSE_GROUPING_DIFF_STEPS"].flatMap(Int.init) ?? 110
    }

    @Test("Incremental grouping equals the reference after every random step",
          arguments: (UInt64(1)...UInt64(20)).map { $0 &* 7_919 })
    func randomized(seed: UInt64) throws {
        try Self.run(seed: seed, steps: Self.stepsPerSeed)
    }

    /// RC-a:从 v3 升上来的目录(发行类别两列是空的、记着「待补算」)。补齐之前问发行类别的查询都答 nil(界面照旧用
    /// 内存模型);后台补算可以停在任意两批之间、下次接着补,补的途中照常写进来的歌连同发行类别一起写;补完与参照
    /// 实现逐项相同。整库重建做完也算补齐。
    @Test("Release categories backfill after an upgrade: resumable, writes in between, then equal to the reference")
    func releaseCategoryBackfill() throws {
        var rng = CatalogTestRandom(seed: 4_242)
        var model = Model()
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        try catalog.setGroupingConfiguration(model.configuration)
        var serial = 0
        for _ in 0..<60 { _ = try Self.randomStep(&rng, model: &model, catalog: catalog, serial: &serial) }
        #expect(try catalog.releaseCategoriesAreComplete())
        let before = try Self.catalogSnapshot(catalog)
        #expect(before == Self.referenceSnapshot(model), "\(Self.describeDifference(before, Self.referenceSnapshot(model)))")

        try catalog.simulateReleaseCategoryUpgradeForTesting()
        #expect(try !catalog.releaseCategoriesAreComplete())
        #expect(try catalog.hasPendingReleaseCategoryBackfill())
        #expect(try catalog.albumReleaseCategories() == nil, "nothing is answered before the backfill completes")
        #expect(try catalog.albumKeys(inReleaseCategory: .album, overrides: [:]) == nil)
        #expect(try catalog.albumArtistIDsWithFullReleases(overrides: [:]) == nil)

        // 两批之后停下(像滑动、来了增量那样),中间照常写几首,再接着补;再停一次、再接着。
        #expect(before.visibleAlbums.count >= 4, "enough albums to stop halfway")
        var batches = 0
        #expect(try !catalog.backfillReleaseCategories(batchSize: 1, isCancelled: { batches += 1; return batches > 2 }))
        #expect(try catalog.hasPendingReleaseCategoryBackfill())
        for _ in 0..<5 { _ = try Self.randomStep(&rng, model: &model, catalog: catalog, serial: &serial) }
        batches = 0
        _ = try catalog.backfillReleaseCategories(batchSize: 1, isCancelled: { batches += 1; return batches > 1 })
        #expect(try catalog.backfillReleaseCategories(batchSize: 4))
        #expect(try catalog.releaseCategoriesAreComplete())
        #expect(try !catalog.hasPendingReleaseCategoryBackfill())
        let expected = Self.referenceSnapshot(model)
        let actual = try Self.catalogSnapshot(catalog)
        #expect(actual == expected, "after the backfill:\n\(Self.describeDifference(actual, expected))")

        // 升级之后紧接着整库重建:重建写的每张专辑都带发行类别,做完就算齐,不用再补。
        try catalog.simulateReleaseCategoryUpgradeForTesting()
        try catalog.rebuildGrouping()
        #expect(try catalog.releaseCategoriesAreComplete())
        let rebuilt = try Self.catalogSnapshot(catalog)
        #expect(rebuilt == expected, "after a rebuild:\n\(Self.describeDifference(rebuilt, expected))")
    }

    /// RC-a:按歌记的手动选择从目录对到专辑(只看启用的源),与内存里按可见歌曲对的相同;按专辑记的、最新的那次
    /// 为准都由同一个 `Snapshot.resolved` 定。
    @MainActor
    @Test("Manual release choices filed under songs resolve to the same albums from the catalog")
    func releaseOverrideResolution() throws {
        var rng = CatalogTestRandom(seed: 99)
        var model = Model()
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        try catalog.setGroupingConfiguration(model.configuration)
        var serial = 0
        for _ in 0..<50 { _ = try Self.randomStep(&rng, model: &model, catalog: catalog, serial: &serial) }
        let suite = "release-overrides-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AlbumReleaseCategoryStore(defaults: defaults)
        let withAlbums = model.songs.filter { $0.albumID != nil }
        for (index, song) in withAlbums.prefix(12).enumerated() {
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            store.set(index.isMultiple(of: 2) ? [.singleEP] : [.live], albumID: "ignored-\(index)", songIDs: [song.id], at: date)
        }
        if let album = try catalog.albums(keys: catalog.albumKeys(visibleOnly: true).keys, visibleCounts: true).first {
            store.set([.album], albumID: album.id, songIDs: [], at: Date(timeIntervalSince1970: 1_800_000_000))
        }
        let snapshot = store.snapshot
        // 内存里的对法:可见歌曲的(纠正过的)专辑 id。
        let reference = Self.referenceSnapshot(model)
        let visibleSongs = model.songs.filter { !model.disabled.contains($0.sourceID) }
        let expected = snapshot.resolved(albumIDForSong: { id in
            visibleSongs.first { $0.id == id }.flatMap { reference.effectiveAlbumIDs[$0.id] }
        })
        let albumIDs = try catalog.visibleAlbumIDs(forSongIDs: snapshot.songIDs)
        let actual = snapshot.resolved(albumIDForSong: { albumIDs[$0] })
        #expect(actual == expected)
        #expect(actual?.isEmpty == false)
    }

    // MARK: - Documented edge cases (AlbumArtistInferencePolicy header, #462, #333)

    static func scenario(_ songs: [Song], configuration: LibraryGroupingConfiguration? = nil, label: String) throws {
        var model = Model()
        if let configuration { model.configuration = configuration }
        let temporary = try TemporaryCatalog()
        try temporary.catalog.setGroupingConfiguration(model.configuration)
        for var song in songs {
            fill(&song, configuration: model.configuration)
            model.upsert(song)
        }
        // 一首一首写:每次都是增量维护。
        for song in model.songs { try temporary.catalog.apply(upserts: [song]) }
        let expected = referenceSnapshot(model)
        let actual = try catalogSnapshot(temporary.catalog)
        #expect(actual == expected, "\(label):\n\(describeDifference(actual, expected))")
        // 再整库重建一次,结果不变。
        try temporary.catalog.rebuildGrouping()
        let rebuilt = try catalogSnapshot(temporary.catalog)
        #expect(rebuilt == expected, "\(label) rebuild:\n\(describeDifference(rebuilt, expected))")
    }

    static func song(_ id: String, source: String = "nas", path: String, album: String?, artist: String?, albumArtist: String? = nil,
                     sourceArtists: [String]? = nil, sourceAlbumArtists: [String]? = nil,
                     year: Int? = nil, disc: Int? = nil, track: Int? = nil, server: ServerCatalogAlbumReference? = nil) -> Song {
        Song(id: id, title: "t\(id)", albumTitle: album, artistName: artist, sourceArtistNames: sourceArtists,
             albumArtistName: albumArtist, trackNumber: track, discNumber: disc, duration: 100, fileFormat: .flac,
             filePath: path, sourceID: source, year: year, serverCatalogAlbum: server,
             sourceAlbumArtistNames: sourceAlbumArtists)
    }

    @Test("#470: structured multi-album-artist collaborations match the reference across incremental apply and rebuild")
    func structuredMultiAlbumArtists() throws {
        try Self.scenario([
            Self.song("1", source: "subsonic", path: "/songs/1", album: "Palmen aus Plastik 2",
                      artist: "Bonez MC • RAF Camora", albumArtist: "Bonez MC • RAF Camora",
                      sourceArtists: ["Bonez MC", "RAF Camora"],
                      sourceAlbumArtists: ["Bonez MC", "RAF Camora"],
                      year: 2018, track: 1,
                      server: .init(id: "pap-2", taggedArtist: "Bonez MC • RAF Camora")),
            Self.song("2", source: "subsonic", path: "/songs/2", album: "Palmen aus Plastik 2",
                      artist: "Bonez MC", albumArtist: "Bonez MC • RAF Camora",
                      sourceAlbumArtists: ["Bonez MC", "RAF Camora"],
                      year: 2018, track: 2,
                      server: .init(id: "pap-2", taggedArtist: "Bonez MC • RAF Camora")),
            Self.song("3", source: "subsonic", path: "/songs/3", album: "Palmen aus Plastik 2",
                      artist: "Bonez MC • RAF Camora • Gzuz", albumArtist: "Bonez MC • RAF Camora",
                      sourceArtists: ["Bonez MC", "RAF Camora", "Gzuz"],
                      sourceAlbumArtists: ["Bonez MC", "RAF Camora"],
                      year: 2018, track: 3,
                      server: .init(id: "pap-2", taggedArtist: "Bonez MC • RAF Camora")),
            Self.song("4", source: "nas", path: "/ost/1.flac", album: "OST", artist: "Composer A",
                      albumArtist: "Various Artists", track: 1),
            Self.song("5", source: "nas", path: "/ost/2.flac", album: "OST", artist: "Composer B & C",
                      albumArtist: "Composer B & C", sourceArtists: ["Composer B", "Composer C"],
                      sourceAlbumArtists: ["Composer B", "Composer C"], track: 2),
            Self.song("6", source: "nas", path: "/other/1.flac", album: "Other", artist: "Solo", track: 1),
        ], label: "multi-album-artists")
    }

    @Test("OST folder: untagged siblings adopt the explicit album artist; the majority absorbs the minority")
    func ostFolder() throws {
        try Self.scenario([
            Self.song("1", path: "/music/ost/1.flac", album: "鸣潮 原声带", artist: "鸣潮先约电台", albumArtist: "鸣潮先约电台"),
            Self.song("2", path: "/music/ost/2.flac", album: "鸣潮 原声带", artist: "Composer Y"),
            Self.song("3", path: "/music/ost/3.flac", album: "鸣潮 原声带", artist: "Composer Z"),
            Self.song("4", path: "/music/other/4.flac", album: "别的专辑", artist: "别人"),
            Self.song("5", path: "/music/vote/5.flac", album: "Vote", artist: "Main"),
            Self.song("6", path: "/music/vote/6.flac", album: "Vote", artist: "Main"),
            Self.song("7", path: "/music/vote/7.flac", album: "Vote", artist: "Guest"),
        ], label: "ost")
    }

    @Test("Flat server source: one explicit tag decides; a different year stays apart; duets fold")
    func flatSource() throws {
        try Self.scenario([
            Self.song("1", source: "server", path: "/songs", album: "纵横四海", artist: "A", albumArtist: "Label X", year: 2021, track: 1),
            Self.song("2", source: "server", path: "/songs", album: "纵横四海", artist: "B", year: 2021, track: 2),
            Self.song("3", source: "server", path: "/songs", album: "纵横四海", artist: "C", year: 1999, track: 1),
            Self.song("4", source: "server", path: "/songs", album: "Duets", artist: "RAF Camora", track: 1),
            Self.song("5", source: "server", path: "/songs", album: "Duets", artist: "RAF Camora feat. Bonez MC", track: 2),
        ], label: "flat")
    }

    @Test("#462: same-titled server albums stay apart; #333: tagged artist inside a server album")
    func serverAlbums() throws {
        try Self.scenario([
            Self.song("1", source: "server", path: "/songs/1", album: "raf", artist: "RAF Camora", year: 2021, track: 1,
                      server: .init(id: "al-1", taggedArtist: nil)),
            Self.song("2", source: "server", path: "/songs/2", album: "raf", artist: "RAF Camora feat. Bonez MC", year: 2021, track: 2,
                      server: .init(id: "al-1", taggedArtist: "RAF Camora")),
            Self.song("3", source: "server", path: "/songs/3", album: "raf", artist: "2 Engel & Charlie", year: 2026, track: 1,
                      server: .init(id: "al-2", taggedArtist: nil)),
            Self.song("4", source: "server", path: "/songs/4", album: "ost", artist: "Guest A", track: 1,
                      server: .init(id: "al-3", taggedArtist: "Label X")),
            Self.song("5", source: "server", path: "/songs/5", album: "ost", artist: "Composer Y", track: 2,
                      server: .init(id: "al-3", taggedArtist: nil)),
            Self.song("6", source: "server", path: "/songs/6", album: "ost", artist: "Composer Z", albumArtist: "Composer Y", track: 3,
                      server: .init(id: "al-3", taggedArtist: nil)),
        ], label: "server")
    }

    @Test("Merge toggles: collaborative and same-named albums across sources and folders")
    func mergeToggles() throws {
        var configuration = LibraryGroupingConfiguration(unknownArtist: Self.unknownArtist)
        configuration.artistNames.mergesCollaborativeAlbums = true
        configuration.artistNames.mergesSameNamedAlbums = true
        configuration = LibraryGroupingConfiguration(
            artistNames: configuration.artistNames, unknownArtist: Self.unknownArtist
        )
        try Self.scenario([
            Self.song("1", source: "nas", path: "/a/1.flac", album: "Together", artist: "A & B", year: 2020),
            Self.song("2", source: "smb", path: "/b/2.flac", album: "Together", artist: "A", year: 2020),
            Self.song("3", source: "nas", path: "/c/3.flac", album: "Hits", artist: "X"),
            Self.song("4", source: "smb", path: "/d/4.flac", album: "Hits", artist: "Y"),
        ], configuration: configuration, label: "merges")
    }
}

private extension CatalogTestRandom {
    /// 给 `randomElement(using:)` 用的可复现生成器。
    var system: CatalogSeededGenerator {
        get { CatalogSeededGenerator(state: state) }
        set { self = CatalogTestRandom(seed: newValue.state) }
    }
}

struct CatalogSeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        var random = CatalogTestRandom(seed: state)
        let value = random.next()
        state = random.state
        return value
    }
}
