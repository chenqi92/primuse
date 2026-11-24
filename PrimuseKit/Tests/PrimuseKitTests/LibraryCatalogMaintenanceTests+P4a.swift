import Foundation
import GRDB
import Testing
@testable import PrimuseKit

@Suite("Library catalog maintenance and offline tables")
struct LibraryCatalogMaintenanceTests {
    typealias Flags = LibraryCatalogMaintenanceFlags
    typealias Delta = LibraryCatalogMaintenanceDelta
    typealias Row = LibraryCatalogMaintenanceRow

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-maintenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func songs(_ count: Int, seed: UInt64) -> [Song] {
        var rng = CatalogTestRandom(seed: seed)
        return (0..<count).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: false).withoutAppliedPlaybackRange }
    }

    private static let allFlags: [Flags] = [
        .titleChecked, .albumArtistChecked, .albumArtistRechecked, .artistChecked, .artworkGivenUp,
        .failed, .incomplete, .sourceIssue, .deferredRetry, .albumArtistUnconfirmed, .peerLyricsPending,
        .deferredArtwork, .playbackArtwork, .sessionGivenUp, .sessionNetworkParked, .sessionStallParked,
    ]

    private static func randomFlags(_ rng: inout CatalogTestRandom) -> Flags {
        var flags: Flags = []
        for flag in allFlags where rng.chance(25) { flags.insert(flag) }
        return flags
    }

    private static func randomDelta(_ rng: inout CatalogTestRandom) -> Delta {
        let set = randomFlags(&rng)
        let clear = randomFlags(&rng)
        let retry: Int? = rng.chance(30) ? rng.int(0...6) : nil
        let note: Delta.NoteChange?
        switch rng.int(0...5) {
        case 0: note = .set(LibraryCatalogMaintenanceNote(kind: UInt8(rng.int(1...8)), detail: "reason \(rng.int(0...9))", lastAttemptAt: Double(rng.int(0...1_000))))
        case 1: note = .clear
        case 2: note = .clearIfKind(UInt16(rng.int(0...0x1FF)))
        default: note = nil
        }
        return Delta(setFlags: set, clearFlags: clear, retryCount: retry, note: note)
    }

    @Test("Composed deltas give the same row as applying them one by one")
    func deltaCompositionMatchesSequentialApplication() {
        var rng = CatalogTestRandom(seed: 4_101)
        for _ in 0..<2_000 {
            var base = Row(flags: Self.randomFlags(&rng), retryCount: rng.int(0...3))
            if rng.chance(40) { base.note = LibraryCatalogMaintenanceNote(kind: UInt8(rng.int(1...8)), detail: "base", lastAttemptAt: 7) }
            let deltas = (0..<rng.int(1...6)).map { _ in Self.randomDelta(&rng) }
            let sequential = deltas.reduce(base) { $1.applied(to: $0) }
            let composed = deltas.dropFirst().reduce(deltas[0]) { $0.then($1) }
            #expect(composed.applied(to: base) == sequential)
            #expect(Delta.replacing(with: sequential).applied(to: base) == sequential)
        }
    }

    @Test("Writes keep changed rows only, drop empty rows and read back aligned")
    func applyAndReadBack() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try LibraryCatalog(path: directory.appendingPathComponent("c.sqlite").path)
        var rng = CatalogTestRandom(seed: 4_102)
        var model: [String: Row] = [:]
        let ids = (0..<300).map { "song-\($0)" }
        for _ in 0..<40 {
            var changes: [(songID: String, delta: Delta)] = []
            for _ in 0..<rng.int(1...60) {
                let id = rng.pick(ids)
                let delta = Self.randomDelta(&rng)
                changes.append((id, delta))
                model[id] = delta.applied(to: model[id] ?? .empty)
            }
            try catalog.applyMaintenance(changes)
        }
        let rows = try catalog.maintenanceRows(songIDs: ids)
        #expect(rows == ids.map { model[$0] ?? .empty })
        let stored = try catalog.maintenanceRowCount()
        #expect(stored == model.values.filter { !$0.isEmpty }.count)

        let reader = try catalog.makeMaintenanceReader()
        #expect(try reader.rows(songIDs: ids) == rows)
        #expect(try reader.row(songID: "missing") == .empty)
    }

    @Test("Flag queries, paging, global clears and session reset")
    func flagQueriesAndClears() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try LibraryCatalog(path: directory.appendingPathComponent("c.sqlite").path)
        var changes: [(songID: String, delta: Delta)] = []
        for index in 0..<500 {
            var set: Flags = [.titleChecked, .artistChecked]
            if index % 7 == 0 { set.insert(.failed) }
            if index % 11 == 0 { set.insert(.sessionGivenUp) }
            if index % 13 == 0 { set.insert(.deferredRetry) }
            let note: Delta.NoteChange? = index % 17 == 0
                ? .set(LibraryCatalogMaintenanceNote(kind: 3, detail: "x", lastAttemptAt: 1)) : nil
            changes.append((String(format: "id-%04d", index), Delta(setFlags: set, note: note)))
        }
        try catalog.applyMaintenance(changes)
        #expect(try catalog.maintenanceCount(withAny: .failed) == (0..<500).filter { $0 % 7 == 0 }.count)
        #expect(try catalog.maintenanceCount(withAny: [.failed, .deferredRetry]) == (0..<500).filter { $0 % 7 == 0 || $0 % 13 == 0 }.count)
        #expect(try catalog.maintenanceCount(withAny: .titleChecked) == 500)
        #expect(try catalog.hasMaintenanceRows(withAny: .incomplete) == false)
        #expect(try catalog.hasMaintenanceRows(withAny: .sessionGivenUp))

        var paged: [String] = []
        var cursor: String?
        while true {
            let page = try catalog.maintenanceSongIDs(withAny: .failed, after: cursor, limit: 10)
            paged += page
            guard let last = page.last else { break }
            cursor = last
        }
        #expect(paged == (0..<500).filter { $0 % 7 == 0 }.map { String(format: "id-%04d", $0) })

        // 少数位的查询走部分索引。
        let plan = try catalog.pool.read { db in
            try GRDB.Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT songID FROM songMaintenance
                WHERE \(LibraryCatalog.maintenanceFlagsTerm(.failed)) AND songID > '' ORDER BY songID
                """).map { $0["detail"] as String }
        }
        #expect(plan.joined(separator: " ").contains("songMaintenance_rare"))

        let reader = try catalog.makeMaintenanceReader()
        #expect(try reader.count(withAny: .failed) == paged.count)
        #expect(try reader.hasRows(withAny: .failed))
        #expect(try reader.songIDs(withAny: .failed, after: paged[2], limit: 3) == Array(paged[3..<6]))

        try catalog.clearMaintenanceFlags(.failed)
        #expect(try catalog.maintenanceCount(withAny: .failed) == 0)
        #expect(try reader.hasRows(withAny: .failed) == false)
        #expect(try catalog.maintenanceCount(withAny: .titleChecked) == 500)

        #expect(try catalog.resetSessionMaintenanceFlags())
        #expect(try catalog.hasMaintenanceRows(withAny: .session) == false)
        #expect(try catalog.resetSessionMaintenanceFlags() == false)

        // 清完就空的行删掉。
        try catalog.clearMaintenanceFlags([.titleChecked, .artistChecked, .deferredRetry])
        #expect(try catalog.maintenanceRowCount() == (0..<500).filter { $0 % 17 == 0 }.count)

        // 一个事务里先整套清空再写新值。
        try catalog.applyMaintenance([("id-0001", Delta(setFlags: .failed))], clearing: .failed)
        #expect(try catalog.maintenanceSongIDs(withAny: .failed) == ["id-0001"])
        try catalog.setMaintenanceValues(["migrated": "1"])
        #expect(try catalog.maintenanceValue("migrated") == "1")
        try catalog.setMaintenanceValues(["migrated": nil])
        #expect(try catalog.maintenanceValue("migrated") == nil)
    }

    @Test("Maintenance rows are keyed by song id: deletes, renames and lagging songs do not touch them")
    func maintenanceSurvivesSongChanges() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try LibraryCatalog(path: directory.appendingPathComponent("c.sqlite").path)
        let songs = Self.songs(40, seed: 4_103)
        try catalog.apply(upserts: songs)
        try catalog.applyMaintenance([
            (songs[0].id, Delta(setFlags: .failed)),
            (songs[1].id, Delta(setFlags: .titleChecked)),
            ("not-in-catalog-yet", Delta(setFlags: .incomplete, retryCount: 2)),
        ])
        try catalog.apply(upserts: [], deletingIDs: [songs[0].id], renaming: [songs[1].id: "renamed"])
        let rows = try catalog.maintenanceRows(songIDs: [songs[0].id, songs[1].id, "not-in-catalog-yet"])
        #expect(rows[0].flags == .failed)
        #expect(rows[1].flags == .titleChecked)
        #expect(rows[2] == Row(flags: .incomplete, retryCount: 2))

        var joined: [String: Row] = [:]
        try catalog.forEachSongMaintenance(.everything) { _, song, row in
            joined[song.id] = row
            return true
        }
        #expect(joined.count == 39)
        #expect(joined["renamed"] == .empty)
        #expect(joined.values.allSatisfy { $0 == .empty })
        try catalog.applyMaintenance([("renamed", Delta(setFlags: .artistChecked))])
        var renamedRow: Row?
        try catalog.forEachSongMaintenance(.everything) { _, song, row in
            if song.id == "renamed" { renamedRow = row }
            return true
        }
        #expect(renamedRow?.flags == .artistChecked)
    }

    @Test("Opening a v1 catalog migrates the maintenance table to the id-keyed layout")
    func schemaMigratesFromV1() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("v1.sqlite").path
        do {
            let queue = try DatabaseQueue(path: path)
            var migrator = DatabaseMigrator()
            LibraryCatalogSchema.registerMigrations(in: &migrator)
            try migrator.migrate(queue, upTo: "catalog-v1")
            try queue.write { db in
                try db.execute(sql: "INSERT INTO catalogMeta (key, value) VALUES ('schemaVersion', '1')")
                try db.execute(sql: "INSERT INTO songMaintenance (songRowid, flags) VALUES (5, 1)")
            }
        }
        let catalog = try LibraryCatalog(path: path)
        let columns = try catalog.pool.read { db in try db.columns(in: "songMaintenance").map(\.name) }
        #expect(columns == ["songID", "songRowid", "flags", "retryCount", "lastAttemptAt", "detail"])
        #expect(try catalog.maintenanceRowCount() == 0)
        let version = try catalog.pool.read { db in try LibraryCatalog.metaValue("schemaVersion", in: db) }
        #expect(version == String(LibraryCatalogSchema.schemaVersion))
        let fresh = try LibraryCatalog(path: directory.appendingPathComponent("fresh.sqlite").path)
        let freshVersion = try fresh.pool.read { db in try LibraryCatalog.metaValue("schemaVersion", in: db) }
        #expect(freshVersion == String(LibraryCatalogSchema.schemaVersion))
        #expect(try fresh.groupingNeedsRebuild == false)
    }

    @Test("Offline table: writes by id and rowid, the populated marker, filter and sort")
    func offlineTable() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try LibraryCatalog(path: directory.appendingPathComponent("c.sqlite").path)
        let songs = Self.songs(120, seed: 4_104)
        try catalog.apply(upserts: songs)
        #expect(try catalog.offlineStateIsCurrent() == false)

        try catalog.beginOfflinePopulation()
        let rowids = try catalog.rowids(forIDs: songs.map(\.id))
        try catalog.setOfflineEntries(rowids: [
            (rowids[3]!, LibraryCatalogOfflineEntry(bytes: 300, updatedAt: 1)),
            (rowids[7]!, LibraryCatalogOfflineEntry(bytes: 700)),
        ])
        #expect(try catalog.offlineStateIsCurrent() == false)
        try catalog.finishOfflinePopulation()
        #expect(try catalog.offlineStateIsCurrent())

        let missing = try catalog.setOfflineEntries([
            (songs[9].id, LibraryCatalogOfflineEntry(bytes: 900)),
            ("not-yet", LibraryCatalogOfflineEntry(bytes: 1)),
            (songs[7].id, nil),
        ])
        #expect(missing == ["not-yet"])
        #expect(try catalog.offlineCount() == 2)
        #expect(try catalog.offlineEntries(songIDs: [songs[3].id, songs[7].id, songs[9].id]) == [
            LibraryCatalogOfflineEntry(bytes: 300, updatedAt: 1), nil, LibraryCatalogOfflineEntry(bytes: 900),
        ])
        #expect(try catalog.offlineRowList().rowids == ContiguousArray([rowids[3]!, rowids[9]!]))
        var streamed: [String] = []
        try catalog.forEachOfflineSong { _, song, entry in
            streamed.append("\(song.id)=\(entry.bytes)")
            return true
        }
        #expect(streamed == ["\(songs[3].id)=300", "\(songs[9].id)=900"])

        // 已有的「已下载」过滤与排序认这张表,不把标记行算进去。
        #expect(try catalog.songCount(LibrarySongScope(includesDisabledSources: true, downloadedOnly: true)) == 2)
        let sorted = try catalog.songRowList(order: .downloaded, scope: .everything).rowids
        #expect(Set(sorted.prefix(2)) == [rowids[3]!, rowids[9]!] || Set(sorted.suffix(2)) == [rowids[3]!, rowids[9]!])

        // 删歌连带删掉它的离线行;去掉标记后行还在。
        try catalog.apply(upserts: [], deletingIDs: [songs[3].id])
        #expect(try catalog.offlineCount() == 1)
        try catalog.invalidateOfflineState()
        #expect(try catalog.offlineStateIsCurrent() == false)
        #expect(try catalog.offlineCount() == 1)
    }

    @Test("A re-import leaves the offline table not current")
    func reimportClearsOfflineMarker() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let songs = Self.songs(60, seed: 4_105)
        let storePath = directory.appendingPathComponent("library-songs.sqlite").path
        let store = try IncrementalSongStore(path: storePath)
        try store.replaceAll(with: songs)
        let catalog = try LibraryCatalog(path: directory.appendingPathComponent("c.sqlite").path)
        _ = try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: catalog)
        try catalog.finishOfflinePopulation()
        #expect(try catalog.offlineStateIsCurrent())
        try catalog.invalidateImport()
        _ = try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: catalog)
        #expect(try catalog.offlineStateIsCurrent() == false)
    }

    @Test("Point reads through the dedicated reader: cost per song for a whole-library pass")
    func pointReadCost() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try LibraryCatalog(path: directory.appendingPathComponent("c.sqlite").path)
        let count = 100_000
        let ids = (0..<count).map { String(format: "%032llx", UInt64($0) &* 0x9E37_79B9_7F4A_7C15) }
        let start = ProcessInfo.processInfo.systemUptime
        for chunk in stride(from: 0, to: count, by: 5_000) {
            try catalog.applyMaintenance(ids[chunk..<min(count, chunk + 5_000)].map {
                (songID: $0, delta: Delta(setFlags: [.titleChecked, .artistChecked, .albumArtistChecked]))
            })
        }
        let written = ProcessInfo.processInfo.systemUptime
        let reader = try catalog.makeMaintenanceReader()
        var hits = 0
        for chunk in stride(from: 0, to: count, by: 1_024) {
            hits += try reader.rows(songIDs: Array(ids[chunk..<min(count, chunk + 1_024)])).filter { !$0.isEmpty }.count
        }
        let read = ProcessInfo.processInfo.systemUptime
        #expect(hits == count)
        // 重复的 id、没有行的 id 都对得上位置。
        let mixed = ["absent"] + Array(ids[10..<300]) + [ids[11], "absent-2", ids[10]]
        let mixedRows = try reader.rows(songIDs: mixed)
        #expect(mixedRows.count == mixed.count)
        #expect(mixedRows.first == .empty && mixedRows[mixed.count - 2] == .empty)
        #expect(mixedRows.last?.flags.contains(.titleChecked) == true && mixedRows[1] == mixedRows.last)
        print(String(
            format: "maintenance.cost write=%.2fus/row read=%.2fus/row rows=%d",
            (written - start) * 1_000_000 / Double(count), (read - written) * 1_000_000 / Double(count), count
        ))
    }

    @Test("The streaming album-artist verdict equals the whole-library verdict")
    func streamingVerdictMatches() {
        var rng = CatalogTestRandom(seed: 4_106)
        let albums = ["OST", " OST", "OST ", "Best of", "Live", "e\u{301}cho", "\u{E9}cho", ""]
        let artists = ["Hans Zimmer", "hans zimmer", "John Williams", "A & B", "A", "B", "Various Artists", ""]
        for _ in 0..<200 {
            let tracks = (0..<rng.int(0...80)).map { index in
                AlbumArtistInferencePolicy.Track(
                    id: "t\(index)",
                    sourceID: rng.pick(["s1", "s2"]),
                    directory: rng.pick(["a", "b", nil]),
                    albumTitle: rng.maybe(90) { $0.pick(albums) },
                    albumArtistName: rng.maybe(25) { $0.pick(artists) },
                    trackArtistName: rng.maybe(85) { $0.pick(artists) },
                    year: rng.maybe(50) { $0.int(1990...1995) },
                    discNumber: rng.maybe(30) { $0.int(1...2) },
                    trackNumber: rng.maybe(70) { $0.int(1...6) }
                )
            }
            let whole = AlbumArtistInferencePolicy.unconfirmedAlbumArtistTrackIDs(for: tracks)
            let streamed = AlbumArtistInferencePolicy.unconfirmedAlbumArtistTrackIDs { body in tracks.forEach(body) }
            #expect(streamed == whole)
        }
    }
}
