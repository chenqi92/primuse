import Foundation
import Testing
@testable import PrimuseKit

@Suite struct SpokenWordControlLayoutTests {
    typealias Layout = SpokenWordControlLayout

    @Test func defaultsMatchTheOldPlayers() {
        let book = Layout.default(for: .audiobook)
        #expect(book.visibleTiles() == [.speed, .sleepTimer, .bookmark, .contents])
        // iPad 横屏目录常驻右栏:不摆目录块。
        #expect(book.visibleTiles(contentsResident: true) == [.speed, .sleepTimer, .bookmark])
        #expect(!book.order.contains(.upNext))

        let podcast = Layout.default(for: .podcast)
        #expect(podcast.visibleTiles() == [.speed, .sleepTimer, .contents, .upNext])
        // 目录常驻时那一格让给书签,和原来一样。
        #expect(podcast.visibleTiles(contentsResident: true) == [.speed, .sleepTimer, .bookmark, .upNext])

        for kind in SpokenWordPlayerKind.allCases {
            let layout = Layout.default(for: kind)
            #expect(layout.encoded() == "")
            #expect(Layout.decode("", kind: kind) == layout)
            #expect(Layout.decode("garbage", kind: kind) == layout)
            #expect(layout.menuFallback().isEmpty)
            #expect(layout.menuFallback(contentsResident: true).isEmpty)
            #expect(layout.showsLike && layout.showsTranscriptToggle && layout.showsChapterButtons)
        }
    }

    @Test func hidingAndReorderingRoundTrips() {
        let layout = Layout.default(for: .audiobook)
            .settingTile(.bookmark, shown: false)
            .movingTiles(fromOffsets: IndexSet(integer: 3), toOffset: 0)
            .settingShowsLike(false)
        #expect(layout.visibleTiles() == [.contents, .speed, .sleepTimer])
        #expect(!layout.showsLike)
        let decoded = Layout.decode(layout.encoded(), kind: .audiobook)
        #expect(decoded == layout)
        #expect(decoded.order == [.contents, .speed, .sleepTimer, .bookmark])
    }

    @Test func userHiddenEntriesFallBackIntoTheMenu() {
        let book = Layout.default(for: .audiobook)
            .settingTile(.bookmark, shown: false)
            .settingShowsLike(false)
            .settingShowsTranscriptToggle(false)
        #expect(book.menuFallback() == [.like, .transcript, .bookmark])

        let podcast = Layout.default(for: .podcast).settingTile(.upNext, shown: false)
        #expect(podcast.menuFallback() == [.upNext])
        // 播客的书签默认就不在页面上,不补。
        #expect(!podcast.menuFallback().contains(.bookmark))
    }

    @Test func customizedTilesDoNotGetTheBookmarkSwap() {
        // 用户自己藏了书签:目录常驻时只去掉目录块,不把书签换回来。
        let book = Layout.default(for: .audiobook).settingTile(.bookmark, shown: false)
        #expect(book.visibleTiles(contentsResident: true) == [.speed, .sleepTimer])
        let podcast = Layout.default(for: .podcast).movingTiles(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        #expect(podcast.visibleTiles(contentsResident: true) == [.upNext, .speed, .sleepTimer])
    }

    @Test func unknownAndMissingTilesAreRepaired() {
        let raw = #"{"order":["contents","future","contents","speed"],"hidden":["gone","speed"]}"#
        let book = Layout.decode(raw, kind: .audiobook)
        #expect(book.order.first == .contents)
        #expect(Set(book.order) == Set(Layout.defaultOrder(for: .audiobook)))
        #expect(book.order.count == Layout.defaultOrder(for: .audiobook).count)
        #expect(!book.isShown(.speed))
        // 书没有「接下来」。
        let upNextRaw = #"{"order":["upNext","speed"]}"#
        #expect(!Layout.decode(upNextRaw, kind: .audiobook).order.contains(.upNext))
        // 老配置里没有书签这一项时,播客照默认把它藏起来。
        let podcast = Layout.decode(#"{"order":["speed","sleepTimer","contents","upNext"]}"#, kind: .podcast)
        #expect(!podcast.isShown(.bookmark))
    }

    @Test func moveMatchesListSemantics() {
        let layout = Layout.default(for: .podcast)
        // 把第一块拖到最后。
        let moved = layout.movingTiles(fromOffsets: IndexSet(integer: 0), toOffset: layout.order.count)
        #expect(moved.order.last == .speed)
        #expect(moved.order.first == .sleepTimer)
    }
}
