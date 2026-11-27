import Foundation
import Testing
@testable import PrimuseKit

@Suite("External spoken-word transcripts")
struct SpokenTranscriptSourcesTests {
    /// 转写工具导出的逐词 WebVTT:一个 cue 一个词(合成样本,不含教材原文)。
    private let wordPerCueVTT = """
    WEBVTT

    00:00:01.000 --> 00:00:01.400
    We

    00:00:01.400 --> 00:00:01.800
    learn

    00:00:01.800 --> 00:00:02.200
    together.

    00:00:05.000 --> 00:00:05.400
    Again

    00:00:05.400 --> 00:00:05.900
    tomorrow.
    """

    private let sentenceVTT = """
    WEBVTT

    00:00:01.000 --> 00:00:02.200
    We learn together.

    00:00:05.000 --> 00:00:05.900
    Again tomorrow.
    """

    // MARK: - Parsing

    @Test("A word-per-cue WebVTT becomes sentence lines with one syllable per cue")
    func groupsWordPerCueSubtitles() throws {
        let lines = LyricsContentParser.parseText(wordPerCueVTT)
        #expect(lines.map(\.text) == ["We learn together.", "Again tomorrow."])
        let first = try #require(lines.first)
        #expect(first.timestamp == 1)
        #expect(first.isSynchronized)
        #expect(first.syllables?.map(\.start) == [1, 1.4, 1.8])
        #expect(first.syllables?.map(\.end) == [1.4, 1.8, 2.2])
        let everyLineIsWordTimed = lines.allSatisfy { $0.containsWordLevelContent }
        #expect(everyLineIsWordTimed)
        #expect(LyricsFormat.detect(wordPerCueVTT) == .wordLevel)
        #expect(LyricsTimingLevel(lines: lines) == .word)
    }

    @Test("Sentence subtitles without spaces stay one line per cue")
    func keepsSentenceCuesWithoutSpaces() {
        let document = """
        1
        00:00:01,000 --> 00:00:04,000
        我们一起学习。

        2
        00:00:04,000 --> 00:00:07,000
        今天天气很好。

        3
        00:00:07,000 --> 00:00:09,000
        明天见。
        """
        let lines = SubtitleLyricsParser.parse(document)
        #expect(lines.map(\.text) == ["我们一起学习。", "今天天气很好。", "明天见。"])
        let hasWordTiming = lines.contains { $0.containsWordLevelContent }
        #expect(!hasWordTiming)
    }

    @Test("Enhanced LRC keeps its word timing")
    func readsEnhancedLRC() {
        let elrc = "[00:01.00]<00:01.00>We <00:01.40>learn <00:01.80>together.<00:02.20>"
        let lines = LyricsContentParser.parseText(elrc)
        #expect(lines.count == 1)
        #expect(LyricsTimingLevel(lines: lines) == .word)
    }

    // MARK: - Audiobookshelf items

    private static var courseJSON: [String: Any] { [
        "id": "li_course",
        "libraryId": "lib_books",
        "mediaType": "book",
        "media": [
            "duration": 300.0,
            "metadata": ["title": "Course"],
            "audioFiles": [
                ["ino": "21", "index": 1, "duration": 100.0,
                 "metadata": ["filename": "chapter01.mp3", "ext": ".mp3", "relPath": "chapter01.mp3", "size": 10]],
                ["ino": "22", "index": 2, "duration": 200.0,
                 "metadata": ["filename": "chapter02.mp3", "ext": ".mp3", "relPath": "CD2/chapter02.mp3", "size": 10]],
            ],
        ],
        "libraryFiles": [
            ["ino": "21", "metadata": ["filename": "chapter01.mp3", "relPath": "chapter01.mp3", "size": 10]],
            ["ino": "31", "metadata": ["filename": "chapter01.vtt", "relPath": "chapter01.vtt", "size": 100]],
            ["ino": "32", "metadata": ["filename": "chapter01.en.srt", "relPath": "chapter01.en.srt", "size": 100]],
            ["ino": "33", "metadata": ["filename": "chapter02.lrc", "relPath": "chapter02.lrc", "size": 100]],
            ["ino": "34", "metadata": ["filename": "Chapter02.LRC", "relPath": "CD2/Chapter02.LRC", "size": 100]],
            ["ino": "35", "metadata": ["filename": "cover.jpg", "relPath": "cover.jpg", "size": 100]],
        ],
    ] }

    @Test("Transcripts are the same-name files in the audio file's own folder")
    func findsSameNameTranscripts() throws {
        let item = try #require(AudiobookshelfCatalogItem(json: Self.courseJSON))
        #expect(item.listsLibraryFiles)
        #expect(!item.isSingleFileItem)
        #expect(item.libraryFiles.count == 6)
        #expect(item.audioFiles.map(\.relPath) == ["chapter01.mp3", "CD2/chapter02.mp3"])
        #expect(item.transcriptFiles(for: .file(ino: "21")).map(\.ino) == ["31", "32"])
        // 根目录那份 chapter02.lrc 不是 CD2 里那个音频的。
        #expect(item.transcriptFiles(for: .file(ino: "22")).map(\.ino) == ["34"])
        #expect(item.transcriptFiles(for: .file(ino: "99")).isEmpty)

        let minimal = try #require(AudiobookshelfCatalogItem(json: ["id": "li_min", "media": [String: Any]()]))
        #expect(!minimal.listsLibraryFiles)
    }

    @Test("Each file of a multi-file book has its own window on the book timeline")
    func multiFileSegments() throws {
        let item = try #require(AudiobookshelfCatalogItem(json: Self.courseJSON))
        #expect(item.transcriptSegment(for: .file(ino: "21"))
            == CueTrackLyricsTimelinePolicy.Segment(start: 0, end: 100, duration: 100))
        #expect(item.transcriptSegment(for: .file(ino: "22"))
            == CueTrackLyricsTimelinePolicy.Segment(start: 100, end: nil, duration: 200))

        var single = Self.courseJSON
        var media = try #require(single["media"] as? [String: Any])
        let oneFile: [[String: Any]] = [
            ["ino": "21", "index": 1, "duration": 100.0, "metadata": ["filename": "book.m4b", "ext": ".m4b"]],
        ]
        media["audioFiles"] = oneFile
        single["media"] = media
        let singleItem = try #require(AudiobookshelfCatalogItem(json: single))
        #expect(singleItem.transcriptSegment(for: .file(ino: "21")) == nil)
    }

    @Test("Reading a transcript prefers the finer timing and reports files that vanished")
    func readsTranscriptThroughFileEndpoint() async throws {
        let requested = AudiobookshelfPathLog()
        let sentence = sentenceVTT
        let words = wordPerCueVTT
        let transport = AudiobookshelfRequestTransport(data: { request in
            let url = try #require(request.url)
            await requested.append(request.httpMethod ?? "GET", url.path)
            let body: String?
            switch url.path {
            case "/api/items/li_course/file/31": body = sentence
            case "/api/items/li_course/file/32": body = words
            default: body = nil
            }
            let status = body == nil ? 404 : 200
            return (Data((body ?? "").utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }, download: { _ in throw URLError(.unsupportedURL) })
        let client = AudiobookshelfServiceClient(sourceID: UUID().uuidString, host: "books.invalid",
            port: nil, useSSL: true, basePath: nil, username: "", secret: "fixture", authType: .apiKey, transport: transport)
        let item = try #require(AudiobookshelfCatalogItem(json: Self.courseJSON))

        let first = AudiobookshelfAPIProtocol.TrackReference(itemID: "li_course", kind: .file(ino: "21"), fileExtension: "mp3")
        let read = try await client.transcriptDocument(for: first, in: item, maximumBytes: 1_000_000)
        #expect(read == .document(fileName: "chapter01.en.srt", text: words))

        let second = AudiobookshelfAPIProtocol.TrackReference(itemID: "li_course", kind: .file(ino: "22"), fileExtension: "mp3")
        #expect(try await client.transcriptDocument(for: second, in: item, maximumBytes: 1_000_000) == .stale)
        #expect(try await client.transcriptDocument(for: first, in: item, maximumBytes: 50) == .absent)
        #expect(await requested.paths.contains("GET /api/items/li_course/file/34"))
    }

    @Test("Asking the server to rescan an item tells a refusal apart from a failure")
    func scansItem() async throws {
        let statuses = AudiobookshelfPathLog()
        let transport = AudiobookshelfRequestTransport(data: { request in
            let url = try #require(request.url)
            await statuses.append(request.httpMethod ?? "GET", url.path)
            let status = url.path.contains("li_admin") ? 200 : 403
            return (Data("{}".utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }, download: { _ in throw URLError(.unsupportedURL) })
        let client = AudiobookshelfServiceClient(sourceID: UUID().uuidString, host: "books.invalid",
            port: nil, useSSL: true, basePath: nil, username: "", secret: "fixture", authType: .apiKey, transport: transport)
        #expect(try await client.scanItem(id: "li_admin") == .scanned)
        #expect(try await client.scanItem(id: "li_user") == .notPermitted)
        #expect(await statuses.paths == ["POST /api/items/li_admin/scan", "POST /api/items/li_user/scan"])
        #expect(LyricsAuthoritativeSourcePolicy.supportsServerDocument(.audiobookshelf))
    }

    // MARK: - Timeline

    @Test("Book-time transcripts move onto the file's own timeline; file-time ones stay")
    func localizesBookTimeTranscripts() throws {
        let segment = CueTrackLyricsTimelinePolicy.Segment(start: 100, end: 300, duration: 200)
        let local = LyricsContentParser.parseText("[00:01.00]One\n[00:50.00]Two\n[03:10.00]Three")
        #expect(SpokenTranscriptTrackTimeline.localized(local, in: segment).map(\.timestamp) == [1, 50, 190])
        #expect(SpokenTranscriptTrackTimeline.localized(local, in: nil).map(\.timestamp) == [1, 50, 190])

        // 整本书只有一份:只留这个文件时间窗里的行。
        let wholeBook = LyricsContentParser.parseText(
            "[00:10.00]A\n[00:50.00]B\n[02:00.00]C\n[04:10.00]D\n[05:20.00]E\n[06:40.00]F"
        )
        #expect(SpokenTranscriptTrackTimeline.localized(wholeBook, in: segment).map(\.timestamp) == [20, 150])

        #expect(SpokenTranscriptTrackTimeline.segments(durations: [100, 200, 50]) == [
            CueTrackLyricsTimelinePolicy.Segment(start: 0, end: 100, duration: 100),
            CueTrackLyricsTimelinePolicy.Segment(start: 100, end: 300, duration: 200),
            CueTrackLyricsTimelinePolicy.Segment(start: 300, end: nil, duration: 50),
        ])
        #expect(SpokenTranscriptTrackTimeline.segments(durations: [100]) == [nil])
        #expect(SpokenTranscriptTrackTimeline.segments(durations: [100, 0]) == [nil, nil])
    }

    @Test("The picked server transcript is handed over in the file's own time")
    func picksAndLocalizesServerTranscript() throws {
        let bookTime = AudiobookshelfTranscriptPolicy.Document(
            fileName: "chapter02.lrc",
            text: "[01:50.00]First\n[03:40.00]Second\n[04:20.00]Third\n[04:50.00]Fourth"
        )
        let segment = CueTrackLyricsTimelinePolicy.Segment(start: 100, end: nil, duration: 200)
        let picked = try #require(AudiobookshelfTranscriptPolicy.pick([bookTime], segment: segment))
        #expect(picked.fileName == "chapter02.lrc")
        #expect(LyricsContentParser.parseText(picked.text).map(\.timestamp) == [10, 120, 160, 190])

        let sentence = AudiobookshelfTranscriptPolicy.Document(fileName: "a.vtt", text: sentenceVTT)
        let words = AudiobookshelfTranscriptPolicy.Document(fileName: "a.en.vtt", text: wordPerCueVTT)
        #expect(AudiobookshelfTranscriptPolicy.pick([sentence, words], segment: nil) == words)
        #expect(AudiobookshelfTranscriptPolicy.pick([sentence], segment: nil) == sentence)
        #expect(AudiobookshelfTranscriptPolicy.pick([], segment: nil) == nil)
    }

    // MARK: - Precedence

    @Test("User transcripts outrank server ones, server ones outrank generated ones")
    func precedence() {
        let plain = [LyricLine(timestamp: 1, text: "Hello", isSynchronized: true)]
        var user = plain
        user[0].documentIsLocalOverride = true
        let server = LyricsDocumentSource.server(MusicSourceType.audiobookshelf.rawValue).stamped(plain)
        let generated = LyricsDocumentSource.transcript.stamped(plain)

        #expect(SpokenTranscriptOrigin(lines: user) == .userProvided)
        #expect(SpokenTranscriptOrigin(lines: server) == .server)
        #expect(SpokenTranscriptOrigin(lines: generated) == .generated)
        #expect(SpokenTranscriptOrigin(lines: plain) == .other)
        #expect(SpokenTranscriptOrigin(lines: []) == nil)

        #expect(SpokenTranscriptPrecedencePolicy.automaticServerDecision(current: user) == .keep)
        #expect(SpokenTranscriptPrecedencePolicy.automaticServerDecision(current: generated) == .replace)
        #expect(SpokenTranscriptPrecedencePolicy.automaticServerDecision(current: server) == .replaceIfImproved)
        #expect(SpokenTranscriptPrecedencePolicy.automaticServerDecision(current: nil) == .replaceIfImproved)

        #expect(SpokenTranscriptPrecedencePolicy.explicitReloadNeedsConfirmation(current: user))
        #expect(!SpokenTranscriptPrecedencePolicy.explicitReloadNeedsConfirmation(current: generated))
        #expect(SpokenTranscriptPrecedencePolicy.pinsGeneratedTranscript(replacing: server))
        #expect(!SpokenTranscriptPrecedencePolicy.pinsGeneratedTranscript(replacing: user))
        #expect(!SpokenTranscriptPrecedencePolicy.pinsGeneratedTranscript(replacing: nil))
    }
}

private actor AudiobookshelfPathLog {
    private(set) var paths: [String] = []

    func append(_ method: String, _ path: String) {
        paths.append("\(method) \(path)")
    }
}
