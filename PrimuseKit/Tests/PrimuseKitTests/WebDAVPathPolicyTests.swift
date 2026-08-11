import Testing
@testable import PrimuseKit

@Suite("WebDAV path policy")
struct WebDAVPathPolicyTests {
    @Test("Direct WebDAV roots map hrefs to source-relative paths")
    func directRoot() {
        let policy = WebDAVPathPolicy(basePath: "/dav/")

        #expect(policy.sourcePath(forServerPath: "/dav/") == "/")
        #expect(policy.sourcePath(forServerPath: "/dav/Albums/song.flac") == "/Albums/song.flac")
        #expect(policy.sourcePath(forServerPath: "/dav-other/song.flac") == nil)
    }

    @Test("Reverse proxy roots accept only the configured root or upstream leaf")
    func reverseProxyRoot() {
        let policy = WebDAVPathPolicy(basePath: "/qa-wan/openlist/dav/")

        #expect(policy.sourcePath(forServerPath: "/qa-wan/openlist/dav/") == "/")
        #expect(policy.sourcePath(forServerPath: "/qa-wan/openlist/dav/Albums") == "/Albums")
        #expect(policy.sourcePath(forServerPath: "/openlist/dav/Albums") == nil)
        #expect(policy.sourcePath(forServerPath: "/dav/") == "/")
        #expect(policy.sourcePath(forServerPath: "/dav/%E5%B9%B4%E8%BD%BB%E7%9C%9F%E5%A5%BD.mp3") == "/年轻真好.mp3")
    }

    @Test("Root collisions and parent traversal stay outside the source")
    func rejectsUnsafePaths() {
        let policy = WebDAVPathPolicy(basePath: "/qa-wan/openlist/dav")

        #expect(policy.sourcePath(forServerPath: "/other/song.mp3") == nil)
        #expect(policy.sourcePath(forServerPath: "/dav-other/song.mp3") == nil)
        #expect(policy.sourcePath(forServerPath: "/wan/openlist/dav/song.mp3") == nil)
        #expect(policy.sourcePath(forServerPath: "/dav/../secret.mp3") == nil)
        #expect(policy.sourcePath(forServerPath: "dav/song.mp3") == nil)
    }

    @Test("Server root paths stay unchanged for root WebDAV sources")
    func rootSource() {
        let policy = WebDAVPathPolicy(basePath: nil)

        #expect(policy.sourcePath(forServerPath: "/") == "/")
        #expect(policy.sourcePath(forServerPath: "/Music/song.mp3") == "/Music/song.mp3")
    }

    @Test("FilesProvider callbacks remain source-relative for root and prefixed servers")
    func providerRelativePaths() {
        let rootPolicy = WebDAVPathPolicy(basePath: nil)
        let prefixedPolicy = WebDAVPathPolicy(basePath: "/dav")

        #expect(rootPolicy.sourcePath(forProviderPath: "/Albums/song.flac")
            == "/Albums/song.flac")
        #expect(prefixedPolicy.sourcePath(forProviderPath: "/Albums/song.flac")
            == "/Albums/song.flac")
        #expect(prefixedPolicy.sourcePath(forProviderPath: "/dav/Albums/song.flac")
            == "/Albums/song.flac")
        #expect(prefixedPolicy.sourcePath(forProviderPath: "/%E5%B9%B4%E8%BD%BB%E7%9C%9F%E5%A5%BD.mp3")
            == "/年轻真好.mp3")
        #expect(prefixedPolicy.sourcePath(forProviderPath: "/Albums/../secret.mp3") == nil)
        #expect(prefixedPolicy.sourcePath(forProviderPath: "Albums/song.flac")
            == "/Albums/song.flac")
    }
}
