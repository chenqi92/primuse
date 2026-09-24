import Foundation
import Testing
@testable import PrimuseKit

@Suite("详情页头图滚动动效")
struct LibraryDetailHeroMotionPolicyTests {
    private typealias Policy = LibraryDetailHeroMotionPolicy

    @Test("静止时不变")
    func restIsIdentity() {
        #expect(Policy.poster(pull: 0, height: 440) == .identity)
        #expect(Policy.artwork(pull: 0, extent: 262) == .identity)
    }

    @Test("下拉时海报上沿钉住、下沿跟着内容，正好填满拉开的空隙")
    func posterStretchFillsGap() {
        let height = 440.0
        let pull = 120.0
        let transform = Policy.poster(pull: pull, height: height)
        // 以上沿为锚点缩放后，上沿在屏幕上的位置 = 内容下移的距离 + 位移 = 0。
        #expect(pull + transform.offsetY == 0)
        // 下沿 = 上沿 + 高度 × 缩放 = 内容里下沿的位置（高度 + 下拉距离）。
        let bottom = pull + transform.offsetY + height * transform.scale
        #expect(abs(bottom - (height + pull)) < 0.0001)
    }

    @Test("上滚时海报以半速跟随，不放大")
    func posterParallax() {
        let transform = Policy.poster(pull: -200, height: 440)
        #expect(transform.scale == 1)
        #expect(transform.offsetY == 100)
        // 滚过头图高度之后不再增加。
        #expect(Policy.poster(pull: -2000, height: 440).offsetY == 220)
    }

    @Test("封面下拉放大有上限，上滚不动")
    func artworkStretch() {
        #expect(abs(Policy.artwork(pull: 40, extent: 200).scale - 1.1) < 0.0001)
        #expect(Policy.artwork(pull: 1000, extent: 262).scale == Policy.artworkMaximumScale)
        #expect(Policy.artwork(pull: -300, extent: 262) == .identity)
    }

    @Test("导航栏标题显隐带滞回，停在线上不闪")
    func inlineTitleHysteresis() {
        let threshold = 300.0
        #expect(!Policy.showsInlineTitle(scrolled: 0, threshold: threshold, wasShowing: false))
        #expect(!Policy.showsInlineTitle(scrolled: 302, threshold: threshold, wasShowing: false))
        #expect(Policy.showsInlineTitle(scrolled: 306, threshold: threshold, wasShowing: false))
        // 已经显示时退回线下 5 点仍保持，退够 6 点才藏。
        #expect(Policy.showsInlineTitle(scrolled: 295, threshold: threshold, wasShowing: true))
        #expect(!Policy.showsInlineTitle(scrolled: 294, threshold: threshold, wasShowing: true))
        // 来回在线附近抖动时状态不翻。
        var showing = false
        for scrolled in [299.0, 301, 298, 303, 300] {
            showing = Policy.showsInlineTitle(scrolled: scrolled, threshold: threshold, wasShowing: showing)
            #expect(!showing)
        }
    }
}
