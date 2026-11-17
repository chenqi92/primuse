import Foundation
import Testing
@testable import PrimuseKit

struct LockScreenMotionArtworkPolicyTests {
    @Test func materialPriorityPrefersUserVideosThenServiceThenCustomAnimationThenStaticCover() {
        let candidates: [(MotionArtworkMaterialKind, String)] = [
            (.coverImage, "cover"),
            (.customAnimation, "song-gif"),
            (.serviceMaterial, "service"),
            (.customAnimation, "album-gif"),
            (.albumVideo, "album-video"),
            (.songVideo, "song-video"),
        ]
        let ordered = MotionArtworkMaterialSelection.ordered(candidates) { $0.0 }.map(\.1)
        #expect(ordered == ["song-video", "album-video", "service", "song-gif", "album-gif", "cover"])
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

    @Test func staticCoverWallpaperOnlyFollowsTheFullScreenSwitch() {
        typealias Policy = LockScreenMotionArtworkPolicy
        #expect(Policy.permitsStillWallpaper(context()))
        // 动态封面的两个开关和「仅 Wi-Fi」不管静态封面：封面本来就在本机。
        #expect(Policy.permitsStillWallpaper(context(animated: false, lockScreen: false)))
        #expect(Policy.permitsStillWallpaper(context(local: false, unmeteredOnly: true, unmetered: false)))
        #expect(!Policy.permitsStillWallpaper(context(fullScreen: false)))
        #expect(!Policy.permitsStillWallpaper(context(system: false)))
        for content: LockScreenMotionArtworkContent in [.musicVideo, .liveRadio, .spokenWord, .podcast, .appleMusic] {
            #expect(!Policy.permitsStillWallpaper(context(content: content)))
        }
        // 反过来，全屏开关不影响动态封面能不能发。
        #expect(Policy.permitsPublishing(context(fullScreen: false)))
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

    @Test func wallpaperLayoutFillsTheVisibleBandWithASquareCover() throws {
        for ratio in [0.42, 0.46, 0.5, 0.6, 0.7] {
            let layout = try #require(LockScreenWallpaperLayout(
                sourceWidth: 1_080, sourceHeight: 1_080, visibleWidthRatio: ratio
            ))
            #expect(layout.height <= MotionCoverImportLimits.maximumLongEdge)
            #expect(layout.width * 4 == layout.height * 3)
            #expect(layout.width % 2 == 0 && layout.height % 8 == 0)
            expectFillsVisibleBand(layout, ratio: ratio)
            // 方形封面高度占满画面，像壁纸一样铺满，不再是「模糊底上一块方形」。
            #expect(layout.imageHeight == layout.height && layout.imageY == 0)
            #expect(layout.imageWidth == layout.imageHeight)
        }
        let phone = try #require(LockScreenWallpaperLayout(
            sourceWidth: 1_080, sourceHeight: 1_080, visibleWidthRatio: 0.46
        ))
        #expect(phone.width == 810 && phone.height == 1_080)
        // 取正中时方形两侧对称地伸到画面外。
        #expect(phone.imageX == (phone.width - phone.imageWidth) / 2)
        #expect(phone.coversCanvas)
    }

    @Test func wallpaperLayoutMovesTheVisibleBandTowardsTheSubject() throws {
        let center = try #require(LockScreenWallpaperLayout(
            sourceWidth: 1_080, sourceHeight: 1_080, visibleWidthRatio: 0.46
        ))
        let left = try #require(LockScreenWallpaperLayout(
            sourceWidth: 1_080, sourceHeight: 1_080, visibleWidthRatio: 0.46,
            focus: LockScreenWallpaperFocus(x: 0.25, y: 0.5)
        ))
        let right = try #require(LockScreenWallpaperLayout(
            sourceWidth: 1_080, sourceHeight: 1_080, visibleWidthRatio: 0.46,
            focus: LockScreenWallpaperFocus(x: 0.75, y: 0.5)
        ))
        // 主体偏左：素材往右挪，左边那部分进到看得见的地方；偏右反之。
        #expect(left.imageX > center.imageX)
        #expect(right.imageX < center.imageX)
        // 主体在 1/4 处：正好落在画面中线上。
        #expect(abs(Double(left.imageX) + 0.25 * Double(left.imageWidth) - Double(left.width) / 2) <= 1)
        for layout in [left, right] {
            expectFillsVisibleBand(layout, ratio: 0.46)
        }
        // 主体贴边时收回到看得见的那一段不露边为止。
        for x in [0.0, 1.0] {
            let edge = try #require(LockScreenWallpaperLayout(
                sourceWidth: 1_080, sourceHeight: 1_080, visibleWidthRatio: 0.46,
                focus: LockScreenWallpaperFocus(x: x, y: 0.5)
            ))
            expectFillsVisibleBand(edge, ratio: 0.46)
            // 锁屏看不见的边角盖不到，要垫底。
            #expect(!edge.coversCanvas)
        }
        // 取景点不同就是不同的构图。
        #expect(left.signature != center.signature && right.signature != center.signature)
    }

    @Test func wallpaperLayoutHandlesNonSquareCovers() throws {
        // 竖封面：高度占满，宽度至少盖住看得见的那一段；上下按取景点挪、不露边。
        let tall = try #require(LockScreenWallpaperLayout(
            sourceWidth: 900, sourceHeight: 1_600, visibleWidthRatio: 0.46,
            focus: LockScreenWallpaperFocus(x: 0.5, y: 0.1)
        ))
        expectFillsVisibleBand(tall, ratio: 0.46)
        #expect(tall.imageY <= 0 && tall.imageY + tall.imageHeight >= tall.height)
        // 横封面：高度占满，左右裁掉更多。
        let wide = try #require(LockScreenWallpaperLayout(
            sourceWidth: 1_920, sourceHeight: 1_080, visibleWidthRatio: 0.46
        ))
        expectFillsVisibleBand(wide, ratio: 0.46)
        #expect(wide.imageHeight == wide.height && wide.imageY == 0)
        #expect(wide.coversCanvas)
    }

    @Test func wallpaperLayoutFallsBackAndClampsTheScreenRatio() throws {
        let fallback = try #require(LockScreenWallpaperLayout(
            sourceWidth: 1_080, sourceHeight: 1_080, visibleWidthRatio: nil
        ))
        #expect(fallback == LockScreenWallpaperLayout(
            sourceWidth: 1_080, sourceHeight: 1_080,
            visibleWidthRatio: LockScreenWallpaperLayout.fallbackVisibleWidthRatio
        ))
        #expect(fallback == LockScreenWallpaperLayout(sourceWidth: 1_080, sourceHeight: 1_080, visibleWidthRatio: .nan))
        #expect(fallback == LockScreenWallpaperLayout(sourceWidth: 1_080, sourceHeight: 1_080, visibleWidthRatio: 0))
        // 比 3:4 还宽的屏幕（iPad）锁屏不裁两侧：整幅都要盖满。
        let wide = try #require(LockScreenWallpaperLayout(
            sourceWidth: 1_080, sourceHeight: 1_080, visibleWidthRatio: 0.9,
            focus: LockScreenWallpaperFocus(x: 0, y: 0.5)
        ))
        #expect(wide.visibleWidthPermille == 750)
        #expect(wide.coversCanvas)
        #expect(LockScreenWallpaperLayout(sourceWidth: 8, sourceHeight: 8, visibleWidthRatio: 0.46) == nil)
        #expect(LockScreenWallpaperLayout(sourceWidth: .infinity, sourceHeight: 1_080, visibleWidthRatio: 0.46) == nil)
    }

    @Test func wallpaperLayoutNeverUpscalesSmallMaterial() throws {
        let small = try #require(LockScreenWallpaperLayout(
            sourceWidth: 240, sourceHeight: 240, visibleWidthRatio: 0.46
        ))
        #expect(small.imageWidth <= 240 && small.imageHeight <= 240)
        #expect(small.height < MotionCoverImportLimits.maximumLongEdge)
        #expect(small.width * 4 == small.height * 3)
        let large = try #require(LockScreenWallpaperLayout(
            sourceWidth: 4_000, sourceHeight: 4_000, visibleWidthRatio: 0.46
        ))
        #expect(large.height == MotionCoverImportLimits.maximumLongEdge)
        // 静态封面可以用更大的上限。
        let still = try #require(LockScreenWallpaperLayout(
            sourceWidth: 4_000, sourceHeight: 4_000, visibleWidthRatio: 0.46, maximumLongEdge: 1_920
        ))
        #expect(still.height == 1_920 && still.width == 1_440)
    }

    @Test func wallpaperFocusWeighsSalientRegionsByAreaAndConfidence() {
        #expect(LockScreenWallpaperFocus(regions: []) == .center)
        let face = LockScreenWallpaperRegion(x: 0.1, y: 0.2, width: 0.2, height: 0.2)
        let single = LockScreenWallpaperFocus(regions: [face])
        #expect(abs(single.x - 0.2) < 1e-9 && abs(single.y - 0.3) < 1e-9)
        // 大的、置信度高的那块分量重。
        let big = LockScreenWallpaperRegion(x: 0.6, y: 0.4, width: 0.4, height: 0.4, confidence: 1)
        let faint = LockScreenWallpaperRegion(x: 0, y: 0, width: 0.1, height: 0.1, confidence: 0.2)
        let mixed = LockScreenWallpaperFocus(regions: [big, faint])
        #expect(mixed.x > 0.75 && mixed.y > 0.55)
        // 不合法的区域不算，越界的坐标收回到 0～1。
        let broken = LockScreenWallpaperRegion(x: .nan, y: 0, width: 1, height: 1)
        let empty = LockScreenWallpaperRegion(x: 0.5, y: 0.5, width: 0, height: 0.2)
        #expect(LockScreenWallpaperFocus(regions: [broken, empty]) == .center)
        #expect(LockScreenWallpaperFocus(x: -1, y: 2) == LockScreenWallpaperFocus(x: 0, y: 1))
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
        let phone = try #require(LockScreenWallpaperLayout(sourceWidth: 1_080, sourceHeight: 1_080, visibleWidthRatio: 0.46))
        let otherScreen = try #require(LockScreenWallpaperLayout(sourceWidth: 1_080, sourceHeight: 1_080, visibleWidthRatio: 0.5))
        let smaller = try #require(LockScreenWallpaperLayout(sourceWidth: 300, sourceHeight: 300, visibleWidthRatio: 0.46))
        let hash = String(repeating: "ab", count: 32)

        let composed = Policy.artworkID(kind: .songVideo, contentKey: hash, wallpaper: phone)
        #expect(composed == Policy.artworkID(kind: .songVideo, contentKey: hash, wallpaper: phone))
        #expect(composed != Policy.artworkID(kind: .songVideo, contentKey: hash, aspect: .square))
        #expect(composed != Policy.artworkID(kind: .songVideo, contentKey: hash, aspect: .tall))
        #expect(composed != Policy.artworkID(kind: .songVideo, contentKey: hash, wallpaper: otherScreen))
        #expect(composed != Policy.artworkID(kind: .albumVideo, contentKey: hash, wallpaper: phone))
        #expect(!Policy.artworkID(kind: .serviceMaterial, contentKey: "a/b c", wallpaper: phone).contains("/"))

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

        // 静态封面合成的静止视频：同一份内容、同一构图也不和动态素材的合成撞名。
        let still = Policy.stillWallpaperCacheName(contentKey: hash, layout: phone)
        #expect(still.hasSuffix(".mp4"))
        #expect(Policy.conversionCachePrefixes.contains { still.hasPrefix($0) })
        #expect(still != name)
        #expect(still == Policy.stillWallpaperCacheName(contentKey: hash, layout: phone))
        #expect(still != Policy.stillWallpaperCacheName(contentKey: hash, layout: otherScreen))
        #expect(!Policy.stillWallpaperCacheName(contentKey: "../../escape", layout: phone).contains("/"))
        #expect(Policy.artworkID(kind: .coverImage, contentKey: hash, wallpaper: phone) != composed)
    }

    private func context(
        system: Bool = true,
        animated: Bool = true,
        lockScreen: Bool = true,
        fullScreen: Bool = true,
        content: LockScreenMotionArtworkContent = .music,
        local: Bool = true,
        unmeteredOnly: Bool = true,
        unmetered: Bool = true
    ) -> LockScreenMotionArtworkContext {
        LockScreenMotionArtworkContext(
            systemSupportsAnimatedArtwork: system,
            animatedArtworkEnabled: animated,
            lockScreenEnabled: lockScreen,
            fullScreenArtworkEnabled: fullScreen,
            content: content,
            materialIsLocal: local,
            unmeteredOnly: unmeteredOnly,
            isOnUnmeteredNetwork: unmetered
        )
    }

    /// 锁屏按屏幕比例居中裁两侧以后看得见的那一段，整段都是素材，没有露出垫底或黑边。
    private func expectFillsVisibleBand(_ layout: LockScreenWallpaperLayout, ratio: Double) {
        let visible = min(Double(layout.width), min(0.75, ratio) * Double(layout.height))
        let visibleLeft = (Double(layout.width) - visible) / 2
        #expect(Double(layout.imageX) <= visibleLeft + 0.5)
        #expect(Double(layout.imageX + layout.imageWidth) >= visibleLeft + visible - 0.5)
        #expect(layout.imageY <= 0)
        #expect(layout.imageY + layout.imageHeight >= layout.height)
    }
}
