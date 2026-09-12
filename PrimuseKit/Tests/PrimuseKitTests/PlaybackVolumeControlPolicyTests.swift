import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playback volume control target")
struct PlaybackVolumeControlPolicyTests {

    @Test("电台音量始终由应用施加，与本地输出模式无关")
    func radioAlwaysUsesApplicationGain() {
        for hiFi in [true, false] {
            for controllable in [true, false] {
                #expect(PlaybackVolumeControlPolicy.target(
                    isLiveRadio: true,
                    isHighFidelityDirect: hiFi,
                    outputDeviceVolumeIsControllable: controllable
                ) == .applicationGain)
            }
        }
    }

    @Test("音效模式走应用增益")
    func effectsModeUsesApplicationGain() {
        #expect(PlaybackVolumeControlPolicy.target(
            isLiveRadio: false,
            isHighFidelityDirect: false,
            outputDeviceVolumeIsControllable: false
        ) == .applicationGain)
    }

    @Test("高保真直通改由输出设备硬件音量承担")
    func highFidelityUsesOutputDevice() {
        #expect(PlaybackVolumeControlPolicy.target(
            isLiveRadio: false,
            isHighFidelityDirect: true,
            outputDeviceVolumeIsControllable: true
        ) == .outputDevice)
    }

    @Test("设备不给调硬件音量时才禁用")
    func highFidelityWithoutDeviceVolumeIsUnavailable() {
        let target = PlaybackVolumeControlPolicy.target(
            isLiveRadio: false,
            isHighFidelityDirect: true,
            outputDeviceVolumeIsControllable: false
        )
        #expect(target == .unavailable)
        #expect(!target.isAdjustable)
    }

    @Test("可调状态")
    func adjustability() {
        #expect(PlaybackVolumeControlTarget.applicationGain.isAdjustable)
        #expect(PlaybackVolumeControlTarget.outputDevice.isAdjustable)
        #expect(!PlaybackVolumeControlTarget.unavailable.isAdjustable)
    }

    @Test("显示值来源随目标切换")
    func displayValueFollowsTarget() {
        #expect(PlaybackVolumeControlPolicy.displayValue(
            target: .applicationGain, userVolume: 0.4, deviceVolume: 0.9
        ) == 0.4)
        #expect(PlaybackVolumeControlPolicy.displayValue(
            target: .outputDevice, userVolume: 0.4, deviceVolume: 0.9
        ) == 0.9)
        // 高保真直通不衰减，显示满格才诚实
        #expect(PlaybackVolumeControlPolicy.displayValue(
            target: .unavailable, userVolume: 0.4, deviceVolume: nil
        ) == 1)
    }

    @Test("设备音量还没读到时先用用户音量占位，不从零跳变")
    func deviceVolumeFallsBackBeforeFirstRead() {
        #expect(PlaybackVolumeControlPolicy.displayValue(
            target: .outputDevice, userVolume: 0.35, deviceVolume: nil
        ) == 0.35)
    }

    @Test("越界与非有限值被夹紧")
    func clampsOutOfRangeValues() {
        #expect(PlaybackVolumeControlPolicy.displayValue(
            target: .applicationGain, userVolume: 1.8, deviceVolume: nil
        ) == 1)
        #expect(PlaybackVolumeControlPolicy.displayValue(
            target: .applicationGain, userVolume: -0.5, deviceVolume: nil
        ) == 0)
        #expect(PlaybackVolumeControlPolicy.displayValue(
            target: .outputDevice, userVolume: 0.5, deviceVolume: .nan
        ) == 0)
    }

    @Test("图标读数与滑块同源")
    func indicatorMatchesSlider() {
        for target in [PlaybackVolumeControlTarget.applicationGain, .outputDevice, .unavailable] {
            #expect(PlaybackVolumeControlPolicy.indicatorValue(
                target: target, userVolume: 0.25, deviceVolume: 0.75
            ) == PlaybackVolumeControlPolicy.displayValue(
                target: target, userVolume: 0.25, deviceVolume: 0.75
            ))
        }
    }
}
