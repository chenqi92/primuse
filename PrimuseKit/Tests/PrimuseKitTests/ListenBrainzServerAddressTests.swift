import Foundation
import Testing
@testable import PrimuseKit

@Suite("ListenBrainz server address")
struct ListenBrainzServerAddressTests {
    typealias Address = ListenBrainzServerAddress

    @Test("Blank input and the official hosts use the official API")
    func official() {
        #expect(Address.parse("") == .official)
        #expect(Address.parse("   \n") == .official)
        #expect(Address.parse("https://api.listenbrainz.org") == .official)
        #expect(Address.parse("https://api.listenbrainz.org/") == .official)
        #expect(Address.parse("api.listenbrainz.org") == .official)
        #expect(Address.parse("https://listenbrainz.org/1/submit-listens") == .official)
        #expect(Address.parse("HTTPS://API.ListenBrainz.org") == .official)
    }

    @Test("Self-hosted roots keep their path; pasted endpoint paths are trimmed")
    func custom() {
        #expect(Address.parse("https://maloja.example.com/apis/listenbrainz")
            == .custom(URL(string: "https://maloja.example.com/apis/listenbrainz")!))
        #expect(Address.parse("https://maloja.example.com/apis/listenbrainz/1/submit-listens")
            == .custom(URL(string: "https://maloja.example.com/apis/listenbrainz")!))
        #expect(Address.parse("https://koito.example.com/apis/listenbrainz/1/validate-token")
            == .custom(URL(string: "https://koito.example.com/apis/listenbrainz")!))
        #expect(Address.parse("http://192.168.1.20:9078/1/")
            == .custom(URL(string: "http://192.168.1.20:9078")!))
        #expect(Address.parse("scrobbler.local:9078/apis/listenbrainz/")
            == .custom(URL(string: "https://scrobbler.local:9078/apis/listenbrainz")!))
        #expect(Address.parse("https://lb.example.com/?x=1#top")
            == .custom(URL(string: "https://lb.example.com")!))
        // 官方主机换了端口或协议就不是官方接口了。
        #expect(Address.parse("http://api.listenbrainz.org")
            == .custom(URL(string: "http://api.listenbrainz.org")!))
    }

    @Test("Other schemes and missing hosts are rejected")
    func invalid() {
        #expect(Address.parse("ftp://example.com") == .invalid)
        #expect(Address.parse("https://") == .invalid)
        #expect(Address.parse("file:///tmp/x") == .invalid)
        #expect(Address.parse("https://exa mple.com") == .invalid)
    }

    @Test("Stored values resolve to the request root")
    func resolvedURL() {
        #expect(Address.resolvedURL(stored: "") == Address.officialURL)
        #expect(Address.resolvedURL(stored: "https://lb.example.com/apis/listenbrainz")
            == URL(string: "https://lb.example.com/apis/listenbrainz")!)
        #expect(Address.resolvedURL(stored: "ftp://x") == nil)
        let root = Address.resolvedURL(stored: "https://lb.example.com/apis/listenbrainz")!
        #expect(root.appendingPathComponent("1/submit-listens").absoluteString
            == "https://lb.example.com/apis/listenbrainz/1/submit-listens")
    }
}

@Suite("ListenBrainz connection draft")
struct ListenBrainzConnectionDraftTests {
    @Test func switchingRootRequiresAnExplicitTokenForThatRoot() throws {
        let root = try #require(URL(string: "https://listen.example/a"))
        var draft = ListenBrainzConnectionDraft(baseURL: root, token: "fixture-a")
        draft.serverText = "https://listen.example/a/1/submit-listens"
        #expect(draft.matchesSavedCredentials)

        draft.serverText = "https://listen.example/b"
        #expect(draft.token.isEmpty)
        #expect(!draft.canSave)
        draft.token = "fixture-b"
        #expect(draft.canSave)

        draft.serverText = "https://other.example"
        #expect(draft.token.isEmpty)
        draft.serverText = root.absoluteString
        #expect(draft.token == "fixture-a")
        draft.serverText = "https://listen.example/b/"
        #expect(draft.token == "fixture-b")
    }

    @Test func editingATokenBeforeChangingServerCannotCarryItToAnotherServer() {
        var draft = ListenBrainzConnectionDraft(token: "fixture-old")
        draft.token = "fixture-replacement"
        draft.serverText = "https://new.example"
        #expect(draft.token.isEmpty)
        draft.serverText = "https://"
        #expect(draft.baseURL == nil)
        #expect(!draft.canSave)

        draft.serverText = "https://listenbrainz.org"
        #expect(draft.token == "fixture-replacement")
        draft.token = ""
        #expect(draft.canSave)
        #expect(!draft.matchesSavedCredentials)
    }
}
