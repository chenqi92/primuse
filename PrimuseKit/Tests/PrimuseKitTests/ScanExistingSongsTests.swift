import Foundation
import Testing
@testable import PrimuseKit

/// 走查问「这个源扫描开始时已有的歌」:曲库目录(影子)的答案与按数组答的相同,
/// 走查自己改过、提交进目录之后,「原」字头的问题仍按开始时的样子答。
@Suite("Scan existing songs on the catalog")
struct ScanExistingSongsTests {
    private static let source = "nas"
    private static let directories = ["/Music", "/Music/Live", "/Music/Live/Disc 2", "/Music/Live-old", "/Music/周杰伦", "/Other"]

    private static func library(seed: UInt64) -> [Song] {
        var rng = CatalogTestRandom(seed: seed)
        var songs: [Song] = []
        for index in 0..<260 {
            let directory = rng.pick(directories)
            // 有意让几首同路径(原路径认不出 id)、几首在别的源。
            let name = rng.chance(6) ? "dup.flac" : "\(index) Track.\(rng.pick(["flac", "mp3"]))"
            songs.append(Song(
                id: "existing-\(seed)-\(index)", title: "Track \(index)",
                trackNumber: rng.chance(60) ? rng.int(1...12) : nil,
                fileFormat: rng.chance(50) ? .flac : .mp3,
                filePath: "\(directory)/\(name)",
                sourceID: rng.chance(90) ? source : "other"
            ))
        }
        // CUE 分轨:同一个文件上的几首(原路径不认它们)。
        for track in 1...3 {
            songs.append(Song(id: "cue-\(seed)-\(track)", title: "Cue \(track)", duration: 200, fileFormat: .flac,
                              filePath: "/Music/Live/image.flac", sourceID: source, cueSheetPath: "/Music/Live/image.cue",
                              cueStartTime: Double(track - 1) * 200, cueEndTime: Double(track) * 200))
        }
        // SACD 光盘镜像的分轨。
        for track in 1...2 {
            songs.append(Song(id: "sacd-\(seed)-\(track)", title: "SACD \(track)", duration: 180, fileFormat: .sacdISO,
                              filePath: "/Music/Album.iso", sourceID: source, cueSheetPath: "/Music/Album.iso",
                              cueStartTime: Double(track - 1) * 180, cueEndTime: Double(track) * 180, sacdTrackNumber: track))
        }
        return songs
    }

    private static func existing(
        _ catalog: LibraryCatalog, excluded: Set<String>, overrides: [Song]
    ) throws -> [Song] {
        var librarySongs: [Song] = []
        try catalog.forEachSong(.source(source)) { _, song in
            librarySongs.append(song)
            return true
        }
        let overrideIDs = Set(overrides.map(\.id))
        return overrides + librarySongs.filter { !excluded.contains($0.id) && !overrideIDs.contains($0.id) }
    }

    @Test("The catalog answers every start-of-scan question like the array", arguments: [1, 2, 3] as [UInt64])
    func catalogMatchesArray(seed: UInt64) throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        let songs = Self.library(seed: seed)
        try catalog.apply(upserts: songs)
        let sourceSongs = songs.filter { $0.sourceID == Self.source }
        let excluded = Set(sourceSongs.prefix(4).map(\.id))
        // 续扫带回来的行(内容和目录里的不同)、本机删掉的文件分段(目录里没有)。
        var resumed = sourceSongs[10]
        resumed.title = "Resumed Title"
        resumed.filePath = "/Music/Live/resumed.flac"
        let hidden = Song(id: "hidden-\(seed)", title: "Hidden", fileFormat: .flac,
                          filePath: "/Music/Live/hidden.flac", sourceID: Self.source)
        let overrides = [resumed, hidden]
        let array = try Self.existing(catalog, excluded: excluded, overrides: overrides)

        let shadow = ScanExistingSongsCatalogShadow(
            catalog: catalog, pendingWrites: nil, sourceID: Self.source, excludedIDs: excluded, overrides: overrides
        )
        let lookup = ScanExistingSongs(array, sourceID: Self.source, matchesOriginalPaths: true, shadow: shadow)

        func askEverything() {
            for directory in Self.directories {
                lookup.prepareDirectory(directory)
                _ = lookup.songIDs(under: directory) { $0.hasPrefix(directory + "/") }
            }
            for song in songs { _ = lookup[song.id] }
            for id in ["missing", hidden.id, resumed.id] + excluded { _ = lookup[id] }
            for song in songs { _ = lookup.originalFilePath(forID: song.id) }
            let paths = Set(songs.map(\.filePath) + [resumed.filePath, hidden.filePath, "/Music/none.flac"])
            for path in paths.sorted() {
                _ = lookup.songID(forOriginalPath: path)
                _ = lookup.discTracks(atPath: path)
            }
        }
        askEverything()
        var report = try #require(lookup.shadowReport)
        #expect(report.mismatches == 0, "\(report.logLine)")
        #expect(report.failures == 0)
        #expect(report.lookups > 800)

        // 走查改了几行(挪路径、改内容、新加),并且已提交进目录:答案仍与数组相同。
        var moved = sourceSongs[20]
        moved.filePath = "/Music/Moved/\(moved.id).flac"
        var edited = sourceSongs[21]
        edited.title = "Edited"
        let added = Song(id: "added-\(seed)", title: "Added", fileFormat: .flac,
                         filePath: sourceSongs[22].filePath, sourceID: Self.source)
        for song in [moved, edited, added] { lookup.update(song) }
        try catalog.apply(upserts: [moved, edited, added])
        askEverything()
        _ = lookup.songID(forOriginalPath: moved.filePath)
        _ = lookup[moved.id]
        _ = lookup[added.id]
        // 走查走完:遇到的是一部分开始时的歌加新加的那首,其余的要删;目录算出来的与数组的相同。
        var encountered = Set(array.filter { _ in Bool.random() }.map(\.id))
        encountered.insert(added.id)
        lookup.compareTerminalDeletions(encountered: encountered)
        lookup.compareTerminalDeletions(encountered: Set(array.map(\.id)))
        report = try #require(lookup.shadowReport)
        #expect(report.mismatches == 0, "\(report.logLine)")
        #expect(lookup.originalFilePath(forID: moved.id) == sourceSongs[20].filePath)
        #expect(lookup.originalFilePath(forID: added.id) == nil)
    }

    @Test("Root repairs before the walk count as the start state")
    func rootRepairsAreTheStartState() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        let legacy = Song(id: "legacy", title: "Legacy", fileFormat: .flac, filePath: "legacy.flac", sourceID: Self.source)
        let other = Song(id: "other", title: "Other", fileFormat: .flac, filePath: "/Music/other.flac", sourceID: Self.source)
        try catalog.apply(upserts: [legacy, other])
        var repaired = legacy
        repaired.filePath = "/Music/legacy.flac"
        let shadow = ScanExistingSongsCatalogShadow(
            catalog: catalog, pendingWrites: nil, sourceID: Self.source, excludedIDs: [], overrides: []
        )
        shadow.overrideStartState(repaired)
        let lookup = ScanExistingSongs([repaired, other], sourceID: Self.source, matchesOriginalPaths: true, shadow: shadow)
        #expect(lookup.songID(forOriginalPath: "/Music/legacy.flac") == "legacy")
        #expect(lookup.songID(forOriginalPath: "legacy.flac") == nil)
        #expect(lookup.originalFilePath(forID: "legacy") == "/Music/legacy.flac")
        #expect(lookup["legacy"] == repaired)
        lookup.prepareDirectory("/Music")
        #expect(Set(lookup.songIDs(under: "/Music") { $0.hasPrefix("/Music/") }) == ["legacy", "other"])
        #expect(lookup.shadowReport?.mismatches == 0, "\(lookup.shadowReport?.logLine ?? "")")
    }

    @Test("Rows compare at the store's whole-second date precision")
    func datesCompareAtStorePrecision() {
        var precise = Song(id: "a", title: "A", fileFormat: .flac, filePath: "/Music/a.flac", sourceID: Self.source)
        precise.dateAdded = Date(timeIntervalSince1970: 1_764_000_000.884)
        var stored = precise
        stored.dateAdded = Date(timeIntervalSince1970: 1_764_000_000)
        #expect(precise != stored)
        #expect(ScanExistingSongsCatalogShadow.sameAtStorePrecision(precise, stored))
        var retitled = stored
        retitled.title = "B"
        #expect(!ScanExistingSongsCatalogShadow.sameAtStorePrecision(precise, retitled))
        #expect(ScanExistingSongsCatalogShadow.difference(catalog: retitled, array: precise).contains("title"))
    }

    @Test("Without a shadow the lookups answer from the array alone")
    func arrayOnly() {
        let songs = [Song(id: "a", title: "A", fileFormat: .flac, filePath: "/Music/a.flac", sourceID: Self.source)]
        let lookup = ScanExistingSongs(songs, sourceID: Self.source, matchesOriginalPaths: false)
        #expect(lookup["a"] == songs[0])
        #expect(lookup.songID(forOriginalPath: "/Music/a.flac") == nil, "original paths are only matched when asked to")
        #expect(lookup.shadowReport == nil)
        #expect(lookup.count == 1)
    }

    // MARK: 文件走查的提交(遇到的 id + 改过的行)对整份终态快照

    private static func row(_ id: String, _ path: String? = nil, size: Int64 = 1_000) -> Song {
        Song(id: id, title: id, fileFormat: .flac, filePath: path ?? "/Music/\(id).flac", sourceID: source, fileSize: size)
    }

    /// 一轮走查:开始时库里有 a、b、c 和本机隐藏的分轨 h;a 没变,b 改了大小,c 的文件没了,
    /// 多了新歌 d,续扫带回来一行 r(库里没有),旧根目录修正过一行 m。
    private static func walk() -> (start: [Song], snapshot: [Song], encountered: Set<String>, submitted: [Song]) {
        let hidden = Song(id: "h", title: "Hidden", duration: 60, fileFormat: .flac, filePath: "/Music/image.flac",
                          sourceID: source, cueSheetPath: "/Music/image.cue", cueStartTime: 60)
        // 没变的行在快照里就是开始时的那一份(加入时间也一样)。
        let unchanged = row("a")
        let start = [unchanged, row("b"), row("c"), row("m", "m.flac"), hidden]
        let changed = row("b", size: 2_000)
        let repaired = row("m", "/Music/m.flac")
        let resumed = row("r")
        let new = row("d")
        return (start, [resumed, unchanged, changed, repaired, hidden, new], ["a", "b", "m", "h", "d", "r"],
                [resumed, changed, repaired, new])
    }

    @Test("A commit of changed rows and encountered ids carries what the terminal snapshot carried")
    func fileWalkCommitMatchesTheSnapshot() {
        let walk = Self.walk()
        let report = ScanFileWalkCommitShadow.compare(
            start: walk.start, terminalSnapshot: walk.snapshot, encountered: walk.encountered, submitted: walk.submitted
        )
        #expect(report.mismatches == 0, "\(report.logLine)")
        #expect(report.lookups == walk.snapshot.count * 2)

        // 同一行交过两次(续扫带回来、走查又改了一次):以后交的为准。
        let earlier = Self.row("b", size: 1_500)
        let twice = ScanFileWalkCommitShadow.compare(
            start: walk.start, terminalSnapshot: walk.snapshot, encountered: walk.encountered,
            submitted: [earlier] + walk.submitted
        )
        #expect(twice.mismatches == 0, "\(twice.logLine)")

        // 交过、这一轮却没遇到的行(续扫带回来、文件已经不在了)不在快照里,也不算数。
        let stale = ScanFileWalkCommitShadow.compare(
            start: walk.start, terminalSnapshot: walk.snapshot, encountered: walk.encountered,
            submitted: walk.submitted + [Self.row("gone")]
        )
        #expect(stale.mismatches == 0, "\(stale.logLine)")
    }

    @Test("Rows that only the terminal snapshot would have carried are reported")
    func fileWalkCommitReportsWhatItWouldLose() {
        let walk = Self.walk()
        func mismatches(
            snapshot: [Song]? = nil, encountered: Set<String>? = nil, submitted: [Song]? = nil
        ) -> ScanExistingSongsShadowReport {
            ScanFileWalkCommitShadow.compare(
                start: walk.start, terminalSnapshot: snapshot ?? walk.snapshot,
                encountered: encountered ?? walk.encountered, submitted: submitted ?? walk.submitted
            )
        }
        // 续扫带回来的行、旧根目录修正过的行、改过的行、新歌:哪一样没交都要报。
        for missing in ["r", "m", "b", "d"] {
            let report = mismatches(submitted: walk.submitted.filter { $0.id != missing })
            #expect(report.mismatches == 1, "\(missing): \(report.logLine)")
            #expect(report.samples.first?.contains("never submitted") == true, "\(missing): \(report.logLine)")
        }
        // 交的不是快照里那一份。
        let stale = mismatches(submitted: walk.submitted.map { $0.id == "b" ? Self.row("b", size: 1_500) : $0 })
        #expect(stale.mismatches == 1, "\(stale.logLine)")
        #expect(stale.samples.first?.contains("fileSize") == true, "\(stale.logLine)")
        // 快照里有、却没算遇到的行:按遇到的 id 剪会把它剪掉。
        let unseen = mismatches(encountered: walk.encountered.subtracting(["a"]))
        #expect(unseen.mismatches == 1, "\(unseen.logLine)")
        // 遇到了、快照里却没有的开始时的行:按快照剪会删、按遇到的 id 剪会留。
        let kept = mismatches(encountered: walk.encountered.union(["c"]))
        #expect(kept.mismatches == 1, "\(kept.logLine)")
        // 遇到过、没有行、也不是开始时的歌(索引里留下的旧 id):两种剪法没有区别。
        let orphan = mismatches(encountered: walk.encountered.union(["index-only"]))
        #expect(orphan.mismatches == 0, "\(orphan.logLine)")
    }
}
