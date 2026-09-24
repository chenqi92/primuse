import Foundation
import Testing
@testable import PrimuseKit

@Suite("停靠播放条宽度")
struct DockedPlayerBarLayoutPolicyTests {
    private typealias Policy = DockedPlayerBarLayoutPolicy

    /// 折叠屏外屏竖握：466 宽里右侧 84 是系统竖栏，容器 382（Duo 模拟器实测）。
    @Test("竖屏 iPhone 与折叠屏外屏不变：左右各内缩 12、铺满整行", arguments: [320.0, 375, 390, 402, 440, 382])
    func portraitPhonesFillTheRow(width: Double) {
        #expect(Policy.barWidth(containerWidth: width) == width - 24)
        #expect(!Policy.isConstrained(containerWidth: width))
    }

    /// SE 横屏、15 Pro 横屏（安全区以内）、Pro Max 横屏、折叠屏外屏横握（678 − 左侧竖栏 84）、
    /// 折叠屏内屏（官方像素推算 890 与模拟器画面缓冲推算 951，还没有实测）。
    @Test("手机横屏与折叠屏内屏限宽，不再通栏", arguments: [667.0, 734.0, 832.0, 594.0, 890.0, 951.0])
    func wideViewportsAreCapped(width: Double) {
        #expect(Policy.barWidth(containerWidth: width) == Policy.maximumWidth)
        #expect(Policy.isConstrained(containerWidth: width))
    }

    @Test("容器比内缩还窄时不给负宽度")
    func tinyContainer() {
        #expect(Policy.barWidth(containerWidth: 10) == 0)
    }
}
