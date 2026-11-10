import Foundation
import Testing
@testable import PrimuseKit

struct WikipediaInsightTests {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    @Test func searchURLsQuoteNamesAsPhrases() throws {
        let artist = try #require(WikipediaInsightPolicy.artistSearchURL(name: #"AC/DC "Live""#))
        let query = URLComponents(url: artist, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value
        #expect(query == #"artist:"AC/DC \"Live\"""#)
        #expect(artist.host == "musicbrainz.org")
        let album = try #require(WikipediaInsightPolicy.releaseGroupSearchURL(title: "Album", artist: "Artist"))
        let albumQuery = URLComponents(url: album, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value
        #expect(albumQuery == #"releasegroup:"Album" AND artist:"Artist""#)
    }

    @Test func onlyAUniqueExactArtistNameIsAccepted() {
        let data = json(#"{"artists":[{"id":"a1","name":"Nirvana"},{"id":"a2","name":"Nirvana UK"}]}"#)
        let candidates = WikipediaInsightPolicy.artistCandidates(fromSearch: data)
        #expect(WikipediaInsightPolicy.uniqueArtistID(name: "nirvana", in: candidates) == "a1")
        let twins = json(#"{"artists":[{"id":"a1","name":"Nirvana"},{"id":"a2","name":"Nirvana"}]}"#)
        #expect(WikipediaInsightPolicy.uniqueArtistID(
            name: "Nirvana", in: WikipediaInsightPolicy.artistCandidates(fromSearch: twins)) == nil)
    }

    @Test func releaseGroupNeedsTitleAndArtistCredit() {
        let data = json(#"""
        {"release-groups":[
          {"id":"g1","title":"Album","artist-credit":[{"name":"Artist","joinphrase":""}]},
          {"id":"g2","title":"Album","artist-credit":[{"name":"Someone Else"}]}
        ]}
        """#)
        let candidates = WikipediaInsightPolicy.releaseGroupCandidates(fromSearch: data)
        #expect(WikipediaInsightPolicy.uniqueReleaseGroupID(title: "Album", artist: "Artist", in: candidates) == "g1")
        #expect(WikipediaInsightPolicy.uniqueReleaseGroupID(title: "Album", artist: "Nobody", in: candidates) == nil)
    }

    @Test func wikidataIDComesOnlyFromACurrentWikidataRelation() {
        let data = json(#"""
        {"relations":[
          {"type":"official homepage","url":{"resource":"https://example.com/Q1"}},
          {"type":"wikidata","ended":true,"url":{"resource":"https://www.wikidata.org/wiki/Q5"}},
          {"type":"wikidata","url":{"resource":"https://evil.example/wiki/Q7"}},
          {"type":"wikidata","url":{"resource":"https://www.wikidata.org/wiki/Q11649"}}
        ]}
        """#)
        #expect(WikipediaInsightPolicy.wikidataID(fromRelations: data) == "Q11649")
        #expect(WikipediaInsightPolicy.relationsURL(entity: "artist", id: "not-an-id") == nil)
        #expect(WikipediaInsightPolicy.sitelinksURL(wikidataID: "Q1&x=1") == nil)
    }

    @Test func articleFollowsInterfaceLanguageThenEnglish() throws {
        let data = json(#"{"entities":{"Q1":{"sitelinks":{"enwiki":{"title":"Nirvana (band)"},"zhwiki":{"title":"涅槃乐队"}}}}}"#)
        let zh = try #require(WikipediaInsightPolicy.article(fromSitelinks: data, wikidataID: "Q1", languageCode: "zh-Hant"))
        #expect(zh == .init(site: "zh", title: "涅槃乐队", variant: "zh-TW"))
        let ja = try #require(WikipediaInsightPolicy.article(fromSitelinks: data, wikidataID: "Q1", languageCode: "ja"))
        #expect(ja == .init(site: "en", title: "Nirvana (band)", variant: nil))
        let url = try #require(WikipediaInsightPolicy.summaryURL(for: ja))
        #expect(url.absoluteString == "https://en.wikipedia.org/api/rest_v1/page/summary/Nirvana_(band)")
        let slash = try #require(WikipediaInsightPolicy.summaryURL(for: .init(site: "en", title: "AC/DC", variant: nil)))
        #expect(slash.absoluteString == "https://en.wikipedia.org/api/rest_v1/page/summary/AC%2FDC")
    }

    @Test func summaryRejectsDisambiguationAndForeignLinks() {
        let good = json(#"{"type":"standard","extract":" Text. ","content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/X"}}}"#)
        #expect(WikipediaInsightPolicy.summary(fromResponse: good)
            == .init(text: "Text.", pageURL: URL(string: "https://en.wikipedia.org/wiki/X")!))
        let disambiguation = json(#"{"type":"disambiguation","extract":"X may refer to","content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/X"}}}"#)
        #expect(WikipediaInsightPolicy.summary(fromResponse: disambiguation) == nil)
        let foreign = json(#"{"type":"standard","extract":"Text","content_urls":{"desktop":{"page":"https://example.com/wiki/X"}}}"#)
        #expect(WikipediaInsightPolicy.summary(fromResponse: foreign) == nil)
    }

    @Test func wikipediaTextIsNeverWrittenBackToTheMusicSource() {
        let record = LibraryInsightEditing.recordFromImport(
            summary: "Text", tags: [],
            subject: .artist(name: "Artist", genres: [], albums: [], tracks: []), id: "id",
            sourceLabel: WikipediaInsightPolicy.sourceLabel,
            sourceURL: URL(string: "https://zh.wikipedia.org/wiki/X"),
            previous: nil, now: Date(timeIntervalSince1970: 0)
        )
        #expect(record?.permitsSourceWriteback == false)
    }
}
