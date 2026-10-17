import Foundation

/// What kind of listening an item is for. Music is played as a collection;
/// spoken word is played as one long thing you come back to. A podcast is
/// spoken word too — it plays the same way — but lives with the podcasts
/// rather than on the book shelf.
public enum ListeningContentKind: String, Codable, Sendable, CaseIterable {
    case music
    case spokenWord
    case podcast

    /// Played the spoken-word way: per-item position, skip buttons, own speed.
    public var isSpokenWordListening: Bool { self != .music }
}

/// Decides whether an item is spoken word (audiobook, 相声/评书, radio drama,
/// lecture) rather than music.
///
/// The rule is deliberately evidence-only: a declared `.m4b` container, a genre
/// that names the category, or the user saying so. **Duration is never used** —
/// a 70-minute DJ set, a live recording and a classical symphony movement are
/// all music, and guessing by length would move them out of the library the
/// listener built.
public enum SpokenWordContentPolicy {
    /// The audiobook container. Nothing else writes it, so it is proof on its
    /// own. `Song.fileFormat` cannot carry it — `.m4b` is stored as its `.m4a`
    /// alias so every decoder keeps a proven extension — which is why callers
    /// pass the path's own extension here.
    public static let audiobookFileExtension = "m4b"

    public static func classify(
        fileExtension: String?,
        genre: String?,
        userOverride: ListeningContentKind? = nil
    ) -> ListeningContentKind {
        // An explicit decision outranks every inference, in both directions:
        // marking a lecture series as music has to stick too.
        if let userOverride { return userOverride }
        if let fileExtension,
           fileExtension.lowercased() == audiobookFileExtension {
            return .spokenWord
        }
        return genreKind(genre) ?? .music
    }

    /// Convenience for the scan/aggregation paths that hold a whole path.
    public static func classify(
        filePath: String,
        genre: String?,
        userOverride: ListeningContentKind? = nil
    ) -> ListeningContentKind {
        classify(
            fileExtension: (filePath as NSString).pathExtension,
            genre: genre,
            userOverride: userOverride
        )
    }

    /// 与 `classify(filePath:)` 的扩展名判定相同。路径里连 "m4b" 这三个字符
    /// (不分大小写)都没有时扩展名不可能是它, 省掉逐首的 NSString 桥接。
    public static func pathHasAudiobookExtension(_ filePath: String) -> Bool {
        var previous2: UInt8 = 0
        var previous1: UInt8 = 0
        var mayContainMarker = false
        for byte in filePath.utf8 {
            if previous2 | 0x20 == UInt8(ascii: "m"),
               previous1 == UInt8(ascii: "4"),
               byte | 0x20 == UInt8(ascii: "b") {
                mayContainMarker = true
                break
            }
            previous2 = previous1
            previous1 = byte
        }
        guard mayContainMarker else { return false }
        return (filePath as NSString).pathExtension.lowercased() == audiobookFileExtension
    }

    /// Whether the genre names spoken-word listening of any kind, podcasts
    /// included.
    public static func genreNamesSpokenWord(_ genre: String?) -> Bool {
        genreKind(genre) != nil
    }

    /// The kind a genre names: `.podcast`, `.spokenWord`, or nil when it names
    /// neither (music, or nothing to go on).
    public static func genreKind(_ genre: String?) -> ListeningContentKind? {
        guard let genre else { return nil }
        let normalized = genre.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        guard !normalized.isEmpty, normalized.count <= 64 else { return nil }
        if podcastGenreMarkers.contains(where: { normalized.contains($0) }) { return .podcast }
        if spokenWordGenreMarkers.contains(where: { normalized.contains($0) }) { return .spokenWord }
        return nil
    }

    /// Genre spellings that name a podcast. Checked before the spoken-word
    /// ones, so a downloaded episode goes to the podcasts, not the book shelf.
    private static let podcastGenreMarkers: Set<String> = [
        "podcast", "\u{64AD}\u{5BA2}", "ポッドキャスト", "팟캐스트",
    ]

    /// Genre spellings that name the category itself rather than a mood. Each
    /// one is long enough that it cannot appear inside an unrelated music
    /// genre. `comedy` is deliberately absent: it covers both 相声 and comedy
    /// *music*, so it would misfile real records.
    private static let spokenWordGenreMarkers: Set<String> = [
        // English and other Latin-script spellings
        "audiobook", "audiobooks", "spokenword", "radiodrama",
        "radioplay", "audiodrama", "audiotheatre", "audiotheater", "audiobuch",
        "hörbuch", "horbuch", "livreaudio", "audiolibro", "audiolivro",
        "аудиокнига", "lecture", "speech", "sermon", "storytelling",
        // Chinese categories, including the ones with no Western equivalent
        "\u{6709}\u{58F0}\u{4E66}", "\u{6709}\u{58F0}\u{5C0F}\u{8BF4}", "\u{6709}\u{58F0}\u{8BFB}\u{7269}", "\u{6709}\u{58F0}\u{6545}\u{4E8B}", "\u{5E7F}\u{64AD}\u{5267}",
        "\u{8BC4}\u{4E66}", "\u{76F8}\u{58F0}", "\u{5FEB}\u{677F}", "\u{5C0F}\u{54C1}", "\u{66F2}\u{827A}", "\u{8BF4}\u{4E66}", "\u{5355}\u{53E3}", "\u{5BF9}\u{53E3}",
        "\u{8131}\u{53E3}\u{79C0}", "\u{8BB2}\u{5EA7}", "\u{6F14}\u{8BB2}", "\u{6717}\u{8BFB}", "\u{6717}\u{8BF5}", "\u{6545}\u{4E8B}\u{4F1A}", "\u{513F}\u{7AE5}\u{6545}\u{4E8B}",
        // Japanese and Korean
        "オーディオブック", "\u{6717}\u{8AAD}", "\u{843D}\u{8A9E}", "오디오북",
    ]
}

/// Where a long recording resumes, and when that position stops being worth
/// keeping.
///
/// This exists because a book, a lecture or a 200-episode 评书 series is
/// listened to across days: the point is not "restore the last session" but
/// "every item remembers where I stopped".
public enum SpokenWordProgressPolicy {
    /// Below this, the listener has effectively not started; resuming there
    /// would be indistinguishable from the beginning and only costs a seek.
    public static let minimumRememberedPosition: TimeInterval = 20

    /// Within this of the end, the item counts as finished and its position is
    /// dropped, so the next play starts over instead of landing on the credits.
    public static let completionTailThreshold: TimeInterval = 30

    /// Resuming rewinds slightly: picking up mid-sentence is disorienting, and
    /// every audiobook player does this.
    public static let resumeRewind: TimeInterval = 5

    /// How many items keep a position. Far more than a listener has in flight,
    /// small enough that the store stays a trivial file.
    public static let maximumRememberedItems = 1000

    /// How often a position is written while playing. Between these, a pause,
    /// a track change, a seek and backgrounding all flush immediately.
    public static let autosaveInterval: TimeInterval = 15

    public static func shouldRemember(
        position: TimeInterval,
        duration: TimeInterval
    ) -> Bool {
        guard position.isFinite, duration.isFinite else { return false }
        guard position >= minimumRememberedPosition else { return false }
        // An unknown duration cannot prove the item was finished, and a long
        // position is still worth keeping for it.
        guard duration > 0 else { return true }
        return position <= duration - completionTailThreshold
    }

    /// The position playback should actually start from, or nil to start at
    /// the beginning.
    public static func resumePosition(
        stored: TimeInterval?,
        duration: TimeInterval
    ) -> TimeInterval? {
        guard let stored, stored.isFinite, stored > 0 else { return nil }
        guard shouldRemember(position: stored, duration: duration) else { return nil }
        return max(0, stored - resumeRewind)
    }
}

/// Skip intervals for spoken word, matching what listeners expect from an
/// audiobook or podcast app: a short step back to re-hear a sentence, a longer
/// one forward to get past a passage.
public enum SpokenWordSkipPolicy {
    public static let backwardInterval: TimeInterval = 15
    public static let forwardInterval: TimeInterval = 30

    /// Position after a skip, clamped so a forward skip past the end stops at
    /// the end rather than wrapping to the next item.
    public static func position(
        from current: TimeInterval,
        offset: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        guard current.isFinite, offset.isFinite else { return max(0, current) }
        let target = current + offset
        guard duration.isFinite, duration > 0 else { return max(0, target) }
        return min(max(0, target), duration)
    }
}

/// 全屏读文稿时,把字幕式的一行行并成段落。
///
/// 文稿多半是字幕(VTT/SRT)或按句断的 LRC:一行几个字到一两句,直接一行一段读起来很碎。
/// 并段的规矩:说话人换了、停顿够长、空行处另起一段;一段太长时在句末断开。不带时间的
/// 纯文本只在空行处分段,作者自己断的行接起来。章节名(「第三章 山河」「Chapter 3」这种
/// 短行)不并进前后的段落,自己成一段,按标题显示。
///
/// 一行字幕里有好几句时(整段一个时间戳的 LRC、按段落切的识别结果),按句末标点再拆成几句,
/// 每句的开始时间按字数在这一行的时长里线性估算 —— 高亮才能跟着念到哪一句,而不是整段一起亮。
///
/// 也可以不并段(`ParagraphMode.perCue`):每一行自己一段,章节名照旧按标题显示,空行不占位。
public enum SpokenWordTranscriptReadingPolicy {
    /// 分段方式:按上面的规矩并成段落,或者每一行字幕自己一段。
    public enum ParagraphMode: String, Sendable, CaseIterable {
        case merged
        case perCue
    }

    public struct Cue: Sendable, Equatable {
        public var text: String
        /// nil:不带时间(纯文本文稿)。
        public var start: TimeInterval?
        public var end: TimeInterval?
        public var speaker: String?

        public init(text: String, start: TimeInterval?, end: TimeInterval? = nil, speaker: String? = nil) {
            self.text = text
            self.start = start
            self.end = end
            self.speaker = speaker
        }
    }

    /// 段落里的一句:整句高亮、搜索后跳到命中的那一句都按它算。多半就是原文稿的一行;一行里有几句时
    /// 拆成几句,`cue` 相同,`start` 是按字数估算的。
    public struct Segment: Sendable, Equatable {
        /// 在原文稿里的位置。
        public var cue: Int
        /// 这一句开始的时间。拆出来的句子是估算值(第一句就是这一行的开始时间)。
        public var start: TimeInterval?
        /// 这一句在段落文字里的位置,按字符(Character)数,不含前面补的空格。
        public var range: Range<Int>
    }

    public struct Paragraph: Sendable, Equatable, Identifiable {
        /// 第一行与最后一行在原文稿里的位置。
        public var firstCue: Int
        public var lastCue: Int
        public var text: String
        /// 第一行开始的时间;不带时间的段落是 nil,点了不跳。
        public var start: TimeInterval?
        /// 章节名:单独成段,按标题显示。
        public var isHeading = false
        /// 段里的每一句,按先后。
        public var segments: [Segment] = []

        public var id: Int { firstCue }
    }

    /// 文稿搜索的一处命中。
    public struct SearchMatch: Sendable, Equatable {
        /// 在段落数组里的位置。
        public var paragraph: Int
        /// 在段落文字里的位置,按字符数。
        public var range: Range<Int>
        /// 命中所在那一句的开始时间(没有就用段首),点了从这里播。
        public var start: TimeInterval?
    }

    /// 前一行有结束时间时,隔这么久就算换了一段话。
    public static let pauseBreak: TimeInterval = 2.5
    /// 只有开始时间(LRC)时两行开头相隔这么久才算停顿:一行本身就要念几秒。
    public static let startGapBreak: TimeInterval = 10
    /// 一段到这么长,遇到句末就断开。
    public static let softLength = 240
    /// 再长也断(没有标点的长文稿)。
    public static let hardLength = 600
    /// 章节名最长这么多字;再长就是正文里恰好以「第三章」开头的一句。
    public static let headingMaxLength = 40
    /// 一行没有结束时间、只能拿下一行的开始当结束时,一个字最多按这么多秒算:下一行隔了半分钟的
    /// 静音不该全算进这一行,否则后几句的估算开始时间会落在静音里。
    public static let estimatedSecondsPerCharacterCeiling: TimeInterval = 0.6

    public static func paragraphs(from cues: [Cue], mode: ParagraphMode = .merged) -> [Paragraph] {
        var result: [Paragraph] = []
        var current: Paragraph?
        var currentLength = 0
        var previous: Cue?
        let spans = cueSpans(cues)

        func close() {
            if let paragraph = current { result.append(paragraph) }
            current = nil
            currentLength = 0
        }

        func open(_ index: Int, _ cue: Cue, text: String, isHeading: Bool) {
            let length = text.count
            current = Paragraph(
                firstCue: index,
                lastCue: index,
                text: text,
                start: cue.start,
                isHeading: isHeading,
                segments: segments(cue: index, text: text, start: cue.start, span: spans[index], offset: 0)
            )
            currentLength = length
        }

        for (index, cue) in cues.enumerated() {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                // 空行:作者断的段。
                close()
                previous = nil
                continue
            }
            if isHeading(text) {
                // 章节名自己一段,下一行另起。
                close()
                open(index, cue, text: text, isHeading: true)
                close()
                previous = nil
                continue
            }
            if mode == .merged, var paragraph = current, let previous,
               !startsNewParagraph(cue, after: previous, currentLength: currentLength) {
                let separator = separator(between: paragraph.text, and: text)
                let lower = currentLength + separator.count
                let length = text.count
                paragraph.text += separator + text
                paragraph.lastCue = index
                paragraph.segments.append(contentsOf: segments(
                    cue: index, text: text, start: cue.start, span: spans[index], offset: lower
                ))
                currentLength = lower + length
                current = paragraph
            } else {
                close()
                open(index, cue, text: text, isHeading: false)
            }
            previous = cue
        }
        close()
        return result
    }

    /// 全屏文稿跟读时的提前量,和歌词页、普通文稿页一样提前 0.25 秒换:高亮动画和滚动要一点时间,
    /// 卡着开始时间换,眼睛看到时已经念出半个字(#313)。
    public static let followLookahead: TimeInterval = 0.25

    /// 正在念的那一段:开始时间不晚于 `time + lookahead` 的最后一段。
    public static func paragraphIndex(
        at time: TimeInterval,
        in paragraphs: [Paragraph],
        lookahead: TimeInterval = 0.05
    ) -> Int? {
        var found: Int?
        for (index, paragraph) in paragraphs.enumerated() {
            guard let start = paragraph.start else { continue }
            if start <= time + lookahead { found = index } else { break }
        }
        return found
    }

    /// 段里正在念的那一句:开始时间不晚于 `time + lookahead` 的最后一句。段落不带时间时是 nil。
    public static func segmentIndex(
        at time: TimeInterval,
        in paragraph: Paragraph,
        lookahead: TimeInterval = 0.05
    ) -> Int? {
        var found: Int?
        for (index, segment) in paragraph.segments.enumerated() {
            guard let start = segment.start else { continue }
            if start <= time + lookahead { found = index } else { break }
        }
        return found
    }

    // MARK: - Sentences

    /// 每一行持续多久:有结束时间用结束时间;没有(LRC)就到下一行有时间的那一行开始,但每个字最多
    /// 按 `estimatedSecondsPerCharacterCeiling` 算。算不出(最后一行、不带时间)是 nil。
    private static func cueSpans(_ cues: [Cue]) -> [TimeInterval?] {
        var spans = [TimeInterval?](repeating: nil, count: cues.count)
        var nextStart: TimeInterval?
        for index in cues.indices.reversed() {
            let cue = cues[index]
            guard let start = cue.start else { continue }
            if let end = cue.end, end > start {
                spans[index] = end - start
            } else if let nextStart, nextStart > start {
                let ceiling = Double(cue.text.trimmingCharacters(in: .whitespacesAndNewlines).count)
                    * estimatedSecondsPerCharacterCeiling
                spans[index] = min(nextStart - start, ceiling)
            }
            nextStart = start
        }
        return spans
    }

    /// 一行字幕在段落里的几句。拆不开(只有一句、没有时间、时长未知)时就是整行一句。
    private static func segments(
        cue index: Int,
        text: String,
        start: TimeInterval?,
        span: TimeInterval?,
        offset: Int
    ) -> [Segment] {
        let whole = Segment(cue: index, start: start, range: offset..<(offset + text.count))
        guard let start, let span, span > 0 else { return [whole] }
        let ranges = sentenceRanges(in: text)
        guard ranges.count >= 2 else { return [whole] }
        let total = Double(text.count)
        return ranges.enumerated().map { position, range in
            let estimated = position == 0 ? start : start + span * Double(range.lowerBound) / total
            return Segment(
                cue: index,
                start: estimated,
                range: (offset + range.lowerBound)..<(offset + range.upperBound)
            )
        }
    }

    /// 一行里每一句的位置(按字符数)。句末是 。！？!?… 以及后面紧跟的引号、括号;拉丁文的句点只在
    /// 后面是空白或到头时算(「3.5」「e.g.」不断)。句与句之间的空格不属于任何一句。
    /// 只有一句,或者哪一句去掉标点不足两个字符(「嗯。」「No.」这种叹词),就不拆,返回空数组。
    static func sentenceRanges(in text: String) -> [Range<Int>] {
        let characters = Array(text)
        let count = characters.count
        var ranges: [Range<Int>] = []
        var pieceStart = 0
        var index = 0
        while index < count {
            let character = characters[index]
            var endsSentence = sentenceTerminators.contains(character)
            if !endsSentence, character == "." {
                var next = index + 1
                while next < count, sentenceClosers.contains(characters[next]) { next += 1 }
                endsSentence = next >= count || characters[next].isWhitespace
            }
            guard endsSentence else {
                index += 1
                continue
            }
            var end = index + 1
            while end < count,
                  sentenceTerminators.contains(characters[end]) || characters[end] == "."
                  || sentenceClosers.contains(characters[end]) {
                end += 1
            }
            ranges.append(pieceStart..<end)
            while end < count, characters[end].isWhitespace { end += 1 }
            pieceStart = end
            index = end
        }
        if pieceStart < count { ranges.append(pieceStart..<count) }
        guard ranges.count >= 2 else { return [] }
        let wordy = ranges.allSatisfy { range in
            characters[range].lazy.filter { $0.isLetter || $0.isNumber }.count >= 2
        }
        return wordy ? ranges : []
    }

    /// 。！？ 及半角 ! ?,还有省略号 …。
    private static let sentenceTerminators: Set<Character> = [
        "\u{3002}", "\u{FF01}", "\u{FF1F}", "!", "?", "\u{2026}",
    ]

    /// 句末标点后面可以紧跟的引号括号:」』”’"'）)】〕］]》〉。
    private static let sentenceClosers: Set<Character> = [
        "\u{300D}", "\u{300F}", "\u{201D}", "\u{2019}", "\"", "'", "\u{FF09}", ")",
        "\u{3011}", "\u{3015}", "\u{FF3D}", "]", "\u{300B}", "\u{3009}",
    ]

    // MARK: - Headings

    /// 章节名:以「第…章/回/集」「序章」「Chapter 3」这类开头、不长、末尾不是句号逗号的一行。
    /// 「第三章」「Chapter 3.」这种只有章号的,带个句号也算。
    public static func isHeading(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 绝大多数字幕行第一个字就对不上,不用跑正则。
        guard let first = trimmed.prefix(1).lowercased().first, headingInitials.contains(first),
              trimmed.count <= headingMaxLength else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if bareHeading.firstMatch(in: trimmed, range: range) != nil { return true }
        guard let last = trimmed.last, !headingTerminators.contains(last) else { return false }
        return titledHeading.firstMatch(in: trimmed, range: range) != nil
    }

    /// 章节名可能的第一个字:第、序、楔、引、前、尾、后、後、最、终、終、大、番、卷、제,
    /// 以及 Chapter、Part、Book、Volume、Prologue、Epilogue、Interlude、Introduction、Foreword、Afterword 的首字母。
    private static let headingInitials: Set<Character> = [
        "\u{7B2C}", "\u{5E8F}", "\u{6954}", "\u{5F15}", "\u{524D}", "\u{5C3E}", "\u{540E}", "\u{5F8C}",
        "\u{6700}", "\u{7EC8}", "\u{7D42}", "\u{5927}", "\u{756A}", "\u{5377}", "\u{C81C}",
        "c", "p", "b", "v", "e", "i", "f", "a",
    ]

    private static let headingTerminators: Set<Character> = [
        "。", "！", "？", "…", ".", "!", "?", "，", ",", "；", ";", "、",
    ]

    // 下面的汉字写成 \u{…}(源码里不放汉字字面量),各条注释里写明是哪些字。

    /// 阿拉伯数字、全角数字、零〇一二三四五六七八九十百千万两,以及壹贰叁肆伍陆柒捌玖拾佰仟。
    private static let headingNumeral = "[0-9\u{FF10}-\u{FF19}\u{96F6}\u{3007}\u{4E00}\u{4E8C}\u{4E09}\u{56DB}\u{4E94}\u{516D}\u{4E03}\u{516B}\u{4E5D}\u{5341}\u{767E}\u{5343}\u{4E07}\u{4E24}\u{58F9}\u{8D30}\u{53C1}\u{8086}\u{4F0D}\u{9646}\u{67D2}\u{634C}\u{7396}\u{62FE}\u{4F70}\u{4EDF}]+"
    private static let englishNumeral = "(?:[0-9]+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten"
        + "|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen"
        + "|twenty[a-z-]*|thirty[a-z-]*|forty[a-z-]*|fifty[a-z-]*)\\b"
    /// 第 + 数字 + 章、卷,后面可以直接接标题;回、节、節、集、部、篇、幕、话、話、讲、講后面紧跟汉字的
    /// 多半是「第二回合」「第一集团」这种词,不算。
    private static let countedChinese = "\u{7B2C}\\s*" + headingNumeral
        + "\\s*(?:[\u{7AE0}\u{5377}]|[\u{56DE}\u{8282}\u{7BC0}\u{96C6}\u{90E8}\u{7BC7}\u{5E55}\u{8BDD}\u{8A71}\u{8BB2}\u{8B1B}](?!\\p{Han}))"
    /// 序章、序言、序幕、楔子、引子、引言、前言、尾声、尾聲、后记、後記、最终章、最終章、终章、終章、
    /// 大结局、大結局、番外(可带「篇」或数字)、序;后面紧跟汉字的(「序列」「前言不搭后语」)不算。
    private static let namedChinese = "(?:\u{5E8F}\u{7AE0}|\u{5E8F}\u{8A00}|\u{5E8F}\u{5E55}|\u{6954}\u{5B50}|\u{5F15}\u{5B50}|\u{5F15}\u{8A00}|\u{524D}\u{8A00}|\u{5C3E}\u{58F0}|\u{5C3E}\u{8072}|\u{540E}\u{8BB0}|\u{5F8C}\u{8A18}|\u{6700}\u{7EC8}\u{7AE0}|\u{6700}\u{7D42}\u{7AE0}|\u{7EC8}\u{7AE0}|\u{7D42}\u{7AE0}"
        + "|\u{5927}\u{7ED3}\u{5C40}|\u{5927}\u{7D50}\u{5C40}|\u{756A}\u{5916}(?:\u{7BC7}|" + headingNumeral + ")?|\u{5E8F})(?!\\p{Han})"
    /// 卷 + 数字。
    private static let volumeChinese = "\u{5377}\\s*" + headingNumeral
    private static let countedKorean = "제\\s*[0-9]+\\s*[장화부편권]"
    private static let englishChapter = "(?:chapter|chap\\.)\\s+" + englishNumeral
    /// 「Part one of my life」是句话:Part / Book 后面要么到头,要么接冒号破折号再写标题。
    private static let englishPart = "(?:part|book|volume|vol\\.)\\s+" + englishNumeral + "(?=\\s*$|\\s*[:.\\-–—])"
    private static let englishNamed = "(?:prologue|epilogue|interlude|preface|foreword|afterword|introduction)"
        + "(?=\\s*$|\\s*[:.\\-–—])"

    private static let titledHeading = try! NSRegularExpression(
        pattern: "^(?:" + [
            countedChinese, namedChinese, volumeChinese, countedKorean,
            englishChapter, englishPart, englishNamed,
        ].joined(separator: "|") + ")",
        options: [.caseInsensitive]
    )

    /// 只有章号的一行:第 + 数字 + 章卷回节節集部篇幕话話讲講,序章、楔子、引子、尾声、尾聲、终章、終章,
    /// Chapter / Part / Book + 数字,Prologue、Epilogue;末尾可以带一个句号或叹号。
    private static let bareHeading = try! NSRegularExpression(
        pattern: "^(?:\u{7B2C}\\s*" + headingNumeral + "\\s*[\u{7AE0}\u{5377}\u{56DE}\u{8282}\u{7BC0}\u{96C6}\u{90E8}\u{7BC7}\u{5E55}\u{8BDD}\u{8A71}\u{8BB2}\u{8B1B}]"
            + "|\u{5E8F}\u{7AE0}|\u{6954}\u{5B50}|\u{5F15}\u{5B50}|\u{5C3E}\u{58F0}|\u{5C3E}\u{8072}|\u{7EC8}\u{7AE0}|\u{7D42}\u{7AE0}"
            + "|(?:chapter|part|book)\\s+" + englishNumeral
            + "|prologue|epilogue)\\s*[。.!！]?$",
        options: [.caseInsensitive]
    )

    // MARK: - Search

    /// 文稿里所有出现 `query` 的地方,按先后。不分大小写、全半角、重音。
    public static func searchMatches(for query: String, in paragraphs: [Paragraph]) -> [SearchMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        var matches: [SearchMatch] = []
        for (index, paragraph) in paragraphs.enumerated() {
            let text = paragraph.text
            var searchStart = text.startIndex
            var offsetIndex = text.startIndex
            var offset = 0
            while searchStart < text.endIndex,
                  let found = text.range(of: needle, options: options, range: searchStart..<text.endIndex) {
                offset += text.distance(from: offsetIndex, to: found.lowerBound)
                let length = max(1, text.distance(from: found.lowerBound, to: found.upperBound))
                let range = offset..<(offset + length)
                matches.append(SearchMatch(
                    paragraph: index,
                    range: range,
                    start: segment(containing: range.lowerBound, in: paragraph)?.start ?? paragraph.start
                ))
                offsetIndex = found.lowerBound
                searchStart = found.upperBound > found.lowerBound ? found.upperBound : text.index(after: found.lowerBound)
            }
        }
        return matches
    }

    /// 刚开始搜时停在哪一处:正在念的那一段或之后的第一处,后面没有就回到第一处。
    public static func initialMatchIndex(_ matches: [SearchMatch], currentParagraph: Int?) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let currentParagraph else { return 0 }
        return matches.firstIndex { $0.paragraph >= currentParagraph } ?? 0
    }

    /// 上一处 / 下一处,首尾相接。
    public static func steppedMatchIndex(_ index: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return forward ? 0 : count - 1 }
        return (index + (forward ? 1 : -1) + count) % count
    }

    private static func segment(containing offset: Int, in paragraph: Paragraph) -> Segment? {
        paragraph.segments.last { $0.range.lowerBound <= offset }
    }

    // MARK: - Joining

    private static func startsNewParagraph(_ cue: Cue, after previous: Cue, currentLength: Int) -> Bool {
        if (cue.speaker ?? "") != (previous.speaker ?? "") { return true }
        if let start = cue.start, let previousStart = previous.start {
            if let previousEnd = previous.end {
                if start - previousEnd >= pauseBreak { return true }
            } else if start - previousStart >= startGapBreak {
                return true
            }
        }
        if currentLength >= hardLength { return true }
        if currentLength >= softLength, endsSentence(previous.text) { return true }
        return false
    }

    private static let sentenceEnds: Set<Character> = [
        "。", "！", "？", "…", ".", "!", "?", "」", "』", "”", "\"",
    ]

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return sentenceEnds.contains(last)
    }

    /// 中日韩文字之间不加空格,拉丁文字之间加一个。
    static func joining(_ head: String, _ tail: String) -> String {
        head + separator(between: head, and: tail) + tail
    }

    private static func separator(between head: String, and tail: String) -> String {
        guard let last = head.unicodeScalars.last, let first = tail.unicodeScalars.first else { return "" }
        return isCJK(last) || isCJK(first) ? "" : " "
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}

/// 全屏文稿里的左右扫:只在控件出现时用来退出全屏(#283)。控件收着时左右扫什么也不做,
/// 叫出控件交给点屏幕左右两边(`SpokenWordTranscriptEdgeTapPolicy`)。
///
/// 上下是翻文稿,所以只认明显横着的一扫(开始和松手时横向都要比纵向大出一截)。退出要扫得够远或够快;
/// 控件在时轻轻一扫不关全屏,只让控件多留一会儿。
public enum SpokenWordTranscriptSwipePolicy {
    public enum Outcome: Sendable, Equatable {
        case none
        case revealChrome
        case dismiss
    }

    /// 横向至少是纵向的这么多倍才算横扫。
    public static let horizontalDominanceRatio = 1.6
    /// 手指刚动时,动了这么远或这么快才判断方向。
    public static let minimumIntentDistance = 10.0
    public static let minimumIntentVelocity = 60.0
    /// 叫出控件:横着扫过这么远,或者扫得这么快(也至少扫过 `flickMinimumDistance`)。
    public static let revealDistance = 36.0
    public static let revealVelocity = 350.0
    /// 退出全屏:要扫得更远或更快,快扫也至少要过两倍的 `flickMinimumDistance`。
    public static let dismissDistance = 96.0
    public static let dismissVelocity = 800.0
    public static let flickMinimumDistance = 24.0
    /// 松手前往回拉得这么快,算是反悔了。
    public static let reversalVelocity = 120.0

    /// 手指刚动时:横着走才接手,竖着走留给文稿滚动。
    public static func shouldBegin(
        translationX: Double,
        translationY: Double,
        velocityX: Double,
        velocityY: Double
    ) -> Bool {
        let distance = hypot(translationX, translationY)
        let speed = hypot(velocityX, velocityY)
        guard distance >= minimumIntentDistance || speed >= minimumIntentVelocity else { return false }
        let usesVelocity = speed >= minimumIntentVelocity
        let horizontal = abs(usesVelocity ? velocityX : translationX)
        let vertical = abs(usesVelocity ? velocityY : translationY)
        return horizontal >= max(1, vertical * horizontalDominanceRatio)
    }

    /// 松手时这一扫算什么。往左往右一样。控件收着时一律不算。
    public static func outcome(
        translationX: Double,
        translationY: Double,
        velocityX: Double,
        chromeVisible: Bool
    ) -> Outcome {
        guard chromeVisible else { return .none }
        let distance = abs(translationX)
        guard distance >= max(1, abs(translationY) * horizontalDominanceRatio) else { return .none }
        if translationX * velocityX < 0, abs(velocityX) >= reversalVelocity { return .none }
        let speed = abs(velocityX)
        if distance >= dismissDistance || (speed >= dismissVelocity && distance >= flickMinimumDistance * 2) {
            return .dismiss
        }
        if distance >= revealDistance || (speed >= revealVelocity && distance >= flickMinimumDistance) {
            return .revealChrome
        }
        return .none
    }
}

/// 全屏文稿左右两边的点按区(#283):点在这两条里只叫出或收起控件,不从那一段开始播。
/// 原来只有正文两侧二十来点的留白算「点空白处」,手指稍微偏一点就点到段落上跳播了。
/// 宽度按屏宽取一成六,最窄 44(一个手指),最宽 120(iPad 上正文限宽居中,两边本来就是空白);
/// 两边加起来不超过屏宽的一半,中间总留着点段落播放的地方。
public enum SpokenWordTranscriptEdgeTapPolicy {
    public static let widthFraction = 0.16
    public static let minimumWidth = 44.0
    public static let maximumWidth = 120.0

    public static func edgeWidth(viewportWidth: Double) -> Double {
        guard viewportWidth > 0 else { return 0 }
        let preferred = min(max(viewportWidth * widthFraction, minimumWidth), maximumWidth)
        return min(preferred, viewportWidth / 4)
    }

    /// `x` 从屏幕(文稿那一屏)左边量起。
    public static func isEdgeTap(x: Double, viewportWidth: Double) -> Bool {
        let width = edgeWidth(viewportWidth: viewportWidth)
        guard width > 0 else { return false }
        return x <= width || x >= viewportWidth - width
    }
}

/// 文稿(播客文字稿、有声书字幕)显示时的时间偏移(#320)。
///
/// 声音和文字对不上有两种来源:输出设备本身有延迟(CarPlay、蓝牙、AirPlay),对所有文稿都一样;
/// 播客插播的动态广告让后面整段往后挪,只对那一集成立。所以分两层:全局一层,加上这一集 / 这本书
/// 自己的一层,两层相加。偏移改的是显示用的文稿时间轴,不改缓存里的原文:点一行跳过去,跳到的是
/// 平移后的时间,也就是这句话在音频里真正出现的地方。
public enum SpokenWordTranscriptOffsetPolicy {
    /// 微调一下的步长。
    public static let step: TimeInterval = 0.5
    /// 插播广告可能有一两分钟;再大多半是误操作。
    public static let limit: TimeInterval = 600

    /// 存起来之前统一取到 0.1 秒、夹在范围内。
    public static func normalized(_ delay: TimeInterval) -> TimeInterval {
        guard delay.isFinite else { return 0 }
        let clamped = min(max(delay, -limit), limit)
        let rounded = (clamped * 10).rounded() / 10
        return rounded == 0 ? 0 : rounded
    }

    /// 两层相加后的偏移。
    public static func effectiveDelay(global: TimeInterval, item: TimeInterval?) -> TimeInterval {
        normalized(global + (item ?? 0))
    }

    /// 一集播客按单集记,一本书按书记(同一本书的章节出自同一套音频,偏差一样),
    /// 其余按这首(一个文件)记。
    public static func itemKey(songID: String, bookID: String?, isPodcastEpisode: Bool) -> String {
        if !isPodcastEpisode, let bookID, !bookID.isEmpty { return "book:\(bookID)" }
        return "song:\(songID)"
    }

    /// `delay` 为正:文稿往后挪,晚一点出来(声音比文字慢);为负:提前。整份一起挪(时间为 0 的
    /// 第一行也算),和 LRC 的 `[offset:]` 同一种平移。不带时间的纯文本文稿原样返回。
    public static func applying(delay: TimeInterval, to lines: [LyricLine]) -> [LyricLine] {
        let delay = normalized(delay)
        guard delay != 0, lines.contains(where: \.isSynchronized) else { return lines }
        return LyricDocumentOffsetPolicy.applying(offset: -delay, to: lines)
    }
}
