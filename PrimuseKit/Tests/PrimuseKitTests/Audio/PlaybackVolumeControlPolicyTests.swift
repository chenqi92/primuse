import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playback volume control target")
struct PlaybackVolumeControlPolicyTests {

    @Test("电台音量始终由应用施加，与本地播放图能不能加增益无关")
    func radioAlwaysUsesApplicationGain() {
        for gainAvailable in [true, false] {
            #expect(PlaybackVolumeControlPolicy.target(
                isLiveRadio: true,
                applicationGainIsAvailable: gainAvailable
            ) == .applicationGain)
        }
    }

    @Test("本地播放能加增益时走应用音量")
    func localPlaybackUsesApplicationGain() {
        #expect(PlaybackVolumeControlPolicy.target(
            isLiveRadio: false,
            applicationGainIsAvailable: true
        ) == .applicationGain)
    }

    @Test("DoP/DSD 直通加不了增益，控件禁用")
    func directDSDStreamIsUnavailable() {
        #expect(PlaybackVolumeControlPolicy.target(
            isLiveRadio: false,
            applicationGainIsAvailable: false
        ) == .unavailable)
    }

    @Test("投屏时声音在远端出，音量走应用侧发给渲染器")
    func castingUsesApplicationGain() {
        for gainAvailable in [true, false] {
            #expect(PlaybackVolumeControlPolicy.target(
                isLiveRadio: false,
                isCastingToRemoteRenderer: true,
                isSystemManagedPlayback: false,
                applicationGainIsAvailable: gainAvailable
            ) == .applicationGain)
        }
    }

    @Test("系统播放器负责发声时应用没有增益节点，控件禁用而不是假装能调")
    func systemManagedPlaybackIsUnavailable() {
        for gainAvailable in [true, false] {
            #expect(PlaybackVolumeControlPolicy.target(
                isLiveRadio: false,
                isCastingToRemoteRenderer: false,
                isSystemManagedPlayback: true,
                applicationGainIsAvailable: gainAvailable
            ) == .unavailable)
        }
    }

    @Test("投屏优先于系统播放器判定 —— 投屏目标自己有音量")
    func castingWinsOverSystemManagedPlayback() {
        #expect(PlaybackVolumeControlPolicy.target(
            isLiveRadio: false,
            isCastingToRemoteRenderer: true,
            isSystemManagedPlayback: true,
            applicationGainIsAvailable: false
        ) == .applicationGain)
    }

    @Test("可调状态")
    func adjustability() {
        #expect(PlaybackVolumeControlTarget.applicationGain.isAdjustable)
        #expect(!PlaybackVolumeControlTarget.unavailable.isAdjustable)
    }

    @Test("显示值来源随目标切换")
    func displayValueFollowsTarget() {
        #expect(PlaybackVolumeControlPolicy.displayValue(
            target: .applicationGain, userVolume: 0.4
        ) == 0.4)
        // 应用没有衰减时显示满格才诚实
        #expect(PlaybackVolumeControlPolicy.displayValue(
            target: .unavailable, userVolume: 0.4
        ) == 1)
    }

    @Test("越界与非有限值被夹紧")
    func clampsOutOfRangeValues() {
        #expect(PlaybackVolumeControlPolicy.displayValue(
            target: .applicationGain, userVolume: 1.8
        ) == 1)
        #expect(PlaybackVolumeControlPolicy.displayValue(
            target: .applicationGain, userVolume: -0.5
        ) == 0)
        #expect(PlaybackVolumeControlPolicy.displayValue(
            target: .applicationGain, userVolume: .nan
        ) == 0)
    }

    @Test("图标读数与滑块同源")
    func indicatorMatchesSlider() {
        for target in [PlaybackVolumeControlTarget.applicationGain, .unavailable] {
            #expect(PlaybackVolumeControlPolicy.indicatorValue(
                target: target, userVolume: 0.25
            ) == PlaybackVolumeControlPolicy.displayValue(
                target: target, userVolume: 0.25
            ))
        }
    }
}
