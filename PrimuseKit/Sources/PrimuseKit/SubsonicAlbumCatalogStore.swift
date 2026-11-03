import Foundation
import GRDB

/// Retains the provider identity after the library assigns its own album ID.
public struct ServerCatalogAlbumReference: Codable, Hashable, Sendable {
    public var id: String
    public var taggedArtist: String?

    public init(id: String, taggedArtist: String?) {
        self.id = id
        self.taggedArtist = taggedArtist
    }
}

public struct ServerCatalogAlbumMetadata: Codable, Equatable, Sendable {
    public var id: String
    public var artist: String?
    public var created: Date?
    public var libraryID: String?

    public init(id: String, artist: String?, created: Date?, libraryID: String?) {
        self.id = id
        self.artist = artist
        self.created = created
        self.libraryID = libraryID
    }
}

public struct ServerCatalogEnrichment: Sendable {
    public var albums: [String: ServerCatalogAlbumMetadata]
    public var hasOverlappingLibraries: Bool

    public init(albums: [String: ServerCatalogAlbumMetadata], hasOverlappingLibraries: Bool = false) {
        self.albums = albums
        self.hasOverlappingLibraries = hasOverlappingLibraries
    }

    public func applying(to original: Song) -> Song {
        guard let reference = original.serverCatalogAlbum,
              let album = albums[reference.id] else { return original }
        var song = original
        song.albumArtistName = AlbumGroupingPolicy.resolvedAlbumArtistName(
            albumArtistName: AlbumGroupingPolicy.serverCatalogAlbumArtistName(
                trackAlbumArtistName: reference.taggedArtist,
                serverAlbumArtistName: album.artist,
                trackArtistName: song.artistName
            ),
            trackArtistName: song.artistName
        )
        if let created = album.created { song.serverAlbumDateAdded = created }
        if !hasOverlappingLibraries, let libraryID = album.libraryID {
            song.serverLibraryID = libraryID
        }
        return song
    }
}

/// Auxiliary metadata only: this cache never proves which songs may be deleted.
public final class SubsonicAlbumCatalogStore: @unchecked Sendable {
    public struct Checkpoint: Sendable {
        public var token: String
        /// -1 marks a fully read scope. Empty scope means the unfiltered library.
        public var offsets: [String: Int]
        public var firstPageIDs: [String: [String]]
        public var albums: [String: ServerCatalogAlbumMetadata]
        public var hasOverlappingLibraries: Bool
        public init(token: String, offsets: [String: Int], firstPageIDs: [String: [String]],
                    albums: [String: ServerCatalogAlbumMetadata], hasOverlappingLibraries: Bool) {
            self.token = token
            self.offsets = offsets
            self.firstPageIDs = firstPageIDs
            self.albums = albums
            self.hasOverlappingLibraries = hasOverlappingLibraries
        }

        public var isComplete: Bool { offsets.values.allSatisfy { $0 == -1 } }
    }

    public static let shared: SubsonicAlbumCatalogStore? = {
        do {
            let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
                .appendingPathComponent("Primuse/SubsonicCatalog", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return try SubsonicAlbumCatalogStore(path: root.appendingPathComponent("albums.sqlite").path)
        } catch { return nil }
    }()

    private let database: DatabaseQueue

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.label = "Primuse Subsonic album metadata"
        database = try DatabaseQueue(path: path, configuration: configuration)
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS albumCatalogs (
                    cacheKey TEXT PRIMARY KEY, revision TEXT, token TEXT NOT NULL,
                    offsets BLOB NOT NULL, firstPageIDs BLOB NOT NULL,
                    overlapping INTEGER NOT NULL DEFAULT 0, updatedAt DOUBLE NOT NULL
                );
                CREATE TABLE IF NOT EXISTS albumCatalogPages (
                    cacheKey TEXT NOT NULL, scope TEXT NOT NULL, pageOffset INTEGER NOT NULL,
                    payload BLOB NOT NULL, PRIMARY KEY (cacheKey, scope, pageOffset)
                );
                """)
        }
    }

    public func claim(key: String, revision: String?, scopes: [String], now: Date = Date()) throws -> Checkpoint {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        return try database.write { db in
            let token = UUID().uuidString
            let row = try Row.fetchOne(db, sql: "SELECT * FROM albumCatalogs WHERE cacheKey = ?", arguments: [key])
            let oldRevision: String? = row?["revision"]
            let updatedAt: Double = row?["updatedAt"] ?? 0
            let oldOffsets = try row.map { try decoder.decode([String: Int].self, from: $0["offsets"]) }
            // A missing revision cannot authorize reuse across separate walks.
            let reusable = revision != nil && oldRevision == revision
                && Set(oldOffsets?.keys.map { $0 } ?? []) == Set(scopes)
                && now.timeIntervalSince1970 - updatedAt < 3_600
            var checkpoint = Checkpoint(token: token,
                                        offsets: Dictionary(uniqueKeysWithValues: scopes.map { ($0, 0) }),
                                        firstPageIDs: [:], albums: [:], hasOverlappingLibraries: false)
            if reusable, let row, let oldOffsets {
                checkpoint.offsets = oldOffsets
                checkpoint.firstPageIDs = try decoder.decode([String: [String]].self, from: row["firstPageIDs"])
                checkpoint.hasOverlappingLibraries = row["overlapping"]
                let pages = try Row.fetchCursor(db, sql: "SELECT payload FROM albumCatalogPages WHERE cacheKey = ? ORDER BY scope, pageOffset", arguments: [key])
                while let page = try pages.next() {
                    for album in try decoder.decode([ServerCatalogAlbumMetadata].self, from: page["payload"]) {
                        checkpoint.albums[album.id] = album
                    }
                }
            } else {
                try db.execute(sql: "DELETE FROM albumCatalogPages WHERE cacheKey = ?", arguments: [key])
            }
            try db.execute(sql: """
                INSERT OR REPLACE INTO albumCatalogs
                (cacheKey, revision, token, offsets, firstPageIDs, overlapping, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [key, revision, token, try encoder.encode(checkpoint.offsets),
                                   try encoder.encode(checkpoint.firstPageIDs), checkpoint.hasOverlappingLibraries,
                                   reusable ? updatedAt : now.timeIntervalSince1970])
            // Leave recently active writers alone; prune old cache entries only.
            let obsolete = try String.fetchAll(db, sql: """
                SELECT cacheKey FROM albumCatalogs WHERE updatedAt < ?
                ORDER BY updatedAt DESC LIMIT -1 OFFSET 8
                """, arguments: [now.timeIntervalSince1970 - 3_600])
            for obsoleteKey in obsolete {
                try db.execute(sql: "DELETE FROM albumCatalogPages WHERE cacheKey = ?", arguments: [obsoleteKey])
                try db.execute(sql: "DELETE FROM albumCatalogs WHERE cacheKey = ?", arguments: [obsoleteKey])
            }
            return checkpoint
        }
    }

    /// A newer connector may adopt the checkpoint. A late old writer then does nothing.
    public func savePage(key: String, checkpoint: Checkpoint, scope: String, offset: Int,
                         albums: [ServerCatalogAlbumMetadata], now: Date = Date()) throws {
        let encoder = JSONEncoder()
        let payload = try encoder.encode(albums)
        let offsets = try encoder.encode(checkpoint.offsets)
        let firstPageIDs = try encoder.encode(checkpoint.firstPageIDs)
        try database.write { db in
            guard try String.fetchOne(db, sql: "SELECT token FROM albumCatalogs WHERE cacheKey = ?", arguments: [key]) == checkpoint.token else { return }
            try db.execute(sql: "INSERT OR REPLACE INTO albumCatalogPages (cacheKey, scope, pageOffset, payload) VALUES (?, ?, ?, ?)",
                           arguments: [key, scope, offset, payload])
            try db.execute(sql: "UPDATE albumCatalogs SET offsets = ?, firstPageIDs = ?, overlapping = ?, updatedAt = ? WHERE cacheKey = ?",
                           arguments: [offsets, firstPageIDs, checkpoint.hasOverlappingLibraries, now.timeIntervalSince1970, key])
        }
    }

    public func invalidate(key: String, token: String) throws {
        try database.write { db in
            guard try String.fetchOne(db, sql: "SELECT token FROM albumCatalogs WHERE cacheKey = ?", arguments: [key]) == token else { return }
            try db.execute(sql: "DELETE FROM albumCatalogPages WHERE cacheKey = ?", arguments: [key])
            try db.execute(sql: "DELETE FROM albumCatalogs WHERE cacheKey = ?", arguments: [key])
        }
    }
}

/// The formatters retain the established millisecond and timezone semantics.
public final class SubsonicCatalogDateParser: @unchecked Sendable {
    public static let shared = SubsonicCatalogDateParser()
    private let lock = NSLock()
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()

    public init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain.formatOptions = [.withInternetDateTime]
    }

    public func date(from value: String) -> Date? {
        lock.withLock { fractional.date(from: value) ?? plain.date(from: value) }
    }
}
