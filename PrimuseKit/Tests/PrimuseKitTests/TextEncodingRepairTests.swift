import Foundation
import Testing
@testable import PrimuseKit

/// 模拟真实的乱码过程: 标签里写的是 `wrote` 编码的字节, 读的人按 `read`
/// 解出来。测试用例因此不需要硬编码乱码字符串, 而是复现产生它的那一步。
private func mojibake(
    _ text: String,
    wrote: String.Encoding,
    read: String.Encoding
) -> String? {
    guard let bytes = text.data(using: wrote) else { return nil }
    return String(data: bytes, encoding: read)
}

// MARK: - 单字节误读 (旧实现已覆盖的方向, 防回归)

@Test func repairsSimplifiedChineseReadAsLatin1() throws {
    let original = "我的歌声里"
    let broken = try #require(mojibake(original, wrote: TextEncodingRepair.gb18030, read: .isoLatin1))

    #expect(broken != original)
    #expect(TextEncodingRepair.repaired(broken) == original)
}

@Test func repairsUTF8ReadAsLatin1() throws {
    let original = "邓丽君"
    let broken = try #require(mojibake(original, wrote: .utf8, read: .isoLatin1))

    #expect(TextEncodingRepair.repaired(broken) == original)
}

// MARK: - 多字节互串 (Han -> Han, 旧实现完全无法检测)

@Test func repairsUTF8ReadAsGBK() throws {
    // 汉字数取偶数, 12 个 UTF-8 字节才能被 GBK 成对读完、不留落单字节。
    let original = "我的歌声"
    let broken = try #require(mojibake(original, wrote: .utf8, read: TextEncodingRepair.gb18030))

    // 这类乱码一个扩展拉丁字符都没有 —— 旧的 A1-FF 计数器看不见它。
    #expect(broken.unicodeScalars.allSatisfy { !(0xA1...0xFF).contains($0.value) })
    #expect(broken != original)
    #expect(TextEncodingRepair.repaired(broken) == original)
}

@Test func repairsLongerUTF8ReadAsGBK() throws {
    let original = "夜空中最亮的星"
    guard let broken = mojibake(original, wrote: .utf8, read: TextEncodingRepair.gb18030) else {
        // 奇数字节会留下落单尾字节, GBK 可能整串拒解 —— 那就不存在这种乱码。
        return
    }

    #expect(TextEncodingRepair.repaired(broken) == original)
}

// MARK: - CP1252 的 0x80-0x9F 区 (旧实现漏检整个区间)

@Test func repairsCP1252SmartQuoteMojibake() throws {
    let original = "Don\u{2019}t Stop Believin\u{2019}"
    let broken = try #require(mojibake(original, wrote: .utf8, read: .windowsCP1252))

    // "â€™" 里只有 â 落在 A1-FF, 旧阈值(>=2)因此永远不触发。
    let extendedLatin = broken.unicodeScalars.filter { (0xA1...0xFF).contains($0.value) }.count
    #expect(extendedLatin >= 1)
    #expect(TextEncodingRepair.looksCorrupted(broken))
    #expect(TextEncodingRepair.repaired(broken) == original)
}

// MARK: - 日语 / 韩语

@Test func repairsJapaneseShiftJISReadAsLatin1() throws {
    let original = "君の名は"
    let broken = try #require(mojibake(original, wrote: .shiftJIS, read: .isoLatin1))

    #expect(TextEncodingRepair.repaired(broken) == original)
}

@Test func repairsKatakanaShiftJISReadAsLatin1() throws {
    let original = "オレンジ"
    let broken = try #require(mojibake(original, wrote: .shiftJIS, read: .isoLatin1))

    // 纯假名在旧的 isCJKScalar 里计数为 0, 正确解码会被判成"没有改善"。
    #expect(TextEncodingRepair.repaired(broken) == original)
}

@Test func repairsHalfwidthKatakanaShiftJISReadAsLatin1() throws {
    let original = "ｵﾚﾝｼﾞ"
    let broken = try #require(mojibake(original, wrote: .shiftJIS, read: .isoLatin1))

    #expect(TextEncodingRepair.repaired(broken) == original)
}

@Test func repairsKoreanEUCKRReadAsLatin1() throws {
    let original = "강남스타일"
    let broken = try #require(mojibake(original, wrote: TextEncodingRepair.eucKR, read: .isoLatin1))

    #expect(TextEncodingRepair.repaired(broken) == original)
}

// MARK: - 保守性: 合法文本不能被改写

@Test func leavesLegitimateWesternTextAlone() {
    for text in ["Beyoncé", "Motörhead", "café", "Björk", "Sigur Rós", "Mylène Farmer"] {
        #expect(TextEncodingRepair.repaired(text) == nil, "误改了 \(text)")
    }
}

@Test func leavesLegitimateWesternTextWithSeveralAccentsAlone() {
    let text = "Björk Guðmundsdóttir"

    #expect(TextEncodingRepair.looksCorrupted(text) == false)
    #expect(TextEncodingRepair.repaired(text) == nil)
}

@Test func leavesLegitimateCJKTextAlone() {
    for text in ["我的歌声里", "君の名は", "강남스타일", "告白氣球", "夜に駆ける"] {
        #expect(TextEncodingRepair.repaired(text) == nil, "误改了 \(text)")
    }
}

@Test func leavesPlainASCIITextAlone() {
    for text in ["What??", "Don't Stop", "Track 01", "R.E.M."] {
        #expect(TextEncodingRepair.repaired(text) == nil, "误改了 \(text)")
    }
}

// MARK: - 不可恢复字符

@Test func detectsUnrecoverableReplacementAcrossScripts() {
    #expect(TextEncodingRepair.hasUnrecoverableReplacement(in: "对面\u{FFFD}"))
    #expect(TextEncodingRepair.hasUnrecoverableReplacement(in: "对面??"))
    // 假名/谚文也要算 CJK, 否则日韩标题的 "??" 不会触发文件名兜底。
    #expect(TextEncodingRepair.hasUnrecoverableReplacement(in: "オレンジ??"))
    #expect(TextEncodingRepair.hasUnrecoverableReplacement(in: "강남??"))
    #expect(TextEncodingRepair.hasUnrecoverableReplacement(in: "What??") == false)
}

// MARK: - ID3 帧解码

@Test func decodesID3FrameWithMisdeclaredGBKEncoding() throws {
    // 老工具常把 GBK 字节写进帧里, 却把编码字节留成 0 (标准里是 ISO-8859-1)。
    let original = "十年"
    let payload = try #require(original.data(using: TextEncodingRepair.gb18030))

    #expect(TextEncodingRepair.decodeID3Text(payload, encodingByte: 0) == original)
}

@Test func decodesID3FrameWithMisdeclaredShiftJISEncoding() throws {
    let original = "残酷な天使のテーゼ"
    let payload = try #require(original.data(using: .shiftJIS))

    #expect(TextEncodingRepair.decodeID3Text(payload, encodingByte: 0) == original)
}

@Test func decodesID3FrameWithLegitimateLatin1Text() throws {
    for original in ["Björk", "Mylène Farmer", "François"] {
        let payload = try #require(original.data(using: .isoLatin1))
        #expect(TextEncodingRepair.decodeID3Text(payload, encodingByte: 0) == original)
    }
}

@Test func decodesID3FrameWithCP1252Punctuation() throws {
    let original = "Don’t Stop"
    let payload = try #require(original.data(using: .windowsCP1252))

    #expect(TextEncodingRepair.decodeID3Text(payload, encodingByte: 0) == original)
}

@Test func bestDecodingPrefersStructurallyValidUTF8() throws {
    let original = "Björk Guðmundsdóttir"
    let payload = try #require(original.data(using: .utf8))

    #expect(
        TextEncodingRepair.bestDecoding(
            of: payload,
            encodings: TextEncodingRepair.legacyTextEncodings
        ) == original
    )
}

@Test func decodesID3FrameWithCorrectUTF8Declaration() throws {
    let original = "小幸运"
    let payload = try #require(original.data(using: .utf8))

    #expect(TextEncodingRepair.decodeID3Text(payload, encodingByte: 3) == original)
}

@Test func decodesID3FrameWithUTF16Declaration() throws {
    let original = "青花瓷"
    let payload = try #require(original.data(using: .utf16))

    #expect(TextEncodingRepair.decodeID3Text(payload, encodingByte: 1) == original)
}

@Test func rejectsID3FrameWithUnknownEncodingByte() {
    #expect(TextEncodingRepair.decodeID3Text(Data([0x41, 0x42]), encodingByte: 9) == nil)
}

@Test func rewriteEncodingUsesOwnedLosslessConversion() {
    let cases: [(String, String.Encoding, [UInt8])] = [
        ("Björk", .isoLatin1, [0x42, 0x6A, 0xF6, 0x72, 0x6B]),
        ("Don’t", .windowsCP1252, [0x44, 0x6F, 0x6E, 0x92, 0x74]),
        ("十年", TextEncodingRepair.gb18030, [0xCA, 0xAE, 0xC4, 0xEA]),
        ("測試", TextEncodingRepair.big5, [0xB4, 0xFA, 0xB8, 0xD5]),
        ("君の名", .shiftJIS, [0x8C, 0x4E, 0x82, 0xCC, 0x96, 0xBC]),
        ("강남", TextEncodingRepair.eucKR, [0xB0, 0xAD, 0xB3, 0xB2]),
    ]

    for (text, encoding, expected) in cases {
        #expect(TextEncodingRepair.losslessEncodedData(text, using: encoding) == Data(expected))
    }
    #expect(TextEncodingRepair.losslessEncodedData("€", using: .isoLatin1) == nil)
}

@Test func parsesRewriteFramesDuringConcurrentCancellation() async {
    // The isolated iOS reproduction uses an encoding-3 TALB frame and an
    // encoding-1 TCOM frame. Keep the real media heads outside the repository;
    // these small synthetic frames preserve both decoder/rewrite routes.
    let mojibake = "Donâ€™t Stop Believinâ€™"
    let repaired = "Don’t Stop Believin’"
    let utf8Frame = id3v24TextTag(
        id: "TALB",
        encodingByte: 3,
        payload: Data(mojibake.utf8)
    )
    let utf16Frame = id3v24TextTag(
        id: "TCOM",
        encodingByte: 1,
        payload: utf16LEData(mojibake)
    )
    let gb18030Frame = id3v24TextTag(
        id: "TIT2",
        encodingByte: 0,
        payload: Data([0xD6, 0xD0, 0xCE, 0xC4])
    )
    let big5Frame = id3v24TextTag(
        id: "TPE1",
        encodingByte: 0,
        payload: Data([0xB4, 0xFA, 0xB8, 0xD5])
    )
    let latin1Frame = id3v24TextTag(
        id: "TALB",
        encodingByte: 0,
        payload: Data([0x42, 0x6A, 0xF6, 0x72, 0x6B])
    )
    let inputs = [utf8Frame, utf16Frame, gb18030Frame, big5Frame, latin1Frame]
    #expect(ID3TextMetadataParser.parse(utf8Frame)?.albumTitle == repaired)

    for _ in 0..<50 {
        let completedCount = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for worker in 0..<32 {
                group.addTask {
                    let parserTask = Task {
                        _ = ID3TextMetadataParser.parse(inputs[worker % inputs.count])
                        return 1
                    }
                    if worker.isMultiple(of: 3) {
                        parserTask.cancel()
                    }
                    return await parserTask.value
                }
            }

            var count = 0
            for await parsed in group {
                count += parsed
            }
            return count
        }
        #expect(completedCount == 32)
    }
}

private func id3v24TextTag(id: String, encodingByte: UInt8, payload: Data) -> Data {
    let frameSize = payload.count + 1
    let tagSize = 10 + frameSize
    var tag = Data([
        0x49, 0x44, 0x33, 0x04, 0x00, 0x00,
        UInt8((tagSize >> 21) & 0x7F), UInt8((tagSize >> 14) & 0x7F),
        UInt8((tagSize >> 7) & 0x7F), UInt8(tagSize & 0x7F),
    ])
    tag.append(contentsOf: id.utf8)
    tag.append(contentsOf: [
        UInt8((frameSize >> 21) & 0x7F), UInt8((frameSize >> 14) & 0x7F),
        UInt8((frameSize >> 7) & 0x7F), UInt8(frameSize & 0x7F),
        0x00, 0x00, encodingByte,
    ])
    tag.append(payload)
    return tag
}

private func utf16LEData(_ text: String) -> Data {
    var data = Data([0xFF, 0xFE])
    for codeUnit in text.utf16 {
        data.append(UInt8(truncatingIfNeeded: codeUnit))
        data.append(UInt8(truncatingIfNeeded: codeUnit >> 8))
    }
    return data
}

// MARK: - 打分

@Test func scoresCommonHanAboveRareHan() throws {
    // "Han -> Han" 乱码的特征是生僻字扎堆; 常用字应当得分明显更高。
    let clean = "我的歌声"
    let garbled = try #require(mojibake(clean, wrote: .utf8, read: TextEncodingRepair.gb18030))

    #expect(TextEncodingRepair.plausibility(clean) > TextEncodingRepair.plausibility(garbled))
    #expect(TextEncodingRepair.looksCorrupted(clean) == false)
    #expect(TextEncodingRepair.looksCorrupted(garbled))
}

// MARK: - 手动修正

@Test func offersManualFixForGarbledFields() throws {
    let title = try #require(mojibake("十年", wrote: TextEncodingRepair.gb18030, read: .isoLatin1))
    let artist = try #require(mojibake("陈奕迅", wrote: TextEncodingRepair.gb18030, read: .isoLatin1))

    let fixes = TextEncodingRepair.availableFixes(for: [title, artist, "", ""])
    let winner = try #require(fixes.first)

    // 整批应用: 选一次, 每个字段一起改。
    #expect(winner.fields[0] == "十年")
    #expect(winner.fields[1] == "陈奕迅")
    // 空字段原样返回, 字段数与输入对齐, 调用方可以按位置回填。
    #expect(winner.fields.count == 4)
    #expect(winner.fields[2].isEmpty)
    #expect(winner.label.contains("Latin-1"))
}

@Test func ranksBetterManualFixesFirst() throws {
    let garbled = try #require(mojibake("夜空中最亮的星", wrote: TextEncodingRepair.gb18030, read: .isoLatin1))
    let fixes = TextEncodingRepair.availableFixes(for: [garbled])

    #expect(fixes.count >= 2, "应当列出多套方案供人工比较")
    // 排序是降序的, 正确那套排第一。
    #expect(fixes.first?.fields[0] == "夜空中最亮的星")
    for (earlier, later) in zip(fixes, fixes.dropFirst()) {
        #expect(earlier.scoreDelta >= later.scoreDelta)
    }
}

@Test func manualFixesAreDistinctAndNonEmpty() throws {
    let garbled = try #require(mojibake("告白气球", wrote: TextEncodingRepair.gb18030, read: .isoLatin1))
    let fixes = TextEncodingRepair.availableFixes(for: [garbled])

    #expect(Set(fixes.map(\.id)).count == fixes.count, "id 必须唯一, 否则 ForEach 会错乱")
    #expect(fixes.allSatisfy { $0.fields != [garbled] }, "没有变化的方案不该列出来")
}

@Test func offersNoManualFixForEmptyInput() {
    #expect(TextEncodingRepair.availableFixes(for: []).isEmpty)
    #expect(TextEncodingRepair.availableFixes(for: ["", "  "]).isEmpty)
}

@Test func offersManualFixEvenWhenAutoRepairDeclines() throws {
    // 自动修复对 GBK<->Big5 要求很大分差, 多数情况下会放弃; 手动模式必须仍然
    // 把候选列出来 —— 这正是它存在的意义。
    let text = "測試歌曲"
    let fixes = TextEncodingRepair.availableFixes(for: [text])

    if TextEncodingRepair.repaired(text) == nil {
        #expect(!fixes.isEmpty, "自动放弃时手动仍应给出候选")
    }
}

// MARK: - 标签 / 文件名取舍

@Test func prefersFileNameOverGarbledTag() {
    // 用户实际遇到的场景: 列表显示乱码, 刮削搜索框(走文件名)却是正常的。
    #expect(
        MediaMetadataTextRepair.preferred(embedded: "对面??", fromFileName: "对面的女孩看过来")
            == "对面的女孩看过来"
    )
}

@Test func prefersCleanCloudFileNameWhenHeaderAlreadyLostBytes() {
    // Screenshot pattern: a replacement glyph is followed by Han-to-Han
    // mojibake. Once U+FFFD exists those bytes are gone; the independent API
    // filename is the only source that may replace it.
    let damagedHeader = "\u{FFFD}倀勬彿淇"
    #expect(TextEncodingRepair.hasUnrecoverableReplacement(in: damagedHeader))
    #expect(
        MediaMetadataTextRepair.preferred(
            embedded: damagedHeader,
            fromFileName: "陈洁仪 - 心动"
        ) == "陈洁仪 - 心动"
    )
}

@Test func repairsReversibleHeaderBeforeUsingFileNameFallback() throws {
    let original = "我的歌声"
    let reversible = try #require(
        mojibake(original, wrote: .utf8, read: TextEncodingRepair.gb18030)
    )

    #expect(
        MediaMetadataTextRepair.preferred(
            embedded: reversible,
            fromFileName: "曲婉婷 - 我的歌声"
        ) == original
    )
}

@Test func doesNotInventTextWhenBothCloudSourcesLostBytes() {
    let damagedHeader = "\u{FFFD}倀勬"
    let damagedFileName = "歌曲\u{FFFD}"

    #expect(
        MediaMetadataTextRepair.preferred(
            embedded: damagedHeader,
            fromFileName: damagedFileName
        ) == damagedHeader
    )
}

@Test func prefersTagWhenTagIsClean() {
    // 标签好使就用标签 —— 它比文件名精确(文件名常带音质/厂牌等噪音)。
    #expect(
        MediaMetadataTextRepair.preferred(embedded: "慕夏", fromFileName: "等什么君 - 慕夏")
            == "慕夏"
    )
}

@Test func keepsGarbledTagWhenFileNameIsAlsoGarbled() {
    // 两边都坏时保留标签原文: 至少让用户看见, 也还能用手动编码修正去救。
    #expect(
        MediaMetadataTextRepair.preferred(embedded: "对面??", fromFileName: "女孩??")
            == "对面??"
    )
}

@Test func fallsBackToFileNameWhenTagMissing() {
    #expect(MediaMetadataTextRepair.preferred(embedded: nil, fromFileName: "慕夏") == "慕夏")
    #expect(MediaMetadataTextRepair.preferred(embedded: "   ", fromFileName: "慕夏") == "慕夏")
    #expect(MediaMetadataTextRepair.preferred(embedded: "慕夏", fromFileName: nil) == "慕夏")
    #expect(MediaMetadataTextRepair.preferred(embedded: nil, fromFileName: nil) == nil)
}
