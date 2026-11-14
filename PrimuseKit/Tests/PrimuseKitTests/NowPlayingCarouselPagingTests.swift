import Foundation
import Testing
@testable import PrimuseKit

@Suite("播放页转轮的翻页排布")
struct NowPlayingCarouselPagingTests {
    private typealias Paging = NowPlayingCarouselPagingPolicy

    @Test("换到相邻一页的那一刻画面不跳")
    func adjacentChangeKeepsPosition() {
        // 停在 2、往右挪开了 0.4 页时松手换到 3:位置仍是 2.4。
        let offset = Paging.offset(changingFrom: 2, to: 3, currentOffset: 0.4)
        #expect(abs(offset - -0.6) < 1e-9)
        #expect(abs((3 + offset) - 2.4) < 1e-9)
        // 往左同理。
        #expect(abs(Paging.offset(changingFrom: 2, to: 1, currentOffset: -0.3) - 0.7) < 1e-9)
        // 拖回原处不换页:偏移不变。
        #expect(Paging.offset(changingFrom: 2, to: 2, currentOffset: 0.2) == 0.2)
    }

    @Test("一次跳好几页只走一页宽,刚离开的那一页画在目标页旁边")
    func jumpTravelsOnePage() {
        // 从播放器(2)点转盘去 4:偏移从 -1 走到 0。
        let offset = Paging.offset(changingFrom: 2, to: 4, currentOffset: 0)
        #expect(offset == -1)
        // 刚离开的 2 排在 4 的左边一格,换页那一刻还正对着人。
        let slot = Paging.slot(pageIndex: 2, settledIndex: 4, departingIndex: 2)
        #expect(slot == -1)
        #expect(Paging.progress(slot: slot, offset: offset) == 0)
        // 目标页从右边一整页外进来。
        #expect(Paging.progress(slot: 0, offset: offset) == 1)
        // 往左跳同理。
        #expect(Paging.offset(changingFrom: 3, to: 0, currentOffset: 0) == 1)
        #expect(Paging.slot(pageIndex: 3, settledIndex: 0, departingIndex: 3) == 1)
        // 不是刚离开的那一页照实际距离排。
        #expect(Paging.slot(pageIndex: 1, settledIndex: 4, departingIndex: 2) == -3)
    }

    @Test("转盘跳页时按实际隔了几页走完全程")
    func dialFollowsWholeJump() {
        #expect(Paging.dialPosition(settledIndex: 4, offset: -1, departingIndex: 2) == 2)
        #expect(Paging.dialPosition(settledIndex: 4, offset: -0.5, departingIndex: 2) == 3)
        #expect(Paging.dialPosition(settledIndex: 4, offset: 0, departingIndex: 2) == 4)
        // 拖动中、相邻换页:就是停着的那一页加偏移。
        #expect(Paging.dialPosition(settledIndex: 2, offset: 0.25, departingIndex: nil) == 2.25)
        #expect(abs(Paging.dialPosition(settledIndex: 3, offset: -0.6, departingIndex: 2) - 2.4) < 1e-9)
    }

    @Test("整页移出去就不画,减弱动态效果时交叉淡入淡出")
    func visibility() {
        #expect(Paging.isOnScreen(progress: 0))
        #expect(Paging.isOnScreen(progress: -0.5))
        #expect(!Paging.isOnScreen(progress: 1))
        #expect(!Paging.isOnScreen(progress: -2))
        #expect(Paging.crossfadeOpacity(progress: 0) == 1)
        #expect(Paging.crossfadeOpacity(progress: 0.25) == 0.75)
        #expect(Paging.crossfadeOpacity(progress: -1.5) == 0)
    }

    @Test("两侧页底下那层玻璃跟着播放器移出去的程度显出来")
    func backdrop() {
        #expect(Paging.backdropAmount(playerProgress: 0) == 0)
        #expect(abs(Paging.backdropAmount(playerProgress: -0.4) - 0.4) < 1e-9)
        #expect(Paging.backdropAmount(playerProgress: 2) == 1)
    }

    @Test("停稳时挂预先挂好的页,拖动时相邻两页都挂上,换页途中原来预挂的不急着卸")
    func mountedPages() {
        // 停在播放器(2),还没预挂:只有它自己。
        #expect(Paging.mountedIndices(settledIndex: 2, departingIndex: nil, warmIndices: [], isDragging: false, pageCount: 5) == [2])
        // 预挂好了右边一页。
        #expect(Paging.mountedIndices(settledIndex: 2, departingIndex: nil, warmIndices: [3], isDragging: false, pageCount: 5) == [2, 3])
        // 拖动时两边都挂上。
        #expect(Paging.mountedIndices(settledIndex: 2, departingIndex: nil, warmIndices: [], isDragging: true, pageCount: 5) == [1, 2, 3])
        // 转到位途中刚离开的那一页还挂着。
        #expect(Paging.mountedIndices(settledIndex: 3, departingIndex: 2, warmIndices: [], isDragging: false, pageCount: 5) == [2, 3])
        // 从播放器翻到 3:原来预挂在 1 的那一页正往外走,先不卸。
        #expect(Paging.mountedIndices(settledIndex: 3, departingIndex: 2, warmIndices: [1, 3], isDragging: false, pageCount: 5) == [1, 2, 3])
        // 跳页途中只挂两头,预挂的相邻页先不挂。
        #expect(Paging.mountedIndices(settledIndex: 4, departingIndex: 2, warmIndices: [3], isDragging: false, pageCount: 5) == [2, 4])
        // 两端只有一边。
        #expect(Paging.neighborIndices(of: 0, pageCount: 5) == [1])
        #expect(Paging.neighborIndices(of: 4, pageCount: 5) == [3])
        #expect(Paging.neighborIndices(of: 0, pageCount: 1).isEmpty)
        // 越界不挂。
        #expect(Paging.mountedIndices(settledIndex: 7, departingIndex: nil, warmIndices: [], isDragging: true, pageCount: 5).isEmpty)
    }
}
