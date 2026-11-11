import Foundation
import Testing
@testable import PrimuseKit

struct WidgetLyricsPresentationPolicyTests {
    private let lines = [
        WidgetLyricLine(time: 0, text: "zero"),
        WidgetLyricLine(time: 1, text: "one"),
        WidgetLyricLine(time: 2, text: "two"),
        WidgetLyricLine(time: 3, text: "three"),
    ]

    @Test func threeRowWindowClampsAnchorsAndMarksTheActualCurrentLine() {
        let beginning = WidgetLyricsPresentationPolicy.rows(
            in: lines,
            anchorIndex: -10,
            maximumRowCount: 3
        )
        #expect(beginning.map(\.index) == [0, 1, 2])
        #expect(beginning.map(\.role) == [.current, .next, .next])

        let end = WidgetLyricsPresentationPolicy.rows(
            in: lines,
            anchorIndex: 99,
            maximumRowCount: 3
        )
        #expect(end.map(\.index) == [1, 2, 3])
        #expect(end.map(\.role) == [.previous, .previous, .current])
    }

    @Test func reducedBudgetsAlwaysKeepTheCurrentLine() {
        let twoRows = WidgetLyricsPresentationPolicy.rows(
            in: lines,
            anchorIndex: 1,
            maximumRowCount: 2
        )
        #expect(twoRows.map(\.index) == [1, 2])
        #expect(twoRows.map(\.role) == [.current, .next])

        let oneRow = WidgetLyricsPresentationPolicy.rows(
            in: lines,
            anchorIndex: 2,
            maximumRowCount: 1
        )
        #expect(oneRow.map(\.index) == [2])
        #expect(oneRow.map(\.role) == [.current])
    }

    @Test func endOfSongUsesPreviousLineBeforeDroppingCurrentLine() {
        let rows = WidgetLyricsPresentationPolicy.rows(
            in: lines,
            anchorIndex: 3,
            maximumRowCount: 2
        )
        #expect(rows.map(\.index) == [2, 3])
        #expect(rows.map(\.role) == [.previous, .current])
    }

    @Test func timelinePositionUsesExactPlaybackAnchorAndLegacyFallback() {
        let exact = LyricsSnapshot(
            songID: "song",
            title: "title",
            artist: "artist",
            coverImageName: nil,
            lines: lines,
            anchorIndex: 1,
            playbackPosition: 1.75,
            isPlaying: true
        )
        #expect(WidgetLyricsPresentationPolicy.playbackPosition(in: exact) == 1.75)
        #expect(WidgetLyricsPresentationPolicy.anchorIndex(for: 2.4, in: lines) == 2)

        var legacy = exact
        legacy.playbackPosition = nil
        legacy.anchorIndex = 99
        #expect(WidgetLyricsPresentationPolicy.playbackPosition(in: legacy) == 3)
    }

    @Test func newerPlaybackSampleRealignsLyricsAndDifferentSongInvalidatesThem() throws {
        let lyricDate = Date(timeIntervalSinceReferenceDate: 100)
        let playbackDate = Date(timeIntervalSinceReferenceDate: 110)
        let snapshot = LyricsSnapshot(
            songID: "song",
            title: "title",
            artist: "artist",
            coverImageName: nil,
            lines: lines,
            anchorIndex: 1,
            playbackPosition: 1,
            isPlaying: true,
            updatedAt: lyricDate
        )
        let playback = PlaybackState(
            currentSongID: "song",
            isPlaying: false,
            currentTime: 2.75,
            duration: 10,
            updatedAt: playbackDate
        )

        let aligned = try #require(
            WidgetLyricsPresentationPolicy.snapshotAlignedWithPlayback(
                snapshot,
                playback: playback
            )
        )
        #expect(aligned.playbackPosition == 2.75)
        #expect(aligned.anchorIndex == 2)
        #expect(aligned.isPlaying == false)
        #expect(aligned.updatedAt == playbackDate)

        var olderPlayback = playback
        olderPlayback.updatedAt = lyricDate.addingTimeInterval(-1)
        let unchanged = try #require(
            WidgetLyricsPresentationPolicy.snapshotAlignedWithPlayback(
                snapshot,
                playback: olderPlayback
            )
        )
        #expect(unchanged.playbackPosition == snapshot.playbackPosition)
        #expect(unchanged.updatedAt == snapshot.updatedAt)

        var nextSong = playback
        nextSong.currentSongID = "next-song"
        #expect(
            WidgetLyricsPresentationPolicy.snapshotAlignedWithPlayback(
                snapshot,
                playback: nextSong
            ) == nil
        )

        var newerLyrics = snapshot
        newerLyrics.playbackPosition = 3.5
        newerLyrics.isPlaying = false
        newerLyrics.updatedAt = playbackDate.addingTimeInterval(1)
        let stateAlignedFromLyrics = try #require(
            WidgetLyricsPresentationPolicy.playbackStateAlignedWithLyrics(
                playback,
                lyrics: newerLyrics
            )
        )
        #expect(stateAlignedFromLyrics.currentTime == 3.5)
        #expect(stateAlignedFromLyrics.isPlaying == false)
        #expect(stateAlignedFromLyrics.updatedAt == newerLyrics.updatedAt)
    }

    @Test func lyricsSnapshotTakesTheCoverFromTheSameSongsPlaybackState() throws {
        // 歌词读完时封面还没写好（Mac 上播放状态在后台写；Apple Music 封面更晚到）。
        let lyricDate = Date(timeIntervalSinceReferenceDate: 100)
        let snapshot = LyricsSnapshot(
            songID: "song", title: "title", artist: "artist", coverImageName: nil,
            lines: lines, anchorIndex: 0, playbackPosition: 0, isPlaying: true, updatedAt: lyricDate
        )
        var playback = PlaybackState(
            currentSongID: "song", coverImageName: "widget_cover.png", isPlaying: true,
            currentTime: 0.5, duration: 10, updatedAt: lyricDate.addingTimeInterval(-5)
        )
        // 播放状态比歌词旧时位置不动，封面照样跟播放状态。
        let older = try #require(WidgetLyricsPresentationPolicy.snapshotAlignedWithPlayback(snapshot, playback: playback))
        #expect(older.coverImageName == "widget_cover.png")
        #expect(older.playbackPosition == 0)

        playback.updatedAt = lyricDate.addingTimeInterval(5)
        let newer = try #require(WidgetLyricsPresentationPolicy.snapshotAlignedWithPlayback(snapshot, playback: playback))
        #expect(newer.coverImageName == "widget_cover.png")

        // 这首没有封面（写不出或用户关了封面共享）：歌词小组件也不再挂旧封面。
        var stale = snapshot
        stale.coverImageName = "widget_cover.png"
        playback.coverImageName = nil
        let cleared = try #require(WidgetLyricsPresentationPolicy.snapshotAlignedWithPlayback(stale, playback: playback))
        #expect(cleared.coverImageName == nil)

        // 没有播放状态时保留歌词快照自己的那一份。
        #expect(WidgetLyricsPresentationPolicy.snapshotAlignedWithPlayback(stale, playback: nil)?.coverImageName == "widget_cover.png")
    }

    @Test func artworkRetryBacksOffAndGivesUp() {
        #expect(WidgetCoverPublishPolicy.retryDelay(afterFailures: 0) == 0)
        #expect(WidgetCoverPublishPolicy.retryDelay(afterFailures: 1) == 5)
        #expect(WidgetCoverPublishPolicy.retryDelay(afterFailures: 2) == 30)
        #expect(WidgetCoverPublishPolicy.retryDelay(afterFailures: 3) == 120)
        #expect(WidgetCoverPublishPolicy.retryDelay(afterFailures: 4) == nil)
    }

    @Test func staleWidgetRequestsAreDropped() {
        #expect(WidgetCoverPublishPolicy.accepts(sequence: 1, after: nil))
        #expect(WidgetCoverPublishPolicy.accepts(sequence: 5, after: 5))
        #expect(WidgetCoverPublishPolicy.accepts(sequence: 6, after: 5))
        #expect(!WidgetCoverPublishPolicy.accepts(sequence: 4, after: 5))
    }

    @Test func renderReceiptsKeepTheLatestPerWidgetKind() {
        func receipt(_ kind: String, _ song: String, at seconds: TimeInterval) -> WidgetRenderReceipt {
            WidgetRenderReceipt(kind: kind, songID: song, coverImageName: "widget_cover.png",
                                coverModifiedAt: nil, coverByteCount: nil,
                                renderedAt: Date(timeIntervalSinceReferenceDate: seconds))
        }
        var receipts = WidgetRenderReceipt.merging(receipt("Lyrics.systemMedium", "a", at: 1), into: [])
        receipts = WidgetRenderReceipt.merging(receipt("NowPlaying.systemSmall", "a", at: 2), into: receipts)
        receipts = WidgetRenderReceipt.merging(receipt("Lyrics.systemMedium", "b", at: 3), into: receipts)
        #expect(receipts.map(\.kind) == ["Lyrics.systemMedium", "NowPlaying.systemSmall"])
        #expect(receipts.first?.songID == "b")
        #expect(receipts.first?.logDescription.contains("song=b cover=widget_cover.png") == true)
    }

    @Test func singleRowFallbackPreservesTheCompletePersianLyric() throws {
        let text = "انتظار و انتظار تا وقتی بازی شروع نشده و تمام واژه‌ها باید دیده شوند"
        let rows = WidgetLyricsPresentationPolicy.rows(
            in: [WidgetLyricLine(time: 0, text: text)],
            anchorIndex: 0,
            maximumRowCount: 1
        )

        #expect(try #require(rows.first).text == text)
    }

    @Test func explicitDocumentDirectionWinsForTaggedMixedLyrics() {
        let mixed = [
            WidgetLyricLine(time: 0, text: "Tonight سلام دنیا"),
            WidgetLyricLine(time: 1, text: "Primuse 2026"),
        ]
        #expect(
            WidgetLyricsPresentationPolicy.writingDirection(
                for: mixed,
                preferredDirection: .rightToLeft
            ) == .rightToLeft
        )
        #expect(
            WidgetLyricsPresentationPolicy.writingDirection(
                for: mixed,
                preferredDirection: .leftToRight
            ) == .leftToRight
        )
    }

    @Test func legacySnapshotsInferPersianButLeaveBalancedMixedTextNatural() {
        let persian = [
            WidgetLyricLine(time: 0, text: "تو مرا جان و جهانی\nچه کنم جان و جهان را"),
            WidgetLyricLine(time: 1, text: "تو مرا گنج روانی چه کنم سود و زیان را"),
        ]
        #expect(
            WidgetLyricsPresentationPolicy.writingDirection(
                for: persian,
                preferredDirection: nil
            ) == .rightToLeft
        )

        let arabic = [WidgetLyricLine(time: 0, text: "ألا ليت الشباب يعود يوماً")]
        #expect(
            WidgetLyricsPresentationPolicy.writingDirection(
                for: arabic,
                preferredDirection: nil
            ) == .rightToLeft
        )

        let mixed = [WidgetLyricLine(time: 0, text: "Hello سلام")]
        #expect(
            WidgetLyricsPresentationPolicy.writingDirection(
                for: mixed,
                preferredDirection: nil
            ) == .natural
        )
    }

    @Test func legacySnapshotPayloadStillDecodesWithoutDirection() throws {
        let legacy = LegacyLyricsSnapshot(
            songID: "song",
            title: "title",
            artist: "artist",
            coverImageName: nil,
            lines: lines,
            anchorIndex: 1,
            isPlaying: true,
            updatedAt: Date(timeIntervalSinceReferenceDate: 42)
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(LyricsSnapshot.self, from: data)

        #expect(decoded.songID == legacy.songID)
        #expect(decoded.anchorIndex == legacy.anchorIndex)
        #expect(decoded.playbackPosition == nil)
        #expect(decoded.writingDirection == nil)
    }
}

private struct LegacyLyricsSnapshot: Codable {
    let songID: String
    let title: String
    let artist: String
    let coverImageName: String?
    let lines: [WidgetLyricLine]
    let anchorIndex: Int
    let isPlaying: Bool
    let updatedAt: Date
}
