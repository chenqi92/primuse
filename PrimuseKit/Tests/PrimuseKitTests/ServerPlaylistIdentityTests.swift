import Testing
@testable import PrimuseKit

@Suite("Server playlist identity")
struct ServerPlaylistIdentityTests {
    @Test("Playlist ID is derived from the source and the server playlist ID")
    func derivesPlaylistID() {
        let id = ServerPlaylistIdentity.playlistID(sourceID: "src-a", serverPlaylistID: "42")

        #expect(id == "primuse.system.serverPlaylist.src-a.42")
        #expect(ServerPlaylistIdentity.isMirrorPlaylist(id))
        #expect(id.hasPrefix(ServerPlaylistIdentity.playlistIDPrefix(sourceID: "src-a")))
    }

    @Test("Per-source prune prefix never reaches another source's mirrors")
    func prunePrefixIsScopedToOneSource() {
        let mine = ServerPlaylistIdentity.playlistID(sourceID: "src-a", serverPlaylistID: "1")
        let theirs = ServerPlaylistIdentity.playlistID(sourceID: "src-b", serverPlaylistID: "1")
        let prefix = ServerPlaylistIdentity.playlistIDPrefix(sourceID: "src-a")

        #expect(mine.hasPrefix(prefix))
        #expect(!theirs.hasPrefix(prefix))
    }

    /// Without the trailing separator, `src-a` would also match `src-a2`, and one
    /// source's scan would prune the other source's mirrors.
    @Test("Prune prefix ends at a separator so sibling source IDs do not collide")
    func prunePrefixDoesNotMatchLongerSourceIDs() {
        let prefix = ServerPlaylistIdentity.playlistIDPrefix(sourceID: "src-a")
        let sibling = ServerPlaylistIdentity.playlistID(sourceID: "src-a2", serverPlaylistID: "1")

        #expect(prefix.hasSuffix("."))
        #expect(!sibling.hasPrefix(prefix))
    }

    @Test("Server item ID round-trips out of connector-built file paths")
    func recoversServerItemID() {
        #expect(ServerPlaylistIdentity.serverItemID(fromFilePath: "/songs/tr-100.flac") == "tr-100")
        #expect(ServerPlaylistIdentity.serverItemID(fromFilePath: "/items/9f8e7d.mp3") == "9f8e7d")
    }

    /// The catalogue scan and the playlist response do not always agree on the
    /// suffix, which is why matching goes through the item ID instead of the
    /// extension-sensitive `Song.id` hash.
    @Test("Item ID is independent of the reported suffix")
    func itemIDIgnoresSuffix() {
        let withSuffix = ServerPlaylistIdentity.serverItemID(fromFilePath: "/songs/tr-100.flac")
        let otherSuffix = ServerPlaylistIdentity.serverItemID(fromFilePath: "/songs/tr-100.m4a")
        let noSuffix = ServerPlaylistIdentity.serverItemID(fromFilePath: "/songs/tr-100")

        #expect(withSuffix == "tr-100")
        #expect(otherSuffix == "tr-100")
        #expect(noSuffix == "tr-100")
    }

    @Test("An empty path yields no item ID")
    func rejectsEmptyPath() {
        #expect(ServerPlaylistIdentity.serverItemID(fromFilePath: "") == nil)
    }

    /// Documents the actual contract rather than an assumed one: `lastPathComponent`
    /// keeps `/` and strips trailing slashes, so a directory-shaped path still
    /// returns a non-nil string. Callers rely on connectors always emitting
    /// `/songs/<id>.<suffix>` or `/items/<id>.<ext>` with a non-empty id, and the
    /// index is per-source, so a degenerate value cannot cross-wire two servers.
    @Test("Directory-shaped paths return their last component, not nil")
    func directoryShapedPathsAreNotRejected() {
        #expect(ServerPlaylistIdentity.serverItemID(fromFilePath: "/") == "/")
        #expect(ServerPlaylistIdentity.serverItemID(fromFilePath: "/songs/") == "songs")
    }

    /// A dotted ID must not be truncated at its first dot — Plex rating keys and
    /// Jellyfin GUIDs can contain dots.
    @Test("Only the final extension is stripped from a dotted item ID")
    func keepsDotsInsideItemID() {
        #expect(ServerPlaylistIdentity.serverItemID(fromFilePath: "/items/a.b.c.mp3") == "a.b.c")
    }

    @Test("A failed detail fetch keeps the existing mirror while omitted IDs are pruned")
    func failedDetailsRemainInTheAuthoritativeKeepSet() {
        let keepIDs = ServerPlaylistReconciliationPolicy.mirrorIDsToKeep(
            sourceID: "src-a",
            synchronizedServerPlaylistIDs: ["fresh"],
            failedServerPlaylistIDs: ["temporarily-unavailable"]
        )

        #expect(keepIDs == Set([
            ServerPlaylistIdentity.playlistID(
                sourceID: "src-a",
                serverPlaylistID: "fresh"
            ),
            ServerPlaylistIdentity.playlistID(
                sourceID: "src-a",
                serverPlaylistID: "temporarily-unavailable"
            )
        ]))
        #expect(!keepIDs.contains(ServerPlaylistIdentity.playlistID(
            sourceID: "src-a",
            serverPlaylistID: "deleted-on-server"
        )))
    }
}

@Suite("Server favorite writeback policy")
struct ServerFavoriteWritebackPolicyTests {
    @Test("Only Emby, Navidrome and explicit Subsonic sources can write favorites")
    func supportsOnlyExplicitFavoriteSources() {
        #expect(ServerFavoriteWritebackPolicy.supports(.emby))
        #expect(ServerFavoriteWritebackPolicy.supports(.navidrome))
        #expect(ServerFavoriteWritebackPolicy.supports(.subsonic))

        for sourceType in MusicSourceType.allCases where ![.emby, .navidrome, .subsonic].contains(sourceType) {
            #expect(!ServerFavoriteWritebackPolicy.supports(sourceType))
        }
    }

    @Test("Song IDs are recovered only from connector-owned song paths")
    func extractsStrictSongIDs() {
        #expect(ServerFavoriteWritebackPolicy.songID(
            fromConnectorPath: "/songs/navidrome-song.flac",
            sourceType: .navidrome
        ) == "navidrome-song")
        #expect(ServerFavoriteWritebackPolicy.songID(
            fromConnectorPath: "/songs/a.b.c.m4a",
            sourceType: .subsonic
        ) == "a.b.c")
        #expect(ServerFavoriteWritebackPolicy.songID(
            fromConnectorPath: "/items/emby-item.mp3",
            sourceType: .emby
        ) == "emby-item")
    }

    @Test("Malformed, mismatched and unsupported paths are rejected before mutation")
    func rejectsUnsafeMutationIDs() {
        let rejected: [(String, MusicSourceType)] = [
            ("", .navidrome),
            ("/", .navidrome),
            ("/songs/", .navidrome),
            ("songs/song.mp3", .navidrome),
            ("/songs/nested/song.mp3", .navidrome),
            ("/albums/album-id.mp3", .navidrome),
            ("/items/emby-item.mp3", .navidrome),
            ("/songs/navidrome-song.mp3", .emby),
            ("/songs/airsonic-song.mp3", .airsonic),
            ("/songs/gonic-song.mp3", .gonic),
            ("/songs/.mp3", .subsonic),
        ]

        for (path, sourceType) in rejected {
            #expect(ServerFavoriteWritebackPolicy.songID(
                fromConnectorPath: path,
                sourceType: sourceType
            ) == nil)
        }
    }
}

@Suite("Source-owned artwork identity")
struct SourceOwnedArtworkReferenceTests {
    @Test("Source and connector reference round-trip without exposing URL syntax")
    func roundTrips() throws {
        let encoded = try #require(SourceOwnedArtworkReference.make(
            sourceID: "server/上海",
            reference: "subsonic-artist/ar+1/2"
        ))

        #expect(!encoded.contains("://"))
        #expect(SourceOwnedArtworkReference.resolve(encoded) == .init(
            sourceID: "server/上海",
            reference: "subsonic-artist/ar+1/2"
        ))
    }

    @Test("Malformed and empty references are rejected")
    func rejectsInvalidReferences() {
        #expect(SourceOwnedArtworkReference.make(sourceID: "", reference: "art") == nil)
        #expect(SourceOwnedArtworkReference.make(sourceID: "source", reference: "") == nil)
        #expect(SourceOwnedArtworkReference.resolve("https://example.com/art.jpg") == nil)
        #expect(SourceOwnedArtworkReference.resolve("primuse-source-artwork:not-base64") == nil)
    }
}

@Suite("Mirror playlist identity")
struct MirrorPlaylistIdentityTests {
    @Test("Both mirror families are recognized")
    func recognizesEveryMirrorFamily() {
        #expect(MirrorPlaylistIdentity.isMirrorPlaylist(AppleMusicLibraryIdentity.systemPlaylistID))
        #expect(MirrorPlaylistIdentity.isMirrorPlaylist(
            AppleMusicLibraryIdentity.userPlaylistIDPrefix + "p.abc"
        ))
        #expect(MirrorPlaylistIdentity.isMirrorPlaylist(
            ServerPlaylistIdentity.playlistID(sourceID: "src-a", serverPlaylistID: "42")
        ))
    }

    /// This predicate gates destructive UI and CloudKit exclusion, so a
    /// user-created playlist must never be classified as a mirror.
    ///
    /// The liked-songs ID is spelled out because `MusicLibrary` lives in the app
    /// target and is not visible here; it is a system playlist but not a mirror,
    /// so callers gate it separately.
    @Test("User and liked playlists are not mirrors")
    func leavesUserPlaylistsEditable() {
        #expect(!MirrorPlaylistIdentity.isMirrorPlaylist("A1B2C3"))
        #expect(!MirrorPlaylistIdentity.isMirrorPlaylist("primuse.system.liked"))
    }
}
