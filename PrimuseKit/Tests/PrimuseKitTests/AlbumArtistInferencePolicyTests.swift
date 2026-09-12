import Foundation
import Testing
@testable import PrimuseKit

@Suite("Album artist inference")
struct AlbumArtistInferencePolicyTests {
    private func track(
        _ id: String,
        sourceID: String = "source",
        directory: String = "/music/ost",
        albumTitle: String? = "鸣潮 原声带",
        albumArtistName: String? = nil,
        trackArtistName: String? = nil
    ) -> AlbumArtistInferencePolicy.Track {
        AlbumArtistInferencePolicy.Track(
            id: id,
            sourceID: sourceID,
            directory: directory,
            albumTitle: albumTitle,
            albumArtistName: albumArtistName,
            trackArtistName: trackArtistName
        )
    }

    /// A lone track in a second folder. It makes the source directory
    /// authoritative without forming a scope of its own (scopes need ≥ 2).
    private var neighbourFolderTrack: AlbumArtistInferencePolicy.Track {
        track(
            "neighbour",
            directory: "/music/other",
            albumTitle: "别的专辑",
            trackArtistName: "别人"
        )
    }

    @Test func untaggedSiblingsAdoptTheOnlyExplicitAlbumArtist() {
        let tracks = [
            track("1", albumArtistName: "鸣潮先约电台", trackArtistName: "作曲家甲"),
            track("2", trackArtistName: "作曲家乙"),
            track("3", trackArtistName: "鸣潮先约电台"),
            neighbourFolderTrack,
        ]

        let result = AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks)

        // 1 already carries the tag and 3 already resolves to it; only 2 moves.
        #expect(result == ["2": "鸣潮先约电台"])
    }

    @Test func conflictingExplicitAlbumArtistsLeaveTheFolderAlone() {
        let tracks = [
            track("1", albumArtistName: "Label A", trackArtistName: "Composer A"),
            track("2", albumArtistName: "Label B", trackArtistName: "Composer B"),
            track("3", trackArtistName: "Composer C"),
            neighbourFolderTrack,
        ]

        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks).isEmpty)
    }

    @Test func dominantTrackArtistAbsorbsTheMinorityAndTheUntaggedTrack() {
        let tracks = [
            track("1", trackArtistName: "鸣潮先约电台"),
            track("2", trackArtistName: "鸣潮先约电台"),
            track("3", trackArtistName: "鸣潮先约电台"),
            track("4", trackArtistName: "作曲家甲"),
            track("5", trackArtistName: nil),
            neighbourFolderTrack,
        ]

        let result = AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks)

        #expect(result == ["4": "鸣潮先约电台", "5": "鸣潮先约电台"])
    }

    @Test func aTieOrAllDistinctTrackArtistsInferNothing() {
        let halved = [
            track("1", trackArtistName: "A"),
            track("2", trackArtistName: "A"),
            track("3", trackArtistName: "B"),
            track("4", trackArtistName: "B"),
            neighbourFolderTrack,
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: halved).isEmpty)

        let compilation = [
            track("1", trackArtistName: "A"),
            track("2", trackArtistName: "B"),
            track("3", trackArtistName: "C"),
            neighbourFolderTrack,
        ]
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: compilation).isEmpty)
    }

    @Test func differentFoldersAndDifferentTitlesNeverInteract() {
        let tracks = [
            track("1", directory: "/music/a", trackArtistName: "Host"),
            track("2", directory: "/music/a", trackArtistName: "Host"),
            track("3", directory: "/music/b", trackArtistName: "Guest"),
            track("4", directory: "/music/a", albumTitle: "Other", trackArtistName: "Guest"),
        ]

        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks).isEmpty)
    }

    @Test func aSourceWithoutRealFoldersIsSkipped() {
        let flat = [
            track("1", sourceID: "server", directory: "/songs", trackArtistName: "Host"),
            track("2", sourceID: "server", directory: "/songs", trackArtistName: "Host"),
            track("3", sourceID: "server", directory: "/songs", trackArtistName: "Guest"),
        ]
        #expect(AlbumArtistInferencePolicy.directoryAuthoritativeSourceIDs(for: flat).isEmpty)
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: flat).isEmpty)

        let foldered = flat + [
            track("4", sourceID: "server", directory: "/songs/other", trackArtistName: "Other")
        ]
        #expect(
            AlbumArtistInferencePolicy.directoryAuthoritativeSourceIDs(for: foldered) == ["server"]
        )
        #expect(AlbumArtistInferencePolicy.inferredAlbumArtists(for: foldered) == ["3": "Host"])
    }

    @Test func spellingVariantsOfOneKeyUnifyToTheMostFrequentSpelling() {
        let tracks = [
            track("1", trackArtistName: "ABC"),
            track("2", trackArtistName: "ABC"),
            track("3", trackArtistName: "ABC"),
            track("4", trackArtistName: "abc"),
            track("5", trackArtistName: "Guest"),
            neighbourFolderTrack,
        ]

        let result = AlbumArtistInferencePolicy.inferredAlbumArtists(for: tracks)

        #expect(result == ["4": "ABC", "5": "ABC"])
    }

    @Test func directoryOfPathMatchesFoundationPathSemantics() {
        #expect(AlbumArtistInferencePolicy.directory(ofPath: "/a/b/c.flac") == "/a/b")
        #expect(AlbumArtistInferencePolicy.directory(ofPath: "c.flac") == "")
        #expect(
            AlbumArtistInferencePolicy.directory(ofPath: "/x/y/")
                == ("/x/y/" as NSString).deletingLastPathComponent
        )
    }
}
