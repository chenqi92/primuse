import Foundation
import Testing
@testable import PrimuseKit

@Suite("Filename tag parser")
struct FilenameTagParserTests {

    // MARK: - 规则

    @Test("Artist first splits on the first separator")
    func artistFirst() {
        let tags = FilenameTagParser.parse("孙露 _ 一定要爱你 _ 2.mp3", pattern: .artistFirst)
        #expect(tags.artist == "孙露")
        #expect(tags.title == "一定要爱你")
    }

    @Test("Title first uses the tail as artist")
    func titleFirst() {
        let tags = FilenameTagParser.parse("一定要爱你 - 孙露.mp3", pattern: .titleFirst)
        #expect(tags.artist == "孙露")
        #expect(tags.title == "一定要爱你")
    }

    @Test("Leading track number is stripped and returned")
    func trackAndTitle() {
        let tags = FilenameTagParser.parse("01. 一定要爱你.mp3", pattern: .trackAndTitle)
        #expect(tags.trackNumber == 1)
        #expect(tags.title == "一定要爱你")
    }

    @Test("Whole-name fallback keeps the stem")
    func titleOnly() {
        let tags = FilenameTagParser.parse("没有歌手只当歌名.mp3", pattern: .titleOnly)
        #expect(tags.title == "没有歌手只当歌名")
    }

    @Test("A separator at the very end does not produce an empty field")
    func danglingSeparatorFallsBack() {
        let tags = FilenameTagParser.parse("歌名 -", pattern: .artistFirst)
        #expect(tags.artist == nil)
        #expect(tags.title == "歌名")
    }

    // MARK: - 清理

    @Test("Parenthesised duplicate counters are dropped from the title")
    func stripsParenthesisedCounter() {
        let tags = FilenameTagParser.parse("一定要爱你 (2).mp3", pattern: .titleOnly)
        #expect(tags.title == "一定要爱你")
    }

    @Test("A bare `_ 2` suffix is dropped only when separated")
    func stripsSeparatedCounter() {
        let tags = FilenameTagParser.parse("孙露 _ 一定要爱你 _ 2.mp3", pattern: .artistFirst)
        #expect(tags.title == "一定要爱你")
    }

    @Test("Numeric titles like 1994 survive untouched")
    func keepsPureNumericTitles() {
        let tags = FilenameTagParser.parse("1994.mp3", pattern: .titleOnly)
        #expect(tags.title == "1994")
    }

    @Test("Path components and extensions are stripped")
    func normalizesStem() {
        let tags = FilenameTagParser.parse("/music/孙露/吻到心伤透.mp3", pattern: .titleOnly)
        #expect(tags.title == "吻到心伤透")
    }

    // MARK: - 批量

    @Test("Suggests artistFirst when the head column is stable across files")
    func suggestsArtistFirst() {
        let pattern = FilenameTagParser.suggestedPattern(for: [
            "孙露 _ 一定要爱你.mp3",
            "孙露 _ 月满西楼.mp3",
            "孙露 _ 千年缘.mp3",
        ])
        #expect(pattern == .artistFirst)
    }

    @Test("Suggests titleFirst when the tail column is the stable one")
    func suggestsTitleFirst() {
        let pattern = FilenameTagParser.suggestedPattern(for: [
            "A1 - 孙露.mp3",
            "A2 - 孙露.mp3",
            "A3 - 孙露.mp3",
        ])
        #expect(pattern == .titleFirst)
    }

    @Test("Suggests titleOnly for a folder with no separators")
    func suggestsTitleOnly() {
        let pattern = FilenameTagParser.suggestedPattern(for: [
            "无分隔文件名一.mp3",
            "无分隔文件名二.mp3",
        ])
        #expect(pattern == .titleOnly)
    }

    @Test("Neighbouring artists are ranked by frequency")
    func neighbouringArtistsRanking() {
        let artists = FilenameTagParser.neighbouringArtists(from: [
            "孙露 _ 一定要爱你.mp3",
            "雷婷 _ 丁香花.mp3",
            "孙露 _ 月满西楼.mp3",
            "孙露 _ 千年缘.mp3",
        ])
        #expect(artists.first == "孙露")
        #expect(artists.contains("雷婷"))
    }

    // MARK: - 候选

    @Test("Candidates deduplicate across rules")
    func candidatesDeduplicate() {
        let candidates = FilenameTagParser.candidates(for: "孙露 _ 一定要爱你 _ 2.mp3")
        let keys = Set(candidates.map { "\($0.tags.artist ?? "")·\($0.tags.title)" })
        #expect(keys.count == candidates.count)
    }
}
