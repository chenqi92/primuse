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

    @Test func wallpaperLayoutKeepsTheCompositionWhenTheSubjectAlreadyFits() throws {
        let center = try #require(squareWallpaper())
        #expect(center.imageX == -135 && center.focus == .center)
        // #460：对称的标志比画面还宽，物体框又松，居中裁才是对的，不能被框拉歪。
        let logo = try #require(squareWallpaper(LockScreenWallpaperSubjects(objects: [
            LockScreenWallpaperRegion(x: 0.10, y: 0.26, width: 0.80, height: 0.52, confidence: 0.74),
        ])))
        #expect(logo.imageX == center.imageX)
        // 人脸稍偏一点但居中裁也放得下：不挪。
        let offCenterFace = try #require(squareWallpaper(LockScreenWallpaperSubjects(faces: [
            LockScreenWallpaperRegion(x: 0.30, y: 0.30, width: 0.15, height: 0.15, confidence: 0.8),
        ])))
        #expect(offCenterFace.imageX == center.imageX)
        // 人脸只在两边各一张、怎么都放不全：留在正中。
        let apart = try #require(squareWallpaper(LockScreenWallpaperSubjects(faces: [
            LockScreenWallpaperRegion(x: 0.0, y: 0.3, width: 0.2, height: 0.3),
            LockScreenWallpaperRegion(x: 0.8, y: 0.3, width: 0.2, height: 0.3),
        ])))
        #expect(apart.imageX == center.imageX)
        // 构图没变，缓存和 artworkID 也不变。
        #expect(logo.signature == center.signature)
    }

    @Test func wallpaperLayoutMovesOnlyAsFarAsTheSubjectNeeds() throws {
        let center = try #require(squareWallpaper())
        // 人脸贴左边：素材往右挪到人脸（含留边）刚好进画面，画面不露边、不用垫底。
        let left = try #require(squareWallpaper(LockScreenWallpaperSubjects(faces: [
            LockScreenWallpaperRegion(x: 0.05, y: 0.3, width: 0.25, height: 0.25),
        ])))
        #expect(left.imageX > center.imageX)
        // 留边按脸宽的 0.15 与 0.04 取大：左边留到 0.01，正好落在画面左边缘。
        #expect(abs(Double(left.imageX) + 0.01 * Double(left.imageWidth)) <= 1)
        #expect(left.coversCanvas)
        // 贴着两边的脸：挪到底也只到素材边缘为止，不露出模糊底。
        for x in [0.0, 0.82] {
            let edge = try #require(squareWallpaper(LockScreenWallpaperSubjects(faces: [
                LockScreenWallpaperRegion(x: x, y: 0.3, width: 0.18, height: 0.2),
            ])))
            #expect(edge.imageX != center.imageX)
            #expect(edge.coversCanvas)
            expectFillsVisibleBand(edge, ratio: 0.46)
            let faceLeft = Double(edge.imageX) + x * Double(edge.imageWidth)
            #expect(faceLeft >= 0 && faceLeft + 0.18 * Double(edge.imageWidth) <= Double(edge.width) + 1)
        }
        // 主体比画面还宽又偏右：画面留在主体范围里、尽量靠正中，左边缘对齐主体（含留边）的左边。
        let wide = try #require(squareWallpaper(LockScreenWallpaperSubjects(objects: [
            LockScreenWallpaperRegion(x: 0.2, y: 0.2, width: 0.8, height: 0.6),
        ])))
        #expect(wide.imageX < center.imageX)
        #expect(abs(Double(wide.imageX) + 0.16 * Double(wide.imageWidth)) <= 1)
        // 构图不同就是不同的缓存。
        #expect(left.signature != center.signature)
    }

    @Test func wallpaperSubjectsPreferFacesAndIgnoreMinorRegions() throws {
        let center = try #require(squareWallpaper())
        // 有脸就只认脸：边上的大物体不拉动取景。
        let faceOverObject = try #require(squareWallpaper(LockScreenWallpaperSubjects(
            faces: [LockScreenWallpaperRegion(x: 0.45, y: 0.3, width: 0.1, height: 0.1)],
            objects: [LockScreenWallpaperRegion(x: 0.0, y: 0.0, width: 0.3, height: 1.0)]
        )))
        #expect(faceOverObject.imageX == center.imageX)
        // 背景里的小脸不算主体。
        let crowd = try #require(squareWallpaper(LockScreenWallpaperSubjects(faces: [
            LockScreenWallpaperRegion(x: 0.4, y: 0.3, width: 0.2, height: 0.2),
            LockScreenWallpaperRegion(x: 0.9, y: 0.1, width: 0.05, height: 0.05),
        ])))
        #expect(crowd.imageX == center.imageX)
        // 反光点这类又小又淡的物体不算主体。
        let glint = try #require(squareWallpaper(LockScreenWallpaperSubjects(objects: [
            LockScreenWallpaperRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4, confidence: 1),
            LockScreenWallpaperRegion(x: 0.0, y: 0.1, width: 0.1, height: 0.1, confidence: 0.2),
        ])))
        #expect(glint.imageX == center.imageX)
        // 不合法的区域不算；越界的框裁回 0～1 再用。
        let broken = try #require(squareWallpaper(LockScreenWallpaperSubjects(
            faces: [
                LockScreenWallpaperRegion(x: .nan, y: 0, width: 1, height: 1),
                LockScreenWallpaperRegion(x: 0.5, y: 0.5, width: 0, height: 0.2),
            ],
            objects: [LockScreenWallpaperRegion(x: 0.0, y: 0.0, width: 0.2, height: 0.2, confidence: 0)]
        )))
        #expect(broken.imageX == center.imageX)
        let outside = try #require(squareWallpaper(LockScreenWallpaperSubjects(faces: [
            LockScreenWallpaperRegion(x: -0.1, y: 0.3, width: 0.2, height: 0.2),
        ])))
        #expect(outside.imageX == 0 && outside.coversCanvas)
    }

    @Test func wallpaperWindowCenterMovesFromTheMiddleOnlyWhenNeeded() {
        typealias Focus = LockScreenWallpaperFocus
        #expect(Focus.windowCenter(keeping: nil, window: 0.75) == 0.5)
        #expect(Focus.windowCenter(keeping: 0.0...0.2, window: 1) == 0.5)
        #expect(Focus.windowCenter(keeping: 0.0...0.2, window: .nan) == 0.5)
        // 放得下：挪到刚好放进。
        #expect(abs(Focus.windowCenter(keeping: 0.1...0.3, window: 0.46) - 0.33) < 1e-9)
        #expect(abs(Focus.windowCenter(keeping: 0.7...0.9, window: 0.46) - 0.67) < 1e-9)
        #expect(Focus.windowCenter(keeping: 0.3...0.6, window: 0.46) == 0.5)
        // 放不下：留在主体范围里、尽量靠正中。
        #expect(Focus.windowCenter(keeping: 0.0...1.0, window: 0.46) == 0.5)
        #expect(abs(Focus.windowCenter(keeping: 0.4...1.0, window: 0.46) - 0.63) < 1e-9)
        #expect(LockScreenWallpaperFocus(x: -1, y: 2) == LockScreenWallpaperFocus(x: 0, y: 1))
    }

    @Test func wallpaperLayoutHandlesNonSquareCovers() throws {
        // 竖封面：高度占满，宽度至少盖住按屏幕宽高比算的那一段；上下不露边。
        let tall = try #require(LockScreenWallpaperLayout(
            sourceWidth: 900, sourceHeight: 1_600, visibleWidthRatio: 0.46,
            subjects: LockScreenWallpaperSubjects(faces: [LockScreenWallpaperRegion(x: 0.4, y: 0, width: 0.2, height: 0.1)])
        ))
        expectFillsVisibleBand(tall, ratio: 0.46)
        #expect(tall.imageY <= 0 && tall.imageY + tall.imageHeight >= tall.height)
        // 很窄的竖图要放大到盖住那一段，上下就有富余：脸在最上面时往下挪到脸进画面为止。
        let narrow = try #require(LockScreenWallpaperLayout(
            sourceWidth: 400, sourceHeight: 1_600, visibleWidthRatio: 0.46,
            subjects: LockScreenWallpaperSubjects(faces: [LockScreenWallpaperRegion(x: 0.3, y: 0, width: 0.4, height: 0.1)])
        ))
        let narrowCentered = try #require(LockScreenWallpaperLayout(
            sourceWidth: 400, sourceHeight: 1_600, visibleWidthRatio: 0.46
        ))
        #expect(narrow.imageHeight > narrow.height)
        #expect(narrow.imageY > narrowCentered.imageY)
        #expect(narrow.imageY <= 0 && narrow.imageY >= -1)
        #expect(narrow.imageY + narrow.imageHeight >= narrow.height)
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
        // 比 3:4 还宽的屏幕（iPad）按整幅宽算：主体贴边也整幅盖满。
        let wide = try #require(LockScreenWallpaperLayout(
            sourceWidth: 1_080, sourceHeight: 1_080, visibleWidthRatio: 0.9,
            subjects: LockScreenWallpaperSubjects(faces: [LockScreenWallpaperRegion(x: 0, y: 0.3, width: 0.1, height: 0.1)])
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
    /// 1080 见方的封面放进 iPhone 竖屏：画面 810×1080，素材 1080×1080，居中时 imageX = -135。
    private func squareWallpaper(_ subjects: LockScreenWallpaperSubjects = .none) -> LockScreenWallpaperLayout? {
        LockScreenWallpaperLayout(sourceWidth: 1_080, sourceHeight: 1_080, visibleWidthRatio: 0.46, subjects: subjects)
    }

    private func expectFillsVisibleBand(_ layout: LockScreenWallpaperLayout, ratio: Double) {
        let visible = min(Double(layout.width), min(0.75, ratio) * Double(layout.height))
        let visibleLeft = (Double(layout.width) - visible) / 2
        #expect(Double(layout.imageX) <= visibleLeft + 0.5)
        #expect(Double(layout.imageX + layout.imageWidth) >= visibleLeft + visible - 0.5)
        #expect(layout.imageY <= 0)
        #expect(layout.imageY + layout.imageHeight >= layout.height)
    }
}
