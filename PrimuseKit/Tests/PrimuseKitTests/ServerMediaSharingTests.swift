import Foundation
import Testing
@testable import PrimuseKit

@Suite("Server media sharing")
struct ServerMediaSharingTests {
    @Test("OpenSubsonic request repeats IDs and encodes expiration in epoch milliseconds")
    func encodesCreateShareQuery() throws {
        let request = try ServerMediaShareRequest(
            itemIDs: ["song.a", "歌曲 2", "song.a"],
            description: "  Road trip  ",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000.125)
        )
        let items = try OpenSubsonicMediaShareCodec.queryItems(for: request)

        #expect(items == [
            URLQueryItem(name: "id", value: "song.a"),
            URLQueryItem(name: "id", value: "歌曲 2"),
            URLQueryItem(name: "description", value: "Road trip"),
            URLQueryItem(name: "expires", value: "1700000000125"),
        ])

        var components = URLComponents(string: "https://music.example/rest/createShare.view")!
        components.queryItems = items
        let encoded = try #require(components.percentEncodedQuery)
        #expect(encoded.contains("id=song.a&id="))
        #expect(encoded.contains("description=Road%20trip"))
        #expect(encoded.hasSuffix("expires=1700000000125"))
    }

    @Test("Expiration conversion rejects values outside signed 64-bit milliseconds")
    func rejectsExpirationOverflow() {
        #expect(throws: ServerMediaSharingError.invalidExpiration) {
            try OpenSubsonicMediaShareCodec.epochMilliseconds(
                from: Date(timeIntervalSince1970: Double.greatestFiniteMagnitude)
            )
        }
    }

    @Test("Standard share response decodes all useful fields")
    func decodesStandardResponse() throws {
        let response = try OpenSubsonicMediaShareCodec.decodeResponse(Data(#"""
        {
          "subsonic-response": {
            "status": "ok",
            "shares": {
              "share": [{
                "id": "share-1",
                "url": "https://music.example/base/share/share-1",
                "description": "Weekend",
                "username": "listener",
                "created": "2026-09-01T00:00:00.123Z",
                "expires": "2026-09-08T00:00:00Z",
                "lastVisited": "2026-09-02T00:00:00Z",
                "visitCount": 4
              }]
            }
          }
        }
        """#.utf8))

        let share = try #require(response.shares?.values.first)
        #expect(response.status == "ok")
        #expect(share.id == "share-1")
        #expect(share.publicURLString == "https://music.example/base/share/share-1")
        #expect(share.description == "Weekend")
        #expect(share.username == "listener")
        #expect(share.createdAt != nil)
        #expect(share.expiresAt != nil)
        #expect(share.lastVisitedAt != nil)
        #expect(share.visitCount == 4)
    }

    @Test("Legacy attribute-wrapped singleton response remains compatible")
    func decodesLegacyResponse() throws {
        let response = try OpenSubsonicMediaShareCodec.decodeResponse(Data(#"""
        {
          "subsonic-response": {
            "_attributes": {"status": "ok", "version": "1.16.1"},
            "shares": {
              "share": {
                "_attributes": {
                  "id": 77,
                  "url": "http://[2001:db8::77]:4533/music/share/legacy",
                  "visitCount": "2"
                }
              }
            }
          }
        }
        """#.utf8))

        let share = try #require(response.shares?.values.first)
        #expect(share.id == "77")
        #expect(share.publicURLString == "http://[2001:db8::77]:4533/music/share/legacy")
        #expect(share.publicURL.host == "[2001:db8::77]" || share.publicURL.host == "2001:db8::77")
        #expect(share.visitCount == 2)
    }

    @Test("Public URL validation rejects streams and credential leaks")
    func validatesPublicURLs() throws {
        try ServerMediaShare.validatePublicURL(
            "https://[2001:db8::8]:4533/music/share/public-id?token=public-capability"
        )

        let rejected = [
            "ftp://music.example/share/id",
            "https://user:password@music.example/share/id",
            "https://music.example/rest/stream.view?id=song&t=token&s=salt&u=user",
            "https://music.example/share/id?p=enc:70617373&u=user",
            "https://music.example/share/id?access_token=secret",
        ]
        for value in rejected {
            #expect(throws: ServerMediaSharingError.unsafePublicURL) {
                try ServerMediaShare.validatePublicURL(value)
            }
        }
    }

    @Test("Unsafe URL in a decoded response preserves the security error")
    func preservesUnsafeResponseError() {
        #expect(throws: ServerMediaSharingError.unsafePublicURL) {
            try OpenSubsonicMediaShareCodec.decodeResponse(Data(#"""
            {
              "subsonic-response": {
                "status": "ok",
                "shares": {
                  "share": [{
                    "id": "share-unsafe",
                    "url": "https://music.example/rest/stream.view?id=1&u=user&t=token&s=salt"
                  }]
                }
              }
            }
            """#.utf8))
        }
    }

    @Test("Aggregate targets use stable member song IDs and reject mixed sources")
    func buildsMultiItemTargetsWithoutGuessingLocalEntityIDs() throws {
        let source = MusicSource(
            id: "nav-source",
            name: "Navidrome",
            type: .navidrome,
            host: "music.example"
        )
        let songs = [
            song(id: "local-song-1", path: "/songs/server.a.flac", sourceID: source.id),
            song(id: "local-song-2", path: "/songs/server-b.m4a", sourceID: source.id),
            song(id: "local-song-3", path: "/songs/server.a.mp3", sourceID: source.id),
        ]

        let target = try ServerMediaShareTargetPolicy.makeTarget(
            kind: .album,
            title: "Local album hash is not sent",
            songs: songs,
            source: source
        )
        #expect(target.itemIDs == ["server.a", "server-b"])

        let mixed = songs + [song(
            id: "other",
            path: "/songs/other.flac",
            sourceID: "another-source"
        )]
        #expect(throws: ServerMediaSharingError.invalidTarget) {
            try ServerMediaShareTargetPolicy.makeTarget(
                kind: .playlist,
                title: "Mixed",
                songs: mixed,
                source: source
            )
        }
    }

    @Test("Only Subsonic-family sources can enter the sharing flow")
    func enforcesSourceBoundary() {
        for sourceType in [
            MusicSourceType.subsonic, .navidrome, .airsonic, .gonic,
        ] {
            #expect(ServerMediaShareTargetPolicy.supports(sourceType))
        }
        for sourceType in MusicSourceType.allCases where ![
            .subsonic, .navidrome, .airsonic, .gonic,
        ].contains(sourceType) {
            #expect(!ServerMediaShareTargetPolicy.supports(sourceType))
        }
    }

    private func song(id: String, path: String, sourceID: String) -> Song {
        Song(
            id: id,
            title: id,
            fileFormat: .flac,
            filePath: path,
            sourceID: sourceID
        )
    }
}
