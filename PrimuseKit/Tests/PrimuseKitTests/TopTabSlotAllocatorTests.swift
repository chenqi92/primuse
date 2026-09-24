import Foundation
import Testing
@testable import PrimuseKit

@Suite("Top tab slot allocator")
struct TopTabSlotAllocatorTests {
    private typealias Allocator = TopTabSlotAllocator<String>

    @Test("槽位没满时每页各占一个,切回去还在原来的槽位")
    func pagesKeepTheirSlotWhileThereIsRoom() {
        var slots = Allocator(capacity: 3)
        let home = slots.select("home")
        let songs = slots.select("songs")
        let albums = slots.select("albums")
        let songsAgain = slots.select("songs")
        #expect(home == 0)
        #expect(songs == 1)
        #expect(albums == 2)
        #expect(songsAgain == 1)
        #expect(slots.selectedPage == "songs")
        #expect(slots.pages == ["home", "songs", "albums"])
    }

    @Test("槽位满了换掉最久没用的那一页")
    func evictsTheLeastRecentlyUsedPage() {
        var slots = Allocator(capacity: 3)
        slots.select("home")
        slots.select("songs")
        slots.select("albums")
        slots.select("home")
        // songs 最久没用。
        let slot = slots.select("radio")
        #expect(slot == 1)
        #expect(slots.pages == ["home", "radio", "albums"])
        #expect(slots.slot(of: "songs") == nil)
    }

    @Test("正在显示的那一页不会被换掉")
    func neverEvictsTheSelectedPage() {
        var slots = Allocator(capacity: 2)
        slots.select("home")
        slots.select("songs")
        slots.select("albums")
        #expect(slots.pages.contains("albums"))
        #expect(slots.slot(of: "home") == nil)
        #expect(slots.selectedPage == "albums")

        var single = Allocator(capacity: 1)
        single.select("home")
        let replaced = single.select("songs")
        #expect(replaced == 0)
        #expect(single.pages == ["songs"])
    }

    @Test("被隐藏的分类让出槽位;清掉的是当前页时告诉调用方")
    func retainClearsUnreachablePages() {
        var slots = Allocator(capacity: 3)
        slots.select("home")
        slots.select("songs")
        let keptSelection = slots.retain(["home", "songs", "albums"])
        #expect(!keptSelection)
        let clearedSelection = slots.retain(["home"])
        #expect(clearedSelection)
        #expect(slots.pages == ["home", nil, nil])
        #expect(slots.selectedPage == nil)
        // 空出来的槽位先给新页面用。
        let reused = slots.select("albums")
        #expect(reused == 1)
    }

    @Test("容量至少为一")
    func capacityHasAFloor() {
        let slots = Allocator(capacity: 0)
        #expect(slots.capacity == 1)
        #expect(slots.pages.count == 1)
    }
}
