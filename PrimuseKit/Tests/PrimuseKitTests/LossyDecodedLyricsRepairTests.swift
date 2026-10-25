import Foundation
import Testing
@testable import PrimuseKit

/// 复现服务端的那一步: 文件是 `encoding` 编码的, 服务端整份当 UTF-8 宽松解码后交出来。
private func serverDecoded(
    _ document: String,
    as encoding: String.Encoding,
    perByte: Bool = false
) throws -> [LyricLine] {
    let bytes = [UInt8](try #require(document.data(using: encoding)))
    let text = perByte
        ? LossyDecodedLyricsRepair.replacingEachInvalidByte(bytes)
        : String(decoding: bytes, as: UTF8.self)
    return LyricsContentParser.parseText(text)
}

private let simplifiedDocument = """
[00:01.00]编曲：林小风
[00:05.00]晚风吹过旧街口
[00:09.50]路灯照亮你回头
[00:14.00]说好明天一起走
[00:18.20]为何时间不停留
[00:22.00]听见远方飞来的歌
[00:26.00]晚风吹过旧街口
[00:30.50]路灯照亮你回头
"""

/// 在线搜到的那份: 繁体, 时间轴也和文件不一样。
private let traditionalReference = """
[00:01.30]編曲：林小風
[00:05.40]晚風吹過舊街口
[00:09.90]路燈照亮你回頭
[00:14.30]說好明天一起走
[00:18.60]為何時間不停留
[00:22.30]聽見遠方飛來的歌
[00:26.40]晚風吹過舊街口
[00:30.90]路燈照亮你回頭
"""

private func texts(_ lines: [LyricLine]) -> [String] { lines.map(\.text) }

@Suite("Lyrics a server decoded lossily as UTF-8")
struct LossyDecodedLyricsRepairTests {
    @Test("A GBK document read as UTF-8 is recognised, clean lyrics are not")
    func detection() throws {
        let damaged = try serverDecoded(simplifiedDocument, as: TextEncodingRepair.gb18030)
        #expect(LossyDecodedLyricsRepair.isDamaged(damaged))
        #expect(!LossyDecodedLyricsRepair.isDamaged(LyricsContentParser.parseText(simplifiedDocument)))
        #expect(!LossyDecodedLyricsRepair.isDamaged(LyricsContentParser.parseText(traditionalReference)))
        // 一个孤零零的替换符可能是文件里本来就有的坏字, 不算整份坏了。
        #expect(!LossyDecodedLyricsRepair.isDamaged("[00:01.00]晚风\u{FFFD}吹过"))
    }

    @Test("A verified reference restores the text and keeps the file's own timing")
    func restoresFromTraditionalReference() throws {
        let damaged = try serverDecoded(simplifiedDocument, as: TextEncodingRepair.gb18030)
        let reference = LyricsContentParser.parseText(traditionalReference)
        let restored = try #require(LossyDecodedLyricsRepair.restored(damaged, using: reference))

        #expect(texts(restored) == texts(LyricsContentParser.parseText(simplifiedDocument)))
        #expect(restored.map(\.timestamp) == damaged.map(\.timestamp))
        #expect(!LossyDecodedLyricsRepair.isDamaged(restored))
    }

    @Test("Servers that replace every invalid byte (Go) are restored too")
    func restoresPerByteReplacement() throws {
        let damaged = try serverDecoded(simplifiedDocument, as: TextEncodingRepair.gb18030, perByte: true)
        #expect(LossyDecodedLyricsRepair.isDamaged(damaged))
        let reference = LyricsContentParser.parseText(traditionalReference)
        let restored = try #require(LossyDecodedLyricsRepair.restored(damaged, using: reference))
        #expect(texts(restored) == texts(LyricsContentParser.parseText(simplifiedDocument)))
    }

    @Test("A Big5 file is restored from a simplified reference")
    func restoresBig5FromSimplifiedReference() throws {
        let damaged = try serverDecoded(traditionalReference, as: TextEncodingRepair.big5)
        #expect(LossyDecodedLyricsRepair.isDamaged(damaged))
        let reference = LyricsContentParser.parseText(simplifiedDocument)
        let restored = try #require(LossyDecodedLyricsRepair.restored(damaged, using: reference))
        #expect(texts(restored) == texts(LyricsContentParser.parseText(traditionalReference)))
    }

    @Test("Another song's lyrics never fill in the damaged lines")
    func rejectsUnrelatedReference() throws {
        let damaged = try serverDecoded(simplifiedDocument, as: TextEncodingRepair.gb18030)
        let unrelated = LyricsContentParser.parseText("""
        [00:01.00]海边的灯塔亮了
        [00:05.00]船还没有回来
        [00:09.00]我在码头等你
        """)
        #expect(LossyDecodedLyricsRepair.restored(damaged, using: unrelated) == nil)
    }

    @Test("A reference missing one line gives up instead of restoring half a document")
    func rejectsIncompleteReference() throws {
        let damaged = try serverDecoded(simplifiedDocument, as: TextEncodingRepair.gb18030)
        let partial = LyricsContentParser.parseText(
            traditionalReference
                .components(separatedBy: "\n")
                .filter { !$0.contains("聽見遠方") }
                .joined(separator: "\n")
        )
        #expect(LossyDecodedLyricsRepair.restored(damaged, using: partial) == nil)
    }

    @Test("A few damaged credit lines are dropped, a fully damaged document is not usable")
    func stripsOnlyMinorDamage() throws {
        let english = """
        [00:01.00]编曲：林小风
        [00:05.00]Walking down the road tonight
        [00:09.00]Every light is shining bright
        [00:13.00]Hold my hand and hold on tight
        [00:17.00]We will be alright
        [00:21.00]Walking down the road tonight
        """
        let damagedEnglish = try serverDecoded(english, as: TextEncodingRepair.gb18030)
        #expect(LossyDecodedLyricsRepair.isDamaged(damagedEnglish))
        let stripped = try #require(LossyDecodedLyricsRepair.usableDocument(damagedEnglish))
        #expect(stripped.count == damagedEnglish.count - 1)
        #expect(!LossyDecodedLyricsRepair.isDamaged(stripped))

        let damagedChinese = try serverDecoded(simplifiedDocument, as: TextEncodingRepair.gb18030)
        #expect(LossyDecodedLyricsRepair.usableDocument(damagedChinese) == nil)
    }

    @Test("Clean lyrics pass through untouched")
    func cleanDocumentIsUnchanged() {
        let clean = LyricsContentParser.parseText(simplifiedDocument)
        #expect(LossyDecodedLyricsRepair.usableDocument(clean) == clean)
    }
}
