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

        let snapshot = SongListSnapshotBuilder.build(songs: songs, order: .title)

        #expect(snapshot.rows.count == 20_000)
        #expect(snapshot.songIDs.count == 20_000)
        #expect(snapshot.rows.first?.id == "song-19999")
        #expect(snapshot.rows.last?.id == "song-0")
        #expect(snapshot.totalDuration == 3_600_000)
    }

    private func song(
        id: String,
        title: String,
        sourceID: String = "source",
        duration: TimeInterval = 180,
        dateAdded: Date = Date(timeIntervalSince1970: 0)
    ) -> Song {
        Song(
            id: id,
            title: title,
            duration: duration,
            fileFormat: .flac,
            filePath: "/Music/\(id).flac",
            sourceID: sourceID,
            dateAdded: dateAdded
        )
    }
}
