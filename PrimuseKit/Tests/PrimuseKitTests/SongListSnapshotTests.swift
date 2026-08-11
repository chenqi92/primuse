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
        #expect(sortedIDs(songs, by: .album) == ["a", "b"])
        #expect(sortedIDs(songs, by: .format) == ["a", "b"])
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
