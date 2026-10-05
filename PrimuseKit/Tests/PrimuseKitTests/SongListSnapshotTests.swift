import Foundation
import Testing
@testable import PrimuseKit

@Suite("Large song-list snapshots")
struct SongListSnapshotTests {
    @Test("Header artwork caches missing covers and preserves its candidate across sorting")
    func headerArtworkCandidate() {
        var first = song(id: "first", title: "Z")
        var second = song(id: "second", title: "A")
        #expect(SongListSnapshotBuilder.build(songs: [first, second], order: .title).coverSongID == nil)
        first.coverArtFileName = ""
        second.coverArtFileName = "second.jpg"
        #expect(SongListSnapshotBuilder.build(songs: [first, second], order: .title).coverSongID == second.id)
        first.coverArtFileName = "first.jpg"
        for order in [LibrarySongSortOrder.title, .titleDescending, .dateAdded] {
            #expect(SongListSnapshotBuilder.build(songs: [first, second], order: order).coverSongID == first.id)
        }
    }

    @Test("Scroll windows cover every visible row throughout each scroll step")
    func scrollWindowCoversViewport() {
        let count = 11_558
        for rowHeight in [24.0, 34.0, 40.0, 48.0] {
            for viewport in [400.0, 785.5, 1_600.0] {
                for firstRow in stride(from: 0, to: count, by: 7) {
                    let range = SongListScrollWindow.range(
                        totalCount: count,
                        firstVisibleRow: firstRow,
                        viewportHeight: viewport,
                        rowHeight: rowHeight
                    )
                    let lastRow = min(count - 1, firstRow + Int(ceil(viewport / rowHeight)))
                    #expect(range.contains(firstRow))
                    #expect(range.contains(lastRow))
                    #expect(range.count <= Int(ceil(viewport / rowHeight)) + 33)
                    #expect(range.lowerBound >= 0 && range.upperBound <= count)
                }
            }
        }
    }

    @Test("Scroll windows stay stable within a step and clamp after filtering")
    func scrollWindowStabilityAndFiltering() {
        func window(_ count: Int, _ firstRow: Int, _ viewport: Double = 720) -> Range<Int> {
            SongListScrollWindow.range(
                totalCount: count, firstVisibleRow: firstRow,
                viewportHeight: viewport, rowHeight: 40
            )
        }
        for row in 320..<336 {
            #expect(window(11_558, row) == window(11_558, 320))
        }
        #expect(window(0, 10_000).isEmpty)
        #expect(window(5, 10_000) == 0..<5)
        #expect(window(11_558, -1) == window(11_558, 0))
        #expect(window(11_558, 0, 0) == window(11_558, 0))
        #expect(window(11_558, 0, .infinity) == window(11_558, 0))
        #expect(window(11_558, 0, 1_000_000) == 0..<11_558)
    }

    @Test("Mixed-height rows map scroll offsets to rows and windows still cover the viewport")
    func mixedHeightRowOffsets() {
        let heights = (0..<5_000).map { $0 % 37 == 5 ? 61.0 : 45.0 }
        let offsets = SongListScrollRowOffsets(rowHeights: heights)
        #expect(offsets.rowCount == 5_000)
        #expect(offsets.totalHeight == heights.reduce(0, +))
        #expect(offsets.top(of: -3) == 0)
        #expect(offsets.top(of: 9_999) == offsets.totalHeight)

        for row in stride(from: 0, to: 5_000, by: 13) {
            let top = offsets.top(of: row)
            #expect(offsets.row(at: top) == row)
            #expect(offsets.row(at: top + heights[row] - 0.5) == row)
        }
        #expect(offsets.row(at: -40) == 0)
        #expect(offsets.row(at: .nan) == 0)
        #expect(offsets.row(at: offsets.totalHeight + 500) == 4_999)
        #expect(SongListScrollRowOffsets(rowHeights: []).row(at: 100) == 0)

        let viewport = 900.0
        for y in stride(from: 0.0, to: offsets.totalHeight, by: 211.0) {
            let first = offsets.row(at: y)
            let stride = SongListScrollWindow.rowStride
            let range = SongListScrollWindow.range(
                totalCount: offsets.rowCount,
                firstVisibleRow: first / stride * stride,
                viewportHeight: viewport,
                rowHeight: 45
            )
            #expect(range.contains(first))
            #expect(range.contains(offsets.row(at: y + viewport)))
        }
    }

    @Test("Builds sorted lightweight rows and aggregates")
    func buildsRowsAndAggregates() {
        let songs = [
            song(id: "b", title: "Beta", sourceID: "nas", duration: 120),
            song(id: "a", title: "Alpha", sourceID: "local", duration: 60),
            song(
                id: "c", title: "Gamma", sourceID: "nas",
                duration: -Double.infinity, filePath: ""
            ),
        ]

        let snapshot = SongListSnapshotBuilder.build(songs: songs, order: .title)

        #expect(snapshot.rows.map(\.id) == ["a", "b", "c"])
        #expect(snapshot.rows.map(\.offset) == [0, 1, 2])
        #expect(snapshot.songIDs == ["a", "b", "c"])
        #expect(snapshot.sourceCounts == ["local": 1, "nas": 2])
        #expect(snapshot.playableCount == 2)
        #expect(snapshot.totalDuration == 180)

        let local = snapshot.sourcePartition(forSourceID: "local")
        #expect(local?.rows.map(\.id) == ["a"])
        #expect(local?.rows.map(\.offset) == [0])
        #expect(local?.playableCount == 1)

        let nas = snapshot.sourcePartition(forSourceID: "nas")
        #expect(nas?.rows.map(\.id) == ["b", "c"])
        #expect(nas?.rows.map(\.offset) == [0, 1])
        #expect(nas?.playableCount == 1)
        #expect(snapshot.sourcePartition(forSourceID: "missing") == nil)
    }

    @Test("Source partitions preserve descending snapshot order")
    func sourcePartitionsPreserveDescendingOrder() {
        let songs = [
            song(id: "a", title: "Alpha", sourceID: "nas"),
            song(id: "c", title: "Gamma", sourceID: "nas"),
            song(id: "b", title: "Beta", sourceID: "local"),
        ]

        let snapshot = SongListSnapshotBuilder.build(songs: songs, order: .titleDescending)

        #expect(snapshot.rows.map(\.id) == ["c", "b", "a"])
        #expect(snapshot.sourcePartition(forSourceID: "nas")?.rows.map(\.id) == ["c", "a"])
        #expect(snapshot.sourcePartition(forSourceID: "nas")?.rows.map(\.offset) == [0, 1])
        #expect(snapshot.sourcePartition(forSourceID: "local")?.rows.map(\.id) == ["b"])
    }

    @Test("Date sorting is newest first with deterministic ties")
    func sortsDatesDeterministically() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let songs = [
            song(id: "z", title: "Z", dateAdded: older),
            song(id: "b", title: "B", dateAdded: newer),
            song(id: "a", title: "A", dateAdded: newer),
        ]

        let snapshot = SongListSnapshotBuilder.build(songs: songs, order: .dateAdded)

        #expect(snapshot.rows.map(\.id) == ["a", "b", "z"])
    }

    @Test("Title and date sorting support both directions")
    func sortsTitlesAndDatesBothWays() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let songs = [
            song(id: "b", title: "Beta", dateAdded: older),
            song(id: "a", title: "Alpha", dateAdded: newer),
        ]

        #expect(sortedIDs(songs, by: .title) == ["a", "b"])
        #expect(sortedIDs(songs, by: .titleDescending) == ["b", "a"])
        #expect(sortedIDs(songs, by: .dateAdded) == ["a", "b"])
        #expect(sortedIDs(songs, by: .dateAddedOldest) == ["b", "a"])
    }

    @Test("Source-date sorting supports both directions and keeps unknown dates last")
    func sortsSourceDatesBothWays() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let songs = [
            song(id: "missing", title: "Missing"),
            song(id: "b", title: "Newer B", lastModified: newer),
            song(id: "old", title: "Older", lastModified: older),
            song(id: "a", title: "Newer A", lastModified: newer),
        ]

        #expect(sortedIDs(songs, by: .sourceDate) == ["a", "b", "old", "missing"])
        #expect(sortedIDs(songs, by: .sourceDateOldest) == ["old", "a", "b", "missing"])
    }

    @Test("Sorts every supported metadata field")
    func sortsEveryMetadataField() {
        let songs = [
            song(
                id: "b",
                title: "Second",
                artistName: "Alpha",
                albumTitle: "Zulu",
                fileFormat: .mp3
            ),
            song(
                id: "a",
                title: "First",
                artistName: "Zulu",
                albumTitle: "Alpha",
                fileFormat: .flac
            ),
        ]

        #expect(sortedIDs(songs, by: .title) == ["a", "b"])
        #expect(sortedIDs(songs, by: .artist) == ["b", "a"])
        #expect(sortedIDs(songs, by: .artistDescending) == ["a", "b"])
        #expect(sortedIDs(songs, by: .album) == ["a", "b"])
        #expect(sortedIDs(songs, by: .albumDescending) == ["b", "a"])
        #expect(sortedIDs(songs, by: .format) == ["a", "b"])
        #expect(sortedIDs(songs, by: .formatDescending) == ["b", "a"])
    }

    @Test("Album sorting keeps each album grouped in disc and track order")
    func albumSortingFollowsTrackOrder() {
        // Hash-like IDs deliberately disagree with track order, as with
        // the tracks split out of a single-file CUE album.
        func track(
            _ id: String,
            _ number: Int?,
            disc: Int? = nil,
            album: String = "Red Flag",
            albumID: String = "album-a"
        ) -> Song {
            var result = song(id: id, title: "T\(id)", albumTitle: album)
            result.albumID = albumID
            result.trackNumber = number
            result.discNumber = disc
            return result
        }
        let songs = [
            track("f3", 3),
            track("a8", 1, disc: 2),
            track("09", 2),
            track("7c", 1),
            track("b1", nil),
            track("2e", 2, albumID: "album-b"),
            track("d4", 1, albumID: "album-b"),
            track("55", 1, album: "Alpha", albumID: "album-c"),
        ]

        #expect(sortedIDs(songs, by: .album) == [
            "55", "7c", "09", "f3", "b1", "a8", "d4", "2e",
        ])
        #expect(sortedIDs(songs, by: .albumDescending) == [
            "d4", "2e", "7c", "09", "f3", "b1", "a8", "55",
        ])
    }

    @Test("Sorts table metrics, server counters, and downloaded state in both directions")
    func sortsMacTableColumns() {
        let songs = [
            song(
                id: "a", title: "A", sourceID: "z-source", duration: 60,
                serverPlayCount: 2, year: 2020, bitRate: 320, bitDepth: 24
            ),
            song(
                id: "b", title: "B", sourceID: "a-source", duration: 180,
                serverPlayCount: 10, year: 2024, bitRate: 1_411, bitDepth: 16
            ),
            song(id: "c", title: "C", sourceID: "z-source", duration: 120),
        ]
        let values = SongListSortValues(
            playCountsBySongID: ["a": 4, "b": 1, "c": 7],
            downloadedSongIDs: ["b"],
            sourceNamesByID: ["a-source": "Alpha", "z-source": "Zulu"]
        )

        #expect(sortedIDs(songs, by: .duration, values: values) == ["a", "c", "b"])
        #expect(sortedIDs(songs, by: .durationDescending, values: values) == ["b", "c", "a"])
        #expect(sortedIDs(songs, by: .playCount, values: values) == ["b", "a", "c"])
        #expect(sortedIDs(songs, by: .playCountDescending, values: values) == ["c", "a", "b"])
        #expect(sortedIDs(songs, by: .serverPlayCount, values: values) == ["a", "b", "c"])
        #expect(sortedIDs(songs, by: .serverPlayCountDescending, values: values) == ["b", "a", "c"])
        #expect(sortedIDs(songs, by: .source, values: values) == ["b", "a", "c"])
        #expect(sortedIDs(songs, by: .sourceDescending, values: values) == ["a", "c", "b"])
        #expect(sortedIDs(songs, by: .yearDescending, values: values) == ["b", "a", "c"])
        #expect(sortedIDs(songs, by: .bitRate, values: values) == ["a", "b", "c"])
        #expect(sortedIDs(songs, by: .bitDepthDescending, values: values) == ["a", "b", "c"])
        #expect(sortedIDs(songs, by: .downloadedFirst, values: values) == ["b", "a", "c"])
        #expect(sortedIDs(songs, by: .downloaded, values: values) == ["a", "c", "b"])
    }

    @Test("Caches every visited order for the current scope version")
    func cachesEveryVisitedOrder() async {
        let store = SongListSnapshotStore()
        let version = SongListSnapshotVersion(
            collectionRevision: 1,
            replacementToken: UUID()
        )
        let songs = [
            song(id: "a", title: "Zulu", artistName: "Alpha"),
            song(id: "b", title: "Alpha", artistName: "Zulu"),
        ]

        guard let title = await store.snapshot(
                  scopeKey: "library",
                  version: version,
                  order: .title,
                  songs: songs
              ),
              let artist = await store.snapshot(
                  scopeKey: "library",
                  version: version,
                  order: .artist,
                  songs: songs
              ),
              let titleAgain = await store.snapshot(
                  scopeKey: "library",
                  version: version,
                  order: .title,
                  songs: songs
              )
        else {
            Issue.record("Snapshot build was unexpectedly cancelled")
            return
        }

        #expect(title !== artist)
        #expect(title === titleAgain)
        #expect(title.rows.map(\.id) == ["b", "a"])
        #expect(artist.rows.map(\.id) == ["a", "b"])
    }

    @Test("Evicts every order when a scope version changes")
    func evictsChangedScopeVersion() async {
        let store = SongListSnapshotStore()
        let firstVersion = SongListSnapshotVersion(
            collectionRevision: 1,
            replacementToken: UUID()
        )
        let secondVersion = SongListSnapshotVersion(
            collectionRevision: 2,
            replacementToken: UUID()
        )
        let songs = [song(id: "a", title: "Alpha")]

        guard let first = await store.snapshot(
            scopeKey: "library",
            version: firstVersion,
            order: .title,
            songs: songs
        ) else {
            Issue.record("First snapshot build was unexpectedly cancelled")
            return
        }
        _ = await store.snapshot(
            scopeKey: "library",
            version: secondVersion,
            order: .title,
            songs: songs
        )
        guard let rebuilt = await store.snapshot(
            scopeKey: "library",
            version: firstVersion,
            order: .title,
            songs: songs
        ) else {
            Issue.record("Rebuilt snapshot was unexpectedly cancelled")
            return
        }

        #expect(first !== rebuilt)
    }

    @Test("Supplemental updates preserve unrelated in-flight sort versions")
    func isolatesSupplementalSortVersions() {
        var current = SongListSortValuesVersion()
        let requested = current
        current.invalidate(.downloaded)

        for order in LibrarySongSortOrder.allCases {
            if order.criterion == .downloaded {
                #expect(current.revision(for: order) != requested.revision(for: order))
            } else {
                #expect(current.revision(for: order) == requested.revision(for: order))
            }
        }
        #expect(current.revision(for: .downloaded) == current.revision(for: .downloadedFirst))
        #expect(current.revision(for: .title) == nil)
    }

    @Test("Refreshing one supplemental column preserves other cached orders", arguments: [
        LibrarySongSortCriterion.playCount, .downloaded, .source,
    ])
    func refreshesOnlyChangedSupplementalColumn(_ changed: LibrarySongSortCriterion) async throws {
        let store = SongListSnapshotStore()
        let version = SongListSnapshotVersion(collectionRevision: 1, replacementToken: UUID())
        var valuesVersion = SongListSortValuesVersion()
        let songs = [
            song(id: "a", title: "Alpha", sourceID: "first"),
            song(id: "b", title: "Beta", sourceID: "second"),
        ]
        let initial = SongListSortValues(
            playCountsBySongID: ["a": 5, "b": 1],
            downloadedSongIDs: ["a"],
            sourceNamesByID: ["first": "Alpha", "second": "Zulu"]
        )
        let orders: [LibrarySongSortOrder] = [.title, .playCountDescending, .downloadedFirst, .source]
        var cached: [LibrarySongSortOrder: SongListSnapshot] = [:]
        for order in orders {
            cached[order] = try #require(await store.snapshot(
                scopeKey: "library", version: version, order: order, songs: songs,
                sortValues: initial, sortValuesVersion: valuesVersion
            ))
            #expect(cached[order]?.orderedSongIDs == ["a", "b"])
        }

        valuesVersion.invalidate(changed)
        let updated = SongListSortValues(
            playCountsBySongID: changed == .playCount ? ["a": 1, "b": 5] : initial.playCountsBySongID,
            downloadedSongIDs: changed == .downloaded ? ["b"] : initial.downloadedSongIDs,
            sourceNamesByID: changed == .source
                ? ["first": "Zulu", "second": "Alpha"] : initial.sourceNamesByID
        )
        for order in orders {
            let rebuilt = try #require(await store.snapshot(
                scopeKey: "library", version: version, order: order, songs: songs,
                sortValues: updated, sortValuesVersion: valuesVersion
            ))
            if order.criterion == changed {
                #expect(rebuilt !== cached[order])
                #expect(rebuilt.orderedSongIDs == ["b", "a"])
            } else {
                #expect(rebuilt === cached[order])
                #expect(rebuilt.orderedSongIDs == ["a", "b"])
            }
        }
    }

    @Test("Recreated views cannot reuse another view's supplemental values")
    func isolatesRecreatedViewSortValues() async throws {
        let store = SongListSnapshotStore()
        let version = SongListSnapshotVersion(collectionRevision: 1, replacementToken: UUID())
        let songs = [song(id: "a", title: "Alpha"), song(id: "b", title: "Beta")]
        let first = try #require(await store.snapshot(
            scopeKey: "library", version: version, order: .downloadedFirst, songs: songs,
            sortValues: SongListSortValues(downloadedSongIDs: ["a"]),
            sortValuesVersion: SongListSortValuesVersion()
        ))
        let reopened = try #require(await store.snapshot(
            scopeKey: "library", version: version, order: .downloadedFirst, songs: songs,
            sortValues: SongListSortValues(downloadedSongIDs: ["b"]),
            sortValuesVersion: SongListSortValuesVersion()
        ))
        #expect(first.orderedSongIDs == ["a", "b"])
        #expect(reopened.orderedSongIDs == ["b", "a"])
    }

    @Test("Handles a large library without embedding songs in row identity")
    func handlesLargeLibrary() {
        let songs = (0..<20_000).map { index in
            song(
                id: "song-\(index)",
                title: String(format: "%05d", 20_000 - index),
                sourceID: "source-\(index % 4)",
                duration: 180
            )
        }

        let clock = ContinuousClock()
        let started = clock.now
        let snapshot = SongListSnapshotBuilder.build(songs: songs, order: .title)
        let elapsed = started.duration(to: clock.now)

        #expect(snapshot.rows.count == 20_000)
        #expect(snapshot.songIDs.count == 20_000)
        #expect(snapshot.rows.first?.id == "song-19999")
        #expect(snapshot.rows.last?.id == "song-0")
        #expect(snapshot.totalDuration == 3_600_000)
        // A generous strategy guard catches accidental main-style quadratic
        // work without pretending to be device frame-rate evidence.
        #expect(elapsed < .seconds(5))
    }

    @Test("Builds a 7,300-song snapshot within the strategy budget")
    func handlesFeedbackSizedLibrary() {
        let songs = (0..<7_300).map { index in
            song(
                id: "feedback-song-\(index)",
                title: String(format: "%05d", 7_300 - index),
                sourceID: "source-\(index % 3)"
            )
        }

        let clock = ContinuousClock()
        let started = clock.now
        let snapshot = SongListSnapshotBuilder.build(songs: songs, order: .title)
        let elapsed = started.duration(to: clock.now)

        #expect(snapshot.rows.count == 7_300)
        #expect(snapshot.rows.first?.id == "feedback-song-7299")
        #expect(snapshot.rows.last?.id == "feedback-song-0")
        #expect(elapsed < .seconds(3))
    }

    @Test("Build cancellation stops obsolete sort work cooperatively")
    func cancelsObsoleteBuild() async {
        let songs = (0..<20_000).map { index in
            song(
                id: "cancel-song-\(index)",
                title: String(format: "%05d", 20_000 - index)
            )
        }
        let task = Task.detached { () -> SongListSnapshot? in
            // Enter the builder with an already-cancelled task so its first
            // cooperative checkpoint is deterministic rather than timing based.
            while !Task.isCancelled {
                await Task.yield()
            }
            return try? SongListSnapshotBuilder.buildCancellable(
                songs: songs,
                order: .artist
            )
        }

        task.cancel()
        let result = await task.value

        #expect(result == nil)
    }

    @Test("Empty and single-song libraries produce complete snapshots")
    func handlesEmptyAndSingleSongLibraries() {
        let empty = SongListSnapshotBuilder.build(songs: [], order: .artist)
        let single = SongListSnapshotBuilder.build(
            songs: [song(id: "only", title: "Only")],
            order: .album
        )

        #expect(empty.rows.isEmpty)
        #expect(empty.songIDs.isEmpty)
        #expect(empty.sourcePartitionsByID.isEmpty)
        #expect(single.rows.map(\.id) == ["only"])
        #expect(single.orderedSongIDs == ["only"])
        #expect(single.sourcePartition(forSourceID: "source")?.rows.map(\.id) == ["only"])
        #expect(single.sourcePartition(forSourceID: "source")?.rows.map(\.offset) == [0])
        #expect(single.sourcePartition(forSourceID: "source")?.playableCount == 1)
    }

    @Test("Repeated selection of the active order is a no-op")
    func ignoresSameSortOrder() {
        #expect(!SongListSortProgressState.acceptsChange(from: .title, to: .title))
        #expect(SongListSortProgressState.acceptsChange(from: .title, to: .artist))
        #expect(!SongListSortProgressState.shouldAwaitFeedbackDeadline(songCount: 1))
        #expect(!SongListSortProgressState.shouldAwaitFeedbackDeadline(songCount: 4_999))
        #expect(SongListSortProgressState.shouldAwaitFeedbackDeadline(songCount: 7_300))
        #expect(SongListSortProgressState.shouldAwaitFeedbackDeadline(songCount: 20_000))
    }

    @Test("Selecting a sort criterion toggles only the active criterion")
    func criterionSelectionTogglesDirection() {
        #expect(LibrarySongSortOrder.title.selecting(.title) == .titleDescending)
        #expect(LibrarySongSortOrder.titleDescending.selecting(.title) == .title)
        #expect(LibrarySongSortOrder.title.selecting(.dateAdded) == .dateAdded)
        #expect(LibrarySongSortOrder.dateAdded.selecting(.dateAdded) == .dateAddedOldest)
        #expect(LibrarySongSortOrder.title.selecting(.sourceDate) == .sourceDate)
        #expect(LibrarySongSortOrder.sourceDate.selecting(.sourceDate) == .sourceDateOldest)
        #expect(LibrarySongSortOrder.sourceDateOldest.selecting(.sourceDate) == .sourceDate)
        #expect(LibrarySongSortOrder.dateAddedOldest.selecting(.artist) == .artist)
        #expect(LibrarySongSortOrder.title.selecting(.playCount) == .playCountDescending)
        #expect(LibrarySongSortOrder.playCountDescending.selecting(.playCount) == .playCount)
        #expect(LibrarySongSortOrder.title.selecting(.downloaded) == .downloadedFirst)
        #expect(LibrarySongSortOrder.downloadedFirst.selecting(.downloaded) == .downloaded)
    }

    @Test("Sort preference defaults safely and repairs unknown values")
    func sortPreferenceDefaultsAndRepairs() throws {
        let suiteName = "LibrarySongSortOrderPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(LibrarySongSortOrderPreference.load(from: defaults) == .title)
        #expect(defaults.string(forKey: LibrarySongSortOrderPreference.storageKey) == "title")

        defaults.set("retired-sort-order", forKey: LibrarySongSortOrderPreference.storageKey)
        #expect(LibrarySongSortOrderPreference.load(from: defaults) == .title)
        #expect(defaults.string(forKey: LibrarySongSortOrderPreference.storageKey) == "title")
    }

    @Test("Sort preference preserves criterion and direction across defaults instances")
    func sortPreferencePersistsCompleteOrder() throws {
        let suiteName = "LibrarySongSortOrderPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        LibrarySongSortOrderPreference.save(.albumDescending, to: defaults)
        let reopened = try #require(UserDefaults(suiteName: suiteName))

        #expect(LibrarySongSortOrderPreference.load(from: reopened) == .albumDescending)
    }

    @Test("Alphabetic sorts expose a complete directional section index")
    func alphabeticSortBuildsSectionIndex() {
        let songs = [
            song(id: "a", title: "Atlas"),
            song(id: "d", title: "Drift"),
            song(id: "z", title: "Zenith"),
        ]

        let ascending = SongListSnapshotBuilder.build(songs: songs, order: .title)
        #expect(ascending.sectionIndexEntries.count == 26)
        #expect(ascending.sectionIndexEntries.first?.label == "A")
        #expect(ascending.sectionIndexEntries.last?.label == "Z")
        #expect(ascending.sectionIndexEntries.first(where: { $0.label == "B" })?.rowOffset == 1)
        #expect(ascending.sectionIndexEntries.first(where: { $0.label == "D" })?.rowOffset == 1)
        #expect(ascending.sectionIndexEntries.first(where: { $0.label == "Y" })?.rowOffset == 2)

        let descending = SongListSnapshotBuilder.build(songs: songs, order: .titleDescending)
        #expect(descending.sectionIndexEntries.count == 26)
        #expect(descending.sectionIndexEntries.first?.label == "Z")
        #expect(descending.sectionIndexEntries.last?.label == "A")
        #expect(descending.sectionIndexEntries.first(where: { $0.label == "Y" })?.rowOffset == 1)
        #expect(descending.sectionIndexEntries.first(where: { $0.label == "B" })?.rowOffset == 2)

        let chronological = SongListSnapshotBuilder.build(songs: songs, order: .dateAdded)
        #expect(chronological.sectionIndexEntries.isEmpty)

        let localized = SongListSnapshotBuilder.build(
            songs: [
                song(id: "number", title: "123 Intro"),
                song(id: "accent", title: "Élan"),
                song(id: "han", title: "北京"),
            ],
            order: .title
        )
        let offsetsByID = Dictionary(uniqueKeysWithValues: localized.rows.map { ($0.id, $0.offset) })
        #expect(
            localized.sectionIndexEntries.first(where: { $0.label == "#" })?.rowOffset
                == offsetsByID["number"]
        )
        #expect(
            localized.sectionIndexEntries.first(where: { $0.label == "B" })?.rowOffset
                == offsetsByID["han"]
        )
        #expect(
            localized.sectionIndexEntries.first(where: { $0.label == "E" })?.rowOffset
                == offsetsByID["accent"]
        )

        let missingArtist = SongListSnapshotBuilder.build(
            songs: [song(id: "unknown", title: "Unknown")],
            order: .artist
        )
        #expect(missingArtist.sectionIndexEntries == [
            SongListSectionIndexEntry(label: "#", rowOffset: 0),
        ])
    }

    @Test("Section index hit testing clamps drags and rejects invalid geometry")
    func sectionIndexHitTestingIsSafe() {
        #expect(SongListSectionIndexHitTesting.index(
            at: -50,
            railOriginY: 10,
            railHeight: 520,
            entryCount: 26
        ) == 0)
        #expect(SongListSectionIndexHitTesting.index(
            at: 30,
            railOriginY: 10,
            railHeight: 520,
            entryCount: 26
        ) == 1)
        #expect(SongListSectionIndexHitTesting.index(
            at: 1_000,
            railOriginY: 10,
            railHeight: 520,
            entryCount: 26
        ) == 25)

        #expect(SongListSectionIndexHitTesting.index(
            at: .nan,
            railOriginY: 0,
            railHeight: 520,
            entryCount: 26
        ) == nil)
        #expect(SongListSectionIndexHitTesting.index(
            at: 100,
            railOriginY: 0,
            railHeight: 0,
            entryCount: 26
        ) == nil)
        #expect(SongListSectionIndexHitTesting.index(
            at: 100,
            railOriginY: 0,
            railHeight: 520,
            entryCount: 0
        ) == nil)
    }

    @Test("Delayed feedback follows the latest generation without flicker")
    func feedbackUsesLatestGeneration() {
        var state = SongListSortProgressState()

        let firstBeganVisible = state.begin(generation: 1, order: .title)
        let firstReveal = state.reveal(generation: 1)
        #expect(!firstBeganVisible)
        #expect(firstReveal)
        #expect(state.isVisible)
        let secondBeganVisible = state.begin(generation: 2, order: .artist)
        #expect(secondBeganVisible)
        #expect(state.isVisible)
        #expect(state.order == .artist)
        let staleReveal = state.reveal(generation: 1)
        let stalePublication = state.markPublished(generation: 1)
        #expect(!staleReveal)
        #expect(!stalePublication)
        #expect(state.generation == 2)
    }

    @Test("Fast publication completes before delayed feedback appears")
    func fastPublicationDoesNotFlashFeedback() {
        var state = SongListSortProgressState()

        state.begin(generation: 3, order: .dateAdded)
        let announcedCompletion = state.markPublished(generation: 3)
        #expect(!announcedCompletion)
        #expect(state.phase == .published)
        #expect(!state.isVisible)
        let finished = state.finish(generation: 3)
        let revealAfterFinish = state.reveal(generation: 3)
        #expect(finished)
        #expect(!revealAfterFinish)
    }

    @Test("Feedback remains visible while publication waits for scrolling")
    func feedbackWaitsForPublication() {
        var state = SongListSortProgressState()

        state.begin(generation: 7, order: .album)
        let revealed = state.reveal(generation: 7)
        let waited = state.markWaitingForPublication(generation: 7)
        #expect(revealed)
        #expect(waited)
        #expect(state.phase == .waitingForPublication)
        #expect(state.isVisible)
        let announcedCompletion = state.markPublished(generation: 7)
        #expect(announcedCompletion)
        #expect(state.phase == .published)
        #expect(state.isVisible)
        let finished = state.finish(generation: 7)
        #expect(finished)
        #expect(state.phase == .idle)
        #expect(!state.isVisible)
    }

    @Test("Selection cancellation clears only the current sort generation")
    func cancellationIsGenerationBound() {
        var state = SongListSortProgressState()

        state.begin(generation: 11, order: .format)
        let staleCancellation = state.cancel(generation: 10)
        #expect(!staleCancellation)
        #expect(state.phase == .requested)
        let currentCancellation = state.cancel(generation: 11)
        #expect(currentCancellation)
        #expect(state.phase == .idle)
        #expect(state.order == nil)
    }

    private func song(
        id: String,
        title: String,
        artistName: String? = nil,
        albumTitle: String? = nil,
        sourceID: String = "source",
        duration: TimeInterval = 180,
        filePath: String? = nil,
        lastModified: Date? = nil,
        dateAdded: Date = Date(timeIntervalSince1970: 0),
        serverPlayCount: Int? = nil,
        year: Int? = nil,
        bitRate: Int? = nil,
        bitDepth: Int? = nil,
        fileFormat: AudioFormat = .flac
    ) -> Song {
        Song(
            id: id,
            title: title,
            albumTitle: albumTitle,
            artistName: artistName,
            duration: duration,
            fileFormat: fileFormat,
            filePath: filePath ?? "/Music/\(id).\(fileFormat.rawValue)",
            sourceID: sourceID,
            bitRate: bitRate,
            bitDepth: bitDepth,
            year: year,
            lastModified: lastModified,
            dateAdded: dateAdded,
            serverPlayCount: serverPlayCount
        )
    }

    private func sortedIDs(
        _ songs: [Song],
        by order: LibrarySongSortOrder,
        values: SongListSortValues = .empty
    ) -> [String] {
        SongListSnapshotBuilder.build(
            songs: songs,
            order: order,
            sortValues: values
        ).rows.map(\.id)
    }
}
