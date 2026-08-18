import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playlist artwork resolution")
struct PlaylistArtworkResolutionPolicyTests {
    @Test("Dedicated artwork is first only when provenance is explicit")
    func dedicatedArtworkPriorityAndLegacyMigration() {
        let songs = [song("member", cover: "member.jpg")]
        let dedicated = Playlist(
            id: "playlist",
            name: "Playlist",
            coverArtPath: "member.jpg",
            hasDedicatedCoverArt: true
        )
        let legacy = Playlist(
            id: "playlist",
            name: "Playlist",
            coverArtPath: "old-first-song.jpg"
        )

        let dedicatedPlan = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: dedicated,
            songs: songs
        )
        let legacyPlan = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: legacy,
            songs: songs
        )

        #expect(dedicatedPlan.candidates.first?.kind == .dedicated)
        #expect(dedicatedPlan.candidates.first?.artworkReference == "member.jpg")
        #expect(!legacyPlan.candidates.contains { $0.kind == .dedicated })
    }

    @Test("Stable pseudo-random order ignores input and member order")
    func deterministicAcrossRendersAndPlatforms() {
        let playlist = Playlist(id: "stable-playlist", name: "Stable")
        let songs = [
            song("a", cover: "a.jpg"),
            song("b", cover: "b.jpg"),
            song("c", cover: "c.jpg"),
            song("d", cover: "d.jpg"),
        ]

        let first = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: playlist,
            songs: songs
        )
        let second = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: playlist,
            songs: songs.reversed()
        )

        #expect(first == second)
        #expect(first.candidates.map(\.songID) == second.candidates.map(\.songID))
        #expect(first.signature == second.signature)
        #expect(first.candidates.compactMap(\.songID) == ["d", "c", "b", "a"])
        #expect(first.signature == "990f9d4bfa52b477")
    }

    @Test("A missing first-song cover falls through to a later valid member")
    func firstSongWithoutArtworkFallsBack() async {
        let playlist = Playlist(id: "later-cover", name: "Later")
        let first = song("first", cover: nil)
        let covered = song("covered", cover: "covered.jpg")
        let plan = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: playlist,
            songs: [first, covered]
        )

        let resolved = await PlaylistArtworkResolver.resolve(plan: plan) { candidate in
            candidate.songID == covered.id ? "visible" : nil
        }

        #expect(resolved?.candidate.songID == covered.id)
        #expect(resolved?.value == "visible")
    }

    @Test("An unresolvable dedicated image continues to stable song fallback")
    func invalidDedicatedArtworkFallsBack() async {
        let playlist = Playlist(
            id: "expired-source-cover",
            name: "Expired",
            coverArtPath: "https://expired.example.test/cover.jpg",
            hasDedicatedCoverArt: true
        )
        let covered = song("covered", cover: "cached.jpg")
        let plan = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: playlist,
            songs: [covered]
        )
        var attempts: [PlaylistArtworkCandidate.Kind] = []

        let resolved = await PlaylistArtworkResolver.resolve(plan: plan) { candidate in
            attempts.append(candidate.kind)
            return candidate.kind == .song ? candidate.songID : nil
        }

        #expect(attempts == [.dedicated, .song])
        #expect(resolved?.candidate.songID == covered.id)
    }

    @Test("Membership and artwork changes invalidate the deterministic plan")
    func candidateChangesProduceNewStableSignature() {
        let playlist = Playlist(id: "changing", name: "Changing")
        let initial = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: playlist,
            songs: [song("a", cover: "a.jpg"), song("b", cover: "b.jpg")]
        )
        let artworkChanged = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: playlist,
            songs: [song("a", cover: "a-v2.jpg"), song("b", cover: "b.jpg")]
        )
        let memberAdded = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: playlist,
            songs: [
                song("a", cover: "a.jpg"),
                song("b", cover: "b.jpg"),
                song("c", cover: "c.jpg"),
            ]
        )

        #expect(initial.signature != artworkChanged.signature)
        #expect(initial.signature != memberAdded.signature)
        #expect(artworkChanged == PlaylistArtworkResolutionPolicy.makePlan(
            playlist: playlist,
            songs: [song("b", cover: "b.jpg"), song("a", cover: "a-v2.jpg")]
        ))
    }

    @Test("Empty and fully invalid playlists resolve to no resource")
    func emptyAndAllInvalidReturnNil() async {
        let empty = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: Playlist(id: "empty", name: "Empty"),
            songs: []
        )
        #expect(empty.candidates.isEmpty)

        let invalid = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: Playlist(id: "invalid", name: "Invalid"),
            songs: [song("one", cover: nil), song("two", cover: "missing.jpg")]
        )
        let resolved: PlaylistArtworkResolution<String>? = await PlaylistArtworkResolver.resolve(
            plan: invalid,
            using: { _ in nil }
        )
        #expect(resolved == nil)
    }

    @Test("All platform adapters consume the same ordered fallback plan")
    func sharedResolverProducesCrossPlatformChoice() async {
        let playlist = Playlist(id: "cross-platform", name: "Shared")
        let plan = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: playlist,
            songs: [
                song("missing", cover: "missing.jpg"),
                song("valid", cover: "valid.jpg"),
                song("also-valid", cover: "also-valid.jpg"),
            ]
        )

        func resolveForPlatform() async -> String? {
            await PlaylistArtworkResolver.resolve(plan: plan) { candidate in
                candidate.songID == "valid" || candidate.songID == "also-valid"
                    ? candidate.songID
                    : nil
            }?.value
        }

        let iOS = await resolveForPlatform()
        let macOS = await resolveForPlatform()
        let tvOS = await resolveForPlatform()
        #expect(iOS == macOS)
        #expect(macOS == tvOS)
        #expect(iOS != "missing")
    }

    @Test("Duplicate song IDs collapse while distinct source identities remain")
    func identityDeduplication() {
        let playlist = Playlist(id: "identity", name: "Identity")
        let duplicated = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: playlist,
            songs: [
                song("same", cover: "one.jpg", source: "source-a"),
                song("same", cover: "two.jpg", source: "source-b"),
            ]
        )
        let distinctSources = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: playlist,
            songs: [
                song("source-a-song", cover: "cover.jpg", source: "source-a"),
                song("source-b-song", cover: "cover.jpg", source: "source-b"),
            ]
        )

        #expect(duplicated.candidates.count == 1)
        #expect(distinctSources.candidates.count == 2)
        #expect(Set(distinctSources.candidates.map(\.id)).count == 2)
    }

    @Test("Large playlist ordering stays stable without comparator-wide rehashing")
    func largePlaylistOrderingIsStable() {
        let playlist = Playlist(id: "large-playlist", name: "Large")
        let songs = (0..<1_500).map { index in
            song(
                "song-\(index)",
                cover: "artwork/album-\(index % 80)/cover.jpg",
                source: "source-\(index % 4)"
            )
        }

        let forward = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: playlist,
            songs: songs
        )
        let reversed = PlaylistArtworkResolutionPolicy.makePlan(
            playlist: playlist,
            songs: songs.reversed()
        )

        #expect(forward.candidates.count == songs.count)
        #expect(forward == reversed)
    }

    private func song(
        _ id: String,
        cover: String?,
        source: String = "source",
        path: String? = nil
    ) -> Song {
        Song(
            id: id,
            title: id,
            fileFormat: .mp3,
            filePath: path ?? "/Music/\(id).mp3",
            sourceID: source,
            coverArtFileName: cover
        )
    }
}
