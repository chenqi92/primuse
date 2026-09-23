import Foundation
import Testing
@testable import PrimuseKit

@Suite("Internet radio")
struct RadioStationTests {
    @Test("Only credential-free HTTP and HTTPS stream URLs are accepted")
    func validatesStreamURLs() {
        #expect(RadioStationValidation.normalizedURLString(" https://radio.example/live ") == "https://radio.example/live")
        #expect(RadioStationValidation.normalizedURLString("http://radio.example:8000/stream") != nil)
        #expect(RadioStationValidation.normalizedURLString("file:///tmp/stream.mp3") == nil)
        #expect(RadioStationValidation.normalizedURLString("ftp://radio.example/live") == nil)
        #expect(RadioStationValidation.normalizedURLString("https://user:secret@radio.example/live") == nil)
        #expect(!RadioStationValidation.isValid(name: "   ", urlString: "https://radio.example/live"))
    }

    @Test("Stream formats are inferred from URL and MIME type")
    func infersStreamFormat() throws {
        #expect(RadioStreamFormat.inferred(from: try #require(URL(string: "https://radio.example/live.m3u8"))) == .hls)
        #expect(RadioStreamFormat.inferred(from: try #require(URL(string: "https://radio.example/live")), mimeType: "audio/flac") == .flac)
        #expect(RadioStreamFormat.inferred(from: try #require(URL(string: "https://radio.example/mellow-flac"))) == .flac)
        #expect(RadioStreamFormat.inferred(from: try #require(URL(string: "https://radio.example/live.aac"))) == .aac)
        #expect(RadioStreamFormat.inferred(from: try #require(URL(string: "https://radio.example/aac-320"))) == .aac)
        #expect(RadioStreamFormat.inferred(from: try #require(URL(string: "https://radio.example/live.mp3"))) == .mp3)
        #expect(RadioStreamFormat.inferred(from: try #require(URL(string: "https://radio.example/mp3-192"))) == .mp3)
    }

    @Test("A station projects a non-library synthetic playback item")
    func projectsPlaybackSong() {
        let station = RadioStation(
            id: "station-id",
            name: "Reference Radio",
            streamURL: "https://radio.example/live.flac",
            streamFormat: .flac,
            bitRate: 1_411_200
        )

        let song = station.playbackSong
        #expect(song.id == "radio:station-id")
        #expect(song.sourceID == RadioStation.playbackSourceID)
        #expect(song.duration == 0)
        #expect(song.fileSize == 0)
        #expect(song.fileFormat == .flac)
        #expect(song.artistName == "FLAC · 1411 kbps")
    }

    @Test("Server mirrors preserve provenance without persisting credentials")
    func projectsServerMirrorPlayback() {
        let station = RadioStation(
            id: ServerRadioStationIdentity.stationID(sourceID: "jf", serverStationID: "radio-1"),
            name: "Server Radio",
            streamURL: "",
            sourceID: "jf",
            serverStationID: "radio-1",
            sourceName: "Jellyfin",
            sourcePlaybackPath: "/items/radio-1.mp3"
        )

        #expect(station.isServerMirror)
        #expect(station.requiresSourceStreamResolution)
        #expect(RadioStationValidation.hasConsistentServerIdentity(station))
        #expect(station.displayEndpoint == "Jellyfin")
        #expect(RadioStationValidation.hasValidPlaybackReference(station))
        #expect(station.playbackSong.sourceID == "jf")
        #expect(station.playbackSong.filePath == "/items/radio-1.mp3")
    }

    @Test("Server mirror identity must match its provenance")
    func rejectsInconsistentServerIdentity() {
        let station = RadioStation(
            id: "unrelated",
            name: "Server Radio",
            streamURL: "https://radio.example.com/live",
            sourceID: "source",
            serverStationID: "station"
        )

        #expect(station.isServerMirror)
        #expect(!RadioStationValidation.hasConsistentServerIdentity(station))
    }

    @Test("Live playback disables track-only presentation capabilities")
    func exposesLiveCapabilities() {
        let capabilities = PlaybackPresentationCapabilities.capabilities(for: .liveRadio)
        #expect(!capabilities.canSeek)
        #expect(!capabilities.supportsQueue)
        #expect(!capabilities.supportsLyrics)
        #expect(!capabilities.supportsLibraryActions)
        #expect(!capabilities.supportsPlaybackRate)
        #expect(!capabilities.supportsShuffleAndRepeat)
    }

    @Test("Explicit station priority is stable and precedes legacy stations")
    func sortsByPriority() {
        let now = Date()
        let stations = [
            RadioStation(id: "legacy", name: "Legacy", streamURL: "https://radio.example/legacy", lastPlayedAt: now),
            RadioStation(id: "second", name: "Second", streamURL: "https://radio.example/second", sortOrder: 1),
            RadioStation(id: "first", name: "First", streamURL: "https://radio.example/first", sortOrder: 0)
        ]

        #expect(RadioStationOrdering.sorted(stations).map(\.id) == ["first", "second", "legacy"])
    }

    @Test("Legacy stations remain ordered by recency and then name")
    func sortsLegacyStations() {
        let now = Date()
        let stations = [
            RadioStation(id: "alpha", name: "Alpha", streamURL: "https://radio.example/alpha"),
            RadioStation(id: "recent", name: "Recent", streamURL: "https://radio.example/recent", lastPlayedAt: now),
            RadioStation(id: "beta", name: "Beta", streamURL: "https://radio.example/beta")
        ]

        #expect(RadioStationOrdering.sorted(stations).map(\.id) == ["recent", "alpha", "beta"])
    }

    @Test("Stations decode from snapshots created before priority was added")
    func decodesLegacyStation() throws {
        let data = try #require("""
        {
          "id": "legacy",
          "name": "Legacy Radio",
          "streamURL": "https://radio.example/live",
          "streamFormat": "automatic",
          "createdAt": 0,
          "modifiedAt": 0,
          "isDeleted": false
        }
        """.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let station = try decoder.decode(RadioStation.self, from: data)
        #expect(station.sortOrder == nil)
        #expect(station.sourceID == nil)
        #expect(!station.isServerMirror)
    }

    @Test("Server radio identities reconcile within one source")
    func reconcilesServerRadioIdentities() {
        let first = ServerRadioStationIdentity.stationID(sourceID: "src-a", serverStationID: "1")
        let second = ServerRadioStationIdentity.stationID(sourceID: "src-a", serverStationID: "2")
        let keep = ServerRadioReconciliationPolicy.mirrorIDsToKeep(
            sourceID: "src-a",
            serverStationIDs: [" 1 "],
            failedServerStationIDs: ["2"]
        )

        #expect(keep == [first, second])
        #expect(first.hasPrefix(ServerRadioStationIdentity.stationIDPrefix(sourceID: "src-a")))
        #expect(!first.hasPrefix(ServerRadioStationIdentity.stationIDPrefix(sourceID: "src-b")))
    }

    @Test("Server mirror tombstones are dropped after the retention window")
    func purgesOldMirrorTombstones() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 24 * 60 * 60
        #expect(!ServerRadioReconciliationPolicy.shouldPurgeMirrorTombstone(deletedAt: now - 29 * day, now: now))
        #expect(ServerRadioReconciliationPolicy.shouldPurgeMirrorTombstone(deletedAt: now - 31 * day, now: now))
        #expect(!ServerRadioReconciliationPolicy.shouldPurgeMirrorTombstone(deletedAt: nil, now: now))
    }

    @Test("Playback state remains compatible with pre-radio snapshots")
    func decodesLegacyPlaybackState() throws {
        let data = try #require("""
        {
          "currentSongID": "song-id",
          "songTitle": "Song",
          "isPlaying": false,
          "currentTime": 12,
          "duration": 180,
          "queueSongIDs": ["song-id"]
        }
        """.data(using: .utf8))

        let state = try JSONDecoder().decode(PlaybackState.self, from: data)
        #expect(state.playbackKind == nil)
        #expect(state.radioStationID == nil)
        #expect(state.updatedAt == nil)
        #expect(!state.isLiveStream)
    }
}

@Suite("电台稀疏排序")
struct RadioStationSparseRankTests {
    private let step = RadioStationOrdering.rankStep

    private func station(_ id: String, rank: Int?, isDeleted: Bool = false) -> RadioStation {
        RadioStation(
            id: id,
            name: "Station \(id)",
            streamURL: "https://radio.example/\(id)",
            sortOrder: rank,
            isDeleted: isDeleted
        )
    }

    /// 按间隔编好号的一排台：第 i 个是 i * rankStep。
    private func ranked(_ ids: [String]) -> [RadioStation] {
        ids.enumerated().map { station($1, rank: $0 * step) }
    }

    private func applying(_ ranks: [String: Int], to stations: [RadioStation]) -> [RadioStation] {
        stations.map { station in
            var updated = station
            if let rank = ranks[station.id] { updated.sortOrder = rank }
            return updated
        }
    }

    private func order(_ stations: [RadioStation]) -> [String] {
        RadioStationOrdering.sorted(stations.filter { !$0.isDeleted }).map(\.id)
    }

    @Test("新台接在最大序号后面一个间隔；还有台没序号时不给序号")
    func appendedRankRequiresEveryLiveStationRanked() {
        #expect(RadioStationOrdering.appendedRank(after: []) == nil)
        #expect(RadioStationOrdering.appendedRank(after: [station("a", rank: nil)]) == nil)
        // 置顶过几个台、其余没序号：新台跟没序号的台一起排，不插到它们前面。
        #expect(RadioStationOrdering.appendedRank(after: [station("a", rank: 0), station("b", rank: nil)]) == nil)
        let expected = 2 * step + step
        #expect(RadioStationOrdering.appendedRank(after: ranked(["a", "b", "c"])) == expected)
        // 墓碑不挡「全都有序号」，但它的序号算进最大值，复活时不会和新台撞号。
        let withTombstone = ranked(["a", "b"]) + [station("gone", rank: 9_000, isDeleted: true), station("old", rank: nil, isDeleted: true)]
        #expect(RadioStationOrdering.appendedRank(after: withTombstone) == 9_000 + step)
        #expect(RadioStationOrdering.rank(after: Int.max) == Int.max)
    }

    @Test("整份重排按顺序写 i * rankStep，重复的 id 只认第一次")
    func denseRanksFollowOrder() {
        let ranks = RadioStationOrdering.denseRanks(for: ["c", "a", "c", "b"])
        #expect(ranks == ["c": 0, "a": step, "b": 2 * step])
    }

    @Test("往前挪一台只改它自己的序号，落在越过的那一台之前")
    func movingUpTouchesOnlyTheMovedStation() throws {
        let stations = ranked(["a", "b", "c", "d"])
        let ranks = try #require(RadioStationOrdering.sparseRanks(moving: ["d"], anchor: .before("b"), in: stations))
        #expect(Array(ranks.keys) == ["d"])
        let rank = try #require(ranks["d"])
        #expect(rank > 0 && rank < step)
        #expect(order(applying(ranks, to: stations)) == ["a", "d", "b", "c"])
    }

    @Test("往后挪、挪到最前、挪到最后都只写被挪的台")
    func movesToEdges() throws {
        let stations = ranked(["a", "b", "c", "d"])

        let down = try #require(RadioStationOrdering.sparseRanks(moving: ["a"], anchor: .after("c"), in: stations))
        #expect(down.count == 1)
        #expect(order(applying(down, to: stations)) == ["b", "c", "a", "d"])

        let top = try #require(RadioStationOrdering.sparseRanks(moving: ["c"], anchor: .before("a"), in: stations))
        #expect(top == ["c": -step])
        #expect(order(applying(top, to: stations)) == ["c", "a", "b", "d"])

        let bottom = try #require(RadioStationOrdering.sparseRanks(moving: ["b"], anchor: .after("d"), in: stations))
        let expectedBottom = 3 * step + step
        #expect(bottom == ["b": expectedBottom])
        #expect(order(applying(bottom, to: stations)) == ["a", "c", "d", "b"])
    }

    @Test("一次挪几台时按给定先后等距落进同一个空位")
    func movesSeveralStationsIntoOneGap() throws {
        let stations = ranked(["a", "b", "c", "d", "e"])
        let ranks = try #require(RadioStationOrdering.sparseRanks(moving: ["e", "d"], anchor: .after("a"), in: stations))
        #expect(Set(ranks.keys) == ["e", "d"])
        let e = try #require(ranks["e"])
        let d = try #require(ranks["d"])
        #expect(0 < e && e < d && d < step)
        #expect(order(applying(ranks, to: stations)) == ["a", "e", "d", "b", "c"])
    }

    @Test("几千个台里挪一个，只有一台改号")
    func largeLibraryMoveWritesOneRank() throws {
        let ids = (0..<4_000).map { "mirror-\($0)" }
        let stations = ranked(ids)
        let ranks = try #require(RadioStationOrdering.sparseRanks(moving: ["mirror-3999"], anchor: .before("mirror-10"), in: stations))
        #expect(ranks.count == 1)
        let result = order(applying(ranks, to: stations))
        #expect(result[10] == "mirror-3999")
        #expect(result[11] == "mirror-10")
    }

    @Test("还有台没序号、空位不够、两台同号、落点找不到时交给整份归一化")
    func fallsBackToNormalization() {
        let partial = [station("a", rank: 0), station("b", rank: step), station("c", rank: nil)]
        #expect(RadioStationOrdering.sparseRanks(moving: ["b"], anchor: .before("a"), in: partial) == nil)

        let tight = [station("a", rank: 5), station("b", rank: 6), station("c", rank: 7)]
        #expect(RadioStationOrdering.sparseRanks(moving: ["c"], anchor: .after("a"), in: tight) == nil)

        let tied = [station("a", rank: 0), station("b", rank: step), station("c", rank: step), station("d", rank: 2 * step)]
        #expect(RadioStationOrdering.sparseRanks(moving: ["d"], anchor: .after("b"), in: RadioStationOrdering.sorted(tied)) == nil)

        let stations = ranked(["a", "b", "c"])
        #expect(RadioStationOrdering.sparseRanks(moving: ["x"], anchor: .before("a"), in: stations) == nil)
        #expect(RadioStationOrdering.sparseRanks(moving: ["c"], anchor: .before("missing"), in: stations) == nil)
        #expect(RadioStationOrdering.sparseRanks(moving: ["a", "b", "c"], anchor: .before("a"), in: stations) == nil)

        let nearLimit = [station("a", rank: Int.min + 10), station("b", rank: Int.max - 10)]
        #expect(RadioStationOrdering.sparseRanks(moving: ["b"], anchor: .before("a"), in: nearLimit) == nil)
    }

    @Test("反复插进同一处，空位用完之前每次都只写一台")
    func repeatedInsertionEventuallyNeedsNormalization() throws {
        var stations = ranked(["a", "b"]) + [station("x", rank: 10 * step)]
        var insertions = 0
        for index in 0..<64 {
            let id = "new-\(index)"
            stations.append(station(id, rank: RadioStationOrdering.appendedRank(after: stations)))
            let ordered = RadioStationOrdering.sorted(stations)
            guard let ranks = RadioStationOrdering.sparseRanks(moving: [id], anchor: .before("b"), in: ordered) else { break }
            #expect(ranks.count == 1)
            stations = applying(ranks, to: stations)
            let current = order(stations)
            let insertedIndex = try #require(current.firstIndex(of: id))
            #expect(current[0] == "a")
            #expect(current[insertedIndex + 1] == "b")
            insertions += 1
        }
        // 1024 的间隔对半分，能连着插十次左右才需要归一化一次。
        #expect(insertions >= 9)
        #expect(insertions < 64)
    }

    @Test("置顶按给定先后排到最前，其余的台不动")
    func movesToTopWithoutRenumberingOthers() {
        let stations = ranked(["a", "b", "c", "d"])
        let ranks = RadioStationOrdering.ranksMovingToTop(["d", "c"], in: stations)
        #expect(Set(ranks.keys) == ["d", "c"])
        #expect(ranks["d"] == -2 * step)
        #expect(ranks["c"] == -step)
        #expect(order(applying(ranks, to: stations)) == ["d", "c", "a", "b"])
    }

    @Test("置顶不需要归一化：没序号的台原样按最近播放排在后面")
    func movesToTopAmongUnrankedStations() {
        let now = Date()
        var stations = [station("a", rank: nil), station("b", rank: nil), station("c", rank: nil)]
        stations[0].lastPlayedAt = now
        let ranks = RadioStationOrdering.ranksMovingToTop(["c"], in: RadioStationOrdering.sorted(stations))
        #expect(ranks == ["c": 0])
        #expect(order(applying(ranks, to: stations)) == ["c", "a", "b"])

        let mixed = [station("p", rank: 0), station("q", rank: nil), station("r", rank: nil)]
        let pinned = RadioStationOrdering.ranksMovingToTop(["r"], in: RadioStationOrdering.sorted(mixed))
        #expect(pinned == ["r": -step])
        #expect(order(applying(pinned, to: mixed)) == ["r", "p", "q"])
    }

    @Test("已经按这个先后排在最前时置顶什么都不写，未知 id 忽略")
    func moveToTopNoOps() {
        let stations = ranked(["a", "b", "c"])
        #expect(RadioStationOrdering.ranksMovingToTop(["a", "b"], in: stations).isEmpty)
        #expect(RadioStationOrdering.ranksMovingToTop(["missing"], in: stations).isEmpty)
        let reordered = RadioStationOrdering.ranksMovingToTop(["b", "a"], in: stations)
        #expect(order(applying(reordered, to: stations)) == ["b", "a", "c"])
    }

    @Test("序号逼近整数下限时置顶退回整份重新编号")
    func moveToTopFallsBackNearIntegerLimit() {
        let stations = [station("a", rank: Int.min + 1), station("b", rank: 0)]
        let ranks = RadioStationOrdering.ranksMovingToTop(["b"], in: stations)
        // 整份按「b, a」重新编号：b 本来就是 0，只有 a 改号。
        #expect(ranks == ["a": step])
        #expect(order(applying(ranks, to: stations)) == ["b", "a"])
    }
}
