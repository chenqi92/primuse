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
