import Foundation
import Testing
@testable import PrimuseKit

@Suite("Adaptive artwork URL rewriting")
struct SourceConnectionURLRewriterTests {
    @Test("Moves a LAN Jellyfin artwork URL onto the selected public prefix")
    func rebasesJellyfinArtworkAndRefreshesCredential() throws {
        let reference = try #require(URL(
            string: "https://192.168.0.50:8096/jellyfin/Items/album-id/Images/Primary?maxWidth=480&api_key=old"
        ))
        let publicBase = try #require(URL(string: "https://music.example.com/media"))

        let rewritten = SourceConnectionURLRewriter.rebasedURL(
            for: reference,
            onto: publicBase,
            pathMarkers: ["/Items/"],
            removingQueryItemsNamed: ["api_key"],
            addingQueryItems: [URLQueryItem(name: "api_key", value: "fresh")]
        )

        #expect(rewritten?.scheme == "https")
        #expect(rewritten?.host == "music.example.com")
        #expect(rewritten?.path == "/media/Items/album-id/Images/Primary")
        let query = URLComponents(url: try #require(rewritten), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first(where: { $0.name == "maxWidth" })?.value == "480")
        #expect(query?.filter { $0.name == "api_key" }.map(\.value) == ["fresh"])
    }

    @Test("Keeps a Plex service path while replacing its token")
    func rebasesPlexArtwork() throws {
        let reference = try #require(URL(
            string: "http://192.168.1.8:32400/library/metadata/42/thumb?X-Plex-Token=old"
        ))
        let publicBase = try #require(URL(string: "https://plex.example.com/proxy"))

        let rewritten = SourceConnectionURLRewriter.rebasedURL(
            for: reference,
            onto: publicBase,
            pathMarkers: ["/library/"],
            removingQueryItemsNamed: ["X-Plex-Token"],
            addingQueryItems: [URLQueryItem(name: "X-Plex-Token", value: "new")]
        )

        #expect(rewritten?.absoluteString == "https://plex.example.com/proxy/library/metadata/42/thumb?X-Plex-Token=new")
    }

    @Test("Rejects unrelated external artwork instead of rebasing its host")
    func rejectsUnownedURL() throws {
        let reference = try #require(URL(string: "https://cdn.example.net/covers/42.jpg"))
        let base = try #require(URL(string: "https://music.example.com"))

        #expect(SourceConnectionURLRewriter.rebasedURL(
            for: reference,
            onto: base,
            pathMarkers: ["/Items/", "/library/"]
        ) == nil)
    }
}
