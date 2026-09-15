import Foundation
import Testing
@testable import PrimuseKit

@Suite("投放渲染器传输状态")
struct RemoteRendererTransportPolicyTests {
    @Test("规范状态按原样解析")
    func parsesSpecifiedStates() {
        #expect(RemoteRendererTransportState(reported: "PLAYING") == .playing)
        #expect(RemoteRendererTransportState(reported: "STOPPED") == .stopped)
        #expect(RemoteRendererTransportState(reported: "PAUSED_PLAYBACK") == .paused)
        #expect(RemoteRendererTransportState(reported: "TRANSITIONING") == .transitioning)
        #expect(RemoteRendererTransportState(reported: "NO_MEDIA_PRESENT") == .noMediaPresent)
    }

    @Test("大小写、空白与简写都能认出来")
    func toleratesFirmwareSpelling() {
        #expect(RemoteRendererTransportState(reported: " playing\n") == .playing)
        #expect(RemoteRendererTransportState(reported: "Paused") == .paused)
        #expect(RemoteRendererTransportState(reported: "paused_playback") == .paused)
        #expect(RemoteRendererTransportState(reported: nil) == .unknown)
        #expect(RemoteRendererTransportState(reported: "") == .unknown)
        #expect(RemoteRendererTransportState(reported: "CUSTOM_STATE") == .unknown)
    }

    @Test("只有已经停住的设备可以直接装新曲目")
    func onlyStoppedRenderersSkipStop() {
        #expect(!RemoteRendererTransportPolicy.requiresStopBeforeLoading(.stopped))
        #expect(!RemoteRendererTransportPolicy.requiresStopBeforeLoading(.noMediaPresent))
        #expect(RemoteRendererTransportPolicy.requiresStopBeforeLoading(.playing))
        #expect(RemoteRendererTransportPolicy.requiresStopBeforeLoading(.paused))
        #expect(RemoteRendererTransportPolicy.requiresStopBeforeLoading(.transitioning))
    }

    @Test("状态不明时宁可多发一条 Stop")
    func unknownStateStopsFirst() {
        #expect(RemoteRendererTransportPolicy.requiresStopBeforeLoading(.unknown))
    }

    @Test("缓冲中仍算在播, 状态不认识就不动界面")
    func transitioningCountsAsPlaying() {
        #expect(RemoteRendererTransportPolicy.isRenderingAudio(.playing) == true)
        #expect(RemoteRendererTransportPolicy.isRenderingAudio(.transitioning) == true)
        #expect(RemoteRendererTransportPolicy.isRenderingAudio(.paused) == false)
        #expect(RemoteRendererTransportPolicy.isRenderingAudio(.stopped) == false)
        #expect(RemoteRendererTransportPolicy.isRenderingAudio(.noMediaPresent) == false)
        #expect(RemoteRendererTransportPolicy.isRenderingAudio(.unknown) == nil)
    }

    @Test("停在曲末算播完, 接下一首")
    func stopAtEndAdvances() {
        #expect(RemoteRendererTransportPolicy.shouldAdvanceAfterTrackEnd(
            state: .stopped,
            hasObservedPlayback: true,
            lastKnownTime: 208,
            knownDuration: 210
        ))
        #expect(RemoteRendererTransportPolicy.shouldAdvanceAfterTrackEnd(
            state: .noMediaPresent,
            hasObservedPlayback: true,
            lastKnownTime: 210,
            knownDuration: 210
        ))
    }

    @Test("停在中间是用户或设备停的, 不接下一首")
    func stopMidTrackKeepsQueue() {
        #expect(!RemoteRendererTransportPolicy.shouldAdvanceAfterTrackEnd(
            state: .stopped,
            hasObservedPlayback: true,
            lastKnownTime: 40,
            knownDuration: 210
        ))
    }

    @Test("没看到它播过就不算播完")
    func neverPlayedDoesNotAdvance() {
        // 刚 SetAVTransportURI 还没起播时设备就回 STOPPED, 不能当成曲末。
        #expect(!RemoteRendererTransportPolicy.shouldAdvanceAfterTrackEnd(
            state: .stopped,
            hasObservedPlayback: false,
            lastKnownTime: 0,
            knownDuration: 210
        ))
    }

    @Test("还在播 / 暂停的设备不触发切歌")
    func activeTransportDoesNotAdvance() {
        for state: RemoteRendererTransportState in [.playing, .paused, .transitioning, .unknown] {
            #expect(!RemoteRendererTransportPolicy.shouldAdvanceAfterTrackEnd(
                state: state,
                hasObservedPlayback: true,
                lastKnownTime: 210,
                knownDuration: 210
            ))
        }
    }

    @Test("时长不可信时不猜曲末")
    func unusableDurationDoesNotAdvance() {
        #expect(!RemoteRendererTransportPolicy.shouldAdvanceAfterTrackEnd(
            state: .stopped,
            hasObservedPlayback: true,
            lastKnownTime: 100,
            knownDuration: 0
        ))
        #expect(!RemoteRendererTransportPolicy.shouldAdvanceAfterTrackEnd(
            state: .stopped,
            hasObservedPlayback: true,
            lastKnownTime: 100,
            knownDuration: .nan
        ))
        #expect(!RemoteRendererTransportPolicy.shouldAdvanceAfterTrackEnd(
            state: .stopped,
            hasObservedPlayback: true,
            lastKnownTime: .infinity,
            knownDuration: 210
        ))
    }

    @Test("回读到同一条 URI 就算装上了")
    func matchingURICountsAsLoaded() {
        let uri = "http://192.168.1.7:49160/ab12cd34/Track.mp3"
        #expect(RemoteRendererTransportPolicy.didLoadRequestedURI(reported: uri, requested: uri))
        #expect(RemoteRendererTransportPolicy.didLoadRequestedURI(
            reported: "HTTP://192.168.1.7:49160/ab12cd34/Track.mp3/",
            requested: uri
        ))
        #expect(RemoteRendererTransportPolicy.didLoadRequestedURI(
            reported: "http://192.168.1.7:49160/ab12cd34/%E6%AD%8C.mp3",
            requested: "http://192.168.1.7:49160/ab12cd34/歌.mp3"
        ))
    }

    @Test("回读到上一首的 URI 说明设备没换曲")
    func staleURIMeansNotLoaded() {
        #expect(!RemoteRendererTransportPolicy.didLoadRequestedURI(
            reported: "http://192.168.1.7:49160/0000aaaa/Previous.mp3",
            requested: "http://192.168.1.7:49160/ab12cd34/Track.mp3"
        ))
    }

    @Test("读不到 CurrentURI 不下失败结论")
    func unreadableURIIsNotAFailure() {
        let uri = "http://192.168.1.7:49160/ab12cd34/Track.mp3"
        #expect(RemoteRendererTransportPolicy.didLoadRequestedURI(reported: nil, requested: uri))
        #expect(RemoteRendererTransportPolicy.didLoadRequestedURI(reported: "", requested: uri))
        #expect(RemoteRendererTransportPolicy.didLoadRequestedURI(reported: "   ", requested: uri))
    }
}
