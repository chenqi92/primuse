import Foundation
import Testing
@testable import PrimuseKit

struct LibraryInsightTests {
    @Test func albumRequestIsClippedDedupedAndCapped() throws {
        let subject = LibraryInsightSubject.album(
            title: "  First   Love ",
            artist: "宇多田ヒカル",
            year: 20011,
            genres: ["J-Pop", "j-pop", "", "R&B", "A", "B", "C", "D"],
            tracks: (0..<50).map { "Track \($0)" } + [String(repeating: "x", count: 300)]
        )
        let request = try #require(LibraryInsightAIExchange.request(for: subject, languageCode: "zh-Hans"))
        #expect(request.kind == .album)
        #expect(request.artist == nil)
        let album = try #require(request.album)
        #expect(album.title == "First Love")
        #expect(album.year == nil)
        #expect(album.genres == ["J-Pop", "R&B", "A", "B", "C"])
        #expect(album.tracks.count == 40)

        let json = LibraryInsightAIExchange.payloadJSON(request) ?? ""
        #expect(json.contains("\"language_code\":\"zh-Hans\""))
        #expect(json.contains("\"kind\":\"album\""))
        #expect(!json.contains("\"artist\":{"))
    }

    @Test func artistRequestKeepsAlbumsWithYears() throws {
        let albums = (0..<25).map { LibraryInsightSubject.AlbumReference(title: "Album \($0)", year: 1990 + $0) }
            + [.init(title: "album 1", year: nil), .init(title: " ", year: 2000)]
        let subject = LibraryInsightSubject.artist(
            name: "Utada", genres: ["Pop"], albums: albums, tracks: (0..<30).map { "Song \($0)" }
        )
        let request = try #require(LibraryInsightAIExchange.request(for: subject, languageCode: "en"))
        let artist = try #require(request.artist)
        #expect(request.album == nil)
        #expect(artist.albums.count == 20)
        #expect(artist.albums.first == .init(title: "Album 0", year: 1990))
        #expect(artist.tracks.count == 20)
    }

    @Test func missingNamesProduceNoRequest() {
        #expect(LibraryInsightAIExchange.request(
            for: .album(title: "  ", artist: "A", year: nil, genres: [], tracks: []),
            languageCode: "en") == nil)
        #expect(LibraryInsightAIExchange.request(
            for: .artist(name: "", genres: [], albums: [], tracks: []),
            languageCode: "en") == nil)
    }

    @Test func knownAnswerIsCleanedAndTagsCapped() throws {
        let output = """
        Sure:
        {"known": true, "summary": "  第一段\\u0007 介绍。\\n\\n第二段   内容。\\n第三段要并进来。",
         "tags": ["J-Pop", "j-pop", "", "R&B", "90 年代", "抒情", "都市", "多余", "\(String(repeating: "长", count: 30))"]}
        """
        let answer = try LibraryInsightAIExchange.answer(from: output)
        #expect(answer.known)
        #expect(answer.summary == "第一段 介绍。\n第二段 内容。 第三段要并进来。")
        #expect(answer.tags == ["J-Pop", "R&B", "90 年代", "抒情", "都市"])
    }

    @Test func unknownOrEmptyAnswersAreBlanked() throws {
        let unknown = try LibraryInsightAIExchange.answer(
            from: #"{"known": false, "summary": "Probably a pop album.", "tags": ["Pop"]}"#
        )
        #expect(unknown == .init(known: false, summary: "", tags: []))
        let empty = try LibraryInsightAIExchange.answer(from: #"{"known": true, "summary": "   ", "tags": ["Pop"]}"#)
        #expect(empty == .init(known: false, summary: "", tags: []))
    }

    @Test func linksAndMalformedAnswersThrow() {
        #expect(throws: LibraryInsightAIExchangeError.containsLink) {
            try LibraryInsightAIExchange.answer(from: #"{"known": true, "summary": "See https://x.com", "tags": []}"#)
        }
        #expect(throws: LibraryInsightAIExchangeError.containsLink) {
            try LibraryInsightAIExchange.answer(from: #"{"known": true, "summary": "Fine.", "tags": ["www.x.com"]}"#)
        }
        #expect(throws: LibraryInsightAIExchangeError.malformedResponse) {
            try LibraryInsightAIExchange.answer(from: "no json here")
        }
        #expect(throws: LibraryInsightAIExchangeError.malformedResponse) {
            try LibraryInsightAIExchange.answer(from: #"{"summary": "x"}"#)
        }
    }

    @Test func longSummariesCutAtSentenceEndOrEllipsis() throws {
        let sentence = String(repeating: "很", count: 99) + "。"
        let long = String(repeating: sentence, count: 7)
        let cut = try LibraryInsightAIExchange.validated(known: true, summary: long, tags: [])
        #expect(cut.summary.count == 600)
        #expect(cut.summary.hasSuffix("。"))

        let decimals = String(repeating: "Version 2.5 of Mr.Children", count: 30)
        let noFalseStop = try LibraryInsightAIExchange.validated(known: true, summary: decimals, tags: [])
        #expect(noFalseStop.summary.hasSuffix("…"))

        let quoted = String(repeating: "x", count: 500) + "他说「好。」" + String(repeating: "y", count: 200)
        let keepsCloser = try LibraryInsightAIExchange.validated(known: true, summary: quoted, tags: [])
        #expect(keepsCloser.summary.hasSuffix("好。」"))

        let noStop = String(repeating: "a", count: 700)
        let hard = try LibraryInsightAIExchange.validated(known: true, summary: noStop, tags: [])
        #expect(hard.summary.count == 600)
        #expect(hard.summary.hasSuffix("…"))
    }

    @Test func recordIDsFollowFoldedNamesOnly() {
        let a = LibraryInsightSubject.album(title: "First Love", artist: "Ｕｔａｄａ", year: nil, genres: [], tracks: [])
        let b = LibraryInsightSubject.album(title: " first love", artist: "utada", year: 1999, genres: ["Pop"], tracks: ["x"])
        #expect(a.recordID() == b.recordID())
        let artist = LibraryInsightSubject.artist(name: "Utada", genres: [], albums: [], tracks: [])
        #expect(artist.recordID() != a.recordID())
        #expect(LibraryInsightAIExchange.normalizedLanguageCode("zh-HK") == "zh-Hant")
        #expect(LibraryInsightAIExchange.normalizedLanguageCode("zh_CN") == "zh-Hans")
        #expect(LibraryInsightAIExchange.normalizedLanguageCode("ja-JP") == "ja")
    }

    @Test func topGenresSplitAndRankByCount() {
        let genres = LibraryInsightSubject.topGenres(["Pop; Rock", "pop", nil, "Jazz", "Other", "Rock"], limit: 2)
        #expect(genres == ["Pop", "Rock"])
    }

    private let subject = LibraryInsightSubject.album(title: "First Love", artist: "Utada", year: nil, genres: [], tracks: [])
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func userTextIsNormalized() {
        let summary = LibraryInsightEditing.normalizedSummary("  第一段   内容 \n\n\n  第二段\t文字 \n")
        #expect(summary == "第一段 内容\n\n第二段 文字")
        #expect(LibraryInsightEditing.tags(fromText: "流行， 九十年代、流行; R&B\n ") == ["流行", "九十年代", "R&B"])
        #expect(LibraryInsightEditing.tags(fromText: (0..<15).map { "t\($0)" }.joined(separator: ",")).count == 10)
        #expect(LibraryInsightEditing.normalizedSummary(String(repeating: "a", count: 3_000)).count == 2_000)
    }

    @Test func aiFillReplacesContentAndUnknownClearsIt() {
        let known = LibraryInsightEditing.recordAfterAIFill(
            .init(known: true, summary: "Intro.", tags: ["Pop"]),
            subject: subject, id: "album-x", providerName: "AI", languageCode: "en", previous: nil, now: t0
        )
        #expect(known.summary == "Intro.")
        #expect(known.aiKnown == true)
        #expect(!known.isUserEdited)
        #expect(known.updatedAt == t0)

        let unknown = LibraryInsightEditing.recordAfterAIFill(
            .init(known: false, summary: "", tags: []),
            subject: subject, id: "album-x", providerName: "AI", languageCode: "en", previous: known, now: t0
        )
        #expect(unknown.summary.isEmpty && unknown.tags.isEmpty)
        #expect(unknown.aiKnown == false)
        #expect(unknown.updatedAt > known.updatedAt)
    }

    @Test func userEditMarksEditedUnlessItKeepsTheAIDraft() throws {
        let draft = (answer: LibraryInsightAIExchange.Answer(known: true, summary: "Intro.", tags: ["Pop"]),
                     providerName: "AI", languageCode: "en")
        let untouched = try #require(LibraryInsightEditing.recordAfterUserEdit(
            summary: "Intro.", tags: ["Pop"], subject: subject, id: "album-x",
            previous: nil, aiDraft: draft, now: t0
        ))
        #expect(!untouched.isUserEdited)
        #expect(untouched.aiProviderName == "AI")

        let edited = try #require(LibraryInsightEditing.recordAfterUserEdit(
            summary: "My own intro.", tags: ["Pop", "pop", "Live"], subject: subject, id: "album-x",
            previous: untouched, aiDraft: nil, now: t0.addingTimeInterval(10)
        ))
        #expect(edited.isUserEdited)
        #expect(edited.tags == ["Pop", "Live"])
        #expect(edited.aiProviderName == "AI")

        let unchanged = LibraryInsightEditing.recordAfterUserEdit(
            summary: " My own intro. ", tags: ["Pop", "Live"], subject: subject, id: "album-x",
            previous: edited, aiDraft: nil, now: t0.addingTimeInterval(20)
        )
        #expect(unchanged == nil)
    }

    @Test func clearingEverythingLeavesATombstone() throws {
        let live = try #require(LibraryInsightEditing.recordAfterUserEdit(
            summary: "Mine", tags: [], subject: subject, id: "album-x", previous: nil, aiDraft: nil, now: t0
        ))
        let cleared = try #require(LibraryInsightEditing.recordAfterUserEdit(
            summary: "  ", tags: [], subject: subject, id: "album-x", previous: live, aiDraft: nil, now: t0
        ))
        #expect(cleared.isDeleted)
        #expect(!cleared.hasContent)
        #expect(cleared.updatedAt > live.updatedAt)
        #expect(LibraryInsightEditing.recordAfterUserEdit(
            summary: "", tags: [], subject: subject, id: "album-x", previous: nil, aiDraft: nil, now: t0
        ) == nil)
        let deleted = LibraryInsightEditing.tombstone(of: live, now: t0)
        #expect(deleted.isDeleted && deleted.summary.isEmpty)
    }

    @Test func importedIntrosAreLabelledAndWorthKeeping() throws {
        let imported = try #require(LibraryInsightEditing.recordFromImport(
            summary: " From the file. ", tags: ["Pop"], subject: subject, id: "album-x",
            sourceLabel: "album.nfo", now: t0
        ))
        #expect(imported.importedFrom == "album.nfo")
        #expect(!imported.isUserEdited)
        #expect(imported.isWorthKeeping)
        #expect(LibraryInsightEditing.recordFromImport(
            summary: "", tags: [], subject: subject, id: "album-x", sourceLabel: "x", now: t0
        ) == nil)
        let edited = try #require(LibraryInsightEditing.recordAfterUserEdit(
            summary: "Changed.", tags: [], subject: subject, id: "album-x",
            previous: imported, aiDraft: nil, now: t0
        ))
        #expect(edited.isUserEdited)
        #expect(edited.importedFrom == "album.nfo")
        let ai = LibraryInsightEditing.recordAfterAIFill(
            .init(known: true, summary: "AI.", tags: []), subject: subject, id: "album-x",
            providerName: "AI", languageCode: "en", previous: edited, now: t0
        )
        #expect(ai.importedFrom == nil)
        #expect(!ai.isWorthKeeping)
    }

    @Test func mergeKeepsTheNewestVersionPerRecord() {
        func record(_ id: String, _ summary: String, _ at: TimeInterval, deleted: Bool = false) -> LibraryInsightRecord {
            LibraryInsightRecord(
                id: id, kind: .album, albumTitle: id, artistName: "A", summary: summary, tags: [],
                isUserEdited: true, updatedAt: t0.addingTimeInterval(at),
                deletedAt: deleted ? t0.addingTimeInterval(at) : nil
            )
        }
        let local = [record("a", "old", 1), record("b", "local only", 1), record("c", "", 5, deleted: true)]
        let incoming = [record("a", "new", 2), record("c", "revived", 3), record("d", "remote only", 1)]
        let merged = LibraryInsightEditing.merged(local, incoming)
        #expect(merged.map(\.id) == ["a", "b", "c", "d"])
        #expect(merged[0].summary == "new")
        #expect(merged[2].isDeleted)
        let tieA = record("x", "aaa", 1)
        let tieB = record("x", "bbb", 1)
        #expect(LibraryInsightEditing.winner(tieA, tieB) == LibraryInsightEditing.winner(tieB, tieA))
    }
}
