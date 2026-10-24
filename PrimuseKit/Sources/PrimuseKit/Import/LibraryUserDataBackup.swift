import Foundation

/// 评分、评论、「我喜欢」和自建歌单的备份文件（看板 PRIM-38）。和音乐源的索引无关：
/// 每首歌按标题、歌手、专辑、时长记身份，重建曲库、换设备之后照样认得回来。
///
/// 只收用户亲手留下的标记。镜像歌单、文件夹歌单、规则歌单跟着来源或规则走，不进备份。
public struct LibraryUserDataBackup: Codable, Sendable, Equatable {
    public static let formatIdentifier = "primuse-library-backup"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var exportedAt: Date
    /// 文件里出现的每首歌只记一次，别处用 `key` 引用。
    public var tracks: [Track]
    public var ratings: [Rating]
    /// 「我喜欢」，按列表里的顺序。
    public var liked: [String]
    public var playlists: [PlaylistRecord]

    public struct Track: Codable, Sendable, Hashable {
        public var key: String
        /// 导出那台设备上的 `Song.id`；歌单里置灰的占位没有。同一台设备上恢复时先认它。
        public var songID: String?
        public var title: String
        public var artists: [String]
        public var album: String?
        /// 秒。
        public var duration: Double?
        public var trackNumber: Int?
        public var discNumber: Int?
        public var fileName: String?
        public var fileSize: Int64?
        /// 只给人看：导出时这首在哪个音乐源。
        public var sourceName: String?

        public init(
            key: String,
            songID: String? = nil,
            title: String,
            artists: [String],
            album: String? = nil,
            duration: Double? = nil,
            trackNumber: Int? = nil,
            discNumber: Int? = nil,
            fileName: String? = nil,
            fileSize: Int64? = nil,
            sourceName: String? = nil
        ) {
            self.key = key
            self.songID = songID
            self.title = title
            self.artists = artists
            self.album = album
            self.duration = duration
            self.trackNumber = trackNumber
            self.discNumber = discNumber
            self.fileName = fileName
            self.fileSize = fileSize
            self.sourceName = sourceName
        }

        public var matchSubject: ExternalTrackMatchPolicy.Subject {
            .init(title: title, artists: artists, duration: duration)
        }

        /// 认领时和换了 id 的歌用同一套规则（`CarriedSongMarksPolicy.select`）。
        public func carriedMarks(
            rating: Int? = nil,
            comment: String? = nil,
            liked: Bool = false,
            createdAt: Date = Date()
        ) -> CarriedSongMarks {
            CarriedSongMarks(
                id: songID ?? "backup:\(key)",
                title: title,
                artists: artists,
                album: album,
                duration: duration,
                fileSize: fileSize,
                fileName: fileName,
                rating: rating,
                comment: comment,
                liked: liked,
                origin: .backup,
                createdAt: createdAt
            )
        }
    }

    public struct Rating: Codable, Sendable, Hashable {
        public var track: String
        /// 1…5；nil 表示只有评论。
        public var rating: Int?
        public var comment: String?
        public var ratedAt: Date?

        public init(track: String, rating: Int?, comment: String? = nil, ratedAt: Date? = nil) {
            self.track = track
            self.rating = rating
            self.comment = comment
            self.ratedAt = ratedAt
        }
    }

    public struct PlaylistRecord: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var createdAt: Date?
        public var updatedAt: Date?
        /// 成员的 `Track.key`，按歌单顺序。
        public var tracks: [String]

        public init(id: String, name: String, createdAt: Date? = nil, updatedAt: Date? = nil, tracks: [String]) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.tracks = tracks
        }
    }

    public init(
        exportedAt: Date = Date(),
        tracks: [Track],
        ratings: [Rating],
        liked: [String],
        playlists: [PlaylistRecord]
    ) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.tracks = tracks
        self.ratings = ratings
        self.liked = liked
        self.playlists = playlists
    }

    public var isEmpty: Bool {
        ratings.isEmpty && liked.isEmpty && playlists.isEmpty
    }

    public enum DecodeError: Error, Equatable, Sendable {
        /// 不是 Primuse 的资料库备份（可能是单个歌单的导出文件）。
        case notABackup
        /// 新版本 App 写的，这个版本读不懂。
        case newerVersion(Int)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// 读文件。引用了不存在的曲目的评分、喜欢和歌单成员直接丢掉，评分超出 1…5 的当作没评分。
    public static func decode(_ data: Data) throws -> LibraryUserDataBackup {
        struct Header: Decodable {
            var format: String?
            var version: Int?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data),
              header.format == formatIdentifier else { throw DecodeError.notABackup }
        if let version = header.version, version > currentVersion {
            throw DecodeError.newerVersion(version)
        }
        var backup = try decoder.decode(LibraryUserDataBackup.self, from: data)
        var seen = Set<String>()
        backup.tracks = backup.tracks.filter {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.key).inserted
        }
        let keys = seen
        backup.ratings = backup.ratings.compactMap { rating in
            guard keys.contains(rating.track) else { return nil }
            var cleaned = rating
            cleaned.rating = rating.rating.flatMap { (1...5).contains($0) ? $0 : nil }
            let comment = rating.comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            cleaned.comment = comment.isEmpty ? nil : comment
            return cleaned.rating == nil && cleaned.comment == nil ? nil : cleaned
        }
        var likedSeen = Set<String>()
        backup.liked = backup.liked.filter { keys.contains($0) && likedSeen.insert($0).inserted }
        backup.playlists = backup.playlists.compactMap { record in
            let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            var cleaned = record
            cleaned.name = name
            cleaned.tracks = record.tracks.filter(keys.contains)
            return cleaned
        }
        return backup
    }
}

/// 从备份恢复时，每一项落到哪里、会不会动到本机已有的标记。只算不写。
public enum LibraryUserDataRestorePolicy {
    /// 本机此刻的状态里恢复要用到的那几样。
    public struct LocalState: Sendable {
        public var ratings: [String: (rating: Int?, comment: String)]
        public var likedSongIDs: Set<String>
        /// 能往里加歌的自建歌单（不含「我喜欢」）。
        public var playlists: [(id: String, name: String)]

        public init(
            ratings: [String: (rating: Int?, comment: String)],
            likedSongIDs: Set<String>,
            playlists: [(id: String, name: String)]
        ) {
            self.ratings = ratings
            self.likedSongIDs = likedSongIDs
            self.playlists = playlists
        }
    }

    public struct ReviewWrite: Sendable, Hashable {
        public var songID: String
        public var rating: Int?
        public var comment: String
    }

    public struct Conflict: Sendable, Hashable {
        public var songID: String
        public var localRating: Int?
        public var backupRating: Int?
    }

    public enum PlaylistTarget: Sendable, Hashable {
        case existing(id: String)
        case new(name: String)
    }

    public enum Member: Sendable, Hashable {
        case song(String)
        /// 曲库里还没有：置灰留位，以后对上了原位点亮。
        case pending(LibraryUserDataBackup.Track)
    }

    public struct PlaylistWrite: Sendable, Hashable {
        public var name: String
        public var target: PlaylistTarget
        public var members: [Member]
    }

    public struct Plan: Sendable {
        /// 本机没有评分（或没有评论）的，直接补上。
        public var reviewWrites: [ReviewWrite] = []
        /// 本机已有不同的评分：默认保留本机，用户选「以备份为准」时才用备份的。
        public var conflicts: [Conflict] = []
        /// 选「以备份为准」时要写的那几条（和 `conflicts` 一一对应）。
        public var conflictWrites: [ReviewWrite] = []
        public var unchangedRatingCount = 0
        public var likedToAdd: [String] = []
        public var alreadyLikedCount = 0
        public var playlistWrites: [PlaylistWrite] = []
        /// 曲库里还没有的歌，评分、喜欢先记着，扫到了再补（见 `CarriedSongMarks`）。
        public var waiting: [CarriedSongMarks] = []
        /// 文件里引用到、但曲库里对不上的歌有几首。
        public var unmatchedTrackCount = 0

        public var restoresRatingCount: Int { reviewWrites.count }
        /// 合并进已有歌单的那几份是不是真的会加歌, 要等写的时候按成员表比对才知道;
        /// 这里只要有歌单就算。
        public var hasChanges: Bool {
            !reviewWrites.isEmpty || !conflicts.isEmpty || !likedToAdd.isEmpty
                || !playlistWrites.isEmpty || !waiting.isEmpty
        }
    }

    /// - Parameter resolutions: `Track.key` → 本机的 `Song.id`，对不上的不在里面。
    public static func plan(
        _ backup: LibraryUserDataBackup,
        resolutions: [String: String],
        local: LocalState,
        now: Date = Date()
    ) -> Plan {
        var plan = Plan()
        let tracksByKey = Dictionary(backup.tracks.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var waitingByKey: [String: CarriedSongMarks] = [:]
        var waitingOrder: [String] = []
        func wait(_ key: String, update: (inout CarriedSongMarks) -> Void) {
            guard let track = tracksByKey[key] else { return }
            if waitingByKey[key] == nil {
                waitingByKey[key] = track.carriedMarks(createdAt: now)
                waitingOrder.append(key)
            }
            update(&waitingByKey[key]!)
        }

        var reviewed = Set<String>()
        for entry in backup.ratings {
            guard let songID = resolutions[entry.track] else {
                wait(entry.track) {
                    $0.rating = entry.rating
                    $0.comment = entry.comment
                }
                continue
            }
            // 两条备份评分落到同一首（同一首歌导出了两份）时只认第一条。
            guard reviewed.insert(songID).inserted else { continue }
            let existing = local.ratings[songID]
            let existingComment = existing?.comment ?? ""
            let backupComment = entry.comment ?? ""
            let fill = (
                rating: existing?.rating ?? entry.rating,
                comment: existingComment.isEmpty ? backupComment : existingComment
            )
            if let localRating = existing?.rating, let backupRating = entry.rating, localRating != backupRating {
                plan.conflicts.append(Conflict(songID: songID, localRating: localRating, backupRating: backupRating))
                plan.conflictWrites.append(ReviewWrite(
                    songID: songID,
                    rating: backupRating,
                    comment: backupComment.isEmpty ? existingComment : backupComment
                ))
                if fill.comment != existingComment {
                    plan.reviewWrites.append(ReviewWrite(songID: songID, rating: localRating, comment: fill.comment))
                }
                continue
            }
            if fill.rating == existing?.rating, fill.comment == existingComment {
                plan.unchangedRatingCount += 1
            } else {
                plan.reviewWrites.append(ReviewWrite(songID: songID, rating: fill.rating, comment: fill.comment))
            }
        }

        var likedSeen = Set<String>()
        for key in backup.liked {
            guard let songID = resolutions[key] else {
                wait(key) { $0.liked = true }
                continue
            }
            guard likedSeen.insert(songID).inserted else { continue }
            if local.likedSongIDs.contains(songID) {
                plan.alreadyLikedCount += 1
            } else {
                plan.likedToAdd.append(songID)
            }
        }

        let localByID = Dictionary(local.playlists.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var localByName: [String: String] = [:]
        for playlist in local.playlists {
            let key = normalizedName(playlist.name)
            if localByName[key] == nil { localByName[key] = playlist.id }
        }
        var claimedTargets = Set<String>()
        for record in backup.playlists {
            let target: PlaylistTarget
            if localByID[record.id] != nil, !claimedTargets.contains(record.id) {
                target = .existing(id: record.id)
                claimedTargets.insert(record.id)
            } else if let id = localByName[normalizedName(record.name)], !claimedTargets.contains(id) {
                target = .existing(id: id)
                claimedTargets.insert(id)
            } else {
                target = .new(name: record.name)
            }
            var members: [Member] = []
            var seen = Set<String>()
            for key in record.tracks {
                guard seen.insert(key).inserted, let track = tracksByKey[key] else { continue }
                if let songID = resolutions[key] {
                    members.append(.song(songID))
                } else {
                    members.append(.pending(track))
                }
            }
            plan.playlistWrites.append(PlaylistWrite(name: record.name, target: target, members: members))
        }

        plan.waiting = waitingOrder.compactMap { waitingByKey[$0] }.filter(\.hasMarks)
        var referenced = Set(backup.ratings.map(\.track))
        referenced.formUnion(backup.liked)
        for record in backup.playlists { referenced.formUnion(record.tracks) }
        plan.unmatchedTrackCount = referenced.filter { tracksByKey[$0] != nil && resolutions[$0] == nil }.count
        return plan
    }

    /// 和导入歌单时认同名歌单(`PlaylistImportMergePolicy.isSameName`)同一套: 忽略首尾空白、
    /// 大小写、变音符与全半角。
    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
