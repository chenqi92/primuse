import Testing
@testable import PrimuseKit

@Suite("Library index maintenance")
struct LibraryIndexMaintenancePolicyTests {
    @Test("latest-only state never starts overlapping work")
    func latestOnlySingleFlight() {
        var state = LatestOnlyLibraryIndexWorkState()

        #expect(state.submit(generation: 1) == .start)
        #expect(state.submit(generation: 2) == .replacePending)
        #expect(state.submit(generation: 3) == .replacePending)
        #expect(state.activeGeneration == 1)
        #expect(state.pendingGeneration == 3)

        #expect(state.complete(generation: 2) == nil)
        #expect(state.activeGeneration == 1)
        #expect(state.complete(generation: 1) == 3)
        #expect(state.activeGeneration == 3)
        #expect(state.pendingGeneration == nil)
        #expect(state.complete(generation: 3) == nil)
        #expect(state.activeGeneration == nil)
    }

    @Test("technical metadata does not regroup albums and artists")
    func technicalMetadataDoesNotInvalidateDerivedCollections() {
        let original = song()
        var updated = original
        updated.bitRate = 1_536
        updated.sampleRate = 48_000
        updated.bitDepth = 24

        #expect(!LibraryIndexMaintenancePolicy.derivedCollectionsChanged(
            from: original,
            to: updated
        ))
    }

    @Test("every derived collection and artwork input invalidates caches")
    func derivedInputsInvalidateCaches() {
        let original = song()
        var variants: [Song] = []

        var artist = original
        artist.artistName = "Guest"
        variants.append(artist)

        var sourceArtists = original
        sourceArtists.sourceArtistNames = ["Artist", "Guest"]
        variants.append(sourceArtists)

        var albumArtist = original
        albumArtist.albumArtistName = "Various Artists"
        variants.append(albumArtist)

        var album = original
        album.albumTitle = "Second Album"
        variants.append(album)

        var year = original
        year.year = 2026
        variants.append(year)

        var genre = original
        genre.genre = "Ambient"
        variants.append(genre)

        var duration = original
        duration.duration = 241
        variants.append(duration)

        var source = original
        source.sourceID = "source-b"
        variants.append(source)

        var artwork = original
        artwork.artistArtworkFileName = "artist.jpg"
        variants.append(artwork)

        var cover = original
        cover.coverArtFileName = "cover.jpg"
        variants.append(cover)

        var disc = original
        disc.discNumber = 2
        variants.append(disc)

        var track = original
        track.trackNumber = 9
        variants.append(track)

        for variant in variants {
            #expect(LibraryIndexMaintenancePolicy.derivedCollectionsChanged(
                from: original,
                to: variant
            ))
        }
    }

    @Test("deferred maintenance has a bounded maximum latency")
    func deferredMaintenanceIsBounded() {
        #expect(LibraryIndexMaintenancePolicy.maximumDeferredMaintenanceInterval == 60)
    }

    @Test("repeated deltas stay bounded by unique changed rows")
    func repeatedDeltasStayIncremental() {
        var state = IncrementalLibrarySearchMutationState()

        for _ in 0..<1_000 {
            state.recordUpserts(["song-a", "song-b"])
        }

        #expect(state.touchedRowCount == 2)
        #expect(state.upsertIDs == ["song-a", "song-b"])
        #expect(state.deletingIDs.isEmpty)
    }

    @Test("latest row operation wins without full reconciliation")
    func latestMutationWins() {
        var state = IncrementalLibrarySearchMutationState()

        state.recordUpserts(["song-a", "song-b"])
        state.recordDeletions(["song-a", "song-c"])
        state.recordUpserts(["song-c"])

        #expect(state.upsertIDs == ["song-b", "song-c"])
        #expect(state.deletingIDs == ["song-a"])
        #expect(state.touchedRowCount == 3)
    }

    @Test("incremental completion never hides a recovery gap")
    func completionRequiresContiguousGeneration() {
        #expect(LibraryIndexMaintenancePolicy.canCompleteIncrementally(
            completedGeneration: 41,
            firstPendingGeneration: 42
        ))
        #expect(!LibraryIndexMaintenancePolicy.canCompleteIncrementally(
            completedGeneration: 41,
            firstPendingGeneration: 43
        ))
        #expect(LibraryIndexMaintenancePolicy.canCompleteIncrementally(
            completedGeneration: .max,
            firstPendingGeneration: 1
        ))
    }

    private func song() -> Song {
        Song(
            id: "song",
            title: "Title",
            albumTitle: "Album",
            artistName: "Artist",
            sourceArtistNames: ["Artist"],
            albumArtistName: "Artist",
            duration: 240,
            fileFormat: .flac,
            filePath: "music/song.flac",
            sourceID: "source-a",
            genre: "Pop",
            year: 2025
        )
    }
}
