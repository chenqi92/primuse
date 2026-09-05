import Foundation
import Testing
@testable import PrimuseKit

@Suite("Wi-Fi transfer library index", .serialized)
struct WiFiTransferLibraryIndexTests {
    private static let sourceID = "large-library"
    private static let otherSourceID = "other-library"
    private static let fixture = makeLargeLibrary()

    @Test("Indexes 100k songs and pages a huge album without omissions")
    func indexesAndPagesLargeLibrary() async throws {
        let clock = ContinuousClock()
        let buildStarted = clock.now
        let index = try await WiFiTransferLibraryIndex.build(
            sourceID: Self.sourceID,
            sourceType: .smb,
            songs: Self.fixture.songs,
            query: ""
        )
        let buildElapsed = buildStarted.duration(to: clock.now)

        #expect(index.sourceID == Self.sourceID)
        #expect(index.songCount == Self.fixture.targetSongCount)
        #expect(index.eligibleCount == Self.fixture.targetEligibleCount)
        #expect(index.albums.count == index.albumsByID.count)

        let hugeAlbum = try #require(index.albumsByID[Self.fixture.hugeGroup])
        #expect(hugeAlbum.count == Self.fixture.hugeSongIDs.count)
        #expect(hugeAlbum.eligibleCount == Self.fixture.hugeEligibleIDs.count)

        let sharedAlbum = try #require(index.albumsByID[Self.fixture.sharedTargetGroup])
        #expect(sharedAlbum.count == 2)
        #expect(index.albumsByID[Self.fixture.sharedOtherGroup] == nil)

        let ungrouped = try #require(index.albumsByID[Self.fixture.ungroupedGroup])
        #expect(ungrouped.count == 1)
        #expect(ungrouped.eligibleCount == 1)

        let pages = WiFiTransferLibraryPages(index: index)
        let firstPageStarted = clock.now
        let firstPage = try await pages.page(in: Self.fixture.hugeGroup, offset: 0)
        let firstPageElapsed = firstPageStarted.duration(to: clock.now)

        let laterPageStarted = clock.now
        let laterPage = try await pages.page(in: Self.fixture.hugeGroup, offset: 4_200)
        let laterPageElapsed = laterPageStarted.duration(to: clock.now)

        #expect(firstPage.count == WiFiTransferLibraryPages.pageSize)
        #expect(laterPage.count == WiFiTransferLibraryPages.pageSize)
        #expect(try await pages.page(in: Self.fixture.hugeGroup, offset: -50) == firstPage)
        #expect(try await pages.page(in: Self.fixture.hugeGroup, offset: 10_200).count == 51)
        #expect(try await pages.page(in: Self.fixture.hugeGroup, offset: 10_251).isEmpty)
        #expect(try await pages.page(in: Self.fixture.hugeGroup, offset: .max).isEmpty)

        var pagedIDs: [String] = []
        for offset in stride(
            from: 0,
            to: Self.fixture.hugeSongIDs.count,
            by: WiFiTransferLibraryPages.pageSize
        ) {
            pagedIDs += try await pages.page(in: Self.fixture.hugeGroup, offset: offset)
        }
        #expect(pagedIDs.count == Self.fixture.hugeSongIDs.count)
        #expect(Set(pagedIDs).count == pagedIDs.count)
        #expect(Set(pagedIDs) == Set(Self.fixture.hugeSongIDs))
        #expect(pagedIDs == Self.fixture.hugeOrderedSongIDs)

        let twoSelected = Set(Self.fixture.selectableEligibleIDs.prefix(2))
        let counts = index.selectionCounts(in: twoSelected.union(["not-in-index"]))
        #expect(counts[Self.fixture.selectableGroup] == 2)
        #expect(counts.values.reduce(0, +) == 2)
        #expect(index.group(forEligibleSongID: Self.fixture.selectableEligibleIDs[0]) == Self.fixture.selectableGroup)
        #expect(index.group(forEligibleSongID: Self.fixture.selectableRestrictedID) == nil)

        let selectionStarted = clock.now
        let selectedAlbum = try index.toggling(
            Self.fixture.selectableGroup,
            in: twoSelected.union(["selection-outside-index"])
        )
        let selectionElapsed = selectionStarted.duration(to: clock.now)
        #expect(Set(Self.fixture.selectableEligibleIDs).isSubset(of: selectedAlbum))
        #expect(selectedAlbum.count == Self.fixture.selectableEligibleIDs.count + 1)

        let deselectedAlbum = try index.toggling(Self.fixture.selectableGroup, in: selectedAlbum)
        #expect(deselectedAlbum == ["selection-outside-index"])

        var selection = Set([Self.fixture.selectableEligibleIDs[0]])
        let originalSelection = selection
        #expect(throws: WiFiTransferError.tooLarge) {
            selection = try index.toggling(Self.fixture.hugeGroup, in: selection)
        }
        #expect(selection == originalSelection)
        #expect(throws: WiFiTransferError.tooLarge) {
            selection = try index.toggling(nil, in: selection)
        }
        #expect(selection == originalSelection)

        recordPerformance(
            build100k: buildElapsed,
            hugeAlbumFirstPage: firstPageElapsed,
            hugeAlbumCachedPage: laterPageElapsed,
            search100k: nil,
            batchSelection: selectionElapsed
        )
        #expect(buildElapsed < .seconds(8))
        #expect(firstPageElapsed < .seconds(2))
        #expect(laterPageElapsed < .milliseconds(500))
        #expect(selectionElapsed < .milliseconds(500))
    }

    @Test("Search filters the source snapshot and retains eligibility")
    func searchesLargeLibrary() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let index = try await WiFiTransferLibraryIndex.build(
            sourceID: Self.sourceID,
            sourceType: .smb,
            songs: Self.fixture.songs,
            query: "  needle  "
        )
        let elapsed = started.duration(to: clock.now)

        #expect(index.songCount == 2)
        #expect(index.eligibleCount == 1)
        #expect(index.albums.count == 1)
        let album = try #require(index.albums.first)
        #expect(album.count == 2)
        #expect(album.eligibleCount == 1)
        #expect(index.group(forEligibleSongID: Self.fixture.searchEligibleID) == album.id)
        #expect(index.group(forEligibleSongID: Self.fixture.searchRestrictedID) == nil)
        #expect(index.group(forEligibleSongID: Self.fixture.foreignSearchID) == nil)

        let selected = try index.toggling(nil, in: [])
        #expect(selected == [Self.fixture.searchEligibleID])

        recordPerformance(
            build100k: nil,
            hugeAlbumFirstPage: nil,
            hugeAlbumCachedPage: nil,
            search100k: elapsed,
            batchSelection: nil
        )
        #expect(elapsed < .seconds(8))
    }

    @Test("Cancelled indexing stops at a cooperative checkpoint")
    func cancelsIndexBuild() async {
        let songs = Self.fixture.songs
        let task = Task.detached { () throws -> WiFiTransferLibraryIndex in
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await WiFiTransferLibraryIndex.build(
                sourceID: Self.sourceID,
                sourceType: .smb,
                songs: songs,
                query: ""
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("100k-row scroll windows remain bounded at every library position")
    func keepsLargeScrollWindowsBounded() {
        let totalCount = 100_000
        let positions = [-500, 0, 1, 15, 16, 9_999, 50_000, 99_998, 99_999, 150_000]
        let viewports = [320.0, 785.5, 1_440.0]
        let rowHeights = [32.0, 40.0, 64.0]

        for viewport in viewports {
            for rowHeight in rowHeights {
                let maximumWindowCount = Int(ceil(viewport / rowHeight))
                    + SongListScrollWindow.rowStride + 17
                for position in positions {
                    let range = SongListScrollWindow.range(
                        totalCount: totalCount,
                        firstVisibleRow: position,
                        viewportHeight: viewport,
                        rowHeight: rowHeight
                    )
                    let clampedPosition = min(max(0, position), totalCount - 1)

                    #expect(range.contains(clampedPosition))
                    #expect(range.lowerBound >= 0)
                    #expect(range.upperBound <= totalCount)
                    #expect(range.count <= maximumWindowCount)
                }
            }
        }
    }

    private struct LargeLibraryFixture: Sendable {
        let songs: [Song]
        let targetSongCount: Int
        let targetEligibleCount: Int
        let hugeGroup: WiFiTransferLibraryGroupID
        let hugeSongIDs: [String]
        let hugeEligibleIDs: [String]
        let hugeOrderedSongIDs: [String]
        let selectableGroup: WiFiTransferLibraryGroupID
        let selectableEligibleIDs: [String]
        let selectableRestrictedID: String
        let sharedTargetGroup: WiFiTransferLibraryGroupID
        let sharedOtherGroup: WiFiTransferLibraryGroupID
        let ungroupedGroup: WiFiTransferLibraryGroupID
        let searchEligibleID: String
        let searchRestrictedID: String
        let foreignSearchID: String
    }

    private static func makeLargeLibrary() -> LargeLibraryFixture {
        var songs: [Song] = []
        songs.reserveCapacity(100_000)
        var targetSongCount = 0
        var targetEligibleCount = 0

        func append(_ song: Song, eligible: Bool) {
            songs.append(song)
            guard song.sourceID == sourceID else { return }
            targetSongCount += 1
            if eligible { targetEligibleCount += 1 }
        }

        var hugeSongIDs: [String] = []
        var hugeEligibleIDs: [String] = []
        hugeSongIDs.reserveCapacity(10_251)
        hugeEligibleIDs.reserveCapacity(10_251)
        for number in 0..<10_251 {
            let id = String(format: "huge-%05d", number)
            let restricted = number.isMultiple(of: 250)
            let song = makeSong(
                id: id,
                title: String(format: "Huge Track %05d", 10_251 - number),
                albumTitle: "Huge Album",
                artistName: "Track Artist \(number % 7)",
                albumArtistName: "Huge Album Artist",
                cueSheetPath: restricted ? "Huge Album/album.cue" : nil
            )
            append(song, eligible: !restricted)
            hugeSongIDs.append(id)
            if !restricted { hugeEligibleIDs.append(id) }
        }

        var selectableEligibleIDs: [String] = []
        var selectableRestrictedID = ""
        for number in 0..<125 {
            let id = String(format: "selectable-%03d", number)
            let restricted = number < 5
            append(
                makeSong(
                    id: id,
                    title: String(format: "Selectable Track %03d", number),
                    albumTitle: "Selectable Album",
                    artistName: "Guest \(number % 3)",
                    albumArtistName: "Selectable Artist",
                    cueSheetPath: restricted ? "Selectable Album/album.cue" : nil
                ),
                eligible: !restricted
            )
            if restricted {
                selectableRestrictedID = id
            } else {
                selectableEligibleIDs.append(id)
            }
        }

        let sharedTargetSongs = (0..<2).map { number in
            makeSong(
                id: "shared-target-\(number)",
                title: "Shared Target \(number)",
                albumTitle: "Shared Album",
                artistName: "Shared Artist"
            )
        }
        for song in sharedTargetSongs { append(song, eligible: true) }

        let sharedOtherSongs = (0..<3).map { number in
            makeSong(
                id: "shared-other-\(number)",
                title: "Shared Other \(number)",
                albumTitle: "Shared Album",
                artistName: "Shared Artist",
                sourceID: otherSourceID
            )
        }
        for song in sharedOtherSongs { append(song, eligible: true) }

        let ungroupedSong = makeSong(
            id: "ungrouped",
            title: "Loose Track",
            albumTitle: nil,
            artistName: nil
        )
        append(ungroupedSong, eligible: true)

        let searchEligible = makeSong(
            id: "needle-eligible",
            title: "Needle Song",
            albumTitle: "Search Album",
            artistName: "Search Artist"
        )
        let searchRestricted = makeSong(
            id: "needle-restricted",
            title: "Needle CUE Song",
            albumTitle: "Search Album",
            artistName: "Search Artist",
            cueSheetPath: "Search Album/album.cue"
        )
        let foreignSearch = makeSong(
            id: "needle-foreign",
            title: "Needle Foreign Song",
            albumTitle: "Search Album",
            artistName: "Search Artist",
            sourceID: otherSourceID
        )
        append(searchEligible, eligible: true)
        append(searchRestricted, eligible: false)
        append(foreignSearch, eligible: true)

        while songs.count < 100_000 {
            let number = songs.count
            let isForeign = number.isMultiple(of: 997)
            let isRestricted = number.isMultiple(of: 509)
            append(
                makeSong(
                    id: String(format: "filler-%06d", number),
                    title: String(format: "Library Track %06d", 100_000 - number),
                    albumTitle: "Filler Album \(number % 1_200)",
                    artistName: "Filler Track Artist \(number % 29)",
                    albumArtistName: "Filler Album Artist \(number % 41)",
                    sourceID: isForeign ? otherSourceID : sourceID,
                    cueSheetPath: isRestricted ? "Filler/album.cue" : nil
                ),
                eligible: !isRestricted
            )
        }

        let hugeGroup = WiFiTransferLibraryGroupID(song: songs[0])
        let selectableGroup = WiFiTransferLibraryGroupID(song: songs[10_251])
        let sharedTargetGroup = WiFiTransferLibraryGroupID(song: sharedTargetSongs[0])
        let sharedOtherGroup = WiFiTransferLibraryGroupID(song: sharedOtherSongs[0])
        let ungroupedGroup = WiFiTransferLibraryGroupID(song: ungroupedSong)
        let hugeIDSet = Set(hugeSongIDs)
        let hugeOrderedSongIDs = songs.lazy
            .filter { hugeIDSet.contains($0.id) }
            .sorted {
                let order = $0.title.localizedStandardCompare($1.title)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            .map(\.id)

        return LargeLibraryFixture(
            songs: songs,
            targetSongCount: targetSongCount,
            targetEligibleCount: targetEligibleCount,
            hugeGroup: hugeGroup,
            hugeSongIDs: hugeSongIDs,
            hugeEligibleIDs: hugeEligibleIDs,
            hugeOrderedSongIDs: hugeOrderedSongIDs,
            selectableGroup: selectableGroup,
            selectableEligibleIDs: selectableEligibleIDs,
            selectableRestrictedID: selectableRestrictedID,
            sharedTargetGroup: sharedTargetGroup,
            sharedOtherGroup: sharedOtherGroup,
            ungroupedGroup: ungroupedGroup,
            searchEligibleID: searchEligible.id,
            searchRestrictedID: searchRestricted.id,
            foreignSearchID: foreignSearch.id
        )
    }

    private static func makeSong(
        id: String,
        title: String,
        albumTitle: String?,
        artistName: String?,
        albumArtistName: String? = nil,
        sourceID: String = WiFiTransferLibraryIndexTests.sourceID,
        cueSheetPath: String? = nil
    ) -> Song {
        Song(
            id: id,
            title: title,
            albumTitle: albumTitle,
            artistName: artistName,
            albumArtistName: albumArtistName,
            duration: 180,
            fileFormat: .flac,
            filePath: "Music/\(id).flac",
            sourceID: sourceID,
            fileSize: 8 * 1_024 * 1_024,
            dateAdded: Date(timeIntervalSince1970: 0),
            cueSheetPath: cueSheetPath
        )
    }

    private func recordPerformance(
        build100k: Duration?,
        hugeAlbumFirstPage: Duration?,
        hugeAlbumCachedPage: Duration?,
        search100k: Duration?,
        batchSelection: Duration?
    ) {
        let measurements: [(String, Duration?)] = [
            ("build_100k_ms", build100k),
            ("huge_album_first_page_ms", hugeAlbumFirstPage),
            ("huge_album_cached_page_ms", hugeAlbumCachedPage),
            ("search_100k_ms", search100k),
            ("batch_selection_ms", batchSelection),
        ]
        let values = measurements.compactMap { name, duration in
            duration.map { "\(name)=\(String(format: "%.3f", milliseconds($0)))" }
        }
        print("WIFI_TRANSFER_LIBRARY_PERF \(values.joined(separator: " "))")
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
