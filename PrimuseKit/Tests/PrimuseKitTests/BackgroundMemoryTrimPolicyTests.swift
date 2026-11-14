import Testing
@testable import PrimuseKit

@Suite("Background memory trim policy")
struct BackgroundMemoryTrimPolicyTests {
    @Test("An idle app in the background gives its rebuildable caches back")
    func idleBackgroundTrims() {
        #expect(BackgroundMemoryTrimPolicy.shouldTrim(phase: .background, activity: .init()))
    }

    @Test("Nothing is released while the scene is still on screen")
    func foregroundNeverTrims() {
        #expect(!BackgroundMemoryTrimPolicy.shouldTrim(phase: .active, activity: .init()))
        // 控制中心、来电横幅、Face ID 都只到 inactive, 马上就回来。
        #expect(!BackgroundMemoryTrimPolicy.shouldTrim(phase: .inactive, activity: .init()))
    }

    @Test("Work that keeps running in the background keeps its caches")
    func backgroundWorkKeepsCaches() {
        let busy: [BackgroundMemoryTrimPolicy.Activity] = [
            .init(isPlaybackActive: true),
            .init(isScanning: true),
            .init(isImporting: true),
            .init(isTransferring: true),
            .init(isDownloadingForOffline: true),
            .init(isSeparatingKaraoke: true),
            .init(isCarPlayActive: true),
        ]
        for activity in busy {
            #expect(activity.keepsWorkingInBackground)
            #expect(!BackgroundMemoryTrimPolicy.shouldTrim(phase: .background, activity: activity))
        }
    }

    @Test("The settle delay leaves the scene transition alone but runs before suspension")
    func settleDelayIsShort() {
        #expect(BackgroundMemoryTrimPolicy.settleDelay > 0)
        // 没有别的后台断言时, 进程退到后台几秒内就会被挂起。
        #expect(BackgroundMemoryTrimPolicy.settleDelay < 5)
    }
}
