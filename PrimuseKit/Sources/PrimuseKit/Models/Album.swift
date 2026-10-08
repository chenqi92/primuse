import Foundation
import GRDB

public struct Album: Codable, Identifiable, Hashable, Sendable {
    public var id: String // SHA256 of album artist name + album title
    public var title: String
    public var artistID: String?
    public var artistName: String?
    public var year: Int?
    public var genre: String?
    public var coverArtPath: String?
    public var songCount: Int
    public var totalDuration: TimeInterval
    public var sourceID: String?

    public init(
        id: String,
        title: String,
        artistID: String? = nil,
        artistName: String? = nil,
        year: Int? = nil,
        genre: String? = nil,
        coverArtPath: String? = nil,
        songCount: Int = 0,
        totalDuration: TimeInterval = 0,
        sourceID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artistID = artistID
        self.artistName = artistName
        self.year = year
        self.genre = genre
        self.coverArtPath = coverArtPath
        self.songCount = songCount
        self.totalDuration = totalDuration
        self.sourceID = sourceID
    }
}

extension Album: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "albums" }
}

/// Album presentation and playback must consume the same track order.
public enum AlbumTrackOrder {
    /// A missing or non-positive disc tag denotes the first disc.
    public static func discNumber(for song: Song) -> Int {
        max(1, song.discNumber ?? 1)
    }

    public static func sorted(_ songs: [Song]) -> [Song] {
        guard songs.count > 1 else { return songs }
        // Resolve each song's position once; a folder of untagged files
        // would otherwise re-parse both file names on every comparison.
        let keys = songs.map { (disc: discNumber(for: $0), track: trackNumber(for: $0) ?? Int.max) }
        return songs.indices.sorted { lhs, rhs in
            if keys[lhs].disc != keys[rhs].disc { return keys[lhs].disc < keys[rhs].disc }
            if keys[lhs].track != keys[rhs].track { return keys[lhs].track < keys[rhs].track }
            return isOrderedByTitle(songs[lhs], songs[rhs])
        }.map { songs[$0] }
    }

    /// `sorted(_:)` of `songs[offsets]`, as song IDs, without copying the
    /// songs out first: a folder index orders every directory of the library.
    public static func sortedIDs(at offsets: [Int], in songs: [Song]) -> [String] {
        guard offsets.count > 1 else { return offsets.map { songs[$0].id } }
        let keys = offsets.map { (disc: discNumber(for: songs[$0]), track: trackNumber(for: songs[$0]) ?? Int.max) }
        return offsets.indices.sorted { lhs, rhs in
            if keys[lhs].disc != keys[rhs].disc { return keys[lhs].disc < keys[rhs].disc }
            if keys[lhs].track != keys[rhs].track { return keys[lhs].track < keys[rhs].track }
            return isOrderedByTitle(songs[offsets[lhs]], songs[offsets[rhs]])
        }.map { songs[offsets[$0]].id }
    }

    /// Disc, then track, then title. Any list that groups songs by album
    /// (e.g. sorting a folder by album) must order within the group this way.
    public static func isOrderedBefore(_ lhs: Song, _ rhs: Song) -> Bool {
        let leftDisc = discNumber(for: lhs)
        let rightDisc = discNumber(for: rhs)
        if leftDisc != rightDisc { return leftDisc < rightDisc }

        let leftTrack = trackNumber(for: lhs) ?? Int.max
        let rightTrack = trackNumber(for: rhs) ?? Int.max
        if leftTrack != rightTrack { return leftTrack < rightTrack }
        return isOrderedByTitle(lhs, rhs)
    }

    private static func isOrderedByTitle(_ lhs: Song, _ rhs: Song) -> Bool {
        // Duplicate or absent track tags must not inherit scan order.
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.id < rhs.id
    }

    /// The track tag, or the number a rip names its files with ("03 Title.flac")
    /// when the tag is missing, so an untagged album is not read A to Z.
    public static func trackNumber(for song: Song) -> Int? {
        if let number = song.trackNumber, number > 0 { return number }
        return fileNameTrackNumber(song.filePath)
    }

    /// "03 Title", "03. Title", "03-Title", "1-03 Title" (disc-track) → 3.
    /// Four digits ("1999 Title") or a word ("4ever") are not track numbers.
    static func fileNameTrackNumber(_ filePath: String) -> Int? {
        let fileName = filePath.split(separator: "/").last.map(String.init) ?? filePath
        let stem = Array(fileName.lastIndex(of: ".").map { fileName[..<$0] } ?? fileName[...])
        func digits(from start: Int) -> (value: Int, end: Int)? {
            var end = start
            while end < stem.count, end - start < 4, stem[end].isASCII, stem[end].isNumber { end += 1 }
            guard (1...3).contains(end - start), let value = Int(String(stem[start..<end])) else { return nil }
            return (value, end)
        }
        func endsNumber(at index: Int) -> Bool {
            index == stem.count || [" ", ".", "-", "_", "、", "．", ")", "]"].contains(stem[index])
        }
        guard let first = digits(from: 0), first.end == stem.count || !stem[first.end].isNumber else { return nil }
        if first.end < stem.count, stem[first.end] == "-" || stem[first.end] == ".",
           let second = digits(from: first.end + 1),
           second.end == stem.count || (!stem[second.end].isNumber && endsNumber(at: second.end)),
           second.value > 0 {
            return second.value
        }
        guard endsNumber(at: first.end), first.value > 0 else { return nil }
        return first.value
    }
}

/// A folder's songs in the order they are meant to be heard: track order,
/// unless the folder holds files renamed after tagging next to files whose
/// names and tags agree on their chapter (rule 6 of the spoken-word book
/// grouping, `SpokenWordBookGroupingRules`). Their track tags then count two
/// releases, and the file names are the one numbering the folder shares.
public enum LibraryFolderTrackOrder {
    public static func sorted(_ songs: [Song]) -> [Song] {
        guard let paths = pathsIfRenamed(songs) else { return AlbumTrackOrder.sorted(songs) }
        return songs.indices.sorted { lhs, rhs in
            isOrderedByPath(songs[lhs], paths[lhs], before: songs[rhs], paths[rhs])
        }.map { songs[$0] }
    }

    /// `sorted(_:)` of `songs[offsets]`, as song IDs, without copying the songs out.
    public static func sortedIDs(at offsets: [Int], in songs: [Song]) -> [String] {
        guard let paths = pathsIfRenamed(offsets.lazy.map { songs[$0] }) else {
            return AlbumTrackOrder.sortedIDs(at: offsets, in: songs)
        }
        return offsets.indices.sorted { lhs, rhs in
            isOrderedByPath(songs[offsets[lhs]], paths[lhs], before: songs[offsets[rhs]], paths[rhs])
        }.map { songs[offsets[$0]].id }
    }

    /// Each song's path (an item-id drive's spelled out of its scanned
    /// folders), when the folder mixes renamed files with agreeing ones.
    static func pathsIfRenamed<Songs: Collection>(_ songs: Songs) -> [String]? where Songs.Element == Song {
        // Only a title numbering its chapter (第…集) can disagree with a name.
        guard songs.count > 1, songs.contains(where: { $0.title.contains("\u{7B2C}") }) else { return nil }
        var paths: [String] = []
        paths.reserveCapacity(songs.count)
        var agrees = false
        var renamed = false
        for song in songs {
            let path = SpokenWordBookSourcePaths.groupingPath(sourceID: song.sourceID, filePath: song.filePath)
            let reading = SpokenWordBookGroupingRules.chapterReading(title: song.title, path: path)
            if reading.agrees { agrees = true }
            if reading.renamed != nil { renamed = true }
            paths.append(path)
        }
        return agrees && renamed ? paths : nil
    }

    private static func isOrderedByPath(_ lhs: Song, _ lhsPath: String, before rhs: Song, _ rhsPath: String) -> Bool {
        let byPath = lhsPath.localizedStandardCompare(rhsPath)
        if byPath != .orderedSame { return byPath == .orderedAscending }
        let byTitle = lhs.title.localizedStandardCompare(rhs.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return lhs.id < rhs.id
    }
}

public enum RecentlyAddedAlbumPolicy {
    public static func sorted(
        albums: [Album], songs: [Song], limit: Int? = nil
    ) -> [Album] {
        var latestDates: [String: Date] = [:]
        for song in songs {
            guard let albumID = song.albumID, !albumID.isEmpty else { continue }
            latestDates[albumID] = max(latestDates[albumID] ?? .distantPast, song.dateAdded)
        }
        return sorted(albums: albums, latestDates: latestDates, limit: limit)
    }

    public static func sorted(
        albums: [Album], latestDates: [String: Date], limit: Int? = nil
    ) -> [Album] {
        let ordered = albums.sorted {
            let lhs = latestDates[$0.id] ?? .distantPast
            let rhs = latestDates[$1.id] ?? .distantPast
            // Imports often give every track the same timestamp. A stable
            // tie-breaker keeps album cards from moving on metadata refresh.
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        return limit.map { Array(ordered.prefix(max(0, $0))) } ?? ordered
    }
}

public enum AlbumArtworkFallbackPolicy {
    public static func preferredSongID(
        orderedSongIDs: [String],
        songIDsWithArtworkReference: Set<String>
    ) -> String? {
        let eligibleSongIDs = orderedSongIDs.filter { !$0.isEmpty }
        return eligibleSongIDs.first(where: songIDsWithArtworkReference.contains)
            ?? eligibleSongIDs.first
    }
}

public struct LibraryArtworkOwner: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case album
        case artist
        case playlist
    }

    public static let cloudRecordIDPrefix = "__artwork_override__"

    public let kind: Kind
    public let id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    public var storageKey: String {
        "\(kind.rawValue):\(id)"
    }

    /// Artwork overrides reuse the already-deployed Playlist CloudKit record
    /// type. A reserved local-ID prefix keeps them out of the user's playlist
    /// collection while avoiding a production schema dependency on a new
    /// record type.
    public var cloudRecordID: String {
        "\(Self.cloudRecordIDPrefix):\(kind.rawValue):\(id)"
    }

    public static func fromCloudRecordID(_ value: String) -> LibraryArtworkOwner? {
        let prefix = "\(cloudRecordIDPrefix):"
        guard value.hasPrefix(prefix) else { return nil }
        let remainder = value.dropFirst(prefix.count)
        guard let separator = remainder.firstIndex(of: ":") else { return nil }
        let kindValue = String(remainder[..<separator])
        let ownerID = String(remainder[remainder.index(after: separator)...])
        guard let kind = Kind(rawValue: kindValue), !ownerID.isEmpty else { return nil }
        return LibraryArtworkOwner(kind: kind, id: ownerID)
    }
}

public enum LibraryArtworkOverrideMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case selectedSong
    case uploaded
}

/// A durable user choice layered above source-provided artwork. Image bytes
/// remain in MetadataAssetStore; this value stores only the content identity or
/// a cross-device song identity.
public struct LibraryArtworkOverride: Codable, Hashable, Identifiable, Sendable {
    public var owner: LibraryArtworkOwner
    public var mode: LibraryArtworkOverrideMode
    public var selectedSongIdentity: SongIdentity?
    public var uploadedContentID: String?
    public var updatedAt: Date
    public var syncRevision: Int64
    public var syncWriterID: String
    public var syncOperationID: String

    public var id: String { owner.storageKey }
    public var cloudRecordID: String { owner.cloudRecordID }

    public init(
        owner: LibraryArtworkOwner,
        mode: LibraryArtworkOverrideMode,
        selectedSongIdentity: SongIdentity? = nil,
        uploadedContentID: String? = nil,
        updatedAt: Date = Date(),
        syncRevision: Int64 = 0,
        syncWriterID: String = "",
        syncOperationID: String = ""
    ) {
        self.owner = owner
        self.mode = mode
        self.selectedSongIdentity = selectedSongIdentity
        self.uploadedContentID = uploadedContentID
        self.updatedAt = updatedAt
        self.syncRevision = syncRevision
        self.syncWriterID = syncWriterID
        self.syncOperationID = syncOperationID
    }
}

public enum LibraryArtworkOverrideResolution: Equatable, Sendable {
    case automatic
    case selectedSong(String)
    case uploaded(String)
}

public enum LibraryArtworkContentIDPolicy {
    public static let maximumSyncedArtworkBytes = 600_000

    public static func isValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

public enum LibraryArtworkOverridePolicy {
    public static func resolve(
        override: LibraryArtworkOverride?,
        resolveSelectedSong: () -> (songID: String, isEligible: Bool)?
    ) -> LibraryArtworkOverrideResolution {
        guard let override else { return .automatic }
        switch override.mode {
        case .automatic:
            return .automatic
        case .selectedSong:
            guard let selectedSong = resolveSelectedSong(),
                  !selectedSong.songID.isEmpty,
                  selectedSong.isEligible else {
                return .automatic
            }
            return .selectedSong(selectedSong.songID)
        case .uploaded:
            guard let contentID = override.uploadedContentID,
                  LibraryArtworkContentIDPolicy.isValid(contentID) else {
                return .automatic
            }
            return .uploaded(contentID)
        }
    }

    public static func resolve(
        override: LibraryArtworkOverride?,
        resolvedSongID: String?,
        eligibleSongIDs: Set<String>
    ) -> LibraryArtworkOverrideResolution {
        resolve(override: override) {
            guard let resolvedSongID else { return nil }
            return (
                songID: resolvedSongID,
                isEligible: eligibleSongIDs.contains(resolvedSongID)
            )
        }
    }
}

/// 自选封面指向的歌在本机换了 id（跨设备挂载、服务端改 id）时，要按身份在整库里找；
/// 这里决定上一次找的结果还能不能接着用。
///
/// `songs` 每重新赋值一次就换一代。冷启动的回填、复查每替换一批歌就换一代，以前代次一变
/// 缓存整个作废，首页每张艺人卡在 body 里各扫一遍整库（5.8 万首时一帧几百毫秒），滑动一直卡。
/// - 同一代：直接用。
/// - 换了代、上次找到过：先核对那首歌是否还在、还对得上，对得上就续用，不用整库找。
/// - 换了代、上次没找到：只在有歌进出（数量变了）或离上次整库找已超过
///   `unresolvedRecheckInterval` 时重找。回填只改元数据时不必每批都扫，
///   靠间隔兜住「补全标题后才对得上」的情况。
public enum LibraryArtworkSongResolutionCachePolicy {
    public struct Entry: Equatable, Sendable {
        public let identity: SongIdentity
        public let songID: String?
        public let generation: UInt64
        public let songCount: Int
        public let checkedAt: Date

        public init(
            identity: SongIdentity,
            songID: String?,
            generation: UInt64,
            songCount: Int,
            checkedAt: Date
        ) {
            self.identity = identity
            self.songID = songID
            self.generation = generation
            self.songCount = songCount
            self.checkedAt = checkedAt
        }

        /// 核对通过后续用：答案不变，只把代次跟上。
        public func carried(to generation: UInt64, songCount: Int) -> Entry {
            Entry(
                identity: identity,
                songID: songID,
                generation: generation,
                songCount: songCount,
                checkedAt: checkedAt
            )
        }
    }

    public enum Decision: Equatable, Sendable {
        case reuse
        /// 上次找到的这首还得核对一下；核对不过就整库重找。
        case verify(songID: String)
        case resolve
    }

    public static let unresolvedRecheckInterval: TimeInterval = 10

    public static func decision(
        cached: Entry?,
        identity: SongIdentity,
        generation: UInt64,
        songCount: Int,
        now: Date
    ) -> Decision {
        guard let cached, cached.identity == identity else { return .resolve }
        guard cached.generation != generation else { return .reuse }
        if let songID = cached.songID { return .verify(songID: songID) }
        guard cached.songCount == songCount,
              now.timeIntervalSince(cached.checkedAt) < unresolvedRecheckInterval else {
            return .resolve
        }
        return .reuse
    }

    /// 与整库匹配同一套条件：同一云账号下的同一路径，或标题相同、时长差一秒以内、
    /// 身份带了艺术家时艺术家也相同。
    public static func song(
        title: String,
        artistName: String?,
        duration: Double,
        filePath: String,
        cloudAccountID: () -> String?,
        matches identity: SongIdentity
    ) -> Bool {
        if let accountID = identity.cloudAccountID,
           !identity.filePath.isEmpty,
           filePath == identity.filePath,
           cloudAccountID() == accountID {
            return true
        }
        return !identity.title.isEmpty
            && title == identity.title
            && abs(duration - identity.duration) < 1.0
            && (identity.artistName == nil || artistName == identity.artistName)
    }
}

public enum LibraryArtworkOverrideConflictWinner: Equatable, Sendable {
    case local
    case remote
}

/// 比 `LibraryArtworkOverrideConflictWinner` 多一档 `equivalent`: 所有参与
/// 比较的字段都相等。`winner` 这时按惯例判本地胜出, 调用方如果据此回推本地
/// 值, 两台设备就会围着同一条记录来回保存。
public enum LibraryArtworkOverrideReconciliationOutcome: Equatable, Sendable {
    case localWins
    case remoteWins
    case equivalent
}

public enum LibraryArtworkOverrideReconciliationPolicy {
    public static func winner(
        local: LibraryArtworkOverride,
        remote: LibraryArtworkOverride
    ) -> LibraryArtworkOverrideConflictWinner {
        switch outcome(local: local, remote: remote) {
        case .remoteWins:
            return .remote
        case .localWins, .equivalent:
            return .local
        }
    }

    public static func outcome(
        local: LibraryArtworkOverride,
        remote: LibraryArtworkOverride
    ) -> LibraryArtworkOverrideReconciliationOutcome {
        precondition(local.owner == remote.owner)
        if local.syncRevision != remote.syncRevision {
            return local.syncRevision > remote.syncRevision ? .localWins : .remoteWins
        }
        if local.syncWriterID != remote.syncWriterID {
            return local.syncWriterID > remote.syncWriterID ? .localWins : .remoteWins
        }
        if local.syncOperationID != remote.syncOperationID {
            return local.syncOperationID > remote.syncOperationID ? .localWins : .remoteWins
        }
        if local.syncRevision == 0, local.updatedAt != remote.updatedAt {
            return local.updatedAt > remote.updatedAt ? .localWins : .remoteWins
        }
        return .equivalent
    }
}

/// Stored in the Playlist record type's existing `songIdentities` Data field.
/// Keeping uploaded data bounded lets deployed CloudKit schemas accept the
/// envelope without introducing a new field or record type.
public struct LibraryArtworkCloudEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var override: LibraryArtworkOverride
    public var uploadedArtworkData: Data?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        override: LibraryArtworkOverride,
        uploadedArtworkData: Data? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.override = override
        self.uploadedArtworkData = uploadedArtworkData
    }
}
