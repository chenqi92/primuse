import Foundation
import Testing
@testable import PrimuseKit

@Suite("Large song-list snapshots")
struct SongListSnapshotTests {
    @Test("Builds sorted lightweight rows and aggregates")
    func buildsRowsAndAggregates() {
        let songs = [
            song(id: "b", title: "Beta", sourceID: "nas", duration: 120),
            song(id: "a", title: "Alpha", sourceID: "local", duration: 60),
            song(id: "c", title: "Gamma", sourceID: "nas", duration: -Double.infinity),
        ]

        let snapshot = SongListSnapshotBuilder.build(songs: songs, order: .title)

        #expect(snapshot.rows.map(\.id) == ["a", "b", "c"])
        #expect(snapshot.rows.map(\.offset) == [0, 1, 2])
        #expect(snapshot.songIDs == ["a", "b", "c"])
        #expect(snapshot.sourceCounts == ["local": 1, "nas": 2])
        #expect(snapshot.playableCount == 3)
        #expect(snapshot.totalDuration == 180)
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
        #expect(single.rows.map(\.id) == ["only"])
        #expect(single.orderedSongIDs == ["only"])
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
        #expect(LibrarySongSortOrder.dateAddedOldest.selecting(.artist) == .artist)
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
        dateAdded: Date = Date(timeIntervalSince1970: 0),
        fileFormat: AudioFormat = .flac
    ) -> Song {
        Song(
            id: id,
            title: title,
            albumTitle: albumTitle,
            artistName: artistName,
            duration: duration,
            fileFormat: fileFormat,
            filePath: "/Music/\(id).\(fileFormat.rawValue)",
            sourceID: sourceID,
            dateAdded: dateAdded
        )
    }

    private func sortedIDs(
        _ songs: [Song],
        by order: LibrarySongSortOrder
    ) -> [String] {
        SongListSnapshotBuilder.build(songs: songs, order: order).rows.map(\.id)
    }
}
