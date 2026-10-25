import Foundation

/// 上游已经按 UTF-8「宽松」解过一遍的歌词。
///
/// Navidrome(`unicode.UTF8.NewDecoder`)、Jellyfin(`File.ReadAllTextAsync(path, Encoding.UTF8)`)
/// 读 GBK / Big5 的 `.lrc` 时, 把读不通的字节换成 U+FFFD 再交出来; 零星没被换掉的字节恰好
/// 拼成 δ、Լ、û 这类别的文字。被换掉的字节已经丢了, 光凭这份文字还原不回来。
///
/// 这里做三件事:
/// 1. 认出这种文档 —— 正常歌词里不会出现成串的 U+FFFD。
/// 2. 拿另一份歌词(之前存下的干净那份、在线搜到的)逐行验证还原。乱码的产生过程是确定的:
///    GBK / Big5 编码, 再按 UTF-8 宽松解码。候选里的一句照做一遍、和坏掉的那句一字不差,
///    才认定原文是这句。时间轴、逐字时间都留坏文档自己的。两个字节都被换掉的字区分不出
///    候选用了哪个异体字, 这类字跟候选的写法。
/// 3. 坏行只占少数(英文歌里的中文署名行之类)时去掉坏行, 其余照用。
///
/// 三样都不行就返回 nil: 宁可没有歌词, 也不把乱码显示出来、存进缓存。
public enum LossyDecodedLyricsRepair {
    fileprivate static let replacement: Unicode.Scalar = "\u{FFFD}"

    /// 一处文字里有两个以上 U+FFFD 才算坏了。只有一个时可能是文件里本来就带的一个坏字,
    /// 不值得为它丢掉整份歌词。
    static let damagedReplacementCount = 2

    /// 坏行不超过有字行数的四分之一时, 去掉坏行还剩一份像样的歌词。
    static let strippableDamagedLineRatio = 0.25

    // MARK: - 识别

    public static func isDamaged(_ text: String) -> Bool {
        var count = 0
        for scalar in text.unicodeScalars where scalar == replacement {
            count += 1
            if count >= damagedReplacementCount { return true }
        }
        return false
    }

    public static func isDamaged(_ lines: [LyricLine]) -> Bool {
        lines.contains { line in
            lineIsDamaged(line)
                || secondaryTexts(of: line).contains(where: isDamaged)
                || (line.metadataLines ?? []).contains(where: isDamaged)
        }
    }

    /// 没坏的原样返回; 坏了先拿 `references` 逐份验证还原, 都对不上时坏行只占少数就去掉坏行,
    /// 还是不行返回 nil。
    public static func usableDocument(
        _ lines: [LyricLine],
        references: [[LyricLine]] = []
    ) -> [LyricLine]? {
        guard isDamaged(lines) else { return lines }
        for reference in references {
            if let restored = restored(lines, using: reference) { return restored }
        }
        return withoutDamagedLines(lines)
    }

    // MARK: - 验证还原

    /// 用 `reference` 逐处还原 `damaged` 里坏掉的文字。有一处对不上就整份放弃, 不拼半份。
    public static func restored(_ damaged: [LyricLine], using reference: [LyricLine]) -> [LyricLine]? {
        guard isDamaged(damaged) else { return damaged }
        let index = ReferenceIndex(reference)
        guard !index.isEmpty else { return nil }

        var keys: [String] = []
        for line in damaged {
            var copy = line
            visitTexts(of: &copy) { text in
                if isDamaged(text) { keys.append(text) }
            }
        }
        guard let resolved = index.resolve(keys) else { return nil }

        var cursor = resolved.makeIterator()
        var restored: [LyricLine] = []
        restored.reserveCapacity(damaged.count)
        for line in damaged {
            var copy = line
            visitTexts(of: &copy) { text in
                if isDamaged(text), let original = cursor.next() { text = original }
            }
            restored.append(restoringSyllables(of: copy, from: line))
        }
        if let metadata = restored.first?.metadataLines {
            // 文档头([ti:]、[by:] 之类)和在线那份常常不一样, 对不上的坏行直接去掉, 不连累正文。
            let kept = metadata.compactMap { line -> String? in
                guard isDamaged(line) else { return line }
                return index.uniqueText(for: line)
            }
            restored[0].metadataLines = kept.isEmpty ? nil : kept
        }
        return isDamaged(restored) ? nil : restored
    }

    // MARK: - 去掉坏行

    public static func withoutDamagedLines(_ lines: [LyricLine]) -> [LyricLine]? {
        let textLines = lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let damagedCount = textLines.filter(lineIsDamaged).count
        guard !textLines.isEmpty,
              Double(damagedCount) <= Double(textLines.count) * strippableDamagedLineRatio else {
            return nil
        }
        var kept = lines.compactMap { line -> LyricLine? in
            lineIsDamaged(line) ? nil : strippingDamagedSecondaryTexts(of: line)
        }
        guard !kept.isEmpty, let first = lines.first else { return nil }
        // 文档头和「本机改过」的标记只记在第一行上; 第一行被去掉时挪到新的第一行。
        let metadata = first.metadataLines?.filter { !isDamaged($0) }
        kept[0].metadataLines = metadata?.isEmpty == false ? metadata : nil
        kept[0].documentIsLocalOverride = first.documentIsLocalOverride
        return isDamaged(kept) ? nil : kept
    }

    // MARK: - 乱码的产生过程

    /// 候选文字的写法: 原样、转简体、转繁体。转出来和原样一样时算同时属于几种。
    fileprivate struct ScriptVariant: OptionSet, Hashable {
        let rawValue: Int
        static let asWritten = ScriptVariant(rawValue: 1)
        static let simplified = ScriptVariant(rawValue: 2)
        static let traditional = ScriptVariant(rawValue: 4)
    }

    fileprivate struct Rendering {
        let damaged: String
        let original: String
        let variant: ScriptVariant
    }

    /// 这段文字存成 GBK / Big5、再被当 UTF-8 宽松解码后会变成什么样。两种替换写法都算:
    /// 一段非法字节换一个 U+FFFD(Swift、.NET、Python、浏览器)和逐字节各换一个(Go)。
    /// `includesScriptVariants` 时繁简两种写法也各算一遍: 文件是简体、候选是繁体很常见。
    fileprivate static func lossyRenderings(
        of text: String,
        includesScriptVariants: Bool = true
    ) -> [Rendering] {
        var variants: [(text: String, variant: ScriptVariant)] = [(text, .asWritten)]
        if includesScriptVariants, text.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) {
            for (transform, variant) in [
                ("Hant-Hans", ScriptVariant.simplified),
                ("Hans-Hant", ScriptVariant.traditional),
            ] {
                guard let converted = text.applyingTransform(
                    StringTransform(transform),
                    reverse: false
                ) else { continue }
                if let existing = variants.firstIndex(where: { $0.text == converted }) {
                    variants[existing].variant.insert(variant)
                } else {
                    variants.append((converted, variant))
                }
            }
        } else {
            variants[0].variant = [.asWritten, .simplified, .traditional]
        }
        var result: [Rendering] = []
        for (variantText, variant) in variants {
            for encoding in [TextEncodingRepair.gb18030, TextEncodingRepair.big5] {
                guard let data = TextEncodingRepair.losslessEncodedData(variantText, using: encoding) else {
                    continue
                }
                let bytes = [UInt8](data)
                for damaged in [String(decoding: bytes, as: UTF8.self), replacingEachInvalidByte(bytes)]
                where !result.contains(where: { $0.damaged == damaged && $0.original == variantText }) {
                    result.append(Rendering(damaged: damaged, original: variantText, variant: variant))
                }
            }
        }
        return result
    }

    /// Go 的写法: 不合法的字节一个换一个 U+FFFD。
    static func replacingEachInvalidByte(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        var index = 0
        while index < bytes.count {
            if let length = utf8ScalarLength(at: index, in: bytes) {
                let decoded = String(decoding: bytes[index..<(index + length)], as: UTF8.self)
                scalars.append(contentsOf: decoded.unicodeScalars)
                index += length
            } else {
                scalars.append(replacement)
                index += 1
            }
        }
        return String(scalars)
    }

    private static func utf8ScalarLength(at index: Int, in bytes: [UInt8]) -> Int? {
        let lead = bytes[index]
        if lead < 0x80 { return 1 }
        let length: Int
        let second: ClosedRange<UInt8>
        switch lead {
        case 0xC2...0xDF: (length, second) = (2, 0x80...0xBF)
        case 0xE0: (length, second) = (3, 0xA0...0xBF)
        case 0xE1...0xEC, 0xEE...0xEF: (length, second) = (3, 0x80...0xBF)
        case 0xED: (length, second) = (3, 0x80...0x9F)
        case 0xF0: (length, second) = (4, 0x90...0xBF)
        case 0xF1...0xF3: (length, second) = (4, 0x80...0xBF)
        case 0xF4: (length, second) = (4, 0x80...0x8F)
        default: return nil
        }
        guard index + length <= bytes.count, second.contains(bytes[index + 1]) else { return nil }
        for offset in 2..<length where !(0x80...0xBF).contains(bytes[index + offset]) {
            return nil
        }
        return length
    }

    // MARK: - 候选索引

    private struct Candidate {
        let order: Int
        let text: String
        let variant: ScriptVariant
    }

    private struct ReferenceIndex {
        private var candidates: [String: [Candidate]] = [:]

        init(_ reference: [LyricLine]) {
            var texts: [String] = []
            for line in reference {
                var copy = line
                LossyDecodedLyricsRepair.visitTexts(of: &copy) { texts.append($0) }
            }
            texts += reference.first?.metadataLines ?? []

            var order = 0
            for text in texts {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !LossyDecodedLyricsRepair.isDamaged(trimmed) else { continue }
                for rendering in LossyDecodedLyricsRepair.lossyRenderings(of: trimmed) {
                    candidates[rendering.damaged, default: []].append(
                        Candidate(order: order, text: rendering.original, variant: rendering.variant)
                    )
                }
                order += 1
            }
        }

        var isEmpty: Bool { candidates.isEmpty }

        func uniqueText(for key: String) -> String? {
            candidates[key].flatMap { Self.singleText(in: $0) }
        }

        /// 先定锚点: 还剩几个字没被换掉、而且只对得上一种写法的坏句。锚点定下文件用的是
        /// 简体还是繁体, 对得上繁简两种写法的坏句按它选。整句只剩 U+FFFD 的只在前后两个锚点
        /// 之间的候选里找, 找到的也必须只有一种写法。锚点不到一半就放弃 —— 那样的「验证」太弱。
        func resolve(_ keys: [String]) -> [String]? {
            guard !keys.isEmpty else { return [] }
            var resolved = [Candidate?](repeating: nil, count: keys.count)
            // 副歌重复时同一句有好几个位置: 取前一个已定下的句子之后的第一次出现。
            func picking(_ matches: [Candidate], at position: Int) -> Candidate {
                let lower = resolved[..<position].compactMap { $0?.order }.last ?? -1
                return matches.first { $0.order > lower } ?? matches[0]
            }
            for (position, key) in keys.enumerated() {
                guard Self.hasSurvivingText(key), let matches = candidates[key],
                      Self.singleText(in: matches) != nil else { continue }
                let pick = picking(matches, at: position)
                resolved[position] = pick
            }
            let fileVariant = Self.dominantVariant(in: resolved.compactMap { $0 })

            for (position, key) in keys.enumerated() where resolved[position] == nil {
                guard Self.hasSurvivingText(key), let matches = candidates[key] else { continue }
                let written = matches.filter { $0.variant.contains(fileVariant) }
                guard Self.singleText(in: written) != nil else { continue }
                let pick = picking(written, at: position)
                resolved[position] = pick
            }
            guard resolved.filter({ $0 != nil }).count * 2 >= keys.count else { return nil }

            for position in keys.indices where resolved[position] == nil {
                guard let matches = candidates[keys[position]] else { return nil }
                let lower = resolved[..<position].compactMap { $0?.order }.last ?? -1
                let upper = resolved[(position + 1)...].compactMap { $0?.order }.first ?? Int.max
                var inRange = matches.filter { $0.order > lower && $0.order < upper }
                if Self.singleText(in: inRange) == nil {
                    inRange = inRange.filter { $0.variant.contains(fileVariant) }
                }
                guard Self.singleText(in: inRange) != nil else { return nil }
                resolved[position] = inRange[0]
            }
            return resolved.map { $0?.text ?? "" }
        }

        private static func singleText(in matches: [Candidate]) -> String? {
            guard let first = matches.first,
                  matches.allSatisfy({ $0.text == first.text }) else { return nil }
            return first.text
        }

        private static func dominantVariant(in anchors: [Candidate]) -> ScriptVariant {
            let options: [ScriptVariant] = [.asWritten, .simplified, .traditional]
            return options.max { lhs, rhs in
                anchors.filter { $0.variant.contains(lhs) }.count
                    < anchors.filter { $0.variant.contains(rhs) }.count
            } ?? .asWritten
        }

        private static func hasSurvivingText(_ key: String) -> Bool {
            key.unicodeScalars.contains {
                $0 != LossyDecodedLyricsRepair.replacement && !$0.properties.isWhitespace
            }
        }
    }

    // MARK: - 行里的文字

    /// 原文、译文、注音、和声子行, 固定顺序逐个交出来; 收集坏句和替换坏句用的是同一个顺序。
    private static func visitTexts(of line: inout LyricLine, _ body: (inout String) -> Void) {
        body(&line.text)
        if var translation = line.manualTranslation {
            body(&translation.text)
            line.manualTranslation = translation
        }
        for position in line.alternateManualTranslations.indices {
            body(&line.alternateManualTranslations[position].text)
        }
        if var romanization = line.romanization {
            body(&romanization)
            line.romanization = romanization
        }
        if var background = line.background {
            for position in background.indices {
                visitTexts(of: &background[position], body)
            }
            line.background = background
        }
    }

    private static func lineIsDamaged(_ line: LyricLine) -> Bool {
        isDamaged(line.text) || (line.syllables.map { isDamaged($0.map(\.text).joined()) } ?? false)
    }

    private static func secondaryTexts(of line: LyricLine) -> [String] {
        var texts = line.allManualTranslations.map(\.text)
        if let romanization = line.romanization { texts.append(romanization) }
        for background in line.background ?? [] {
            texts.append(background.text)
            if let syllables = background.syllables { texts.append(syllables.map(\.text).joined()) }
            texts += secondaryTexts(of: background)
        }
        return texts
    }

    private static func strippingDamagedSecondaryTexts(of line: LyricLine) -> LyricLine {
        var line = line
        if let translation = line.manualTranslation, isDamaged(translation.text) {
            line.manualTranslation = nil
        }
        line.alternateManualTranslations.removeAll { isDamaged($0.text) }
        if let romanization = line.romanization, isDamaged(romanization) {
            line.romanization = nil
        }
        if let background = line.background {
            let kept = background.compactMap { row -> LyricLine? in
                lineIsDamaged(row) ? nil : strippingDamagedSecondaryTexts(of: row)
            }
            line.background = kept.isEmpty ? nil : kept
        }
        return line
    }

    /// 逐字时间在服务端按 `<mm:ss.xx>` 切开, 切口是 ASCII, 宽松解码在 ASCII 处重新开始,
    /// 所以每个字块单独验证得了。原文已经还原好, 按字块顺序从头切: 每块取最短的、照样弄坏后
    /// 和坏字块一样的那一段。切不开就只留整句时间。
    private static func restoringSyllables(of restored: LyricLine, from damaged: LyricLine) -> LyricLine {
        var line = restored
        if let syllables = damaged.syllables, isDamaged(syllables.map(\.text).joined()) {
            line.syllables = splitting(restored.text, like: syllables)
        }
        if let restoredRows = line.background, let damagedRows = damaged.background,
           restoredRows.count == damagedRows.count {
            line.background = zip(restoredRows, damagedRows).map { restoringSyllables(of: $0, from: $1) }
        }
        return line
    }

    private static func splitting(_ text: String, like syllables: [LyricSyllable]) -> [LyricSyllable]? {
        guard let last = syllables.indices.last else { return nil }
        var remaining = Substring(text)
        var result = syllables
        for position in syllables.indices {
            let target = syllables[position].text
            if position == last {
                guard matches(String(remaining), damaged: target) else { return nil }
                result[position].text = String(remaining)
                return result
            }
            var end = remaining.startIndex
            var piece: String?
            while end < remaining.endIndex {
                end = remaining.index(after: end)
                let candidate = String(remaining[..<end])
                if matches(candidate, damaged: target) {
                    piece = candidate
                    break
                }
            }
            guard let piece else { return nil }
            result[position].text = piece
            remaining = remaining[end...]
        }
        return nil
    }

    private static func matches(_ candidate: String, damaged: String) -> Bool {
        candidate == damaged
            || lossyRenderings(of: candidate, includesScriptVariants: false)
                .contains { $0.damaged == damaged }
    }
}
