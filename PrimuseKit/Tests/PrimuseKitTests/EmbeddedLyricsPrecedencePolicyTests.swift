import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyric files beside the song outrank embedded lyrics")
struct EmbeddedLyricsPrecedencePolicyTests {
    private let plain = [LyricLine(timestamp: 0, text: "Let it be", isSynchronized: false)]
    private let timed = [LyricLine(timestamp: 10.45, text: "Let it be")]
    private let wordTimed = [LyricLine(
        timestamp: 10.45,
        text: "Let it be",
        syllables: [
            LyricSyllable(text: "Let ", start: 10.45, end: 10.8),
            LyricSyllable(text: "it be", start: 10.8, end: 11.6),
        ]
    )]

    @Test("Source documents are told apart from the app's own cache names")
    func sourceReferences() {
        #expect(EmbeddedLyricsPrecedencePolicy.referencesSourceDocument("/Music/Album/Song.lrc"))
        #expect(EmbeddedLyricsPrecedencePolicy.referencesSourceDocument("Song.ttml"))
        // Google Drive 记的是歌词文件的 id。
        #expect(EmbeddedLyricsPrecedencePolicy.referencesSourceDocument("1AbC-dEf_ghIJ"))
        #expect(!EmbeddedLyricsPrecedencePolicy.referencesSourceDocument("0f3a9c1e2b4d5a6f7e8d9c0b1a2f3e4d.json"))
        #expect(!EmbeddedLyricsPrecedencePolicy.referencesSourceDocument(nil))
        #expect(!EmbeddedLyricsPrecedencePolicy.referencesSourceDocument("  "))
    }

    @Test("Timing levels rank word over line over plain")
    func timingLevels() {
        #expect(LyricsTimingLevel(lines: plain) == .plain)
        #expect(LyricsTimingLevel(lines: timed) == .line)
        #expect(LyricsTimingLevel(lines: wordTimed) == .word)
        #expect(LyricsTimingLevel.plain < .line && LyricsTimingLevel.line < .word)
    }

    @Test("Caches short of word timing are rechecked, and only finer timing replaces lyrics")
    func recheck() {
        var edited = plain
        edited[0].documentIsLocalOverride = true

        #expect(EmbeddedLyricsPrecedencePolicy.shouldRecheckSourceDocument(cached: plain))
        // #208: 早先存下的内嵌歌词是逐行的, 也要回源核对。
        #expect(EmbeddedLyricsPrecedencePolicy.shouldRecheckSourceDocument(cached: timed))
        #expect(!EmbeddedLyricsPrecedencePolicy.shouldRecheckSourceDocument(cached: wordTimed))
        #expect(!EmbeddedLyricsPrecedencePolicy.shouldRecheckSourceDocument(cached: edited))
        #expect(!EmbeddedLyricsPrecedencePolicy.shouldRecheckSourceDocument(cached: []))

        #expect(EmbeddedLyricsPrecedencePolicy.sourceDocumentReplaces(cached: plain, with: timed))
        #expect(EmbeddedLyricsPrecedencePolicy.sourceDocumentReplaces(cached: timed, with: wordTimed))
        #expect(!EmbeddedLyricsPrecedencePolicy.sourceDocumentReplaces(cached: plain, with: plain))
        #expect(!EmbeddedLyricsPrecedencePolicy.sourceDocumentReplaces(cached: timed, with: timed))
        #expect(!EmbeddedLyricsPrecedencePolicy.sourceDocumentReplaces(cached: edited, with: timed))
    }

    @Test("A song pointing at a lyric file follows that file once its timing is no coarser")
    func linkedRecheck() {
        typealias Policy = EmbeddedLyricsPrecedencePolicy
        let embedded = [
            LyricLine(timestamp: 12.1, text: "Embedded first line"),
            LyricLine(timestamp: 15.3, text: "Embedded second line"),
        ]
        var edited = embedded
        edited[0].documentIsLocalOverride = true

        #expect(Policy.sourceDocumentLink(reference: "1AbC-dEf_ghIJ", isPinned: false) == .referenced)
        #expect(Policy.sourceDocumentLink(reference: "/Music/Song.lrc", isPinned: false) == .referenced)
        #expect(Policy.sourceDocumentLink(reference: "0f3a9c1e.json", isPinned: false) == .none)
        #expect(Policy.sourceDocumentLink(reference: "0f3a9c1e.json", isPinned: true) == .pinned)

        // 歌指着歌词文件: 同样逐行、内容不同就换成文件; 文件更粗不换。
        #expect(Policy.sourceDocumentReplaces(cached: embedded, with: timed, link: .referenced))
        #expect(!Policy.sourceDocumentReplaces(cached: embedded, with: plain, link: .referenced))
        // 缓存名(刮削到的歌词)只在更细时换。
        #expect(!Policy.sourceDocumentReplaces(cached: embedded, with: timed, link: .none))
        #expect(Policy.sourceDocumentReplaces(cached: embedded, with: wordTimed, link: .none))
        // 用户选定的文件粗细都换。
        #expect(Policy.sourceDocumentReplaces(cached: embedded, with: plain, link: .pinned))
        // 同一份、用户改过的都不换。
        #expect(!Policy.sourceDocumentReplaces(cached: timed, with: timed, link: .pinned))
        #expect(!Policy.sourceDocumentReplaces(cached: edited, with: timed, link: .pinned))
        #expect(!Policy.sourceDocumentReplaces(cached: embedded, with: [], link: .pinned))
    }

    @Test("The same lyric file stays the same document after the cache adds to it")
    func sameDocument() {
        typealias Policy = EmbeddedLyricsPrecedencePolicy
        let parsed = [
            LyricLine(id: "a", timestamp: 10.45, text: "Let it be"),
            LyricLine(id: "b", timestamp: 10.45, text: "顺其自然"),
            LyricLine(id: "c", timestamp: 14.2, text: "Whisper words &amp; wisdom"),
        ]
        // 缓存里另配了 id、双语 LRC 的译文行配到了上一行、实体解码、用户补了一条译文。
        var cachedFirst = LyricLine(id: "x", timestamp: 10.45, text: "Let it be")
        cachedFirst.manualTranslation = LyricManualTranslation(text: "顺其自然", source: .bilingualLRC)
        var cachedSecond = LyricLine(id: "y", timestamp: 14.2, text: "Whisper words & wisdom ")
        cachedSecond.manualTranslation = LyricManualTranslation(text: "低语智慧", source: .localEditor)
        #expect(Policy.sameDocument(parsed, [cachedFirst, cachedSecond]))

        var moved = cachedSecond
        moved.timestamp = 14.5
        #expect(!Policy.sameDocument(parsed, [cachedFirst, moved]))
        var reworded = cachedSecond
        reworded.text = "Speaking words of wisdom"
        #expect(!Policy.sameDocument(parsed, [cachedFirst, reworded]))
        // 一样的字, 一份逐行一份没时间轴, 不算同一份。
        #expect(!Policy.sameDocument(timed, plain.map {
            var line = $0
            line.timestamp = 10.45
            line.isSynchronized = false
            return line
        }))
    }

    @Test("Word-timed files win over line-timed ones, whatever their format")
    func timingPreferredDocument() {
        // 两份可写文件原来是冲突, 现在逐字的那份胜出。
        let pair = ["Song.lrc", "Song.ttml", "Song.flac"]
        #expect(LyricsSidecarSelectionPolicy.timingPreferredDocument(
            baseName: "Song", names: pair, levels: [.line, .word, nil]
        ) == 1)
        // 时间轴一样: 取排在前面的可写文件(与歌词来源页「使用中」一致)。
        #expect(LyricsSidecarSelectionPolicy.timingPreferredDocument(
            baseName: "Song", names: pair, levels: [.line, .line, nil]
        ) == 0)

        // 只读的逐字 .elrc 胜过可写的逐行 .lrc。
        let elrc = ["Song.lrc", "Song.elrc"]
        #expect(LyricsSidecarSelectionPolicy.timingPreferredDocument(
            baseName: "Song", names: elrc, levels: [.line, .word]
        ) == 1)
        // 原来的规则已经挑中最好的那份时不必另选。
        #expect(LyricsSidecarSelectionPolicy.timingPreferredDocument(
            baseName: "Song", names: elrc, levels: [.word, .word]
        ) == nil)
        // 读不出的不参与; 只有一份就没得选。
        #expect(LyricsSidecarSelectionPolicy.timingPreferredDocument(
            baseName: "Song", names: elrc, levels: [nil, .line]
        ) == 1)
        #expect(LyricsSidecarSelectionPolicy.timingPreferredDocument(
            baseName: "Song", names: ["Song.lrc"], levels: [.plain]
        ) == nil)
    }

    @Test("An automatic pick yields to the listener's choice and becomes theirs once saved")
    func automaticPicks() {
        let store = LyricsDocumentPinStore(fileURL: nil)
        #expect(!store.hasEvaluatedAutomaticPick(forSongID: "s"))
        store.setAutomaticPick(nil, forSongID: "s")
        #expect(store.hasEvaluatedAutomaticPick(forSongID: "s"))
        #expect(store.effectiveFileName(forSongID: "s") == nil)

        store.setAutomaticPick("Song.ttml", forSongID: "s")
        #expect(store.effectiveFileName(forSongID: "s") == "Song.ttml")
        #expect(store.pinnedFileName(forSongID: "s") == nil)

        store.pin("Song.lrc", forSongID: "s")
        #expect(store.effectiveFileName(forSongID: "s") == "Song.lrc")

        let saved = LyricsDocumentPinStore(fileURL: nil)
        saved.setAutomaticPick("Song.ttml", forSongID: "s")
        saved.followSave(toFileName: "Song.ttml", forSongID: "s")
        #expect(saved.pinnedFileName(forSongID: "s") == "Song.ttml")

        let deleted = LyricsDocumentPinStore(fileURL: nil)
        deleted.setAutomaticPick("Song.ttml", forSongID: "s")
        deleted.forgetFile(named: "song.TTML", forSongID: "s")
        #expect(deleted.effectiveFileName(forSongID: "s") == nil)
        #expect(!deleted.hasEvaluatedAutomaticPick(forSongID: "s"))
    }
}
