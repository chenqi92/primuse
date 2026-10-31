import Foundation
import Testing
@testable import PrimuseKit

struct LastFmLibraryInsightTests {
    private let artist = LibraryInsightSubject.artist(name: "Artist", genres: [], albums: [], tracks: [])
    private let album = LibraryInsightSubject.album(title: "Album", artist: "Artist", year: nil, genres: [], tracks: [])

    @Test func queryKeepsAlbumAndArtistNamesAndUsesISOLanguage() throws {
        let subject = LibraryInsightSubject.album(title: "A & B / C", artist: "Artist + Band", year: nil, genres: [], tracks: [])
        let items = try #require(LastFmLibraryInsight.queryItems(for: subject, languageCode: "zh-Hant"))
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query["method"] == "album.getInfo")
        #expect(query["album"] == subject.albumTitle)
        #expect(query["artist"] == subject.artistName)
        #expect(query["lang"] == "zh")
        #expect(LastFmLibraryInsight.language("pt-BR") == "pt")
        #expect(LastFmLibraryInsight.language("en_US") == "en")
        #expect(LastFmLibraryInsight.language("") == "en")
        #expect(LastFmLibraryInsight.queryItems(for: .album(title: "Album", artist: "", year: nil, genres: [], tracks: []), languageCode: "en") == nil)
        #expect(LastFmLibraryInsight.queryItems(for: artist, languageCode: "en")?.contains { $0.name == "album" } == false)
    }

    @Test func artistFullBiographyWinsAndFooterDoesNotBecomeContent() throws {
        let data = Data(#"{"artist":{"url":"http://www.last.fm/music/Artist?tracking=1","bio":{"summary":"Short","content":"<p>Full &amp; detailed &#x27;bio&#039;.</p><p>Second paragraph.</p><a href=\"https://www.last.fm/music/Artist\">Read more on Last.fm</a>. User-contributed text is available under a license."},"tags":{"tag":[{"name":"Rock"},{"name":"rock"},{"name":" Pop "}]}}}"#.utf8)
        let result = try #require(try LastFmLibraryInsight.decode(data, for: artist))
        #expect(result.summary == "Full & detailed 'bio'.\n\nSecond paragraph.")
        #expect(result.tags == ["Rock", "Pop"])
        #expect(result.sourceLabel == "Last.fm")
        #expect(result.sourceURL?.absoluteString == "https://www.last.fm/music/Artist")
    }

    @Test func albumWikiFallsBackToSummaryAndAcceptsSingleTag() throws {
        let data = Data(#"{"album":{"wiki":{"content":" ","summary":"An album.<br />Second line."},"tags":{"tag":{"name":"Pop"}}}}"#.utf8)
        let result = try #require(try LastFmLibraryInsight.decode(data, for: album))
        #expect(result.summary == "An album.\nSecond line.")
        #expect(result.tags == ["Pop"])
        #expect(result.sourceURL?.absoluteString == "https://www.last.fm/music/Artist/Album")
    }

    @Test func missingWikiTagsOnlyAndFooterOnlyAreNotIntroductions() throws {
        for json in [
            #"{"album":{"tags":{"tag":[{"name":"Rock"}]}}}"#,
            #"{"album":{"wiki":{"summary":"<a href=\"https://www.last.fm/music/Artist/Album\">Read more on Last.fm</a>."}}}"#
        ] {
            #expect(try LastFmLibraryInsight.decode(Data(json.utf8), for: album) == nil)
        }
        #expect(throws: (any Error).self) { try LastFmLibraryInsight.decode(Data("{}".utf8), for: artist) }
    }

    @Test func importedTextUsesTheExistingLengthLimitAndRejectsUntrustedSourceLinks() throws {
        for url in ["https://last.fm.evil.example/music/a", "javascript:alert(1)", "https://secret@www.last.fm/music/a"] {
            let data = try JSONSerialization.data(withJSONObject: ["album": ["url": url, "wiki": ["content": String(repeating: "a", count: 2500)]]])
            let result = try #require(try LastFmLibraryInsight.decode(data, for: album))
            #expect(result.summary.count == LibraryInsightEditing.maximumUserSummaryLength)
            #expect(result.sourceURL?.absoluteString == "https://www.last.fm/music/Artist/Album")
        }
    }

    @Test func unchangedImportedDraftRetainsProvenanceButManualChangesAreEdited() throws {
        let draft = LibraryInsightImportedDraft(summary: "Biography", tags: ["Rock"], sourceLabel: "Last.fm", sourceURL: URL(string: "https://www.last.fm/music/Artist"))
        for edited in [false, true] {
            let record = try #require(LibraryInsightEditing.recordAfterUserEdit(
                summary: edited ? "My edit" : draft.summary, tags: draft.tags, subject: artist,
                id: artist.recordID(), previous: nil, aiDraft: nil, importedDraft: draft, now: Date()
            ))
            #expect(record.isUserEdited == edited)
            #expect(record.importedFrom == "Last.fm")
            #expect(record.importedURL == draft.sourceURL)
            #expect(record.aiKnown == nil)
            #expect(record.aiProviderName == nil)
            #expect(try JSONDecoder().decode(LibraryInsightRecord.self, from: JSONEncoder().encode(record)) == record)
        }
    }

    @Test func explicitFetchRevivesTombstoneWithANewerVersionAndClearsAIProvenance() throws {
        let previous = LibraryInsightRecord(id: album.recordID(), kind: .album, albumTitle: "Album", artistName: "Artist", summary: "", tags: [], aiKnown: true, aiProviderName: "AI", isUserEdited: false, updatedAt: Date(timeIntervalSince1970: 100), deletedAt: Date(timeIntervalSince1970: 100))
        let result = try #require(LibraryInsightEditing.recordFromImport(
            summary: "Album description", tags: ["Rock"], subject: album, id: album.recordID(),
            sourceLabel: "Last.fm", previous: previous, now: Date(timeIntervalSince1970: 10)
        ))
        #expect(result.updatedAt > previous.updatedAt)
        #expect(!result.isDeleted)
        #expect(result.aiProviderName == nil)
        #expect(LibraryInsightEditing.winner(previous, result) == result)
    }

    @Test func oldSnapshotsWithoutSourceURLStillDecode() throws {
        let old = Data(#"{"id":"artist","kind":"artist","albumTitle":"","artistName":"Artist","summary":"Old","tags":[],"isUserEdited":true,"updatedAt":0}"#.utf8)
        #expect(try JSONDecoder().decode(LibraryInsightRecord.self, from: old).importedURL == nil)
    }

    @Test func aiFillClearsImportedAttribution() throws {
        let previous = LibraryInsightEditing.recordFromImport(summary: "Old", tags: [], subject: artist, id: artist.recordID(), sourceLabel: "Last.fm", sourceURL: URL(string: "https://www.last.fm/music/Artist"), now: Date())
        let result = LibraryInsightEditing.recordAfterAIFill(.init(known: true, summary: "New", tags: []), subject: artist, id: artist.recordID(), providerName: "AI", languageCode: "en", previous: previous, now: Date())
        #expect(result.importedFrom == nil)
        #expect(result.importedURL == nil)
        #expect(result.aiProviderName == "AI")
        let editedAI = try #require(LibraryInsightEditing.recordAfterUserEdit(
            summary: "Edited AI text", tags: [], subject: artist, id: artist.recordID(), previous: previous,
            aiDraft: (.init(known: true, summary: "AI text", tags: []), "AI", "en"), now: Date()
        ))
        #expect(editedAI.isUserEdited)
        #expect(editedAI.importedFrom == nil)
        #expect(editedAI.importedURL == nil)
    }
}
