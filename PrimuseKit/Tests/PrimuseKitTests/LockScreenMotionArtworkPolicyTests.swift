import Foundation
import Testing
@testable import PrimuseKit

struct LockScreenMotionArtworkPolicyTests {
    @Test func materialPriorityPrefersUserVideosThenServiceThenCustomAnimation() {
        let candidates: [(MotionArtworkMaterialKind, String)] = [
            (.customAnimation, "song-gif"),
            (.serviceMaterial, "service"),
            (.customAnimation, "album-gif"),
            (.albumVideo, "album-video"),
            (.songVideo, "song-video"),
        ]
        let ordered = MotionArtworkMaterialSelection.ordered(candidates) { $0.0 }.map(\.1)
        #expect(ordered == ["song-video", "album-video", "service", "song-gif", "album-gif"])
        let none = MotionArtworkMaterialSelection.ordered([(MotionArtworkMaterialKind, String)]()) { $0.0 }
        #expect(none.isEmpty)
    }

    @Test func onlyLibraryMusicPublishesWhenEverySwitchIsOn() {
        #expect(LockScreenMotionArtworkPolicy.permitsPublishing(context()))
        #expect(!LockScreenMotionArtworkPolicy.permitsPublishing(context(system: false)))
        #expect(!LockScreenMotionArtworkPolicy.permitsPublishing(context(animated: false)))
        #expect(!LockScreenMotionArtworkPolicy.permitsPublishing(context(lockScreen: false)))
        for content: LockScreenMotionArtworkContent in [.musicVideo, .liveRadio, .spokenWord, .podcast, .appleMusic] {
            #expect(!LockScreenMotionArtworkPolicy.permitsPublishing(context(content: content)))
        }
    }

    @Test func wifiOnlyLimitsDownloadsNotLocalMaterial() {
        #expect(LockScreenMotionArtworkPolicy.permitsPublishing(context(unmeteredOnly: true, unmetered: false)))
        #expect(!LockScreenMotionArtworkPolicy.permitsPublishing(
            context(local: false, unmeteredOnly: true, unmetered: false)
        ))
        #expect(LockScreenMotionArtworkPolicy.permitsPublishing(
            context(local: false, unmeteredOnly: true, unmetered: true)
        ))
        #expect(LockScreenMotionArtworkPolicy.permitsPublishing(
            context(local: false, unmeteredOnly: false, unmetered: false)
        ))
    }

    @Test func squareMaterialGetsAComposedTallRenditionOnlyWhenTheTallSlotExists() {
        typealias Policy = LockScreenMotionArtworkPolicy
        #expect(Policy.renditions(for: .square, supported: [.square, .tall], canComposeTall: true)
            == [.original(.square), .squareInTall])
        #expect(Policy.renditions(for: .square, supported: [.tall], canComposeTall: true) == [.squareInTall])
        #expect(Policy.renditions(for: .square, supported: [.square, .tall], canComposeTall: false)
            == [.original(.square)])
        #expect(Policy.renditions(for: .square, supported: [.square], canComposeTall: true) == [.original(.square)])
        #expect(Policy.renditions(for: .square, supported: [.tall], canComposeTall: false).isEmpty)
        #expect(Policy.renditions(for: .square, supported: [], canComposeTall: true).isEmpty)
        // 3:4 素材照旧只放 3:4 位，不合成。
        #expect(Policy.renditions(for: .tall, supported: [.square, .tall], canComposeTall: true) == [.original(.tall)])
        #expect(Policy.renditions(for: .tall, supported: [.square], canComposeTall: true).isEmpty)
        #expect(LockScreenMotionArtworkRendition.squareInTall.slot == .tall)
        #expect(LockScreenMotionArtworkRendition.original(.square).slot == .square)
    }

    @Test func squareInTallLayoutKeepsTheWholeSquareInsideTheVisibleBand() throws {
        for ratio in [0.42, 0.46, 0.5, 0.6, 0.7] {
            let layout = try #require(LockScreenSquareInTallLayout(sourceSide: 1_080, visibleWidthRatio: ratio))
            #expect(layout.height <= MotionCoverImportLimits.maximumLongEdge)
            #expect(layout.width * 4 == layout.height * 3)
            #expect(layout.width % 2 == 0 && layout.height % 8 == 0)
            // 锁屏按屏幕比例居中裁两侧以后看得见的那一段，方形整个在里面、而且基本铺满这段宽度。
            let visible = ratio * Double(layout.height)
            let visibleLeft = (Double(layout.width) - visible) / 2
            #expect(Double(layout.foregroundX) >= visibleLeft - 1)
            #expect(Double(layout.foregroundX + layout.foregroundSide) <= visibleLeft + visible + 1)
            #expect(Double(layout.foregroundSide) >= visible - 2)
            #expect(layout.foregroundSide % 2 == 0)
            #expect(layout.foregroundY >= 0)
            #expect(layout.foregroundY + layout.foregroundSide <= layout.height)
        }
        let phone = try #require(LockScreenSquareInTallLayout(sourceSide: 1_080, visibleWidthRatio: 0.46))
        #expect(phone.width == 810 && phone.height == 1_080)
        // 略偏上：方形中心在高度的 38% 附近，下面比上面留得多（给系统控件）。
        let center = Double(phone.foregroundY) + Double(phone.foregroundSide) / 2
        #expect(abs(center / Double(phone.height) - LockScreenSquareInTallLayout.foregroundCenterFraction) < 0.01)
        #expect(phone.height - phone.foregroundY - phone.foregroundSide > phone.foregroundY * 2)
    }

    @Test func squareInTallLayoutFallsBackAndClampsTheScreenRatio() throws {
        let fallback = try #require(LockScreenSquareInTallLayout(sourceSide: 1_080, visibleWidthRatio: nil))
        #expect(fallback == LockScreenSquareInTallLayout(
            sourceSide: 1_080,
            visibleWidthRatio: LockScreenSquareInTallLayout.fallbackVisibleWidthRatio
        ))
        #expect(fallback == LockScreenSquareInTallLayout(sourceSide: 1_080, visibleWidthRatio: .nan))
        #expect(fallback == LockScreenSquareInTallLayout(sourceSide: 1_080, visibleWidthRatio: 0))
        // 比 3:4 还宽的屏幕（iPad）锁屏不裁两侧：方形占满整幅宽，仍在画面以内。
        let wide = try #require(LockScreenSquareInTallLayout(sourceSide: 1_080, visibleWidthRatio: 0.9))
        #expect(wide.visibleWidthPermille == 750)
        #expect(wide.foregroundSide == wide.width && wide.foregroundX == 0)
        #expect(wide.foregroundY + wide.foregroundSide <= wide.height)
        #expect(LockScreenSquareInTallLayout(sourceSide: 8, visibleWidthRatio: 0.46) == nil)
        #expect(LockScreenSquareInTallLayout(sourceSide: .infinity, visibleWidthRatio: 0.46) == nil)
    }

    @Test func squareInTallLayoutNeverUpscalesSmallMaterial() throws {
        let small = try #require(LockScreenSquareInTallLayout(sourceSide: 240, visibleWidthRatio: 0.46))
        #expect(small.foregroundSide <= 240)
        #expect(small.height < MotionCoverImportLimits.maximumLongEdge)
        #expect(small.width * 4 == small.height * 3)
        let large = try #require(LockScreenSquareInTallLayout(sourceSide: 4_000, visibleWidthRatio: 0.46))
        #expect(large.height == MotionCoverImportLimits.maximumLongEdge)
    }

    @Test func operatingSystemThresholdIsVersion26() {
        #expect(!LockScreenMotionArtworkPolicy.operatingSystemSupportsAnimatedArtwork(majorVersion: 18))
        #expect(!LockScreenMotionArtworkPolicy.operatingSystemSupportsAnimatedArtwork(majorVersion: 25))
        #expect(LockScreenMotionArtworkPolicy.operatingSystemSupportsAnimatedArtwork(majorVersion: 26))
        #expect(LockScreenMotionArtworkPolicy.operatingSystemSupportsAnimatedArtwork(majorVersion: 27))
    }

    @Test func artworkIDIsStableForSharedAlbumMaterialAndChangesWithContent() {
        let hash = String(repeating: "ab", count: 32)
        let first = LockScreenMotionArtworkPolicy.artworkID(kind: .albumVideo, contentKey: hash, aspect: .tall)
        let again = LockScreenMotionArtworkPolicy.artworkID(kind: .albumVideo, contentKey: hash, aspect: .tall)
        #expect(first == again)
        #expect(first != LockScreenMotionArtworkPolicy.artworkID(kind: .albumVideo, contentKey: hash, aspect: .square))
        #expect(first != LockScreenMotionArtworkPolicy.artworkID(kind: .songVideo, contentKey: hash, aspect: .tall))
        #expect(first != LockScreenMotionArtworkPolicy.artworkID(
            kind: .albumVideo,
            contentKey: String(repeating: "cd", count: 32),
            aspect: .tall
        ))
        let unsafe = LockScreenMotionArtworkPolicy.artworkID(kind: .serviceMaterial, contentKey: "a/b c", aspect: .square)
        #expect(!unsafe.contains("/") && !unsafe.contains(" "))
    }

    @Test func conversionCacheNameTracksContentAspectAndSize() {
        let name = LockScreenMotionArtworkPolicy.conversionCacheName(
            contentKey: "abc", aspect: .square, width: 480, height: 480
        )
        #expect(name.hasSuffix(".mp4"))
        #expect(name == LockScreenMotionArtworkPolicy.conversionCacheName(
            contentKey: "abc", aspect: .square, width: 480, height: 480
        ))
        #expect(name != LockScreenMotionArtworkPolicy.conversionCacheName(
            contentKey: "abc", aspect: .tall, width: 360, height: 480
        ))
        #expect(name != LockScreenMotionArtworkPolicy.conversionCacheName(
            contentKey: "abd", aspect: .square, width: 480, height: 480
        ))
        #expect(!LockScreenMotionArtworkPolicy.conversionCacheName(
            contentKey: "../../escape", aspect: .square, width: 1, height: 1
        ).contains("/"))
    }

    @Test func composedTallVariantsHaveTheirOwnCacheNameAndArtworkID() throws {
        typealias Policy = LockScreenMotionArtworkPolicy
        let phone = try #require(LockScreenSquareInTallLayout(sourceSide: 1_080, visibleWidthRatio: 0.46))
        let otherScreen = try #require(LockScreenSquareInTallLayout(sourceSide: 1_080, visibleWidthRatio: 0.5))
        let smaller = try #require(LockScreenSquareInTallLayout(sourceSide: 300, visibleWidthRatio: 0.46))
        let hash = String(repeating: "ab", count: 32)

        let composed = Policy.artworkID(kind: .songVideo, contentKey: hash, squareInTall: phone)
        #expect(composed == Policy.artworkID(kind: .songVideo, contentKey: hash, squareInTall: phone))
        #expect(composed != Policy.artworkID(kind: .songVideo, contentKey: hash, aspect: .square))
        #expect(composed != Policy.artworkID(kind: .songVideo, contentKey: hash, aspect: .tall))
        #expect(composed != Policy.artworkID(kind: .songVideo, contentKey: hash, squareInTall: otherScreen))
        #expect(composed != Policy.artworkID(kind: .albumVideo, contentKey: hash, squareInTall: phone))
        #expect(!Policy.artworkID(kind: .serviceMaterial, contentKey: "a/b c", squareInTall: phone).contains("/"))

        let name = Policy.tallCompositionCacheName(contentKey: hash, layout: phone)
        #expect(name.hasSuffix(".mp4"))
        #expect(Policy.conversionCachePrefixes.contains { name.hasPrefix($0) })
        #expect(name == Policy.tallCompositionCacheName(contentKey: hash, layout: phone))
        #expect(name != Policy.tallCompositionCacheName(contentKey: hash, layout: otherScreen))
        #expect(name != Policy.tallCompositionCacheName(contentKey: hash, layout: smaller))
        #expect(name != Policy.tallCompositionCacheName(contentKey: "cd", layout: phone))
        // 不和动图原画幅转码的缓存撞名。
        #expect(name != Policy.conversionCacheName(contentKey: hash, aspect: .tall, width: phone.width, height: phone.height))
        #expect(!Policy.tallCompositionCacheName(contentKey: "../../escape", layout: phone).contains("/"))
        let animation = Policy.conversionCacheName(contentKey: "abc", aspect: .square, width: 480, height: 480)
        #expect(Policy.conversionCachePrefixes.contains { animation.hasPrefix($0) })
    }

    private func context(
        system: Bool = true,
        animated: Bool = true,
        lockScreen: Bool = true,
        content: LockScreenMotionArtworkContent = .music,
        local: Bool = true,
        unmeteredOnly: Bool = true,
        unmetered: Bool = true
    ) -> LockScreenMotionArtworkContext {
        LockScreenMotionArtworkContext(
            systemSupportsAnimatedArtwork: system,
            animatedArtworkEnabled: animated,
            lockScreenEnabled: lockScreen,
            content: content,
            materialIsLocal: local,
            unmeteredOnly: unmeteredOnly,
            isOnUnmeteredNetwork: unmetered
        )
    }
}
