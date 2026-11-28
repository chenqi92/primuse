import Foundation
import GRDB

/// 一首歌对它所在专辑的贡献(专辑聚合的输入,按库内顺序)。
struct AlbumMember {
    let rowid: Int64
    let year: Int?
    let sourceKey: Int64
    let kind: Int
    /// `durationKey`:非有限值记 0、负数记 0,与参照实现的 `groupingSanitizedDuration` 一致。
    let duration: Double
    let dateAdded: Double
    /// 这首歌的署名里有专辑艺人(参照实现里这张专辑才算进专辑艺人的专辑数)。
    let credited: Bool
    /// 已校验过未被推断覆盖的原生多专辑艺人列表。
    let sourceAlbumArtistNames: [String]?
    /// 这首歌的发行类型标签认出的类别(`AlbumReleaseCategoryRule.explicitFlags`)。
    var releaseFlags: AlbumReleaseCategoryRule.Flags = []
}

/// 一张专辑的聚合,与参照实现 `computeAlbumsAndArtists` 逐项同一口径:首首歌按库内顺序,
/// 年份取第一个大于 0 的,时长按库内顺序逐首累加(浮点结果逐位相同)。
struct AlbumAggregate {
    struct StatKey: Hashable {
        let sourceKey: Int64
        let kind: Int
    }

    struct Stat {
        var count = 0
        var duration = 0.0
        var maxDateAdded = -Double.infinity
        /// 这个源、这一类里各首的发行类型标签认出的类别的并集(可见集按启用的源再合)。
        var releaseFlags: AlbumReleaseCategoryRule.Flags = []
    }

    let firstRowid: Int64
    let year: Int?
    let songCount: Int
    let duration: Double
    let ownerCredited: Bool
    let sourceArtistNames: [String]?
    let stats: [(key: StatKey, stat: Stat)]

    init?(members: some Sequence<AlbumMember>) {
        var first: Int64?
        var year: Int?
        var count = 0
        var duration = 0.0
        var credited = false
        var sourceArtistNames: [String]?
        var order: [StatKey] = []
        var stats: [StatKey: Stat] = [:]
        for member in members {
            if first == nil { first = member.rowid }
            if year == nil, let value = member.year, value > 0 { year = value }
            if sourceArtistNames == nil, let names = member.sourceAlbumArtistNames {
                sourceArtistNames = names
            }
            count += 1
            duration += member.duration
            if member.credited { credited = true }
            let key = StatKey(sourceKey: member.sourceKey, kind: member.kind)
            var stat = stats[key] ?? {
                order.append(key)
                return Stat()
            }()
            stat.count += 1
            stat.duration += member.duration
            stat.maxDateAdded = max(stat.maxDateAdded, member.dateAdded)
            stat.releaseFlags.formUnion(member.releaseFlags)
            stats[key] = stat
        }
        guard let first else { return nil }
        firstRowid = first
        self.year = year
        songCount = count
        self.duration = duration
        ownerCredited = credited
        self.sourceArtistNames = sourceArtistNames
        self.stats = order.map { ($0, stats[$0]!) }
    }
}

extension GroupingMaintenance {
    // MARK: - Album artist inference over dirty scopes

    /// 专辑艺人推断只在推断范围之内互相影响:有文件夹的源按(源、目录、标题),没有文件夹的、
    /// 服务器专辑里的按(源、标题),打开合并开关时按标题。只取脏范围里的行(只读推断要的几列),
    /// 一次交给 `AlbumArtistInferencePolicy`,回写 `effectiveAlbumRef`;新旧专辑都记脏。
    mutating func regroupDirtyScopes() throws {
        guard !dirty.scopeSeeds.isEmpty || !dirty.sourceTitles.isEmpty else { return }
        let sources = try allSources()
        let merges = configuration.mergesAcrossFolders
        var titleUnits = Set<Int64>()
        var sourceTitleUnits = Set<GroupingSourceTitle>()
        var unfolderedUnits = Set<GroupingSourceTitle>()
        var folderUnits = Set<GroupingScopeSeed>()
        for unit in dirty.sourceTitles {
            if merges { titleUnits.insert(unit.titleHash) } else { sourceTitleUnits.insert(unit) }
        }
        for (seed, mayBeInServerAlbum) in dirty.scopeSeeds {
            if merges {
                titleUnits.insert(seed.titleHash)
                continue
            }
            let unit = GroupingSourceTitle(sourceKey: seed.sourceKey, titleHash: seed.titleHash)
            guard !sourceTitleUnits.contains(unit) else { continue }
            let authoritative = sources[seed.sourceKey]?.hasDirectoryAuthority ?? false
            if authoritative, seed.directory != nil { folderUnits.insert(seed) }
            if !authoritative || seed.directory == nil || mayBeInServerAlbum { unfolderedUnits.insert(unit) }
        }

        func isFoldered(_ row: LibraryCatalogSongCodec.GroupingFields) -> Bool {
            guard let source = sources[row.sourceKey] else { return false }
            return row.isOutsideServerAlbum && source.hasDirectoryAuthority
                && Self.directory(of: row, source: source) != nil
        }

        var rows: [LibraryCatalogSongCodec.GroupingFields] = []
        var seen = Set<Int64>()
        for titleHash in titleUnits {
            for row in try fetchGroupingRows(where: "s.titleHash = ?", arguments: [titleHash])
            where seen.insert(row.rowid).inserted {
                rows.append(row)
            }
        }
        for unit in sourceTitleUnits {
            for row in try fetchGroupingRows(where: "s.titleHash = ? AND s.sourceKey = ?", arguments: [unit.titleHash, unit.sourceKey])
            where seen.insert(row.rowid).inserted {
                rows.append(row)
            }
        }
        for unit in unfolderedUnits where !sourceTitleUnits.contains(unit) {
            for row in try fetchGroupingRows(where: "s.titleHash = ? AND s.sourceKey = ?", arguments: [unit.titleHash, unit.sourceKey])
            where !isFoldered(row) && seen.insert(row.rowid).inserted {
                rows.append(row)
            }
        }
        for seed in folderUnits {
            guard let directory = seed.directory,
                  !sourceTitleUnits.contains(GroupingSourceTitle(sourceKey: seed.sourceKey, titleHash: seed.titleHash)) else { continue }
            let fetched: [LibraryCatalogSongCodec.GroupingFields]
            switch directory {
            case .folder(let key):
                fetched = try fetchGroupingRows(where: "s.folderKey = ? AND s.titleHash = ?", arguments: [key, seed.titleHash])
            case .parent(let parent):
                fetched = try fetchGroupingRows(
                    where: "s.sourceKey = ? AND s.inferenceDirectory = ? AND s.titleHash = ?",
                    arguments: [seed.sourceKey, parent, seed.titleHash]
                )
            }
            for row in fetched where isFoldered(row) && seen.insert(row.rowid).inserted {
                rows.append(row)
            }
        }
        guard !rows.isEmpty else { return }

        let assignments = Self.albumIdentities(for: rows, sources: sources, configuration: configuration)
        let update = try db.cachedStatement(sql: "UPDATE song SET effectiveAlbumRef = ? WHERE rowid = ?")
        for (row, identity) in zip(rows, assignments) {
            var albumKey: Int64?
            if let identity { albumKey = try self.albumKey(for: identity) }
            if let albumKey { dirty.albums.insert(albumKey) }
            guard row.effectiveAlbumRef != albumKey else { continue }
            try update.execute(arguments: [albumKey, row.rowid])
            work.rowsWritten += 1
            if let old = row.effectiveAlbumRef { dirty.albums.insert(old) }
        }
    }

    /// 一组完整推断范围里的行(范围内按库内顺序)的专辑身份。纯函数,可以多核分片跑(片按范围切)。
    static func albumIdentities(
        for rows: [LibraryCatalogSongCodec.GroupingFields],
        sources: [Int64: SourceInfo],
        configuration: LibraryGroupingConfiguration
    ) -> [AlbumGroupingIdentity?] {
        let authoritative = Set(sources.values.filter(\.hasDirectoryAuthority).map(\.id))
        let tracks = rows.map { row in
            row.track(sourceID: sources[row.sourceKey]?.id ?? "", directory: directory(of: row, source: sources[row.sourceKey]))
        }
        let inferred = AlbumArtistInferencePolicy.inferredAlbumArtists(
            for: tracks, directoryAuthoritativeSourceIDs: authoritative, configuration: configuration.artistNames
        )
        return rows.map { row in
            AlbumGroupingPolicy.identity(
                albumTitle: row.albumTitle,
                albumArtistName: inferred[String(row.rowid)] ?? row.albumArtistName,
                trackArtistName: row.artistName,
                unknownArtistName: configuration.unknownArtist
            )
        }
    }

    static func directory(of row: LibraryCatalogSongCodec.GroupingFields, source: SourceInfo?) -> String? {
        guard let source else { return nil }
        return GroupingDirectory(
            usesFolderParents: source.usesFolderParents, folderKey: row.folderKey, inferenceDirectory: row.inferenceDirectory
        )?.text
    }

    func allSources() throws -> [Int64: SourceInfo] {
        var sources: [Int64: SourceInfo] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT key, id, usesFolderParents, hasDirectoryAuthority FROM source") {
            sources[row[0]] = SourceInfo(id: row[1], usesFolderParents: (row[2] as Int) != 0, hasDirectoryAuthority: (row[3] as Int) != 0)
        }
        return sources
    }

    mutating func fetchGroupingRows(where condition: String, arguments: StatementArguments) throws -> [LibraryCatalogSongCodec.GroupingFields] {
        let rows = try Row.fetchAll(
            db.cachedStatement(sql: """
                SELECT \(LibraryCatalogSongCodec.groupingColumns) FROM song s WHERE \(condition) ORDER BY s.rowid
                """),
            arguments: arguments
        )
        work.rowsRead += rows.count
        return try rows.map(LibraryCatalogSongCodec.decodeGroupingFields)
    }

    // MARK: - Albums

    /// 专辑身份 → 专辑键。新的专辑先插一行身份(标题、艺人、署名),聚合随后由 `refreshAlbum` 填。
    mutating func albumKey(for identity: AlbumGroupingIdentity) throws -> Int64 {
        let albumID = LibraryGroupingReference.hashID("\(identity.artistName):\(identity.albumTitle)")
        if let key = refs.albumKey(id: albumID) { return key }
        if let key = try Int64.fetchOne(db.cachedStatement(sql: "SELECT key FROM album WHERE id = ?"), arguments: [albumID]) {
            refs.remember(albumKey: key, id: albumID)
            return key
        }
        let artistID = LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey(identity.artistName))
        let artistRef = try refs.artistRef(artistID, in: db)
        try db.cachedStatement(sql: """
            INSERT INTO album (id, title, titleKey, artistRef, artistID, artistName, artistKey) VALUES (?, ?, ?, ?, ?, ?, ?)
            """).execute(arguments: [
                albumID, identity.albumTitle,
                LibraryCatalogDerivedFields.keyData(LibraryCollationPolicy.key(for: identity.albumTitle)),
                artistRef, artistID, identity.artistName,
                LibraryCatalogDerivedFields.keyData(LibraryCollationPolicy.key(for: identity.artistName)),
            ])
        let key = db.lastInsertedRowID
        let album = Album(id: albumID, title: identity.albumTitle, artistID: artistID, artistName: identity.artistName)
        let insertCredit = try db.cachedStatement(sql: """
            INSERT INTO albumArtistCredit (albumKey, ordinal, artistRef, name) VALUES (?, ?, ?, ?)
            """)
        for (ordinal, credit) in Self.parsedCredits(for: album, configuration: configuration.artistNames).enumerated() {
            try insertCredit.execute(arguments: [key, ordinal, try refs.artistRef(credit.id, in: db), credit.name])
        }
        refs.remember(albumKey: key, id: albumID)
        work.rowsWritten += 1
        return key
    }

    /// `AlbumArtistIndexBuilder` 里专辑艺人不是可见曲目艺人时的那一支(优先用原生多值,否则按名字拆)。
    /// 是可见曲目艺人时只用专辑自己的艺人 id,那一支在查询时判断。
    static func parsedCredits(for album: Album, configuration: ArtistNameConfiguration) -> [(id: String, name: String?)] {
        guard let originalID = album.artistID, !originalID.isEmpty else { return [] }
        let native = AlbumArtistCreditPolicy.distinctNormalizedNames(album.sourceArtistNames)
        if native.count > 1 {
            return native.map { (LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey($0)), $0) }
        }
        let names = ArtistNameParser.names(rawName: album.artistName, configuration: configuration.normalized())
        if names.isEmpty { return [(originalID, nil)] }
        if names.count == 1,
           ArtistIdentityPolicy.groupingKey(names[0]) == ArtistIdentityPolicy.groupingKey(album.artistName ?? "") {
            return [(originalID, names[0])]
        }
        return names.map { (LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey($0)), $0) }
    }

    mutating func replaceAlbumArtistCredits(albumKey: Int64, album: Album) throws {
        try db.cachedStatement(sql: "DELETE FROM albumArtistCredit WHERE albumKey = ?").execute(arguments: [albumKey])
        let insertCredit = try db.cachedStatement(sql: """
            INSERT INTO albumArtistCredit (albumKey, ordinal, artistRef, name) VALUES (?, ?, ?, ?)
            """)
        let credits = Self.parsedCredits(for: album, configuration: configuration.artistNames)
        for (ordinal, credit) in credits.enumerated() {
            try insertCredit.execute(arguments: [albumKey, ordinal, try refs.artistRef(credit.id, in: db), credit.name])
        }
        work.rowsWritten += 1 + credits.count
    }

    static func encodeSourceArtistNames(_ names: [String]?) -> String? {
        guard let names, names.count > 1,
              let data = try? JSONEncoder().encode(names),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    static func decodeSourceArtistNames(_ raw: String?) -> [String]? {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data),
              names.count > 1 else { return nil }
        return names
    }

    mutating func refreshDirtyAlbums() throws {
        guard !dirty.albums.isEmpty else { return }
        for key in dirty.albums.sorted() { try refreshAlbum(key: key) }
    }

    /// 从专辑自己的歌(专辑键索引,按库内顺序)重算它的行与按源统计;没有歌了就删掉。
    /// 「署名里有专辑艺人」变了,专辑艺人的专辑数跟着变。
    mutating func refreshAlbum(key: Int64) throws {
        guard let album = try Row.fetchOne(
            db.cachedStatement(sql: """
                SELECT artistRef, ownerCredited, id, title, artistID, artistName, sourceArtistNames FROM album WHERE key = ?
                """), arguments: [key]
        ) else { return }
        let artistRef: Int64 = album[0]
        let wasCredited = (album[1] as Int) != 0
        let albumID: String = album[2]
        let albumTitle: String = album[3]
        let albumArtistID: String = album[4]
        let albumArtistName: String = album[5]
        let previousSourceArtists = Self.decodeSourceArtistNames(album[6])
        let rows = try Row.fetchAll(db.cachedStatement(sql: """
            SELECT s.rowid, s.year, s.sourceKey, s.kind, s.durationKey, s.dateAdded,
                   EXISTS (SELECT 1 FROM songArtist sa WHERE sa.songRowid = s.rowid AND sa.artistRef = ?),
                   s.albumArtistName, s.extra
            FROM song s WHERE s.effectiveAlbumRef = ? ORDER BY s.rowid
            """), arguments: [artistRef, key])
        work.rowsRead += rows.count
        try db.cachedStatement(sql: "DELETE FROM albumSourceStat WHERE albumKey = ?").execute(arguments: [key])
        var members: [AlbumMember] = []
        members.reserveCapacity(rows.count)
        for row in rows {
            let albumArtistFields = try LibraryCatalogSongCodec.decodeAlbumArtistFields(
                albumArtistColumn: row[7],
                extraBlob: row.dataNoCopy(atIndex: 8)
            )
            let validatedSourceArtists = AlbumArtistCreditPolicy.validatedSourceArtistNames(
                songAlbumArtistName: albumArtistFields.albumArtistName,
                candidate: albumArtistFields.sourceAlbumArtistNames,
                effectiveAlbumArtistName: albumArtistName
            )
            members.append(AlbumMember(
                rowid: row[0], year: row[1], sourceKey: row[2], kind: row[3], duration: row[4],
                dateAdded: row[5], credited: row[6], sourceAlbumArtistNames: validatedSourceArtists,
                releaseFlags: releaseFlags(releaseType: albumArtistFields.releaseType)
            ))
        }
        guard let aggregate = AlbumAggregate(members: members) else {
            try db.cachedStatement(sql: "DELETE FROM album WHERE key = ?").execute(arguments: [key])
            try db.cachedStatement(sql: "DELETE FROM albumArtistCredit WHERE albumKey = ?").execute(arguments: [key])
            work.rowsWritten += 1
            refs.forgetAlbums()
            if wasCredited { dirty.artists.insert(artistRef) }
            return
        }
        guard let firstRow = try Row.fetchOne(
            db.cachedStatement(sql: "SELECT \(LibraryCatalogSongCodec.groupingColumns) FROM song s WHERE s.rowid = ?"),
            arguments: [aggregate.firstRowid]
        ) else { throw LibraryCatalogError.corruptRow }
        let first = try LibraryCatalogSongCodec.decodeGroupingFields(firstRow)
        let sourceID = try sourceInfo(first.sourceKey).id
        try writeAlbumAggregate(key: key, aggregate: aggregate, genre: first.genre, sourceID: sourceID, title: albumTitle)
        if aggregate.sourceArtistNames != previousSourceArtists {
            let updatedAlbum = Album(
                id: albumID,
                title: albumTitle,
                artistID: albumArtistID,
                artistName: albumArtistName,
                sourceArtistNames: aggregate.sourceArtistNames
            )
            try replaceAlbumArtistCredits(albumKey: key, album: updatedAlbum)
        }
        if aggregate.ownerCredited != wasCredited { dirty.artists.insert(artistRef) }
    }

    /// 只补一张专辑的发行类别(升级后补算,`backfillReleaseCategories`):各源、各类里各首标签认出的类别,与标题
    /// 那一条。与 `refreshAlbum` 写的同一份值,不碰别的聚合列。
    mutating func refreshReleaseCategories(albumKey key: Int64, title: String) throws {
        var flagsByStat: [AlbumAggregate.StatKey: AlbumReleaseCategoryRule.Flags] = [:]
        let rows = try Row.fetchAll(
            db.cachedStatement(sql: "SELECT sourceKey, kind, extra FROM song WHERE effectiveAlbumRef = ?"), arguments: [key]
        )
        work.rowsRead += rows.count
        for row in rows {
            let releaseType = try LibraryCatalogSongCodec.decodeReleaseType(extraBlob: row.dataNoCopy(atIndex: 2))
            let statKey = AlbumAggregate.StatKey(sourceKey: row[0], kind: row[1])
            flagsByStat[statKey, default: []].formUnion(releaseFlags(releaseType: releaseType))
        }
        let update = try db.cachedStatement(sql: """
            UPDATE albumSourceStat SET releaseFlags = ? WHERE albumKey = ? AND sourceKey = ? AND kind = ?
            """)
        for (statKey, flags) in flagsByStat where !flags.isEmpty {
            try update.execute(arguments: [flags.rawValue, key, statKey.sourceKey, statKey.kind])
        }
        try db.cachedStatement(sql: "UPDATE album SET releaseTitleFlags = ? WHERE key = ?")
            .execute(arguments: [AlbumReleaseCategoryRule.titleFlags(title).rawValue, key])
        work.rowsWritten += 1 + flagsByStat.count
    }

    /// 专辑行的聚合列与按源、按类别的统计(调用方已清掉旧统计)。`title`:专辑标题,发行类别的标题那一条按它算
    /// (`album.releaseTitleFlags`;各源统计里记标签认出的类别 `releaseFlags`)。
    mutating func writeAlbumAggregate(
        key: Int64, aggregate: AlbumAggregate, genre: String?, sourceID: String, title: String
    ) throws {
        try db.cachedStatement(sql: """
            UPDATE album SET year = ?, genre = ?, sourceID = ?, firstRowid = ?, songCount = ?, duration = ?,
                             ownerCredited = ?, sourceArtistNames = ?, releaseTitleFlags = ? WHERE key = ?
            """).execute(arguments: [
                aggregate.year, genre, sourceID, aggregate.firstRowid, aggregate.songCount, aggregate.duration,
                aggregate.ownerCredited ? 1 : 0, Self.encodeSourceArtistNames(aggregate.sourceArtistNames),
                AlbumReleaseCategoryRule.titleFlags(title).rawValue, key,
            ])
        let insert = try db.cachedStatement(sql: """
            INSERT INTO albumSourceStat (albumKey, sourceKey, kind, songCount, duration, maxDateAdded, releaseFlags)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        for (statKey, stat) in aggregate.stats {
            try insert.execute(arguments: [
                key, statKey.sourceKey, statKey.kind, stat.count, stat.duration, stat.maxDateAdded, stat.releaseFlags.rawValue,
            ])
        }
        work.rowsWritten += 1 + aggregate.stats.count
    }

    // MARK: - Artists

    mutating func refreshDirtyArtists() throws {
        var keys = dirty.artists
        keys.formUnion(dirty.artistDeltas.keys)
        guard !keys.isEmpty else { return }
        for ref in keys.sorted() { try refreshArtist(ref: ref, delta: dirty.artistDeltas[ref] ?? 0) }
    }

    /// 一个艺人:歌曲数 = 原值 + 增量;名字取首次署名(库内顺序、署名次序)的那个写法;专辑数数
    /// 「专辑艺人是它且署名里有它」的专辑;缩略图从带艺人图的署名里按顺序找第一个合格的。
    /// 都是带索引的查询,与艺人的歌曲数无关。
    mutating func refreshArtist(ref: Int64, delta: Int) throws {
        let existing = try Int.fetchOne(db.cachedStatement(sql: "SELECT songCount FROM artist WHERE key = ?"), arguments: [ref])
        let count = (existing ?? 0) + delta
        let first = count > 0
            ? try Row.fetchOne(db.cachedStatement(sql: """
                SELECT songRowid, ordinal FROM songArtist WHERE artistRef = ? ORDER BY songRowid, ordinal LIMIT 1
                """), arguments: [ref])
            : nil
        guard let first else {
            if existing != nil {
                try db.cachedStatement(sql: "DELETE FROM artist WHERE key = ?").execute(arguments: [ref])
                work.rowsWritten += 1
            }
            return
        }
        let firstRowid: Int64 = first[0]
        let firstOrdinal: Int = first[1]
        let name = try creditName(songRowid: firstRowid, ordinal: firstOrdinal)
        let albumCount = try Int.fetchOne(
            db.cachedStatement(sql: "SELECT count(*) FROM album WHERE artistRef = ? AND ownerCredited = 1"), arguments: [ref]
        ) ?? 0
        let thumbnail = try thumbnailPath(artistRef: ref, name: name)
        try upsertArtist(ref: ref, name: name, firstRowid: firstRowid, firstOrdinal: firstOrdinal,
                         songCount: count, albumCount: albumCount, thumbnailPath: thumbnail)
    }

    mutating func upsertArtist(
        ref: Int64, name: String, firstRowid: Int64, firstOrdinal: Int, songCount: Int, albumCount: Int, thumbnailPath: String?
    ) throws {
        guard let id = try String.fetchOne(db.cachedStatement(sql: "SELECT id FROM artistRef WHERE ref = ?"), arguments: [ref]) else {
            throw LibraryCatalogError.corruptRow
        }
        try db.cachedStatement(sql: """
            INSERT INTO artist (key, id, name, nameKey, firstRowid, firstOrdinal, songCount, albumCount, thumbnailPath)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET id = excluded.id, name = excluded.name, nameKey = excluded.nameKey,
                firstRowid = excluded.firstRowid, firstOrdinal = excluded.firstOrdinal, songCount = excluded.songCount,
                albumCount = excluded.albumCount, thumbnailPath = excluded.thumbnailPath
            """).execute(arguments: [
                ref, id, name, LibraryCatalogDerivedFields.keyData(LibraryCollationPolicy.key(for: name)),
                firstRowid, firstOrdinal, songCount, albumCount, thumbnailPath,
            ])
        work.rowsWritten += 1
    }

    mutating func decodeSong(rowid: Int64) throws -> Song {
        guard let row = try Row.fetchOne(
            db.cachedStatement(sql: """
                SELECT \(LibraryCatalogSongCodec.selectColumns) \(LibraryCatalogSongCodec.selectFrom) WHERE song.rowid = ?
                """),
            arguments: [rowid]
        ) else { throw LibraryCatalogError.corruptRow }
        work.rowsRead += 1
        return try LibraryCatalogSongCodec.decode(row)
    }

    /// 一行署名的写法:按当前配置重新解析那首歌的艺人名,取第 `ordinal` 个(署名行就是这样写进去的)。
    mutating func creditName(songRowid: Int64, ordinal: Int) throws -> String {
        let song = try decodeSong(rowid: songRowid)
        let names = LibraryGroupingReference.resolvedArtistNames(
            for: song, configuration: configuration.artistNames, unknownArtist: configuration.unknownArtist
        )
        guard names.indices.contains(ordinal) else { throw LibraryCatalogError.corruptRow }
        return names[ordinal]
    }

    /// 参照实现的缩略图规则:按(库内顺序、署名次序)看每一条署名,第一首满足其一的歌给出缩略图——
    /// 它的自动艺人图里有这个艺人名,或者它的第一个署名就是这个艺人。只有带艺人图的歌可能满足,
    /// 只扫这些(部分索引 `songArtist_artwork`)。同一首歌的后几条署名结果相同,跳过。
    mutating func thumbnailPath(artistRef: Int64, name: String) throws -> String? {
        let entries = try Row.fetchAll(db.cachedStatement(sql: """
            SELECT songRowid, ordinal FROM songArtist WHERE artistRef = ? AND artwork = 1 ORDER BY songRowid, ordinal
            """), arguments: [artistRef])
        var previous: Int64?
        for entry in entries {
            let songRowid: Int64 = entry[0]
            let ordinal: Int = entry[1]
            guard songRowid != previous else { continue }
            previous = songRowid
            let song = try decodeSong(rowid: songRowid)
            if let automatic = AutomaticArtistArtworkReference.resolve(song.artistArtworkFileName),
               let artwork = automatic.entry(forArtistName: name) {
                return SourceOwnedArtworkReference.make(
                    sourceID: song.sourceID, reference: artwork.reference, cacheDiscriminator: artwork.cacheDiscriminator
                )
            }
            if ordinal == 0, let reference = song.artistArtworkFileName {
                return SourceOwnedArtworkReference.make(sourceID: song.sourceID, reference: reference)
            }
        }
        return nil
    }

    /// 整库:按艺人键顺序扫一遍署名行(覆盖索引),逐个艺人写行。只占一个艺人的状态。
    mutating func rebuildAllArtists() throws {
        try db.execute(sql: "DELETE FROM artist")
        var albumCounts: [Int64: Int] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT artistRef, count(*) FROM album WHERE ownerCredited = 1 GROUP BY artistRef") {
            albumCounts[row[0]] = row[1]
        }
        let withArtwork = Set(try Int64.fetchAll(db, sql: "SELECT DISTINCT artistRef FROM songArtist WHERE artwork = 1"))
        var current: (ref: Int64, firstRowid: Int64, firstOrdinal: Int, count: Int)?
        func finish(_ entry: (ref: Int64, firstRowid: Int64, firstOrdinal: Int, count: Int), _ maintenance: inout GroupingMaintenance) throws {
            let name = try maintenance.creditName(songRowid: entry.firstRowid, ordinal: entry.firstOrdinal)
            let thumbnail = withArtwork.contains(entry.ref) ? try maintenance.thumbnailPath(artistRef: entry.ref, name: name) : nil
            try maintenance.upsertArtist(
                ref: entry.ref, name: name, firstRowid: entry.firstRowid, firstOrdinal: entry.firstOrdinal,
                songCount: entry.count, albumCount: albumCounts[entry.ref] ?? 0, thumbnailPath: thumbnail
            )
        }
        let cursor = try Row.fetchCursor(db, sql: "SELECT artistRef, songRowid, ordinal FROM songArtist ORDER BY artistRef, songRowid, ordinal")
        while let row = try cursor.next() {
            let ref: Int64 = row[0]
            if let entry = current, entry.ref == ref {
                current!.count += 1
                continue
            }
            if let entry = current { try finish(entry, &self) }
            current = (ref, row[1], row[2], 1)
        }
        if let entry = current { try finish(entry, &self) }
    }

    // MARK: - Per-source artist stats

    mutating func applyLookupDeltas() throws {
        guard !dirty.lookupDeltas.isEmpty else { return }
        let upsert = try db.cachedStatement(sql: """
            INSERT INTO artistSourceStat (artistRef, sourceKey, kind, songCount) VALUES (?, ?, ?, ?)
            ON CONFLICT(artistRef, sourceKey, kind) DO UPDATE SET songCount = songCount + excluded.songCount
            """)
        let prune = try db.cachedStatement(sql: """
            DELETE FROM artistSourceStat WHERE artistRef = ? AND sourceKey = ? AND kind = ? AND songCount <= 0
            """)
        for (key, delta) in dirty.lookupDeltas where delta != 0 {
            try upsert.execute(arguments: [key.artistRef, key.sourceKey, key.kind, delta])
            try prune.execute(arguments: [key.artistRef, key.sourceKey, key.kind])
            work.rowsWritten += 1
        }
    }

    /// 整库重建:一条语句重算全部按源、按类别的艺人统计。
    func rebuildAllArtistStats() throws {
        try db.execute(sql: """
            DELETE FROM artistSourceStat;
            INSERT INTO artistSourceStat (artistRef, sourceKey, kind, songCount)
            SELECT l.artistRef, s.sourceKey, s.kind, count(*) FROM songArtistLookup l
            JOIN song s ON s.rowid = l.songRowid GROUP BY l.artistRef, s.sourceKey, s.kind;
            """)
    }
}
