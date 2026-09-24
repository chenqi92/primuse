import Foundation
import Testing
@testable import PrimuseKit

/// 飞牛服务端 `offset` 经 `[offset:]` 标签进入真实的 LRC 解析器后，时间线要按
/// 「正值＝提前」移动，且标签不会残留在元数据行里。
@Suite("Feiniu lyric offset reaches the LRC timeline")
struct FnMusicLyricOffsetPipelineTests {
    @Test func serverOffsetShiftsParsedTimestampsEarlier() throws {
        let item: [String: Any] = [
            "guid": "g", "source": 1, "offset": 350,
            "content": "[ti:歌名]\n[00:01.00]第一行\n[00:05.50]第二行",
        ]
        let document = try #require(FnMusicLyricSelection.select(payload: ["list": [item]]))
        let lines = LyricsContentParser.parseText(document.text)
        #expect(lines.map(\.text) == ["第一行", "第二行"])
        #expect(lines.map { ($0.timestamp * 1000).rounded() } == [650, 5150])
        #expect(lines.first?.metadataLines?.contains { $0.lowercased().hasPrefix("[offset") } != true)
    }

    @Test func zeroOrMissingServerOffsetLeavesTheDocumentAlone() throws {
        let content = "[offset:-500]\n[00:01.00]第一行"
        for item in [["guid": "g", "content": content], ["guid": "g", "content": content, "offset": 0]] as [[String: Any]] {
            let document = try #require(FnMusicLyricSelection.select(payload: ["list": [item]]))
            #expect(document.text == content)
            let lines = LyricsContentParser.parseText(document.text)
            #expect(lines.first.map { ($0.timestamp * 1000).rounded() } == 1500, "自带标签按 Primuse 既有语义处理")
        }
    }
}
