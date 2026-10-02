import Foundation
import Testing
@testable import PrimuseKit

/// 「我的歌声里」的 GBK 字节被当成 Latin-1 读出来的样子。
private let garbledGBKTitle = "\u{CE}\u{D2}\u{B5}\u{C4}\u{B8}\u{E8}\u{C9}\u{F9}\u{C0}\u{EF}"
/// 「邓丽君」的 UTF-8 字节被当成 Latin-1 读出来的样子。
private let garbledUTF8Artist = "\u{E9}\u{82}\u{93}\u{E4}\u{B8}\u{BD}\u{E5}\u{90}\u{9B}"

@Suite("Tag cleanup: garbled and non-standard text")
struct TagCleanupEncodingTests {
    private func proposals(_ songs: [TagCleanupSong]) -> [TagCleanupProposal] {
        TagCleanupPolicy.proposals(for: songs, currentYear: 2026)
    }

    @Test("Garbled titles and artists are decoded again and say why")
    func restoresGarbledText() {
        let result = proposals([TagCleanupSong(
            id: "1", title: garbledGBKTitle, artist: garbledUTF8Artist, album: "Album"
        )])
        #expect(result.contains(TagCleanupProposal(
            songID: "1", field: .title, oldValue: garbledGBKTitle,
            newValue: "我的歌声里", reason: .encodingRepair
        )))
        #expect(result.contains(TagCleanupProposal(
            songID: "1", field: .artist, oldValue: garbledUTF8Artist,
            newValue: "邓丽君", reason: .encodingRepair
        )))
    }

    @Test("A restored value that also needed tidying keeps the encoding as its reason")
    func restoredThenTidied() {
        let result = proposals([TagCleanupSong(id: "1", title: garbledGBKTitle + "  ", artist: "A")])
        #expect(result == [TagCleanupProposal(
            songID: "1", field: .title, oldValue: garbledGBKTitle + "  ",
            newValue: "我的歌声里", reason: .encodingRepair
        )])
    }

    @Test("Text that is already right is never decoded again")
    func leavesValidTextAlone() {
        let result = proposals([
            TagCleanupSong(id: "1", title: "Björk", artist: "Mylène Farmer"),
            TagCleanupSong(id: "2", title: "我的歌声里", artist: "曲婉婷"),
            TagCleanupSong(id: "3", title: "사랑", artist: "아이유"),
        ])
        #expect(result.isEmpty)
    }

    @Test("Lost characters and full-width letters go to the AI service, not to a guess")
    func flagsWhatTheRulesCannotSettle() {
        let lost = TagCleanupSong(id: "1", title: "晴天??", artist: "周杰伦")
        let fullWidth = TagCleanupSong(id: "2", title: "Song", artist: "\u{FF2A}\u{FF21}\u{FF39}")
        let fine = TagCleanupSong(id: "3", title: "晴天", artist: "周杰伦", album: "叶惠美")
        #expect(proposals([lost, fullWidth]).isEmpty)
        #expect(TagCleanupPolicy.needsAttention(lost))
        #expect(TagCleanupPolicy.needsAttention(fullWidth))
        #expect(!TagCleanupPolicy.needsAttention(fine))
    }

    @Test("File and folder names that can vouch for a restored value")
    func references() {
        let path = "Music/叶惠美/03 - 周杰伦 - 晴天.flac"
        #expect(TagCleanupPolicy.encodingReferences(for: .title, fileName: path)
            == ["03 - 周杰伦 - 晴天", "周杰伦 - 晴天", "周杰伦", "晴天"])
        #expect(TagCleanupPolicy.encodingReferences(for: .album, fileName: path) == ["叶惠美"])
        #expect(TagCleanupPolicy.encodingReferences(for: .album, fileName: "song.mp3").isEmpty)
        #expect(TagCleanupPolicy.encodingReferences(for: .genre, fileName: path).isEmpty)
    }

    @Test("Review keeps an exact decoding over an AI guess, otherwise the AI service wins")
    func reviewPrecedence() {
        let local = [
            TagCleanupProposal(songID: "1", field: .title, oldValue: garbledGBKTitle,
                               newValue: "我的歌声里", reason: .encodingRepair),
            TagCleanupProposal(songID: "1", field: .album, oldValue: "a  b", newValue: "a b", reason: .whitespace),
            TagCleanupProposal(songID: "1", field: .genre, oldValue: "pop", newValue: "Pop", reason: .unifiedSpelling),
        ]
        let ai = [
            TagCleanupProposal(songID: "1", field: .title, oldValue: garbledGBKTitle,
                               newValue: "我的歌声", reason: .assistant),
            TagCleanupProposal(songID: "1", field: .album, oldValue: "a  b", newValue: "A B", reason: .assistant),
        ]
        let merged = TagCleanupPolicy.reviewProposals(ai: ai, local: local)
        #expect(merged.map(\.id) == ["1|title", "1|album", "1|genre"])
        #expect(merged.map(\.newValue) == ["我的歌声里", "A B", "Pop"])
    }
}

@Suite("Tag cleanup: shared AI exchange")
struct TagCleanupStructuredExchangeTests {
    @Test("Rows carry tokens and leave out impossible numbers")
    func rows() throws {
        let songs = [
            TagCleanupSong(id: "id-a", title: "T", artist: "A", year: 123_456, trackNumber: 3,
                           discNumber: -1, fileName: "dir/03 T.flac"),
        ]
        let batch = TagCleanupAIExchange.rows(for: songs)
        #expect(batch.rows.count == 1)
        #expect(batch.rows[0].id == "s0")
        #expect(batch.rows[0].year == nil)
        #expect(batch.rows[0].track == 3)
        #expect(batch.rows[0].disc == nil)
        #expect(batch.rows[0].file == "03 T")
        #expect(batch.songsByToken["s0"]?.id == "id-a")

        let payload = try #require(TagCleanupAIExchange.payload(for: songs, languageCode: "zh-Hans"))
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(payload.json.utf8)) as? [String: Any]
        )
        #expect(json["language"] as? String == "zh-Hans")
        let row = try #require((json["songs"] as? [[String: Any]])?.first)
        #expect(Set(row.keys) == ["id", "title", "artist", "track", "file"])
    }

    @Test("Structured changes pass the same checks as a free-form answer")
    func structuredChanges() {
        let song = TagCleanupSong(id: "id-a", title: garbledGBKTitle, artist: "Unknown Artist", year: 2001)
        let proposals = TagCleanupAIExchange.proposals(
            from: [
                .init(id: "s0", field: "title", value: " 我的歌声里 ", reason: "乱码"),
                .init(id: "s0", field: "title", value: "again"),
                .init(id: "s0", field: "artist", value: nil, reason: "占位值"),
                .init(id: "s0", field: "year", value: "2001"),
                .init(id: "s0", field: "track", value: "1000"),
                .init(id: "s5", field: "title", value: "x"),
            ],
            songsByToken: ["s0": song],
            currentYear: 2026
        )
        #expect(proposals.map(\.id) == ["id-a|title", "id-a|artist"])
        #expect(proposals[0].newValue == "我的歌声里")
        #expect(proposals[0].note == "乱码")
        #expect(proposals[1].newValue == nil)
        #expect(proposals.allSatisfy { $0.reason == .assistant })
    }
}
