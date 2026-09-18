import Foundation
import Testing
@testable import PrimuseKit

@Suite("Song row aligned columns policy")
struct SongRowColumnsPolicyTests {
    @Test("竖屏手机与分屏小窗一列都不显示")
    func narrowContainerKeepsTheOriginalRow() {
        // 竖屏 iPhone 的列表容器约 390 点宽。
        let portrait = SongRowColumnsPolicy.columns(containerWidth: 390)
        #expect(portrait == SongRowColumns.hidden)
        #expect(!portrait.isActive)

        // 门槛下方一点仍然不显示，避免在边界上来回翻。
        let justBelow = SongRowColumnsPolicy.columns(containerWidth: 599)
        #expect(justBelow == SongRowColumns.hidden)
    }

    @Test("六百点起只加时长列")
    func durationColumnAppearsFirst() {
        let columns = SongRowColumnsPolicy.columns(containerWidth: 600)
        #expect(columns.showsDuration)
        #expect(!columns.showsAlbum)
        #expect(columns.durationWidth == 56)
        #expect(columns.albumWidth == 0)
        #expect(columns.isActive)
    }

    @Test("SE 横屏只够时长列")
    func compactLandscapePhoneKeepsAlbumInTheSubtitle() {
        // iPhone SE 3 横屏 667 点宽，没有左右安全区。
        let columns = SongRowColumnsPolicy.columns(containerWidth: 667)
        #expect(columns.showsDuration)
        #expect(!columns.showsAlbum)
    }

    @Test("常见手机横屏宽度两列都有")
    func regularLandscapePhoneGetsBothColumns() {
        // iPhone 15/16 横屏 852，减去左右各 59 的安全区后是 734。
        let columns = SongRowColumnsPolicy.columns(containerWidth: 734)
        #expect(columns.showsAlbum)
        #expect(columns.showsDuration)
        #expect(columns.albumWidth == 161)
        #expect(columns.durationWidth == 56)
    }

    @Test("专辑列在门槛附近取到宽度下限")
    func albumColumnHasALowerBound() {
        let atThreshold = SongRowColumnsPolicy.columns(containerWidth: 680)
        #expect(atThreshold.showsAlbum)
        #expect(atThreshold.albumWidth == 156)

        let slightlyWider = SongRowColumnsPolicy.columns(containerWidth: 700)
        #expect(slightlyWider.albumWidth == 156)
    }

    @Test("专辑列在宽屏上封顶")
    func albumColumnHasAnUpperBound() {
        let wide = SongRowColumnsPolicy.columns(containerWidth: 1366)
        #expect(wide.albumWidth == 260)

        // 上限刚好咬住的位置：0.22 × 1200 = 264。
        let atCap = SongRowColumnsPolicy.columns(containerWidth: 1200)
        #expect(atCap.albumWidth == 260)
    }

    @Test("列宽随容器宽度单调不减")
    func albumColumnGrowsWithTheContainer() {
        let narrow = SongRowColumnsPolicy.columns(containerWidth: 734)
        let medium = SongRowColumnsPolicy.columns(containerWidth: 900)
        let wide = SongRowColumnsPolicy.columns(containerWidth: 1024)
        #expect(narrow.albumWidth == 161)
        #expect(medium.albumWidth == 198)
        #expect(wide.albumWidth == 225)
    }

    @Test("本来就不显示专辑的页面只拿到时长列")
    func albumColumnCanBeOptedOut() {
        let columns = SongRowColumnsPolicy.columns(containerWidth: 900, allowsAlbum: false)
        #expect(columns.showsDuration)
        #expect(!columns.showsAlbum)
        #expect(columns.albumWidth == 0)
    }

    @Test("宽度还没量到或不是有限值时按窄容器处理")
    func unusableWidthsFallBackToHidden() {
        #expect(SongRowColumnsPolicy.columns(containerWidth: 0) == SongRowColumns.hidden)
        #expect(SongRowColumnsPolicy.columns(containerWidth: -100) == SongRowColumns.hidden)
        #expect(SongRowColumnsPolicy.columns(containerWidth: .nan) == SongRowColumns.hidden)
        #expect(SongRowColumnsPolicy.columns(containerWidth: .infinity) == SongRowColumns.hidden)
    }
}
