import Testing
@testable import PrimuseKit

@Suite("Visible library presence policy")
struct VisibleLibraryPresencePolicyTests {
    @Test("Albumless tracks still form a usable library")
    func acceptsAlbumlessTracks() {
        #expect(VisibleLibraryPresencePolicy.hasContent(songCount: 12, albumCount: 0))
    }

    @Test("An empty visible snapshot remains empty")
    func rejectsEmptySnapshot() {
        #expect(!VisibleLibraryPresencePolicy.hasContent(songCount: 0, albumCount: 0))
    }

    @Test("Album-backed libraries retain their existing behavior")
    func acceptsAlbums() {
        #expect(VisibleLibraryPresencePolicy.hasContent(songCount: 0, albumCount: 1))
    }
}
