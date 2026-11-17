import Foundation
import Testing
@testable import PrimuseKit

@Suite("Indexed song snapshot")
struct IndexedSongSnapshotTests {
    private func song(_ id: String, path: String, source: String = "source") -> Song {
        Song(id: id, title: "Fixture \(id)", fileFormat: .flac, filePath: path, sourceID: source)
    }

    @Test("path identity stays anchored to the original snapshot across row updates")
    func originalPathsSurviveUpdates() {
        let first = song("one", path: "/old.flac")
        let duplicateID = song("one", path: "/duplicate-id.flac")
        var snapshot = IndexedSongSnapshot([first, duplicateID], matchingOriginalPathsForSourceID: "source")
        let frozen = snapshot
        var moved = first
        moved.filePath = "/new.flac"
        moved.title = "Renamed"
        snapshot.update(moved)
        snapshot.update(song("added", path: "/added.flac"))

        #expect(snapshot["one"] == moved)
        #expect(snapshot.originalFilePath(forID: "one") == "/old.flac")
        #expect(snapshot.songID(forOriginalPath: "/old.flac") == "one")
        #expect(snapshot.songID(forOriginalPath: "/duplicate-id.flac") == "one")
        #expect(snapshot.songID(forOriginalPath: "/new.flac") == nil)
        #expect(snapshot.originalFilePath(forID: "added") == nil)
        #expect(snapshot.songID(forOriginalPath: "/added.flac") == nil)
        #expect(snapshot.count == 2)
        #expect(snapshot.keys == ["one", "added"])
        #expect(frozen["one"] == first)
        #expect(frozen["added"] == nil)
        #expect(frozen.count == 1)
    }

    @Test("only unambiguous physical tracks from the requested source match by path")
    func pathMatchesExcludeCueTracksAndOtherSources() {
        var cue = song("cue", path: "/shared.flac")
        cue.cueSheetPath = "/album.cue"
        cue.cueStartTime = 0
        let physical = song("physical", path: cue.filePath)
        let other = song("other", path: cue.filePath, source: "other-source")
        let snapshot = IndexedSongSnapshot([cue, physical, other], matchingOriginalPathsForSourceID: "source")
        #expect(snapshot.songID(forOriginalPath: cue.filePath) == physical.id)
        #expect(snapshot[other.id] == other)
        #expect(snapshot.originalFilePath(forID: cue.id) == cue.filePath)
        let cueOnly = IndexedSongSnapshot([cue], matchingOriginalPathsForSourceID: "source")
        #expect(cueOnly.songID(forOriginalPath: cue.filePath) == nil)
    }

    @Test("duplicate paths remain ambiguous with three entries and equivalent Unicode spellings")
    func ambiguousPathsNeverAcquireAnIdentity() {
        let songs = [
            song("one", path: "/caf\u{e9}.flac"),
            song("two", path: "/cafe\u{301}.flac"),
            song("three", path: "/caf\u{e9}.flac"),
            song("same-id", path: "/repeated.flac"),
            song("same-id", path: "/repeated.flac")
        ]
        let snapshot = IndexedSongSnapshot(songs, matchingOriginalPathsForSourceID: "source")
        #expect(snapshot.songID(forOriginalPath: "/caf\u{e9}.flac") == nil)
        #expect(snapshot.songID(forOriginalPath: "/cafe\u{301}.flac") == nil)
        #expect(snapshot.songID(forOriginalPath: "/repeated.flac") == nil)
        #expect(snapshot.count == 4)
    }

    @Test("ID filtering and optional path matching preserve existing snapshot callers")
    func defaultAndFilteredSnapshots() {
        let songs = [song("one", path: "/one.flac"), song("two", path: "/two.flac", source: "other")]
        let all = IndexedSongSnapshot(songs)
        #expect(all.count == 2)
        #expect(all.originalFilePath(forID: "one") == "/one.flac")
        #expect(all.songID(forOriginalPath: "/one.flac") == nil)
        let filtered = IndexedSongSnapshot(songs, sourceID: "other", matchingOriginalPathsForSourceID: "other")
        #expect(filtered["one"] == nil)
        #expect(filtered.originalFilePath(forID: "one") == nil)
        #expect(filtered.songID(forOriginalPath: "/one.flac") == nil)
        #expect(filtered["two"] == songs[1])
        #expect(filtered.songID(forOriginalPath: "/two.flac") == "two")
        #expect(filtered.keys == ["two"])
        #expect(IndexedSongSnapshot([]).count == 0)
    }
}

#if canImport(Darwin)
import Darwin

@Suite("Scan identity lookup footprint")
struct ScanIdentityLookupFootprintMeasurement {
    private func mallocInUse() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return statistics.size_in_use
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRIMUSE_SCAN_LOOKUP_MEASURE"] != nil))
    func measureLookupTables() throws {
        let environment = ProcessInfo.processInfo.environment
        let mode = environment["PRIMUSE_SCAN_LOOKUP_MEASURE"] ?? "file"
        let count = Int(environment["PRIMUSE_SCAN_LOOKUP_SONGS"] ?? "") ?? 456_790
        try #require(["legacy", "file", "catalogue"].contains(mode) && count > 0)
        var songs: [Song] = []
        songs.reserveCapacity(count)
        for index in 0..<count {
            songs.append(Song(
                id: String(format: "%032x", index), title: "Fixture Track \(index)",
                albumTitle: "Fixture Album \(index / 12)", artistName: "Fixture Artist \(index / 120)",
                fileFormat: .flac, filePath: "/music/artist-\(index / 120)/album-\(index / 12)/track-\(index).flac",
                sourceID: "source"
            ))
        }
        let baseline = mallocInUse()
        let start = ContinuousClock.now
        let snapshot = IndexedSongSnapshot(songs, matchingOriginalPathsForSourceID: mode == "file" ? "source" : nil)
        var allSongIndexByID: [String: Int] = [:]
        allSongIndexByID.reserveCapacity(count)
        for (index, song) in songs.enumerated() { allSongIndexByID[song.id] = index }
        var legacyIDsByPath: [String: String] = [:]
        var legacyPathsByID: [String: String] = [:]
        if mode == "legacy" {
            for song in songs { legacyIDsByPath[song.filePath] = song.id }
            legacyPathsByID = Dictionary(songs.map { ($0.id, $0.filePath) }, uniquingKeysWith: { first, _ in first })
        }
        let elapsed = start.duration(to: .now)
        try withExtendedLifetime((songs, snapshot, allSongIndexByID, legacyIDsByPath, legacyPathsByID)) {
            let current = mallocInUse()
            let record: [String: Any] = [
                "mode": mode, "songs": count, "song_fixture_heap_bytes": baseline,
                "heap_bytes_with_lookups": current, "lookup_heap_bytes": current - baseline,
                "build_seconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            ]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print("SCAN_LOOKUP_MEASUREMENT \(String(decoding: data, as: UTF8.self))")
            #expect(snapshot[songs[count - 1].id] == songs[count - 1])
            #expect(allSongIndexByID[songs[count - 1].id] == count - 1)
            if mode == "file" { #expect(snapshot.songID(forOriginalPath: songs[0].filePath) == songs[0].id) }
        }
    }
}
#endif
