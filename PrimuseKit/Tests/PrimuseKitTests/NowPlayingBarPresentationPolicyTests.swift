import Foundation
import Testing
@testable import PrimuseKit

@Suite("正在播放那一条的取值")
struct NowPlayingBarPresentationPolicyTests {
    @Test("第二行:出错原因优先,其次艺术家,空艺术家不写")
    func subtitleOrder() {
        #expect(NowPlayingBarPresentationPolicy.subtitle(playbackError: "无法连接", artistName: "Nova") == .error("无法连接"))
        #expect(NowPlayingBarPresentationPolicy.subtitle(playbackError: nil, artistName: "Nova") == .artist("Nova"))
        #expect(NowPlayingBarPresentationPolicy.subtitle(playbackError: nil, artistName: "") == nil)
        #expect(NowPlayingBarPresentationPolicy.subtitle(playbackError: nil, artistName: nil) == nil)
        // 出错时即使原因是空串也占住第二行,不退回艺术家 —— 与播放条原来的写法一致。
        #expect(NowPlayingBarPresentationPolicy.subtitle(playbackError: "", artistName: "Nova") == .error(""))
    }

    @Test("朗读标签按「正在播放: 歌名: 第二行」拼,空的部分略过")
    func accessibilityLabel() {
        #expect(
            NowPlayingBarPresentationPolicy.accessibilityLabel(
                nowPlaying: "正在播放",
                title: "Evidence",
                subtitle: .artist("Nova Harbor")
            ) == "正在播放: Evidence: Nova Harbor"
        )
        #expect(
            NowPlayingBarPresentationPolicy.accessibilityLabel(
                nowPlaying: "正在播放",
                title: "Evidence",
                subtitle: nil
            ) == "正在播放: Evidence"
        )
        #expect(
            NowPlayingBarPresentationPolicy.accessibilityLabel(
                nowPlaying: "正在播放",
                title: "",
                subtitle: .error("")
            ) == "正在播放"
        )
    }

    @Test("进度:夹在 0...1 之间;直播、时长未知或时刻无效时是 0")
    func progress() {
        #expect(NowPlayingBarPresentationPolicy.progress(elapsed: 15, duration: 30, isLiveRadio: false) == 0.5)
        #expect(NowPlayingBarPresentationPolicy.progress(elapsed: 45, duration: 30, isLiveRadio: false) == 1)
        #expect(NowPlayingBarPresentationPolicy.progress(elapsed: -3, duration: 30, isLiveRadio: false) == 0)
        #expect(NowPlayingBarPresentationPolicy.progress(elapsed: 15, duration: 30, isLiveRadio: true) == 0)
        #expect(NowPlayingBarPresentationPolicy.progress(elapsed: 15, duration: 0, isLiveRadio: false) == 0)
        #expect(NowPlayingBarPresentationPolicy.progress(elapsed: 15, duration: .infinity, isLiveRadio: false) == 0)
        #expect(NowPlayingBarPresentationPolicy.progress(elapsed: 15, duration: .nan, isLiveRadio: false) == 0)
        #expect(NowPlayingBarPresentationPolicy.progress(elapsed: .nan, duration: 30, isLiveRadio: false) == 0)
        #expect(NowPlayingBarPresentationPolicy.duration(-1) == 0)
        #expect(NowPlayingBarPresentationPolicy.duration(180) == 180)
    }

    @Test("只有往前走一秒以内才算时钟推进;换歌、倒退、跳转都硬跳")
    func clockAdvance() {
        // 30 秒的歌,半秒一采样。
        #expect(NowPlayingBarPresentationPolicy.isClockAdvance(from: 10.0 / 30, to: 10.5 / 30, duration: 30))
        #expect(NowPlayingBarPresentationPolicy.isClockAdvance(from: 10.0 / 30, to: 10.9 / 30, duration: 30))
        #expect(!NowPlayingBarPresentationPolicy.isClockAdvance(from: 10.0 / 30, to: 12.0 / 30, duration: 30))
        #expect(!NowPlayingBarPresentationPolicy.isClockAdvance(from: 0.8, to: 0, duration: 30))
        #expect(!NowPlayingBarPresentationPolicy.isClockAdvance(from: 0.4, to: 0.4, duration: 30))
        #expect(!NowPlayingBarPresentationPolicy.isClockAdvance(from: 0.1, to: 0.11, duration: 0))
    }
}
