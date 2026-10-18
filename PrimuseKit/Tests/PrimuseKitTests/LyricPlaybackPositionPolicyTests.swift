import Testing
@testable import PrimuseKit

@Suite("Lyric playback positioning")
struct LyricPlaybackPositionPolicyTests {
    @Test("Companion rows do not deactivate the source word timeline")
    func deactivationSkipsTheCurrentTimestampGroup() throws {
        let lyrics = [
            LyricLine(timestamp: 61.364, text: "Source"),
            LyricLine(timestamp: 61.364, text: "Reading"),
            LyricLine(timestamp: 61.365, text: "Translation"),
            LyricLine(timestamp: 64.166, text: "Next"),
        ]
        let end = try #require(LyricPlaybackPositionPolicy.wordLevelDeactivationTime(
            in: lyrics, afterLine: 0, lookahead: 0.1
        ))
        #expect(abs(end - 64.066) < 0.000001)
        #expect(63.0 < end)
        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics, at: 63, lookahead: 0.1
        ) == 0)
        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics, at: end + 0.001, lookahead: 0.1
        ) == 3)
    }

    @Test("A final timestamp group has no next-line deactivation")
    func finalGroupKeepsItsWordTimeline() {
        let lyrics = [
            LyricLine(timestamp: 88.507, text: "Source"),
            LyricLine(timestamp: 88.507, text: "Reading"),
            LyricLine(timestamp: 88.507, text: "Translation"),
        ]
        for index in lyrics.indices {
            #expect(LyricPlaybackPositionPolicy.wordLevelDeactivationTime(
                in: lyrics, afterLine: index, lookahead: 0.1
            ) == nil)
        }
        #expect(LyricPlaybackPositionPolicy.wordLevelDeactivationTime(
            in: lyrics, afterLine: -1
        ) == nil)
        #expect(LyricPlaybackPositionPolicy.wordLevelDeactivationTime(
            in: [], afterLine: 0
        ) == nil)
    }

    @Test("Ordinary line takeovers retain lookahead and the current start bound")
    func deactivationPreservesOrdinaryTakeovers() {
        let lyrics = [
            LyricLine(timestamp: 1, text: "First"),
            LyricLine(timestamp: 1.05, text: "Second"),
        ]
        #expect(LyricPlaybackPositionPolicy.wordLevelDeactivationTime(
            in: lyrics, afterLine: 0, lookahead: 0.1
        ) == 1)
        #expect(LyricPlaybackPositionPolicy.wordLevelDeactivationTime(
            in: lyrics, afterLine: 0, lookahead: -1
        ) == 1.05)
    }

    @Test("Lyrics loaded in the middle of playback select the current row")
    func selectsCurrentRowAfterDelayedLoad() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 0, text: "First"),
            LyricLine(id: "second", timestamp: 12, text: "Second"),
            LyricLine(id: "third", timestamp: 24, text: "Third"),
        ]

        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: 19
        ) == 1)
    }

    @Test("Lookahead can advance to an imminent lyric row")
    func appliesLookahead() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 0, text: "First"),
            LyricLine(id: "second", timestamp: 10, text: "Second"),
        ]

        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: 9.8,
            lookahead: 0.25
        ) == 1)
    }

    @Test("Playback waits before the first synchronized lyric")
    func waitsBeforeFirstLyric() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 3.1, text: "First"),
            LyricLine(id: "second", timestamp: 8, text: "Second"),
        ]

        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: 2.99,
            lookahead: 0.1
        ) == nil)
        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 2.99,
            lookahead: 0.1
        ) == nil)
        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: 3,
            lookahead: 0.1
        ) == 0)
    }

    @Test("Empty lyrics have no active row")
    func emptyLyricsHaveNoActiveRow() {
        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: [],
            at: 30
        ) == nil)
    }

    @Test("Only synchronized lyrics follow playback")
    func synchronizationControlsAutomaticFollow() {
        let plain = [
            LyricLine(timestamp: 0, text: "First", isSynchronized: false),
            LyricLine(timestamp: 0, text: "Second", isSynchronized: false),
        ]
        let synchronized = [
            LyricLine(timestamp: 0, text: "First", isSynchronized: true),
            LyricLine(timestamp: 10, text: "Second", isSynchronized: true),
        ]

        #expect(!LyricPlaybackPositionPolicy.shouldFollowPlayback(in: plain))
        #expect(LyricPlaybackPositionPolicy.shouldFollowPlayback(in: synchronized))
    }

    @Test("A platform lyric model can reuse timestamp positioning")
    func supportsPlatformSpecificLyricModels() {
        struct Line { let time: Double }
        let lyrics = [Line(time: 0), Line(time: 8), Line(time: 16)]

        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: 12,
            timestamp: { $0.time }
        ) == 1)
    }

    @Test("Long line-level gaps scroll to an interlude without advancing the active lyric")
    func longLineLevelGapUsesInterludeTarget() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 0, text: "First"),
            LyricLine(id: "second", timestamp: 40, text: "Second"),
        ]

        #expect(LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: 20
        ) == 0)
        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 20
        ) == .interlude(afterLine: 0))
    }

    @Test("Interlude scrolling waits until the current lyric has visibly finished")
    func interludeTargetHonorsActivationDelay() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 0, text: "First"),
            LyricLine(id: "second", timestamp: 40, text: "Second"),
        ]

        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 9.4
        ) == .line(0))
        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 9.5
        ) == .interlude(afterLine: 0))
    }

    @Test("Ordinary lyric spacing never creates an interlude target")
    func ordinaryGapStaysOnActiveLine() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 0, text: "First"),
            LyricLine(id: "second", timestamp: 10, text: "Second"),
        ]

        #expect(!LyricPlaybackPositionPolicy.hasLongInterlude(
            afterLine: 0,
            in: lyrics
        ))
        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 9
        ) == .line(0))
    }

    @Test("Word-level interludes use the final syllable end time")
    func wordLevelGapUsesExplicitEndTime() {
        let lyrics = [
            LyricLine(
                id: "first",
                timestamp: 0,
                text: "First",
                syllables: [LyricSyllable(text: "First", start: 0, end: 20)]
            ),
            LyricLine(id: "second", timestamp: 40, text: "Second"),
        ]

        // 知道人声什么时候停:唱完 0.6 秒就换成提示点,不用像估算那样再等 6 秒。
        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 20.5
        ) == .line(0))
        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 20.7
        ) == .interlude(afterLine: 0))
    }

    @Test("有结束时间的歌词四秒的空档就算间奏,三秒多不算")
    func timedLyricsUseTheShortThreshold() {
        let sung = LyricLine(
            id: "a",
            timestamp: 0,
            text: "Sung",
            syllables: [LyricSyllable(text: "Sung", start: 0, end: 5)]
        )
        let shortGap = [sung, LyricLine(id: "b", timestamp: 8.5, text: "Next")]
        let longGap = [sung, LyricLine(id: "b", timestamp: 9.2, text: "Next")]

        #expect(!LyricPlaybackPositionPolicy.hasLongInterlude(afterLine: 0, in: shortGap))
        #expect(LyricPlaybackPositionPolicy.hasLongInterlude(afterLine: 0, in: longGap))
        #expect(LyricPlaybackPositionPolicy.scrollTarget(in: longGap, at: 6) == .interlude(afterLine: 0))
    }

    @Test("普通 LRC 只有开始时间,门槛照旧保守")
    func lineLevelLyricsKeepTheConservativeThreshold() {
        let lyrics = [
            LyricLine(id: "a", timestamp: 0, text: "First"),
            LyricLine(id: "b", timestamp: 9, text: "Second"),
        ]
        #expect(!LyricPlaybackPositionPolicy.hasLongInterlude(afterLine: 0, in: lyrics))
        #expect(LyricPlaybackPositionPolicy.scrollTarget(in: lyrics, at: 8) == .line(0))
    }

    @Test("和声比主唱唱得久时,间奏从和声停下算起")
    func backgroundVocalsExtendTheVocalEnd() {
        let lyrics = [
            LyricLine(
                id: "a",
                timestamp: 0,
                text: "Lead",
                syllables: [LyricSyllable(text: "Lead", start: 0, end: 4)],
                background: [LyricLine(
                    timestamp: 3,
                    text: "Echo",
                    syllables: [LyricSyllable(text: "Echo", start: 3, end: 7)]
                )]
            ),
            LyricLine(id: "b", timestamp: 10, text: "Next"),
        ]
        // 主唱 4 秒停,到下一句有 6 秒;和声唱到 7 秒,只剩 3 秒,不算间奏。
        #expect(!LyricPlaybackPositionPolicy.hasLongInterlude(afterLine: 0, in: lyrics))
    }

    @Test("间奏开头的空行就是人声停下的时刻")
    func blankLrcLineMarksTheVocalEnd() {
        let lyrics = [
            LyricLine(id: "a", timestamp: 0, text: "First"),
            LyricLine(id: "gap", timestamp: 3, text: ""),
            LyricLine(id: "b", timestamp: 8, text: "Second"),
        ]
        #expect(LyricPlaybackPositionPolicy.scrollTarget(in: lyrics, at: 3.5) == .line(1))
        #expect(LyricPlaybackPositionPolicy.scrollTarget(in: lyrics, at: 3.7) == .interlude(afterLine: 1))
        #expect(LyricPlaybackPositionPolicy.scrollTarget(in: lyrics, at: 8) == .line(2))
    }

    @Test("第一句前够长的前奏显示提示点,短前奏不显示")
    func introBeforeTheFirstLine() {
        let longIntro = [
            LyricLine(id: "a", timestamp: 12, text: "First"),
            LyricLine(id: "b", timestamp: 16, text: "Second"),
        ]
        #expect(LyricPlaybackPositionPolicy.scrollTarget(in: longIntro, at: 0) == .intro)
        #expect(LyricPlaybackPositionPolicy.scrollTarget(in: longIntro, at: 11.9) == .intro)
        #expect(LyricPlaybackPositionPolicy.scrollTarget(in: longIntro, at: 12) == .line(0))
        // 拖到前奏中间,直接就是前奏的状态和进度。
        let window = LyricPlaybackPositionPolicy.introWindow(in: longIntro)!
        #expect(LyricPlaybackPositionPolicy.phase(of: window, at: 6).progress == 0.5)

        let shortIntro = [LyricLine(id: "a", timestamp: 3, text: "First")]
        #expect(LyricPlaybackPositionPolicy.introWindow(in: shortIntro) == nil)
        #expect(LyricPlaybackPositionPolicy.scrollTarget(in: shortIntro, at: 1) == nil)
    }

    @Test("开头的空时间标签算在前奏里")
    func leadingBlankLinesBelongToTheIntro() {
        let lyrics = [
            LyricLine(id: "blank", timestamp: 0, text: ""),
            LyricLine(id: "a", timestamp: 20, text: "First"),
        ]
        #expect(LyricPlaybackPositionPolicy.scrollTarget(in: lyrics, at: 5) == .intro)
        #expect(!LyricPlaybackPositionPolicy.hasLongInterlude(afterLine: 0, in: lyrics))
    }

    @Test("心跳只在下一句开始前那一小段,开唱时已经回到原大小")
    func heartbeatPrecedesTheNextLine() {
        let timing = LyricPlaybackPositionPolicy.InterludeTiming.standard
        #expect(LyricPlaybackPositionPolicy.interludeHeartbeatScale(secondsUntilNextLine: 2) == 1)
        #expect(LyricPlaybackPositionPolicy.interludeHeartbeatScale(secondsUntilNextLine: 0) == 1)
        #expect(LyricPlaybackPositionPolicy.interludeHeartbeatScale(secondsUntilNextLine: -0.2) == 1)
        let samples = stride(from: 0.0, through: timing.anticipation, by: 0.01).map {
            LyricPlaybackPositionPolicy.interludeHeartbeatScale(secondsUntilNextLine: $0)
        }
        let peak = samples.max() ?? 1
        #expect(peak > 1.12 && peak < 1.2)
        #expect(samples.allSatisfy { $0 >= 1 })
        // 第一下比第二下大,两下之间回落。
        let first = LyricPlaybackPositionPolicy.interludeHeartbeatScale(secondsUntilNextLine: timing.anticipation * 0.7)
        let between = LyricPlaybackPositionPolicy.interludeHeartbeatScale(secondsUntilNextLine: timing.anticipation * 0.54)
        let second = LyricPlaybackPositionPolicy.interludeHeartbeatScale(secondsUntilNextLine: timing.anticipation * 0.38)
        #expect(first > second && second > between)
        #expect(LyricPlaybackPositionPolicy.interludeHeartbeatScale(secondsUntilNextLine: 0.01) < 1.01)
    }

    @Test("提示点的进度带上和滚动一样的提前量")
    func phaseHonorsLookahead() {
        let lyrics = [
            LyricLine(id: "a", timestamp: 0, text: "First"),
            LyricLine(id: "b", timestamp: 40, text: "Second"),
        ]
        let window = LyricPlaybackPositionPolicy.interludeWindow(afterLine: 0, in: lyrics)!
        let phase = LyricPlaybackPositionPolicy.phase(of: window, at: 39.5, lookahead: 0.25)
        #expect(abs(phase.secondsUntilNextLine - 0.25) < 0.0001)
    }

    /// 电视自己存一份歌词行(`TVLyricLine`),走泛型那一份;每一种间奏写法都要和 `LyricLine` 判得一模一样。
    @Test("自带歌词行模型的界面得到与 LyricLine 相同的前奏、间奏与滚动目标")
    func platformLyricModelsShareTheInterludeRules() {
        struct PlatformRow {
            let time: Double
            let text: String
            let end: Double?
            let backgroundEnds: [Double?]

            init(_ line: LyricLine) {
                time = line.timestamp
                text = line.text
                end = line.endTime
                backgroundEnds = (line.background ?? []).map(\.endTime)
            }
        }
        typealias Policy = LyricPlaybackPositionPolicy
        func vocalEnd(_ row: PlatformRow) -> Double? {
            Policy.vocalEnd(lineEnd: row.end, backgroundEnds: row.backgroundEnds)
        }
        func isBlank(_ row: PlatformRow) -> Bool {
            Policy.isInterludeBlank(text: row.text, hasBackground: !row.backgroundEnds.isEmpty)
        }
        // 先取出结果再比:`#expect` 展开时会把闭包实参包一层,非逃逸的闭包参数过不去。
        func intro(_ rows: [PlatformRow]) -> Policy.InterludeWindow? {
            Policy.introWindow(in: rows, timestamp: \.time, isBlank: isBlank)
        }
        func window(after index: Int, in rows: [PlatformRow]) -> Policy.InterludeWindow? {
            Policy.interludeWindow(afterLine: index, in: rows, timestamp: \.time, vocalEnd: vocalEnd, isBlank: isBlank)
        }
        func target(_ rows: [PlatformRow], at time: Double, lookahead: Double = 0) -> Policy.ScrollTarget? {
            Policy.scrollTarget(
                in: rows, at: time, lookahead: lookahead,
                timestamp: \.time, vocalEnd: vocalEnd, isBlank: isBlank
            )
        }
        func active(_ rows: [PlatformRow], at time: Double, lookahead: Double) -> Policy.InterludeWindow? {
            Policy.activeInterlude(
                in: rows, at: time, lookahead: lookahead,
                timestamp: \.time, vocalEnd: vocalEnd, isBlank: isBlank
            )
        }
        let fixtures: [[LyricLine]] = [
            // 普通 LRC:估算唱完、长空档、短空档。
            [
                LyricLine(id: "a", timestamp: 0, text: "First"),
                LyricLine(id: "b", timestamp: 9, text: "Second"),
                LyricLine(id: "c", timestamp: 40, text: "Third"),
            ],
            // 逐字:最后一个字的结束时间,以及唱得更久的和声。
            [
                LyricLine(
                    id: "a",
                    timestamp: 6,
                    text: "Lead",
                    syllables: [LyricSyllable(text: "Lead", start: 6, end: 10)],
                    background: [LyricLine(
                        timestamp: 9,
                        text: "Echo",
                        syllables: [LyricSyllable(text: "Echo", start: 9, end: 13)]
                    )]
                ),
                LyricLine(
                    id: "b",
                    timestamp: 16,
                    text: "Next",
                    syllables: [LyricSyllable(text: "Next", start: 16, end: 18)]
                ),
                LyricLine(id: "c", timestamp: 23, text: "Last"),
            ],
            // 行末时间(字幕、TTML 行级)与同一时间戳的译文行。
            [
                LyricLine(id: "a", timestamp: 1, text: "Line", endTimestamp: 3),
                LyricLine(id: "a-t", timestamp: 1, text: "译文", endTimestamp: 3),
                LyricLine(id: "b", timestamp: 9, text: "Line two"),
            ],
            // 开头的空时间标签算前奏,中间的空时间标签就是人声停下的时刻。
            [
                LyricLine(id: "lead", timestamp: 0, text: ""),
                LyricLine(id: "a", timestamp: 14, text: "First"),
                LyricLine(id: "gap", timestamp: 17, text: " "),
                LyricLine(id: "b", timestamp: 24, text: "Second"),
            ],
        ]

        for lyrics in fixtures {
            let rows = lyrics.map(PlatformRow.init)
            #expect(intro(rows) == Policy.introWindow(in: lyrics))
            for index in lyrics.indices {
                #expect(window(after: index, in: rows) == Policy.interludeWindow(afterLine: index, in: lyrics))
            }
            for tenth in 0...450 {
                let time = Double(tenth) / 10
                #expect(target(rows, at: time, lookahead: 0.25) == Policy.scrollTarget(in: lyrics, at: time, lookahead: 0.25))
                #expect(active(rows, at: time, lookahead: 0.25) == Policy.activeInterlude(in: lyrics, at: time, lookahead: 0.25))
            }
        }

        // 各段都真的走到了:否则上面全是 nil == nil。
        let wordLevel = fixtures[1].map(PlatformRow.init)
        #expect(target(wordLevel, at: 2) == .intro)
        #expect(window(after: 0, in: wordLevel) == nil)
        #expect(target(wordLevel, at: 19) == .interlude(afterLine: 1))
        let leadingBlank = fixtures[3].map(PlatformRow.init)
        #expect(target(leadingBlank, at: 5) == .intro)
        #expect(target(leadingBlank, at: 18) == .interlude(afterLine: 2))
        let subtitle = fixtures[2].map(PlatformRow.init)
        #expect(target(subtitle, at: 4) == .interlude(afterLine: 0))
        #expect(target(fixtures[0].map(PlatformRow.init), at: 20) == .interlude(afterLine: 1))
    }

    @Test("人声结束取行末与和声里最晚的,空行要既没有字也没有和声")
    func vocalEndAndBlankRowHelpers() {
        #expect(LyricPlaybackPositionPolicy.vocalEnd(lineEnd: nil, backgroundEnds: []) == nil)
        #expect(LyricPlaybackPositionPolicy.vocalEnd(lineEnd: 4, backgroundEnds: [7, nil]) == 7)
        #expect(LyricPlaybackPositionPolicy.vocalEnd(lineEnd: .infinity, backgroundEnds: [nil]) == nil)
        #expect(LyricPlaybackPositionPolicy.isInterludeBlank(text: " \n", hasBackground: false))
        #expect(!LyricPlaybackPositionPolicy.isInterludeBlank(text: "", hasBackground: true))
        #expect(!LyricPlaybackPositionPolicy.isInterludeBlank(text: "la", hasBackground: false))
    }

    @Test("The next timestamp ends the interlude and selects its lyric")
    func nextLineEndsInterlude() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 0, text: "First"),
            LyricLine(id: "second", timestamp: 40, text: "Second"),
        ]

        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 40
        ) == .line(1))
    }

    /// refs #152 —— 配对不成立时（多声部，或结构本身就说不清的文件）同一个
    /// 时间戳上会留着好几行。高亮落在最后一行等于把译文当成正在唱的那一句：
    /// 原文反而是灰的。唱的是第一行。
    @Test("同一时间戳的多行高亮落在第一行")
    func picksTheFirstRowOfATimestampCluster() {
        let lyrics = [
            LyricLine(id: "source", timestamp: 12, text: "두고 봐 Babe"),
            LyricLine(id: "roman", timestamp: 12, text: "du go bwa Babe"),
            LyricLine(id: "translation", timestamp: 12, text: "走着瞧吧 宝贝"),
            LyricLine(id: "next", timestamp: 20, text: "Next"),
        ]

        #expect(LyricPlaybackPositionPolicy.activeLineIndex(in: lyrics, at: 15) == 0)
        #expect(LyricPlaybackPositionPolicy.scrollTarget(in: lyrics, at: 15) == .line(0))
        #expect(LyricPlaybackPositionPolicy.activeLineIndex(in: lyrics, at: 21) == 3)
    }

    /// 同一时间戳上的兄弟行不是「下一句」：拿它们当下一句，每一段间奏的时长
    /// 都会算成 0，间奏标记就永远不出现。
    @Test("间奏判定跳过同一时间戳的兄弟行")
    func interludeLooksPastSiblingRows() {
        let lyrics = [
            LyricLine(id: "source", timestamp: 0, text: "First"),
            LyricLine(id: "translation", timestamp: 0, text: "第一句"),
            LyricLine(id: "next", timestamp: 40, text: "Second"),
        ]

        #expect(LyricPlaybackPositionPolicy.hasLongInterlude(afterLine: 0, in: lyrics))
        #expect(LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: 26
        ) == .interlude(afterLine: 0))
    }

    @Test("Now Playing metadata uses the active synchronized lyric")
    func nowPlayingMetadataUsesActiveLyric() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 0, text: "First", isSynchronized: true),
            LyricLine(id: "second", timestamp: 12, text: "Second", isSynchronized: true),
        ]

        let presentation = NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: "Song",
            artistName: "Artist",
            lyrics: lyrics,
            playbackTime: 15,
            isEnabled: true,
            isLiveStream: false
        )

        #expect(presentation.title == "Second")
        #expect(presentation.artist == "Song · Artist")
        #expect(presentation.lyricLineID == "second")
    }

    @Test("Now Playing metadata advances one synchronized lyric at a time")
    func nowPlayingMetadataAdvancesWithPlayback() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 0, text: "First", isSynchronized: true),
            LyricLine(id: "second", timestamp: 12, text: "Second", isSynchronized: true),
        ]

        let first = NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: "Song",
            artistName: "Artist",
            lyrics: lyrics,
            playbackTime: 3,
            isEnabled: true,
            isLiveStream: false
        )
        let second = NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: "Song",
            artistName: "Artist",
            lyrics: lyrics,
            playbackTime: 15,
            isEnabled: true,
            isLiveStream: false
        )

        #expect(first.title == "First")
        #expect(first.lyricLineID == "first")
        #expect(second.title == "Second")
        #expect(second.lyricLineID == "second")
    }

    @Test("CarPlay keeps the title stable across lyric changes and seeks")
    func carPlayLyricsAdvanceInSubtitle() {
        let lyrics = [
            LyricLine(id: "first", timestamp: 8, text: "First", isSynchronized: true),
            LyricLine(id: "second", timestamp: 12, text: "Second", isSynchronized: true),
        ]
        let presentations = [3.0, 9, 15, 9].map { time in
            NowPlayingLyricsMetadataPolicy.presentation(
                canonicalTitle: "Song",
                artistName: "Artist",
                lyrics: lyrics,
                playbackTime: time,
                isEnabled: true,
                isLiveStream: false,
                prefersStableTitle: true
            )
        }

        #expect(presentations.map(\.title) == ["Song", "Song", "Song", "Song"])
        #expect(presentations.map(\.artist) == ["Artist", "First", "Second", "First"])
        #expect(presentations.map(\.lyricLineID) == [nil, "first", "second", "first"])
    }

    @Test("Connecting and disconnecting CarPlay changes layout without changing the lyric")
    func carPlayConnectionChangesLyricsLayout() {
        let lyrics = [LyricLine(id: "line", timestamp: 0, text: "Lyric", isSynchronized: true)]
        let presentations = [false, true, false].map { connected in
            NowPlayingLyricsMetadataPolicy.presentation(
                canonicalTitle: "Song",
                artistName: "Artist",
                lyrics: lyrics,
                playbackTime: 10,
                isEnabled: true,
                isLiveStream: false,
                prefersStableTitle: connected
            )
        }

        #expect(presentations.map(\.title) == ["Lyric", "Song", "Lyric"])
        #expect(presentations.map(\.artist) == ["Song · Artist", "Lyric", "Song · Artist"])
        #expect(presentations.allSatisfy { $0.lyricLineID == "line" })
    }

    @Test("Now Playing metadata keeps the song title before the first lyric", arguments: [false, true])
    func nowPlayingMetadataWaitsForFirstLyric(prefersStableTitle: Bool) {
        let lyrics = [
            LyricLine(id: "first", timestamp: 8, text: "First", isSynchronized: true),
        ]

        let presentation = NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: "Song",
            artistName: "Artist",
            lyrics: lyrics,
            playbackTime: 3,
            isEnabled: true,
            isLiveStream: false,
            prefersStableTitle: prefersStableTitle
        )

        #expect(presentation.title == "Song")
        #expect(presentation.artist == "Artist")
        #expect(presentation.lyricLineID == nil)
    }

    @Test("Disabled, live and plain lyrics preserve canonical Now Playing metadata", arguments: [false, true])
    func unsupportedNowPlayingLyricsPreserveCanonicalMetadata(prefersStableTitle: Bool) {
        let synchronized = [
            LyricLine(id: "line", timestamp: 0, text: "Lyric", isSynchronized: true),
        ]
        let plain = [
            LyricLine(id: "plain", timestamp: 0, text: "Plain", isSynchronized: false),
        ]

        for presentation in [
            NowPlayingLyricsMetadataPolicy.presentation(
                canonicalTitle: "Song",
                artistName: "Artist",
                lyrics: synchronized,
                playbackTime: 10,
                isEnabled: false,
                isLiveStream: false,
                prefersStableTitle: prefersStableTitle
            ),
            NowPlayingLyricsMetadataPolicy.presentation(
                canonicalTitle: "Song",
                artistName: "Artist",
                lyrics: synchronized,
                playbackTime: 10,
                isEnabled: true,
                isLiveStream: true,
                prefersStableTitle: prefersStableTitle
            ),
            NowPlayingLyricsMetadataPolicy.presentation(
                canonicalTitle: "Song",
                artistName: "Artist",
                lyrics: plain,
                playbackTime: 10,
                isEnabled: true,
                isLiveStream: false,
                prefersStableTitle: prefersStableTitle
            ),
        ] {
            #expect(presentation.title == "Song")
            #expect(presentation.artist == "Artist")
            #expect(presentation.lyricLineID == nil)
        }
    }

    @Test("Missing lyrics preserve canonical Now Playing metadata", arguments: [false, true])
    func missingNowPlayingLyricsPreserveCanonicalMetadata(prefersStableTitle: Bool) {
        let presentation = NowPlayingLyricsMetadataPolicy.presentation(
            canonicalTitle: "Song",
            artistName: "Artist",
            lyrics: [],
            playbackTime: 10,
            isEnabled: true,
            isLiveStream: false,
            prefersStableTitle: prefersStableTitle
        )

        #expect(presentation.title == "Song")
        #expect(presentation.artist == "Artist")
        #expect(presentation.lyricLineID == nil)
    }

    @Test("Empty system lyrics retry transient failures with a bounded backoff")
    func emptySystemLyricsUseBoundedRetry() {
        #expect(NowPlayingLyricsLoadRetryPolicy.delay(
            afterEmptyResultCount: 1,
            hasDemand: true,
            isLiveStream: false
        ) == 2)
        #expect(NowPlayingLyricsLoadRetryPolicy.delay(
            afterEmptyResultCount: 2,
            hasDemand: true,
            isLiveStream: false
        ) == 10)
        #expect(NowPlayingLyricsLoadRetryPolicy.delay(
            afterEmptyResultCount: 3,
            hasDemand: true,
            isLiveStream: false
        ) == nil)
    }

    @Test("System lyrics do not retry without demand or for live streams")
    func unsupportedSystemLyricsDoNotRetry() {
        #expect(NowPlayingLyricsLoadRetryPolicy.delay(
            afterEmptyResultCount: 1,
            hasDemand: false,
            isLiveStream: false
        ) == nil)
        #expect(NowPlayingLyricsLoadRetryPolicy.delay(
            afterEmptyResultCount: 1,
            hasDemand: true,
            isLiveStream: true
        ) == nil)
    }

    @Test func interludeProgressFollowsTheTimeline() {
        // 第一句 10 秒开始(估计 3.5 秒唱完),下一句 40 秒:间奏点 19.5 秒出现,40 秒走满。
        let lyrics = [
            LyricLine(timestamp: 10, text: "Before"),
            LyricLine(timestamp: 40, text: "After"),
        ]
        #expect(LyricPlaybackPositionPolicy.interludeProgress(afterLine: 1, in: lyrics, at: 30) == nil)
        #expect(LyricPlaybackPositionPolicy.interludeProgress(afterLine: 0, in: lyrics, at: 15) == 0)
        let middle = LyricPlaybackPositionPolicy.interludeProgress(afterLine: 0, in: lyrics, at: 29.75)
        #expect(middle.map { abs($0 - 0.5) < 0.001 } == true)
        #expect(LyricPlaybackPositionPolicy.interludeProgress(afterLine: 0, in: lyrics, at: 45) == 1)
        // 和滚动用的是同一个时间窗。
        #expect(LyricPlaybackPositionPolicy.scrollTarget(in: lyrics, at: 19.4) == .line(0))
        #expect(LyricPlaybackPositionPolicy.scrollTarget(in: lyrics, at: 19.6) == .interlude(afterLine: 0))
    }

    @Test func interludeDotsLightUpInTurn() {
        #expect(LyricPlaybackPositionPolicy.interludeDotLevels(progress: 0) == [0, 0, 0])
        #expect(LyricPlaybackPositionPolicy.interludeDotLevels(progress: 0.5) == [1, 0.5, 0])
        #expect(LyricPlaybackPositionPolicy.interludeDotLevels(progress: 1) == [1, 1, 1])
        #expect(LyricPlaybackPositionPolicy.interludeDotLevels(progress: .nan) == [0, 0, 0])
    }
}

@Suite("Now Playing lyric preview line")
struct NowPlayingLyricPreviewPolicyTests {
    private let lyrics = [
        LyricLine(id: "a", timestamp: 20, text: "First"),
        LyricLine(id: "b", timestamp: 24, text: "Second"),
        LyricLine(id: "gap", timestamp: 28, text: ""),
        LyricLine(id: "c", timestamp: 40, text: "Third"),
    ]

    @Test("前奏里不提前露出第一句,而是轮换提示")
    func introShowsMessagesInsteadOfTheFirstLine() {
        let start = NowPlayingLyricPreviewPolicy.resolve(in: lyrics, at: 0)
        #expect(start.display == .intro(.starting))
        #expect(start.nextChange == NowPlayingLyricPreviewPolicy.introMessageInterval)
        let late = NowPlayingLyricPreviewPolicy.resolve(in: lyrics, at: 18)
        #expect(late.display == .intro(.vocalsIncoming))
        let messages = stride(from: 0.0, to: 19, by: 0.5).map {
            NowPlayingLyricPreviewPolicy.resolve(in: lyrics, at: $0).display
        }
        #expect(!messages.contains(.line(0)))
    }

    @Test("开唱前切成心跳点,开唱那一刻换成第一句")
    func anticipationThenFirstLine() {
        let beforeVocals = NowPlayingLyricPreviewPolicy.resolve(in: lyrics, at: 19.5)
        guard case .anticipation(let window) = beforeVocals.display else {
            Issue.record("expected anticipation, got \(beforeVocals.display)")
            return
        }
        #expect(window.nextLineStart == 20)
        #expect(beforeVocals.nextChange == 20)
        #expect(NowPlayingLyricPreviewPolicy.resolve(in: lyrics, at: 20).display == .line(0))
    }

    @Test("唱的时候只放当前这一句")
    func singingShowsOnlyTheCurrentLine() {
        let resolution = NowPlayingLyricPreviewPolicy.resolve(in: lyrics, at: 22)
        #expect(resolution.display == .line(0))
        #expect(resolution.nextChange == 24)
    }

    @Test("间奏里显示间奏标签,不留上一句也不提前放下一句")
    func instrumentalBreakShowsTheLabel() {
        #expect(NowPlayingLyricPreviewPolicy.resolve(in: lyrics, at: 28.2).display == .empty)
        let label = NowPlayingLyricPreviewPolicy.resolve(in: lyrics, at: 30)
        #expect(label.display == .instrumental)
        #expect(abs((label.nextChange ?? 0) - 39.2) < 0.0001)
        if case .anticipation = NowPlayingLyricPreviewPolicy.resolve(in: lyrics, at: 39.5).display {
        } else {
            Issue.record("expected anticipation before the third line")
        }
        #expect(NowPlayingLyricPreviewPolicy.resolve(in: lyrics, at: 40).display == .line(3))
    }

    @Test("关掉间奏提示:前奏空着,间奏停在空行上也空着")
    func interludesOff() {
        #expect(NowPlayingLyricPreviewPolicy.resolve(in: lyrics, at: 5, showsInterludes: false).display == .empty)
        #expect(NowPlayingLyricPreviewPolicy.resolve(in: lyrics, at: 30, showsInterludes: false).display == .empty)
        #expect(NowPlayingLyricPreviewPolicy.resolve(in: lyrics, at: 22, showsInterludes: false).display == .line(0))
    }

    @Test("提前量让换行与心跳都提前同样多")
    func lookaheadShiftsBoundaries() {
        let resolution = NowPlayingLyricPreviewPolicy.resolve(in: lyrics, at: 23.8, lookahead: 0.25)
        #expect(resolution.display == .line(1))
    }

    @Test("没有时间轴的歌词什么都不放")
    func unsynchronizedLyricsStayEmpty() {
        let plain = [LyricLine(timestamp: 0, text: "Plain", isSynchronized: false)]
        #expect(NowPlayingLyricPreviewPolicy.resolve(in: plain, at: 3).display == .empty)
    }

    @Test("前奏提示的顺序:第一条与最后一条固定,倒数第二条是「快到了」")
    func introMessageOrder() {
        let interval = NowPlayingLyricPreviewPolicy.introMessageInterval
        let span = interval * 5
        let order = (0..<5).map {
            NowPlayingLyricPreviewPolicy.introMessage(elapsed: Double($0) * interval + 0.1, span: span).message
        }
        #expect(order == [.starting, .settingTheMood, .musicTakesOver, .almostThere, .vocalsIncoming])
        #expect(NowPlayingLyricPreviewPolicy.introMessage(elapsed: 1, span: interval * 1.5).message == .starting)
        let short = NowPlayingLyricPreviewPolicy.introMessage(elapsed: interval + 0.5, span: interval * 2.5)
        #expect(short.message == .vocalsIncoming)
        #expect(short.end == interval * 2.5)
    }

    private func rows(at time: Double, count: Int) -> [NowPlayingLyricPreviewPolicy.Row] {
        let display = NowPlayingLyricPreviewPolicy.resolve(in: lyrics, at: time).display
        return NowPlayingLyricPreviewPolicy.rows(for: display, in: lyrics, at: time, rowCount: count)
    }

    @Test("一行时和单行显示一样:正在唱的那句,或提示那一格")
    func singleRowMatchesTheSingleLine() {
        #expect(rows(at: 22, count: 1) == [.line(0, .current)])
        #expect(rows(at: 5, count: 1) == [.status])
        #expect(rows(at: 30, count: 1) == [.status])
    }

    @Test("两行:正在唱的在第一格,下面是下一句,跳过空行")
    func twoRowsShowTheNextLine() {
        #expect(rows(at: 22, count: 2) == [.line(0, .current), .line(1, .upcoming)])
        #expect(rows(at: 25, count: 2) == [.line(1, .current), .line(3, .upcoming)])
        #expect(rows(at: 5, count: 2) == [.status, .line(0, .upcoming)])
    }

    @Test("三行起上面留一句唱过的;前面没有句子时空着,后面不够时补空格")
    func threeRowsKeepOneSungLineAbove() {
        #expect(NowPlayingLyricPreviewPolicy.anchorRow(rowCount: 3) == 1)
        #expect(NowPlayingLyricPreviewPolicy.anchorRow(rowCount: 7) == 2)
        #expect(rows(at: 22, count: 3) == [.blank, .line(0, .current), .line(1, .upcoming)])
        #expect(rows(at: 25, count: 3) == [.line(0, .past), .line(1, .current), .line(3, .upcoming)])
        #expect(rows(at: 41, count: 3) == [.line(1, .past), .line(3, .current), .blank])
    }

    @Test("间奏里提示那一格夹在唱过的和接下来的中间")
    func interludeKeepsContextAroundTheStatus() {
        #expect(rows(at: 30, count: 3) == [.line(1, .past), .status, .line(3, .upcoming)])
        #expect(rows(at: 39.5, count: 4) == [.line(1, .past), .status, .line(3, .upcoming), .blank])
    }

    @Test("同一个时间戳的几行一起算正在唱")
    func sameTimestampGroupIsCurrent() {
        let grouped = [
            LyricLine(id: "a", timestamp: 1, text: "Source"),
            LyricLine(id: "b", timestamp: 1, text: "Companion"),
            LyricLine(id: "c", timestamp: 5, text: "Next"),
        ]
        let display = NowPlayingLyricPreviewPolicy.resolve(in: grouped, at: 2).display
        #expect(display == .line(0))
        #expect(NowPlayingLyricPreviewPolicy.rows(for: display, in: grouped, at: 2, rowCount: 3)
            == [.blank, .line(0, .current), .line(1, .current)])
    }
}
