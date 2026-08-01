import Testing
@testable import PrimuseKit

@Suite("SFTP and NFS path scope")
struct RemotePathScopePolicyTests {
    @Test("Absolute paths must remain inside the configured source root")
    func absolutePathScope() {
        let policy = RemotePathScopePolicy(rootPath: "/srv/music")

        #expect(policy.resolvedPath(forStoredPath: "/srv/music/Albums/song.flac")
            == "/srv/music/Albums/song.flac")
        #expect(policy.relativePath(forStoredPath: "/srv/music/Albums/song.flac")
            == "/Albums/song.flac")
        #expect(policy.resolvedPath(forStoredPath: "/srv/private/song.flac") == nil)
    }

    @Test("Parent components are rejected before normalization")
    func parentTraversalIsRejected() {
        let policy = RemotePathScopePolicy(rootPath: "/srv/music")

        #expect(policy.resolvedPath(forStoredPath: "../private/song.flac") == nil)
        #expect(policy.resolvedPath(forStoredPath: "Albums/../../private/song.flac") == nil)
        #expect(policy.resolvedPath(forStoredPath: "/srv/music/../private/song.flac") == nil)
    }

    @Test("A matching string prefix is not the same source root or export")
    func componentPrefixCollisionIsRejected() {
        let policy = RemotePathScopePolicy(rootPath: "/exports/music")

        #expect(policy.resolvedPath(forStoredPath: "/exports/music-old/song.flac") == nil)
        #expect(!policy.matchesRoot("/exports/music-old"))
        #expect(!policy.matchesRoot("/exports/music/../music"))
    }

    @Test("Legitimate relative children and the exact NFS export remain valid")
    func legitimateChildrenRemainValid() {
        let policy = RemotePathScopePolicy(rootPath: "/exports/music/")

        #expect(policy.rootPath == "/exports/music")
        #expect(policy.resolvedPath(forStoredPath: "Albums/./Live/song.flac")
            == "/exports/music/Albums/Live/song.flac")
        #expect(policy.relativePath(forStoredPath: "Albums/Live/song.flac")
            == "/Albums/Live/song.flac")
        #expect(policy.matchesRoot("/exports/music/"))
    }

    @Test("NFS selections are confined to an exact configured export")
    func nfsSelectionMatchesConfiguredExport() {
        #expect(NFSSelectionScopePolicy.resolve(
            exportPath: "/exports/music/",
            relativePath: "/Albums/song.flac",
            configuredExportPath: " /exports/music "
        ) == NFSScopedSelection(
            exportPath: "/exports/music",
            relativePath: "/Albums/song.flac"
        ))

        #expect(NFSSelectionScopePolicy.resolve(
            exportPath: "/exports/music-old",
            relativePath: "/Albums/song.flac",
            configuredExportPath: "/exports/music"
        ) == nil)
    }

    @Test("NFS selections reject parent components before mounting")
    func nfsSelectionRejectsParentComponents() {
        #expect(NFSSelectionScopePolicy.resolve(
            exportPath: "/exports/music/../private",
            relativePath: "/song.flac",
            configuredExportPath: nil
        ) == nil)

        #expect(NFSSelectionScopePolicy.resolve(
            exportPath: "/exports/music",
            relativePath: "/Albums/../../private/song.flac",
            configuredExportPath: nil
        ) == nil)

        #expect(NFSSelectionScopePolicy.resolve(
            exportPath: "/exports/music",
            relativePath: "/song.flac",
            configuredExportPath: "/exports/allowed/../music"
        ) == nil)
    }
}
