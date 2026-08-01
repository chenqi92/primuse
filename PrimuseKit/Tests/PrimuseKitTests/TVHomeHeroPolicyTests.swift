import Testing
@testable import PrimuseKit

@Suite("tvOS home hero policy")
struct TVHomeHeroPolicyTests {
    @Test("Albumless songs use a whole-library song hero")
    func albumlessLibraryUsesSongs() {
        let content = TVHomeHeroPolicy.content(
            totalSongCount: 12,
            albumCount: 0,
            candidateAlbumSongCount: 0
        )

        #expect(content == .song)
        #expect(TVHomeHeroPolicy.displayedSongCount(
            for: content,
            totalSongCount: 12,
            candidateAlbumSongCount: 0
        ) == 12)
    }

    @Test("A stale empty album cannot turn a playable library into a zero-song hero")
    func emptyAlbumFallsBackToSongs() {
        let content = TVHomeHeroPolicy.content(
            totalSongCount: 12,
            albumCount: 1,
            candidateAlbumSongCount: 0
        )

        #expect(content == .song)
        #expect(TVHomeHeroPolicy.displayedSongCount(
            for: content,
            totalSongCount: 12,
            candidateAlbumSongCount: 0
        ) == 12)
    }

    @Test("A populated album retains the album hero")
    func populatedAlbumUsesAlbum() {
        let content = TVHomeHeroPolicy.content(
            totalSongCount: 12,
            albumCount: 2,
            candidateAlbumSongCount: 7
        )

        #expect(content == .album)
        #expect(TVHomeHeroPolicy.displayedSongCount(
            for: content,
            totalSongCount: 12,
            candidateAlbumSongCount: 7
        ) == 7)
    }

    @Test("Only an actually empty library uses the empty hero")
    func emptyLibraryStaysEmpty() {
        let content = TVHomeHeroPolicy.content(
            totalSongCount: 0,
            albumCount: 0,
            candidateAlbumSongCount: 0
        )

        #expect(content == .empty)
        #expect(TVHomeHeroPolicy.displayedSongCount(
            for: content,
            totalSongCount: 0,
            candidateAlbumSongCount: 0
        ) == 0)
    }
}
