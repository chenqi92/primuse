import Foundation
import Testing
@testable import PrimuseKit

@Suite("Apple Music library API")
struct AppleMusicLibraryAPITests {
    @Test("Initial URLs clamp the page limit")
    func initialURLClampsLimit() {
        #expect(
            AppleMusicLibraryAPI.initialURL(for: .songs, limit: 500).absoluteString
                == "https://api.music.apple.com/v1/me/library/songs?limit=100&include=albums"
        )
        #expect(
            AppleMusicLibraryAPI.initialURL(for: .playlists, limit: 0).absoluteString
                == "https://api.music.apple.com/v1/me/library/playlists?limit=1"
        )
    }

    @Test("Relative next links stay on the expected endpoint")
    func relativeNextURL() throws {
        let data = Data(#"{"next":"/v1/me/library/songs?offset=100"}"#.utf8)
        let url = try AppleMusicLibraryAPI.nextPageURL(from: data, endpoint: .songs)
        #expect(url?.absoluteString == "https://api.music.apple.com/v1/me/library/songs?offset=100")
    }

    @Test("A response without a next link ends pagination")
    func missingNextURL() throws {
        let data = Data(#"{"data":[]}"#.utf8)
        #expect(try AppleMusicLibraryAPI.nextPageURL(from: data, endpoint: .songs) == nil)
    }

    @Test("Pagination rejects another host")
    func rejectsAnotherHost() {
        let data = Data(#"{"next":"https://example.com/v1/me/library/songs?offset=100"}"#.utf8)
        #expect(throws: AppleMusicLibraryAPI.PaginationError.self) {
            try AppleMusicLibraryAPI.nextPageURL(from: data, endpoint: .songs)
        }
    }

    @Test("Pagination rejects a different Apple Music endpoint")
    func rejectsDifferentEndpoint() {
        let data = Data(#"{"next":"/v1/me/library/albums?offset=100"}"#.utf8)
        #expect(throws: AppleMusicLibraryAPI.PaginationError.self) {
            try AppleMusicLibraryAPI.nextPageURL(from: data, endpoint: .songs)
        }
    }
}
