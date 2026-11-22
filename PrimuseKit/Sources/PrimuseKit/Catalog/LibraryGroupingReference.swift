import CryptoKit
import Foundation

/// 曲库整库派生的参照实现:原先写在 `MusicLibrary` 里的专辑/艺人分组、专辑艺人推断、
/// 逐首 id、可见集分类与计数,原样搬到 Kit。App 调用这里;目录(`LibraryCatalog`)的
/// 增量维护与差分测试都以它为准。只依赖 App 的输入(本地化的「未知艺人」、有声分类快照)
/// 由参数传进来。
public enum LibraryGroupingReference {
    /// 纯函数, 可跨 actor 调用 ── rebuildIndex 后台化时 nonisolated
    /// computeAlbumsAndArtists 也要用。
    public static func hashID(_ input: String) -> String {
        let hash = SHA256.hash(data: Data(input.utf8))
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for byte in hash.prefix(16) {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 给单首歌就近填好 albumID / artistID, 不依赖整库 rebuildIndex。这样
    /// addSongs / replaceSong 同步路径里, song 加入 library 时 IDs 立刻
    /// 可读, 后台 rebuildIndex 只负责 derive albums/artists 集合。
    public static func resolvedArtistNames(
        for song: Song,
        configuration: ArtistNameConfiguration = .defaultValue,
        unknownArtist: @autoclosure () -> String
    ) -> [String] {
        let names = song.effectiveArtistNames(configuration: configuration)
        return names.isEmpty ? [unknownArtist()] : names
    }

    /// `resolvedArtistIDs` 读到的全部歌曲字段; 配置在一趟遍历里不变。
    public struct ArtistResolutionFields: Hashable, Sendable {
        public let artistID: String?
        public let artistName: String?
        public let sourceArtistNames: [String]?

        public init(_ song: Song) {
            artistID = song.artistID
            artistName = song.artistName
            sourceArtistNames = song.sourceArtistNames
        }
    }

    public static func resolvedArtistIDs(
        for song: Song,
        configuration: ArtistNameConfiguration,
        unknownArtist: @autoclosure () -> String
    ) -> [String] {
        if let primaryID = song.artistID, !primaryID.isEmpty {
            var firstNativeName: String?
            var nativeNameCount = 0
            for value in song.sourceArtistNames ?? [] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if firstNativeName == nil { firstNativeName = trimmed }
                nativeNameCount += 1
                if nativeNameCount == 2 { break }
            }
            let rawName = song.artistName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = rawName.flatMap { $0.isEmpty ? nil : $0 }
                ?? firstNativeName
                ?? ""
            let containsConfiguredSeparator = configuration.separators.contains { separator in
                guard !separator.isEmpty else { return false }
                return candidate.range(
                    of: separator,
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                ) != nil
            }
            if nativeNameCount <= 1, !containsConfiguredSeparator {
                return [primaryID]
            }
        }

        var seen = Set<String>()
        return resolvedArtistNames(for: song, configuration: configuration, unknownArtist: unknownArtist()).compactMap { name in
            let id = hashID(ArtistIdentityPolicy.groupingKey(name))
            return seen.insert(id).inserted ? id : nil
        }
    }

    /// 整库一遍重算 id 时记住已经算过的：同样的艺人名只解析、哈希一次，同一张专辑的
    /// 身份只哈希一次。装载时 5 万首里艺人名与专辑各只有几千个，原来逐首重算。
    /// 只在一趟遍历里用（艺人名配置在一趟里不变）。
    public final class DerivedIDMemo {
        public struct ArtistNames: Hashable {
            public let artistName: String?
            public let sourceArtistNames: [String]?

            public init(artistName: String?, sourceArtistNames: [String]?) {
                self.artistName = artistName
                self.sourceArtistNames = sourceArtistNames
            }
        }

        public let unknownArtist: String
        public var artistIDs: [ArtistNames: String] = [:]
        public var albumIDs: [AlbumGroupingIdentity: String] = [:]

        public init(unknownArtist: String) {
            self.unknownArtist = unknownArtist
        }
    }

    public static func fillDerivedIDs(
        _ song: inout Song,
        configuration: ArtistNameConfiguration = .defaultValue,
        inferredAlbumArtist: String? = nil,
        memo: DerivedIDMemo? = nil,
        /// 调用方已对这一行跑过同一个修复且它没有改动任何东西（修复对它是恒等的），
        /// 再跑一遍必然还是原样：跳过。
        textRepairIsNoOp: Bool = false,
        unknownArtist fallbackUnknownArtist: @autoclosure () -> String
    ) {
        let previousAlbumArtist = song.albumArtistName
        if !textRepairIsNoOp {
            MediaMetadataTextRepair.repairFileBackedMetadata(in: &song)
        }
        let correctedInference = inferredAlbumArtist == previousAlbumArtist
            ? song.albumArtistName : inferredAlbumArtist
        let unknownArtist = memo?.unknownArtist ?? fallbackUnknownArtist()
        let artistNames = DerivedIDMemo.ArtistNames(
            artistName: song.artistName,
            sourceArtistNames: song.sourceArtistNames
        )
        if let cached = memo?.artistIDs[artistNames] {
            song.artistID = cached
        } else {
            let artist = resolvedArtistNames(
                for: song,
                configuration: configuration,
                unknownArtist: unknownArtist
            ).first ?? unknownArtist
            let artistID = hashID(ArtistIdentityPolicy.groupingKey(artist))
            song.artistID = artistID
            memo?.artistIDs[artistNames] = artistID
        }
        if let identity = AlbumGroupingPolicy.identity(
            albumTitle: song.albumTitle,
            albumArtistName: correctedInference ?? song.albumArtistName,
            trackArtistName: song.artistName,
            unknownArtistName: unknownArtist
        ) {
            if let cached = memo?.albumIDs[identity] {
                song.albumID = cached
            } else {
                let albumID = hashID("\(identity.artistName):\(identity.albumTitle)")
                song.albumID = albumID
                memo?.albumIDs[identity] = albumID
            }
        } else {
            song.albumID = nil
        }
    }

    public static func albumArtistInferenceTrack(
        _ song: Song,
        folders: AlbumArtistFolderIndex
    ) -> AlbumArtistInferencePolicy.Track {
        AlbumArtistInferencePolicy.Track(
            song: song,
            directory: folders.directory(sourceID: song.sourceID, filePath: song.filePath)
        )
    }

    /// 整库口径: 每个源的所有歌一起判定目录权威性与同目录同名专辑的归属。
    public static func inferredAlbumArtists(
        for songs: [Song],
        folders: AlbumArtistFolderIndex,
        configuration: ArtistNameConfiguration = .defaultValue
    ) -> [String: String] {
        autoreleasepool {
            AlbumArtistInferencePolicy.inferredAlbumArtists(
                for: songs.map { albumArtistInferenceTrack($0, folders: folders) },
                configuration: configuration
            )
        }
    }

    /// Candidates being inserted/replaced, judged against the library rows they
    /// will sit next to. `replaceSong` runs on every playback start (the
    /// duration correction), so the library is only pre-filtered by source and
    /// album title here; the policy then splits by folder, or by album title
    /// alone for a source whose paths carry none, and runs on the few rows that
    /// share a scope. The album title is the wider of the two keys, so
    /// pre-filtering by it feeds both splits. Directory authority still stops
    /// at the second distinct folder of a source.
    public static func inferredAlbumArtists(
        for candidates: [Song],
        among library: [Song],
        folders: AlbumArtistFolderIndex,
        configuration: ArtistNameConfiguration = .defaultValue
    ) -> [String: String] {
        guard !candidates.isEmpty else { return [:] }
        var titlesBySource: [String: Set<String>] = [:]
        for song in candidates {
            guard let title = albumArtistInferenceTitle(song.albumTitle) else { continue }
            titlesBySource[song.sourceID, default: []].insert(title)
        }
        guard !titlesBySource.isEmpty else { return [:] }
        let sharedTitles = Set(titlesBySource.values.flatMap { $0 })

        let candidateIDs = Set(candidates.map(\.id))
        let candidateTracks = candidates.map { albumArtistInferenceTrack($0, folders: folders) }
        var directoriesBySource: [String: Set<String>] = [:]
        var authoritative: Set<String> = []
        for track in candidateTracks {
            guard let directory = track.directory else { continue }
            directoriesBySource[track.sourceID, default: []].insert(directory)
        }

        var scoped: [AlbumArtistInferencePolicy.Track] = []
        for song in library where !candidateIDs.contains(song.id) {
            guard let titles = (configuration.mergesCollaborativeAlbums || configuration.mergesSameNamedAlbums)
                    ? sharedTitles : titlesBySource[song.sourceID] else { continue }
            let needsAuthority = !authoritative.contains(song.sourceID)
            let sharesTitle = albumArtistInferenceTitle(song.albumTitle)
                .map { titles.contains($0) } ?? false
            guard needsAuthority || sharesTitle else { continue }
            let track = albumArtistInferenceTrack(song, folders: folders)
            if needsAuthority, let directory = track.directory {
                directoriesBySource[song.sourceID, default: []].insert(directory)
                if (directoriesBySource[song.sourceID]?.count ?? 0) >= 2 {
                    authoritative.insert(song.sourceID)
                }
            }
            if sharesTitle {
                scoped.append(track)
            }
        }
        for (sourceID, directories) in directoriesBySource where directories.count >= 2 {
            authoritative.insert(sourceID)
        }
        scoped.append(contentsOf: candidateTracks)

        let inferred = AlbumArtistInferencePolicy.inferredAlbumArtists(
            for: scoped,
            directoryAuthoritativeSourceIDs: authoritative,
            configuration: configuration
        )
        return inferred.filter { candidateIDs.contains($0.key) }
    }

    public static func albumArtistInferenceTitle(_ value: String?) -> String? {
        guard let title = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }

    /// 后台 derive albums / artists 集合。纯函数 ── 给定 songs 数组, 算出
    /// 派生集合, 不操作 self。
    /// `inferredAlbumArtists` 非空时必须是对同一批歌、同一份 `folders` 算出的推断。
    public static func computeAlbumsAndArtists(
        songs: [Song],
        configuration: ArtistNameConfiguration = .defaultValue,
        folders: AlbumArtistFolderIndex = .empty,
        inferredAlbumArtists: [String: String]? = nil,
        unknownArtist: String
    ) -> (albums: [Album], artists: [Artist], albumIDCorrections: [String: String]) {
        computeAlbumsAndArtists(
            songs: songs,
            configuration: configuration,
            folders: folders,
            precomputedInference: inferredAlbumArtists,
            unknownArtist: unknownArtist,
            cancellationCheck: { false }
        )!
    }

    /// Task-aware counterpart used by the incremental rebuild worker. The old
    /// worker only checked cancellation after all filtering/grouping/sorting had
    /// completed, so every superseded task still consumed a full-library pass.
    public static func computeAlbumsAndArtistsCancellable(
        songs: [Song],
        configuration: ArtistNameConfiguration,
        folders: AlbumArtistFolderIndex,
        unknownArtist: String
    ) -> (albums: [Album], artists: [Artist], albumIDCorrections: [String: String])? {
        computeAlbumsAndArtists(
            songs: songs,
            configuration: configuration,
            folders: folders,
            unknownArtist: unknownArtist,
            cancellationCheck: { Task.isCancelled }
        )
    }

    private struct ArtistNameKey: Hashable {
        let artistName: String?
        let sourceArtistNames: [String]?
    }

    /// One pass per question instead of one per song: each album identity,
    /// album ID, artist name list and artist ID is worked out once and looked
    /// up by position afterwards. Songs are referred to by index, never copied
    /// into groups — at a few hundred thousand songs the former grouping held
    /// two extra copies of the library and hashed every song several times.
    public static func computeAlbumsAndArtists(
        songs: [Song],
        configuration: ArtistNameConfiguration,
        folders: AlbumArtistFolderIndex,
        precomputedInference: [String: String]? = nil,
        unknownArtist: String,
        cancellationCheck: () -> Bool
    ) -> (albums: [Album], artists: [Artist], albumIDCorrections: [String: String])? {
        guard !cancellationCheck() else { return nil }
        // 整库才看得见同一目录里的兄弟文件, 所以 album artist 的补全在这里先
        // 算一次, 下面两处 identity 与逐首 albumID 的对账都用同一份结果。
        let inferredAlbumArtists = precomputedInference
            ?? Self.inferredAlbumArtists(for: songs, folders: folders, configuration: configuration)
        guard !cancellationCheck() else { return nil }

        var artistIDByName: [String: String] = [:]
        func artistID(named name: String) -> String {
            if let id = artistIDByName[name] { return id }
            let id = hashID(ArtistIdentityPolicy.groupingKey(name))
            artistIDByName[name] = id
            return id
        }

        // Albums ── 只 group 有 albumTitle 的歌曲。Every song gets its album's
        // slot (or -1); per album the first song supplies genre/source.
        var slotByIdentity: [AlbumGroupingIdentity: Int] = [:]
        var albumIdentities: [AlbumGroupingIdentity] = []
        var albumFirstSong: [Int] = []
        var albumYears: [Int?] = []
        var albumSongCount: [Int] = []
        var albumDuration: [TimeInterval] = []
        var albumSlotBySong = [Int32](repeating: -1, count: songs.count)
        for (offset, song) in songs.enumerated() {
            if offset.isMultiple(of: 256), cancellationCheck() { return nil }
            guard let identity = AlbumGroupingPolicy.identity(
                albumTitle: song.albumTitle,
                albumArtistName: inferredAlbumArtists[song.id] ?? song.albumArtistName,
                trackArtistName: song.artistName,
                unknownArtistName: unknownArtist
            ) else { continue }
            let slot: Int
            if let existing = slotByIdentity[identity] {
                slot = existing
            } else {
                slot = albumIdentities.count
                slotByIdentity[identity] = slot
                albumIdentities.append(identity)
                albumFirstSong.append(offset)
                albumYears.append(nil)
                albumSongCount.append(0)
                albumDuration.append(0)
            }
            albumSlotBySong[offset] = Int32(slot)
            if albumYears[slot] == nil, let year = song.year, year > 0 {
                albumYears[slot] = year
            }
            albumSongCount[slot] += 1
            albumDuration[slot] += song.duration.groupingSanitizedDuration
        }
        slotByIdentity = [:]
        guard !cancellationCheck() else { return nil }
        var albumIDBySlot: [String] = []
        var albumArtistIDBySlot: [String] = []
        albumIDBySlot.reserveCapacity(albumIdentities.count)
        albumArtistIDBySlot.reserveCapacity(albumIdentities.count)
        var albums: [Album] = []
        albums.reserveCapacity(albumIdentities.count)
        for (slot, identity) in albumIdentities.enumerated() {
            if slot.isMultiple(of: 64), cancellationCheck() { return nil }
            let albumID = hashID("\(identity.artistName):\(identity.albumTitle)")
            let albumArtistID = artistID(named: identity.artistName)
            albumIDBySlot.append(albumID)
            albumArtistIDBySlot.append(albumArtistID)
            let first = songs[albumFirstSong[slot]]
            albums.append(Album(
                id: albumID,
                title: identity.albumTitle,
                artistID: albumArtistID,
                artistName: identity.artistName,
                year: albumYears[slot],
                genre: first.genre,
                songCount: albumSongCount[slot],
                totalDuration: albumDuration[slot],
                sourceID: first.sourceID
            ))
        }
        albums.sort { lhs, rhs in
            autoreleasepool { lhs.title.localizedCompare(rhs.title) == .orderedAscending }
        }
        guard !cancellationCheck() else { return nil }

        // Artists ── every contributor participates while album grouping stays
        // tied to albumArtistName above. This lets a guest artist own the song
        // without incorrectly gaining the host album.
        var namesByKey: [ArtistNameKey: [String]] = [:]
        func artistNames(for song: Song) -> [String] {
            let key = ArtistNameKey(artistName: song.artistName, sourceArtistNames: song.sourceArtistNames)
            if let names = namesByKey[key] { return names }
            let names = resolvedArtistNames(for: song, configuration: configuration, unknownArtist: unknownArtist)
            namesByKey[key] = names
            return names
        }
        var artistSlotByID: [String: Int] = [:]
        var artistIDs: [String] = []
        var artistEntries: [[(name: String, song: Int32)]] = []
        for (offset, song) in songs.enumerated() {
            if offset.isMultiple(of: 256), cancellationCheck() { return nil }
            for name in artistNames(for: song) {
                let id = artistID(named: name)
                let slot: Int
                if let existing = artistSlotByID[id] {
                    slot = existing
                } else {
                    slot = artistIDs.count
                    artistSlotByID[id] = slot
                    artistIDs.append(id)
                    artistEntries.append([])
                }
                artistEntries[slot].append((name, Int32(offset)))
            }
        }
        artistSlotByID = [:]
        guard !cancellationCheck() else { return nil }
        var artists: [Artist] = []
        artists.reserveCapacity(artistIDs.count)
        for (slot, id) in artistIDs.enumerated() {
            if slot.isMultiple(of: 64), cancellationCheck() { return nil }
            let entries = artistEntries[slot]
            guard let name = entries.first?.name else { continue }
            var albumIDs: Set<String> = []
            var thumbnailPath: String?
            for entry in entries {
                let songIndex = Int(entry.song)
                let albumSlot = Int(albumSlotBySong[songIndex])
                if albumSlot >= 0, albumArtistIDBySlot[albumSlot] == id {
                    albumIDs.insert(albumIDBySlot[albumSlot])
                }
                if thumbnailPath == nil {
                    let song = songs[songIndex]
                    if let automatic = AutomaticArtistArtworkReference.resolve(
                        song.artistArtworkFileName
                    ), let artwork = automatic.entry(forArtistName: name) {
                        thumbnailPath = SourceOwnedArtworkReference.make(
                            sourceID: song.sourceID,
                            reference: artwork.reference,
                            cacheDiscriminator: artwork.cacheDiscriminator
                        )
                    } else if artistNames(for: song).first.map({ artistID(named: $0) }) == id,
                              let reference = song.artistArtworkFileName {
                        thumbnailPath = SourceOwnedArtworkReference.make(
                            sourceID: song.sourceID,
                            reference: reference
                        )
                    }
                }
            }
            artists.append(Artist(
                id: id,
                name: name,
                albumCount: albumIDs.count,
                songCount: entries.count,
                thumbnailPath: thumbnailPath
            ))
        }
        artistEntries = []
        artists.sort { lhs, rhs in
            autoreleasepool { lhs.name.localizedCompare(rhs.name) == .orderedAscending }
        }
        guard !cancellationCheck() else { return nil }

        // 逐首入库时只看得见自己那一行, albumID 可能停在未合并的旧值。整库
        // 知道正确答案, 这里把差异交回给调用方去落地。
        var albumIDCorrections: [String: String] = [:]
        for (offset, song) in songs.enumerated() {
            if offset.isMultiple(of: 256), cancellationCheck() { return nil }
            let albumSlot = Int(albumSlotBySong[offset])
            guard albumSlot >= 0 else { continue }
            let expected = albumIDBySlot[albumSlot]
            if song.albumID != expected {
                albumIDCorrections[song.id] = expected
            }
        }
        guard !cancellationCheck() else { return nil }

        return (albums, artists, albumIDCorrections)
    }

    public static func makeVisibleLookups(
        songs: [Song],
        artistNameConfiguration: ArtistNameConfiguration,
        spokenWordClassification: SpokenWordClassificationInputs,
        unknownArtist: String,
        reusingIndexByID reusedIndexByID: [String: Int]? = nil
    ) -> (
        indexByID: [String: Int],
        songIDsByArtistID: [String: [String]],
        songPositionsBySourceID: [String: [Int]],
        unplayableSourceIDs: Set<String>,
        countBySourceID: [String: Int],
        preferredArtworkSongIDByArtistID: [String: String],
        spokenWordSongIDs: Set<String>,
        podcastSongIDs: Set<String>,
        ambientSongIDs: Set<String>,
        collectionOnlySongIDs: Set<String>,
        musicArtistIDs: Set<String>,
        releaseMetadataIndex: AlbumReleaseMetadataIndex
    ) {
        var indexByID: [String: Int] = [:]
        var songIDsByArtistID: [String: [String]] = [:]
        var positionsBySourceID: [String: [Int]] = [:]
        var unplayableSourceIDs: Set<String> = []
        var countBySourceID: [String: Int] = [:]
        // Positions, not songs: the comparison below would otherwise copy a
        // whole song into the table every time one wins.
        var preferredArtworkPositionByArtistID: [String: Int] = [:]
        // Artist field combinations already counted towards the music artists.
        var musicArtistFields: Set<ArtistResolutionFields> = []
        // Growing a dictionary rehashes into a table twice the size while the
        // old one is still alive; sized up front, the peak stays one table.
        if let reusedIndexByID {
            indexByID = reusedIndexByID
        } else {
            indexByID.reserveCapacity(songs.count)
        }
        // Classifying inside this existing pass keeps the whole-library cost
        // to one extension check plus one genre check per song; a separate
        // filter over the library would walk every row a second time.
        var spokenWordSongIDs: Set<String> = []
        var podcastSongIDs: Set<String> = []
        var ambientSongIDs: Set<String> = []
        var collectionOnlySongIDs: Set<String> = []
        let collectionOnlyCandidates = spokenWordClassification.collectionOnlySongIDs
        var musicArtistIDs: Set<String> = []
        // 同一组艺术家字段在整库里反复出现(6.6 万首通常只有几千种), 而每次
        // 解析都要做带区域设置的分隔符检索、折叠和哈希, 这一趟按字段记一次。
        var artistIDsByFields: [ArtistResolutionFields: [String]] = [:]
        var spokenWordGenreVerdicts: [String: ListeningContentKind] = [:]
        var releaseMetadataIndex = AlbumReleaseMetadataIndex()
        for (index, song) in songs.enumerated() {
            autoreleasepool {
                if reusedIndexByID == nil { indexByID[song.id] = index }
                releaseMetadataIndex.include(song)
                let isCollectionOnly = collectionOnlyCandidates.contains(song.id)
                let kind: ListeningContentKind
                if isCollectionOnly {
                    kind = .music
                    collectionOnlySongIDs.insert(song.id)
                } else {
                    kind = spokenWordClassification.kind(
                        songID: song.id,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        genre: song.genre,
                        serverLibraryID: song.serverLibraryID,
                        genreVerdicts: &spokenWordGenreVerdicts
                    )
                }
                if kind.isSpokenWordListening { spokenWordSongIDs.insert(song.id) }
                if kind == .podcast { podcastSongIDs.insert(song.id) }
                if kind == .ambient { ambientSongIDs.insert(song.id) }
                let isSeparateFromMusic = kind.isSeparateFromMusic
                let artistFields = ArtistResolutionFields(song)
                let artistIDs: [String]
                if let memoized = artistIDsByFields[artistFields] {
                    artistIDs = memoized
                } else {
                    artistIDs = resolvedArtistIDs(
                        for: song,
                        configuration: artistNameConfiguration,
                        unknownArtist: unknownArtist
                    )
                    artistIDsByFields[artistFields] = artistIDs
                }
                if !isSeparateFromMusic, !isCollectionOnly, musicArtistFields.insert(artistFields).inserted {
                    musicArtistIDs.formUnion(artistIDs)
                }
                for artistID in artistIDs {
                    songIDsByArtistID[artistID, default: []].append(song.id)
                    if let current = preferredArtworkPositionByArtistID[artistID] {
                        if artworkFallbackPrecedes(song, songs[current]) {
                            preferredArtworkPositionByArtistID[artistID] = index
                        }
                    } else {
                        preferredArtworkPositionByArtistID[artistID] = index
                    }
                }
                positionsBySourceID[song.sourceID, default: []].append(index)
                countBySourceID[song.sourceID, default: 0] += 1
                if !song.isPlayable { unplayableSourceIDs.insert(song.sourceID) }
            }
        }
        return (
            indexByID,
            songIDsByArtistID,
            positionsBySourceID,
            unplayableSourceIDs,
            countBySourceID,
            preferredArtworkPositionByArtistID.mapValues { songs[$0].id },
            spokenWordSongIDs,
            podcastSongIDs,
            ambientSongIDs,
            collectionOnlySongIDs,
            musicArtistIDs,
            releaseMetadataIndex
        )
    }

    /// 同一个源的歌在库里是连着存的: 按连续段数, 一段只查一次字典。整库扫描收尾
    /// 与源卡片对账都在主线程上调它。
    public static func makeSongCountsBySourceID(
        _ songs: [Song]
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        songs.withUnsafeBufferPointer { buffer in
            var index = 0
            while index < buffer.count {
                let sourceID = buffer[index].sourceID
                var end = index + 1
                while end < buffer.count, buffer[end].sourceID == sourceID { end += 1 }
                counts[sourceID, default: 0] += end - index
                index = end
            }
        }
        return counts
    }

    public static func makePreferredArtworkSongLookup(
        songs: [Song]
    ) -> [String: String] {
        var preferredPositions: [String: Int] = [:]
        for (index, song) in songs.enumerated() {
            guard let albumID = song.albumID, !albumID.isEmpty else { continue }
            guard let current = preferredPositions[albumID] else {
                preferredPositions[albumID] = index
                continue
            }
            if artworkFallbackPrecedes(song, songs[current]) {
                preferredPositions[albumID] = index
            }
        }
        return preferredPositions.mapValues { songs[$0].id }
    }

    public static func artworkFallbackPrecedes(
        _ lhs: Song,
        _ rhs: Song
    ) -> Bool {
        let lhsHasArtwork = lhs.coverArtFileName?.isEmpty == false
        let rhsHasArtwork = rhs.coverArtFileName?.isEmpty == false
        if lhsHasArtwork != rhsHasArtwork { return lhsHasArtwork }

        let lhsDisc = lhs.discNumber ?? Int.max
        let rhsDisc = rhs.discNumber ?? Int.max
        if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }

        let lhsTrack = lhs.trackNumber ?? Int.max
        let rhsTrack = rhs.trackNumber ?? Int.max
        if lhsTrack != rhsTrack { return lhsTrack < rhsTrack }
        return lhs.id < rhs.id
    }

    public static func makeSongIndex(_ songs: [Song]) -> [String: Int] {
        var result: [String: Int] = [:]
        result.reserveCapacity(songs.count)
        for (index, song) in songs.enumerated() {
            result[song.id] = index
        }
        return result
    }

    /// `prepareVisibleCache` 里可见专辑与可见艺人的那一段:停用了源或分出了非音乐内容时,
    /// 专辑只留有可见音乐歌曲的,计数与时长按可见歌曲重算;艺人只留音乐艺人,歌曲数跟随
    /// 艺人页列出的可见歌曲。最后按 id 去重。
    public static func visibleAlbumsAndArtists(
        albums: [Album],
        artists: [Artist],
        visibleSongs nextVisibleSongs: [Song],
        musicSongs: [Song],
        disabledSourceIDs: Set<String>,
        splitsMusic: Bool,
        musicArtistIDs: Set<String>,
        songIDsByArtistID: [String: [String]]
    ) -> (albums: [Album], artists: [Artist], artistByID: [String: Artist]) {
        let nextVisibleAlbums: [Album]
        let candidateVisibleArtists: [Artist]
        if disabledSourceIDs.isEmpty, !splitsMusic {
            nextVisibleAlbums = albums
            candidateVisibleArtists = artists
        } else {
            let visibleAlbumIDs = Set(musicSongs.compactMap(\.albumID))
            // An album can span sources. Its summary must use the same visible
            // tracks as songs(forAlbum:), including after a source is disabled.
            var totals: [String: (count: Int, duration: TimeInterval)] = [:]
            for song in nextVisibleSongs {
                guard let albumID = song.albumID, visibleAlbumIDs.contains(albumID) else { continue }
                var total = totals[albumID] ?? (0, 0)
                total.count += 1
                total.duration += song.duration.groupingSanitizedDuration
                totals[albumID] = total
            }
            nextVisibleAlbums = albums.compactMap { album in
                guard let total = totals[album.id] else { return nil }
                var visible = album
                visible.songCount = total.count
                visible.totalDuration = total.duration
                return visible
            }
            // Artists come from the whole library; with a source switched off
            // their counts must follow the songs the artist page lists.
            candidateVisibleArtists = artists.compactMap { artist in
                guard musicArtistIDs.contains(artist.id) else { return nil }
                guard let songIDs = songIDsByArtistID[artist.id],
                      songIDs.count != artist.songCount else { return artist }
                var visible = artist
                visible.songCount = songIDs.count
                return visible
            }
        }
        // Older derived-index caches may contain two display-name variants
        // that resolve to the same stable artist ID. Keep launch resilient
        // while the disposable cache is rebuilt with the current grouping.
        var artistByID: [String: Artist] = [:]
        let nextVisibleArtists = candidateVisibleArtists.filter { artist in
            guard artistByID[artist.id] == nil else { return false }
            artistByID[artist.id] = artist
            return true
        }
        return (nextVisibleAlbums, nextVisibleArtists, artistByID)
    }
}

extension TimeInterval {
    /// 与 App 的 `TimeInterval.sanitizedDuration` 相同:非有限值记 0,负数记 0。
    var groupingSanitizedDuration: TimeInterval {
        guard isFinite else { return 0 }
        return Swift.max(0, self)
    }
}
