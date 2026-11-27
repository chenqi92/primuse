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

@Suite("Song model release policy")
struct SongModelReleasePolicyTests {
    private func inputs(
        enabled: Bool = true, background: Bool = true, settled: Bool = true,
        activity: BackgroundMemoryTrimPolicy.Activity = .init(), playbackBlocks: Bool = true
    ) -> SongModelReleasePolicy.Inputs {
        .init(residencyEnabled: enabled, isInBackground: background, sceneSettleFinished: settled,
              activity: activity, playbackBlocksRelease: playbackBlocks)
    }

    @Test("Released only when residency is on, the app is in the background, settled and idle")
    func everyConditionHolds() {
        #expect(SongModelReleasePolicy.refusal(inputs()) == nil)
        #expect(SongModelReleasePolicy.refusal(inputs(enabled: false)) == "residency is off")
        #expect(SongModelReleasePolicy.refusal(inputs(background: false)) == "not in the background")
        #expect(SongModelReleasePolicy.refusal(inputs(settled: false)) == "scene settle not finished")
    }

    @Test("With residency off nothing is ever released, whatever else holds")
    func residencyOffNeverReleases() {
        for background in [true, false] {
            for settled in [true, false] {
                for playbackBlocks in [true, false] {
                    for activity in [BackgroundMemoryTrimPolicy.Activity(), .init(isPlaybackActive: true)] {
                        let refusal = SongModelReleasePolicy.refusal(inputs(
                            enabled: false, background: background, settled: settled,
                            activity: activity, playbackBlocks: playbackBlocks
                        ))
                        #expect(refusal == "residency is off")
                    }
                }
            }
        }
    }

    @Test("Background work refuses by name; playback only while the switch says so")
    func backgroundWorkRefuses() {
        let busy: [(BackgroundMemoryTrimPolicy.Activity, String)] = [
            (.init(isScanning: true), "scanning"),
            (.init(isImporting: true), "importing"),
            (.init(isTransferring: true), "transferring"),
            (.init(isDownloadingForOffline: true), "offline download"),
            (.init(isSeparatingKaraoke: true), "karaoke separation"),
            (.init(isCarPlayActive: true), "CarPlay"),
        ]
        for (activity, name) in busy {
            #expect(SongModelReleasePolicy.refusal(inputs(activity: activity)) == name)
            #expect(SongModelReleasePolicy.refusal(inputs(activity: activity, playbackBlocks: false)) == name)
        }
        let playing = BackgroundMemoryTrimPolicy.Activity(isPlaybackActive: true)
        #expect(SongModelReleasePolicy.refusal(inputs(activity: playing)) == "playback")
        #expect(SongModelReleasePolicy.refusal(inputs(activity: playing, playbackBlocks: false)) == nil)
        // 放歌之外还有别的活儿:开关关着也照样拦。
        let playingAndScanning = BackgroundMemoryTrimPolicy.Activity(isPlaybackActive: true, isScanning: true)
        #expect(SongModelReleasePolicy.refusal(inputs(activity: playingAndScanning, playbackBlocks: false)) == "scanning")
    }

    @Test("The first attempt waits for the scene settle and still runs inside the background window")
    func backgroundDelayFitsTheWindow() {
        #expect(SongModelReleasePolicy.backgroundDelay > 2)
        #expect(SongModelReleasePolicy.backgroundDelay < 10)
    }
}

@Suite("Decoded image cache budget")
struct DecodedImageCacheBudgetTests {
    private let mebibyte = 1_024 * 1_024

    @Test("Foreground limits are the caches' original limits")
    func foregroundKeepsOriginalLimits() {
        #expect(DecodedImageCacheBudget.foregroundLimit(for: .artworkViews) == 64 * mebibyte)
        #expect(DecodedImageCacheBudget.foregroundLimit(for: .imageCache) == 50 * mebibyte)
        #expect(DecodedImageCacheBudget.foregroundLimit(for: .playerBackdrop) == 96 * mebibyte)
        #expect(DecodedImageCacheBudget.foregroundLimit(for: .playerBackdrop, isTV: true) == 32 * mebibyte)
        #expect(DecodedImageCacheBudget.foregroundLimit(for: .animatedArtwork) == 48 * mebibyte)
        #expect(DecodedImageCacheBudget.foregroundLimit(for: .scrapeReview) == 32 * mebibyte)
        for cache in DecodedImageCacheBudget.Cache.allCases {
            #expect(DecodedImageCacheBudget.limit(for: cache, inBackground: false, carPlayActive: true)
                == DecodedImageCacheBudget.foregroundLimit(for: cache))
        }
    }

    @Test("In the background every decoded image cache stays small, playing or not, within 8 MiB in total")
    func backgroundStaysSmall() {
        #expect(DecodedImageCacheBudget.backgroundTotal(carPlayActive: false) <= 8 * mebibyte)
        #expect(DecodedImageCacheBudget.backgroundTotal(carPlayActive: true) <= 16 * mebibyte)
        for cache in DecodedImageCacheBudget.Cache.allCases {
            let background = DecodedImageCacheBudget.limit(for: cache, inBackground: true, carPlayActive: false)
            // NSCache 把 0 当成「不限」:后台上限必须是正数。
            #expect(background > 0)
            #expect(background < DecodedImageCacheBudget.foregroundLimit(for: cache, isTV: true))
        }
    }

    @Test("CarPlay keeps its own artwork caches and a larger artwork-view layer while it is on screen")
    func carPlayKeepsWhatItShows() {
        #expect(DecodedImageCacheBudget.keepsCarPlayCaches(inBackground: true, carPlayActive: true))
        #expect(!DecodedImageCacheBudget.keepsCarPlayCaches(inBackground: true, carPlayActive: false))
        #expect(DecodedImageCacheBudget.keepsCarPlayCaches(inBackground: false, carPlayActive: false))
        #expect(DecodedImageCacheBudget.backgroundLimit(for: .artworkViews, carPlayActive: true)
            > DecodedImageCacheBudget.backgroundLimit(for: .artworkViews, carPlayActive: false))
    }
}
