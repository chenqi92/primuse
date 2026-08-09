import Foundation

/// 整篇歌词的文本级操作 ── 粘贴后自动分句、去空行、剔除「作词/作曲」这类版权行。
///
/// 和 `LyricsEditorDocument` 的分工：那边管已经成行的文档(打轴、排序、偏移)，
/// 这边管「一坨文字怎么变成一行一句」。都在 PrimuseKit 里，可以脱离 UI 单测。
public enum LyricsTextTools {
    /// 拆句结果。UI 拿 `removedBlankRuns` / `droppedCreditLines` 告诉用户
    /// "合并了 N 处空行 · 去掉了 M 行"，让自动处理是可见的而不是偷偷做掉。
    public struct SplitResult: Equatable, Sendable {
        public var lines: [String]
        /// 被合并掉的连续空行段数。
        public var removedBlankRuns: Int
        /// 被判定为版权信息而丢弃的行原文。
        public var droppedCreditLines: [String]

        public init(lines: [String], removedBlankRuns: Int = 0, droppedCreditLines: [String] = []) {
            self.lines = lines
            self.removedBlankRuns = removedBlankRuns
            self.droppedCreditLines = droppedCreditLines
        }

        public var isEmpty: Bool { lines.isEmpty }
    }

    /// 版权/制作信息行的前缀。这些行混在歌词里会被当成一句唱词打轴，
    /// 但它们从来不被唱出来。只匹配「行首关键词 + 冒号」，避免误伤
    /// 恰好含这些字的正常歌词。
    private static let creditKeywords = [
        "作词", "作曲", "编曲", "填词", "monitor", "制作人", "混音", "母带", "和声",
        "吉他", "贝斯", "鼓", "键盘", "弦乐", "录音", "出品", "发行", "策划", "统筹",
        "词", "曲", "唱", "演唱", "原唱", "翻唱",
        "lyrics by", "composed by", "composer", "lyricist", "arranged by", "arranger",
        "produced by", "producer", "mixing", "mastering", "written by", "vocals",
    ]

    private static let creditSeparators: Set<Character> = ["：", ":"]

    /// 这一行是否带 `[mm:ss]` 形态的时间戳。带时间戳的文本交给
    /// `LyricsEditorDocument` 处理，拆句阶段必须原样保留 ── 否则按标点一拆就把
    /// `[00:12.30]` 和它的正文分开了。
    public static func hasTimestamp(_ line: String) -> Bool {
        guard let open = line.firstIndex(of: "["),
              let close = line[open...].firstIndex(of: "]") else { return false }
        let inner = line[line.index(after: open)..<close]
        guard let colon = inner.firstIndex(of: ":") else { return false }
        let minutes = inner[inner.startIndex..<colon]
        let rest = inner[inner.index(after: colon)...]
        let seconds = rest.prefix { $0.isNumber }
        return !minutes.isEmpty
            && minutes.allSatisfy(\.isNumber)
            && seconds.count == 2
    }

    // MARK: - 粘贴 / 自动分句

    /// 把粘贴进来的整段文字拆成一行一句。
    ///
    /// 换行优先：用户复制来的歌词多半已经分好行，尊重它。只有当整段几乎没有换行
    /// (一行超过 `sentenceSplitThreshold` 个字)时才按标点补拆 —— 从网页复制常常
    /// 会把整首歌粘成一坨。
    public static func splitIntoLines(
        _ text: String,
        dropCredits: Bool = true,
        sentenceSplitThreshold: Int = 40
    ) -> SplitResult {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SplitResult(lines: [])
        }

        var blankRuns = 0
        var wasBlank = false
        var rawLines: [String] = []

        for rawLine in normalized.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !wasBlank, !rawLines.isEmpty { blankRuns += 1 }
                wasBlank = true
                continue
            }
            wasBlank = false
            rawLines.append(line)
        }

        // 已经带时间戳的文本别再按标点拆。
        let hasTimestamps = rawLines.contains(where: hasTimestamp)
        var expanded: [String] = []
        for line in rawLines {
            if !hasTimestamps, line.count > sentenceSplitThreshold {
                expanded.append(contentsOf: splitBySentence(line))
            } else {
                expanded.append(line)
            }
        }

        guard dropCredits, !hasTimestamps else {
            return SplitResult(lines: expanded, removedBlankRuns: blankRuns)
        }

        var kept: [String] = []
        var dropped: [String] = []
        for line in expanded {
            if isCreditLine(line) { dropped.append(line) } else { kept.append(line) }
        }
        // 整篇都被判成版权行说明判据在这份文本上失灵了，宁可全留下。
        guard !kept.isEmpty else {
            return SplitResult(lines: expanded, removedBlankRuns: blankRuns)
        }
        return SplitResult(lines: kept, removedBlankRuns: blankRuns, droppedCreditLines: dropped)
    }

    /// 按中英文句末标点拆一长串。标点跟随前一句保留，读起来更像原文。
    public static func splitBySentence(_ line: String) -> [String] {
        let terminators: Set<Character> = ["。", "！", "？", "；", "，", ".", "!", "?", ";", ","]
        var result: [String] = []
        var buffer = ""

        for character in line {
            buffer.append(character)
            guard terminators.contains(character) else { continue }
            let trimmed = buffer.trimmingCharacters(in: .whitespaces)
            // 太短的碎片(`啊，`)并进下一句，避免拆出一堆语气词单行。
            if trimmed.count > 2 {
                result.append(trimmed)
                buffer = ""
            }
        }

        let tail = buffer.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty {
            if tail.count <= 2, var last = result.popLast() {
                last += tail
                result.append(last)
            } else {
                result.append(tail)
            }
        }
        return result.isEmpty ? [line] : result
    }

    // MARK: - 整篇清理

    /// 去掉空行。返回 nil 表示没有可去的，UI 据此把按钮置灰。
    public static func removingBlankLines(_ text: String) -> String? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
        let kept = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard kept.count != lines.count else { return nil }
        return kept.joined(separator: "\n")
    }

    /// 判断一行是不是版权/制作信息。
    public static func isCreditLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // 冒号必须靠前，否则 `我说：我爱你` 这种正常歌词会被误杀。
        guard let separatorIndex = trimmed.firstIndex(where: { creditSeparators.contains($0) }),
              trimmed.distance(from: trimmed.startIndex, to: separatorIndex) <= 12 else {
            return false
        }
        let head = trimmed[trimmed.startIndex..<separatorIndex]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !head.isEmpty else { return false }
        return creditKeywords.contains { keyword in
            // 单字关键词只认全等 —— 用前缀匹配的话「曲终人散：…」这种正常歌词
            // 会因为以「曲」开头被当成制作信息删掉。
            keyword.count <= 1 ? head == keyword : head.hasPrefix(keyword)
        }
    }
}
