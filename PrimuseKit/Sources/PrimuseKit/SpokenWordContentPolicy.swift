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
        "podcast", "播客", "ポッドキャスト", "팟캐스트",
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
        "有声书", "有声小说", "有声读物", "有声故事", "广播剧",
        "评书", "相声", "快板", "小品", "曲艺", "说书", "单口", "对口",
        "脱口秀", "讲座", "演讲", "朗读", "朗诵", "故事会", "儿童故事",
        // Japanese and Korean
        "オーディオブック", "朗読", "落語", "오디오북",
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
/// 纯文本只在空行处分段,作者自己断的行接起来。
public enum SpokenWordTranscriptReadingPolicy {
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

    public struct Paragraph: Sendable, Equatable, Identifiable {
        /// 第一行与最后一行在原文稿里的位置。
        public var firstCue: Int
        public var lastCue: Int
        public var text: String
        /// 第一行开始的时间;不带时间的段落是 nil,点了不跳。
        public var start: TimeInterval?

        public var id: Int { firstCue }
    }

    /// 前一行有结束时间时,隔这么久就算换了一段话。
    public static let pauseBreak: TimeInterval = 2.5
    /// 只有开始时间(LRC)时两行开头相隔这么久才算停顿:一行本身就要念几秒。
    public static let startGapBreak: TimeInterval = 10
    /// 一段到这么长,遇到句末就断开。
    public static let softLength = 240
    /// 再长也断(没有标点的长文稿)。
    public static let hardLength = 600

    public static func paragraphs(from cues: [Cue]) -> [Paragraph] {
        var result: [Paragraph] = []
        var current: Paragraph?
        var previous: Cue?

        func close() {
            if let paragraph = current { result.append(paragraph) }
            current = nil
        }

        for (index, cue) in cues.enumerated() {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                // 空行:作者断的段。
                close()
                previous = nil
                continue
            }
            if var paragraph = current, let previous,
               !startsNewParagraph(cue, after: previous, currentLength: paragraph.text.count) {
                paragraph.text = joining(paragraph.text, text)
                paragraph.lastCue = index
                current = paragraph
            } else {
                close()
                current = Paragraph(firstCue: index, lastCue: index, text: text, start: cue.start)
            }
            previous = cue
        }
        close()
        return result
    }

    /// 正在念的那一段:开始时间不晚于 `time` 的最后一段。
    public static func paragraphIndex(at time: TimeInterval, in paragraphs: [Paragraph]) -> Int? {
        var found: Int?
        for (index, paragraph) in paragraphs.enumerated() {
            guard let start = paragraph.start else { continue }
            if start <= time + 0.05 { found = index } else { break }
        }
        return found
    }

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
        guard let last = head.unicodeScalars.last, let first = tail.unicodeScalars.first else { return head + tail }
        return isCJK(last) || isCJK(first) ? head + tail : head + " " + tail
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
