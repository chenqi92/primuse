import Testing
@testable import PrimuseKit

struct PlaylistOperationAvailabilityTests {
    @Test func fileImportMatchesPlatformCapability() {
        #expect(PlaylistOperationAvailability.standard.supportsImport)
        #expect(!PlaylistOperationAvailability.television.supportsImport)
    }
}

@Suite struct PlaylistImportDestinationPolicyTests {
    private let likedNames = ["我喜欢", "我的最愛", "Liked Songs", "好きな曲", "Gefällt mir"]

    @Test func aMarkedExportOfTheLikedListGoesBackToTheLikedList() {
        #expect(PlaylistImportDestinationPolicy.suggestedDestination(
            kindMarker: "liked", playlistName: "Anything", likedPlaylistNames: likedNames
        ) == .likedSongs)
        #expect(PlaylistImportDestinationPolicy.suggestedDestination(
            kindMarker: " Liked ", playlistName: "", likedPlaylistNames: []
        ) == .likedSongs)
    }

    @Test func aMarkerWinsOverTheNameSoARenamedOrdinaryPlaylistStaysOrdinary() {
        #expect(PlaylistImportDestinationPolicy.suggestedDestination(
            kindMarker: "playlist", playlistName: "Liked Songs", likedPlaylistNames: likedNames
        ) == .newPlaylist)
    }

    @Test func exportsWrittenBeforeTheMarkerAreRecognisedByNameInAnyLanguage() {
        for name in ["我喜欢", " liked songs ", "GEFALLT MIR", "Ｌｉｋｅｄ Ｓｏｎｇｓ", "好きな曲"] {
            #expect(PlaylistImportDestinationPolicy.suggestedDestination(
                kindMarker: nil, playlistName: name, likedPlaylistNames: likedNames
            ) == .likedSongs, "\(name)")
        }
        for name in ["Road Trip", "我喜欢的摇滚", "", "   "] {
            #expect(PlaylistImportDestinationPolicy.suggestedDestination(
                kindMarker: nil, playlistName: name, likedPlaylistNames: likedNames
            ) == .newPlaylist, "\(name)")
        }
        #expect(PlaylistImportDestinationPolicy.suggestedDestination(
            kindMarker: "", playlistName: "Liked Songs", likedPlaylistNames: likedNames
        ) == .likedSongs)
    }

    @Test func theM3UDirectiveRoundTripsAndOtherCommentsAreNotMarkers() {
        let line = PlaylistImportDestinationPolicy.m3uKindLine(
            marker: PlaylistImportDestinationPolicy.likedKindMarker
        )
        #expect(line == "#PRIMUSE-KIND:liked")
        #expect(PlaylistImportDestinationPolicy.kindMarker(fromM3ULine: line) == "liked")
        #expect(PlaylistImportDestinationPolicy.kindMarker(fromM3ULine: "  #primuse-kind: liked  ") == "liked")
        #expect(PlaylistImportDestinationPolicy.kindMarker(fromM3ULine: "#PRIMUSE-KIND:") == nil)
        #expect(PlaylistImportDestinationPolicy.kindMarker(fromM3ULine: "#PLAYLIST:Liked Songs") == nil)
        #expect(PlaylistImportDestinationPolicy.kindMarker(fromM3ULine: "#EXTINF:200,Artist - Title") == nil)
    }
}
