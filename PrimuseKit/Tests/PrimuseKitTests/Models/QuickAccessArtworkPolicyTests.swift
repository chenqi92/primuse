import Foundation
import Testing
@testable import PrimuseKit

@Suite("Quick access cover selection")
struct QuickAccessArtworkPolicyTests {
    @Test("Collages try later tracks after missing artwork and skip resolved duplicates")
    func failuresAndDuplicates() async {
        let songs = [song("missing", cover: "shared"), song("a", cover: "shared"),
                     song("duplicate", cover: "shared"), song("b", cover: "b"),
                     song("c", cover: "c"), song("d", cover: "d"), song("unused", cover: "e")]
        var attempts: [String] = []
        let result = await QuickAccessArtworkPolicy.resolveCollage(plan: orderedPlan(songs), songs: songs) { candidate in
            attempts.append(candidate.songID!)
            return candidate.songID == "missing" ? nil : candidate.songID
        }
        #expect(result == ["a", "b", "c", "d"])
        #expect(attempts == ["missing", "a", "b", "c", "d"])
    }

    @Test("The same relative artwork reference in different sources remains distinct")
    func sourceScopedReferences() async {
        let songs = [song("a", cover: "cover.jpg", source: "one"),
                     song("b", cover: "cover.jpg", source: "two")]
        let result = await QuickAccessArtworkPolicy.resolveCollage(plan: orderedPlan(songs), songs: songs) { $0.songID }
        #expect(result == ["a", "b"])
    }

    @Test("Embedded artwork is attempted even without a cover reference")
    func embeddedArtworkAndEmptyCollections() async {
        let songs = [song("embedded", cover: nil)]
        let result = await QuickAccessArtworkPolicy.resolveCollage(plan: orderedPlan(songs), songs: songs) { $0.songID }
        #expect(result == ["embedded"])
        let empty: [String] = await QuickAccessArtworkPolicy.resolveCollage(plan: orderedPlan([]), songs: []) { _ in
            Issue.record("An empty collection must not start artwork loading")
            return nil
        }
        #expect(empty.isEmpty)
    }

    @Test("Unavailable sources do not trigger unbounded artwork requests")
    func boundedFailures() async {
        let songs = (0..<100).map { song("\($0)", cover: "\($0).jpg") }
        var attempts = 0
        let result: [String] = await QuickAccessArtworkPolicy.resolveCollage(plan: orderedPlan(songs), songs: songs) { _ in
            attempts += 1
            return nil
        }
        #expect(result.isEmpty)
        #expect(attempts == 24)
    }

    @Test("Selection remains stable when membership is reordered and refreshes for new artwork")
    func stablePlan() {
        let songs = [song("a", cover: "a.jpg"), song("b", cover: nil)]
        let initial = QuickAccessArtworkPolicy.makePlan(itemID: "liked", songs: songs)
        #expect(initial == QuickAccessArtworkPolicy.makePlan(itemID: "liked", songs: songs.reversed()))
        var updated = songs
        updated[1].coverArtFileName = "b.jpg"
        #expect(initial.signature != QuickAccessArtworkPolicy.makePlan(itemID: "liked", songs: updated).signature)
    }

    private func orderedPlan(_ songs: [Song]) -> PlaylistArtworkResolutionPlan {
        PlaylistArtworkResolutionPlan(signature: "test", candidates: songs.map {
            PlaylistArtworkCandidate(kind: .song, id: $0.id, songID: $0.id, artworkReference: $0.coverArtFileName)
        })
    }

    private func song(_ id: String, cover: String?, source: String = "source") -> Song {
        Song(id: id, title: id, fileFormat: .mp3, filePath: "/Music/\(id).mp3", sourceID: source, coverArtFileName: cover)
    }
}
