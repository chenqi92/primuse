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
        // 目录常驻时只去掉目录块,书签开关关着就不出来(#320)。
        #expect(podcast.visibleTiles(contentsResident: true) == [.speed, .sleepTimer, .upNext])

        for kind in SpokenWordPlayerKind.allCases {
            let layout = Layout.default(for: kind)
            #expect(layout.encoded() == "")
            #expect(Layout.decode("", kind: kind) == layout)
            #expect(Layout.decode("garbage", kind: kind) == layout)
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
        #expect(decoded.order == [.contents, .speed, .sleepTimer, .bookmark, .airPlay, .transcript, .like, .more])
    }

    @Test func userHiddenEntriesFallBackIntoTheMenu() {
        let book = Layout.default(for: .audiobook)
            .settingTile(.bookmark, shown: false)
            .settingShowsLike(false)
            .settingShowsTranscriptToggle(false)
        let bookContext = SpokenWordControlContext(hasTranscript: true, hasPartRow: true)
        #expect(book.menuFallback(for: book.resolved(in: bookContext), context: bookContext) == [.like, .transcript, .bookmark])

        let podcast = Layout.default(for: .podcast).settingTile(.upNext, shown: false)
        let podcastContext = SpokenWordControlContext(hasTranscript: false, hasInnerChapterPair: true)
        let podcastFallback = podcast.menuFallback(for: podcast.resolved(in: podcastContext), context: podcastContext)
        #expect(podcastFallback == [.upNext])
        // 播客的书签默认就不在页面上,不补。
        #expect(!podcastFallback.contains(.bookmark))
        // 没有功能块的版面(手机横屏)只补喜欢。
        let landscape = SpokenWordControlContext(hasTranscript: true, hasTiles: false)
        #expect(book.menuFallback(for: book.resolved(in: landscape), context: landscape) == [.like])
    }

    @Test func tilesFollowTheTogglesWhenContentsMovesAway() {
        // 目录常驻时只去掉目录块,不拿书签补位。
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

    @Test func menuItemsCanBeHiddenAndRoundTrip() {
        for kind in SpokenWordPlayerKind.allCases {
            #expect(Layout.default(for: kind).hiddenMenuItems.isEmpty)
        }
        let layout = Layout.default(for: .audiobook)
            .settingMenuItem(.goToBook, visible: false)
            .settingMenuItem(.equalizer, visible: false)
        #expect(!layout.showsMenuItem(.goToBook))
        #expect(!layout.showsMenuItem(.equalizer))
        #expect(layout.showsMenuItem(.share))
        #expect(layout.hiddenMenuItems == [.goToBook, .equalizer])
        #expect(!layout.isDefault)
        // 功能块的摆法没动,菜单项单独存。
        #expect(layout.tilesAreDefault)
        let decoded = Layout.decode(layout.encoded(), kind: .audiobook)
        #expect(decoded == layout)
        // 先关哪一项,编出来都是同一个字符串。
        let reversed = Layout.default(for: .audiobook)
            .settingMenuItem(.equalizer, visible: false)
            .settingMenuItem(.goToBook, visible: false)
        #expect(reversed.encoded() == layout.encoded())
        // 改功能块不影响菜单的显隐,全部显示回来就是默认。
        #expect(decoded.settingTile(.bookmark, shown: false).hiddenMenuItems == [.goToBook, .equalizer])
        #expect(layout.settingMenuItem(.goToBook, visible: true).hiddenMenuItems == [.equalizer])
        #expect(layout.showingAllMenuItems().isDefault)
        // 别的版本写进来的菜单项名字原样保留。
        let future = Layout.decode(#"{"hiddenMenu":["futureItem","sleepTimer"]}"#, kind: .podcast)
        #expect(future.hiddenMenuItems == [.sleepTimer])
        #expect(future.settingMenuItem(.share, visible: false).encoded().contains("futureItem"))
        let context = SpokenWordControlContext(hasTranscript: false, hasInnerChapterPair: true)
        #expect(future.menuFallback(for: future.resolved(in: context), context: context).isEmpty)
    }

    @Test func tileLabelStyleRoundTripsAndDefaultsToText() {
        for kind in SpokenWordPlayerKind.allCases {
            #expect(Layout.default(for: kind).tileLabelStyle == .iconAndText)
        }
        let layout = Layout.default(for: .podcast).settingTileLabelStyle(.iconOnly)
        #expect(!layout.isDefault)
        #expect(layout.tilesAreDefault)
        #expect(layout.encoded().contains("iconOnly"))
        #expect(Layout.decode(layout.encoded(), kind: .podcast) == layout)
        #expect(layout.settingTileLabelStyle(.iconAndText).isDefault)
        // 别的版本新加的写法这台设备认不出,按默认。
        #expect(Layout.decode(#"{"labelStyle":"hologram"}"#, kind: .podcast).tileLabelStyle == .iconAndText)
    }

    @Test func moveMatchesListSemantics() {
        let layout = Layout.default(for: .podcast)
        // 把第一块拖到最后。
        let moved = layout.movingTiles(fromOffsets: IndexSet(integer: 0), toOffset: layout.order.count)
        #expect(moved.order.last == .speed)
        #expect(moved.order.first == .sleepTimer)
    }
}

@Suite struct SpokenWordControlSlotTests {
    typealias Layout = SpokenWordControlLayout
    typealias Context = SpokenWordControlContext

    /// 有声书竖版:章节那一行在,两侧外面没有那一对上一章 / 下一章。
    static func bookPortrait(transcript: Bool, collapsed: Bool = false) -> Context {
        Context(hasTranscript: transcript, hasPartRow: true, controlsCollapsed: collapsed)
    }

    /// 播客竖版:紧挨快退快进有一对上一章 / 下一章。
    static func genericPortrait(transcript: Bool) -> Context {
        Context(hasTranscript: transcript, hasInnerChapterPair: true)
    }

    @Test func automaticSlotsMatchTheOldPlayers() {
        let book = Layout.default(for: .audiobook)
        #expect(book.slotsAreAutomatic)
        // 有文字稿:左文字稿、右目录,功能块不再摆目录;章节那一行是上一章 / 下一章。
        let withText = book.resolved(in: Self.bookPortrait(transcript: true))
        #expect(withText.leadingSide == .transcript)
        #expect(withText.trailingSide == .contents)
        #expect(withText.partRow == .chapters)
        #expect(withText.tiles == [.speed, .sleepTimer, .bookmark])
        #expect(withText.headerShowsAirPlay && withText.headerShowsLike && withText.headerShowsMore)
        // 没有文字稿:两侧空着、不占位,目录回到功能块。
        let plain = book.resolved(in: Self.bookPortrait(transcript: false))
        #expect(plain.leadingSide == nil && plain.trailingSide == nil)
        #expect(!plain.hasSideKeys)
        #expect(plain.tiles == [.speed, .sleepTimer, .bookmark, .contents])

        // 播客竖版有文字稿:外侧文字稿与说明,里面那一对上一章 / 下一章照旧;说明挪走后剩下的平均排开,
        // 不拿默认关着的书签补位(#320)。
        let podcast = Layout.default(for: .podcast).resolved(in: Self.genericPortrait(transcript: true))
        #expect(podcast.leadingSide == .transcript && podcast.trailingSide == .contents)
        #expect(podcast.showsInnerChapters)
        #expect(podcast.tiles == [.speed, .sleepTimer, .upNext])
        // 手机横屏:两侧在没有文字稿时放上一章 / 下一章。
        let landscape = Layout.default(for: .podcast).resolved(in: Context(hasTranscript: false, hasTiles: false))
        #expect(landscape.leadingSide == .chapters && landscape.trailingSide == .chapters)
        #expect(landscape.tiles.isEmpty)

        for kind in SpokenWordPlayerKind.allCases {
            for transcript in [true, false] {
                for context in [Self.bookPortrait(transcript: transcript), Self.genericPortrait(transcript: transcript)] {
                    let layout = Layout.default(for: kind)
                    #expect(layout.menuFallback(for: layout.resolved(in: context), context: context).isEmpty)
                }
            }
        }
    }

    @Test func hiddenContentsStaysHiddenNextToTheTranscript() {
        // #283:关了目录,有文字稿时右边那一格不再放目录。
        let book = Layout.default(for: .audiobook).settingTile(.contents, shown: false)
        let resolved = book.resolved(in: Self.bookPortrait(transcript: true))
        #expect(resolved.leadingSide == .transcript)
        #expect(resolved.trailingSide == nil)
        #expect(resolved.hasSideKeys)
        #expect(!resolved.tiles.contains(.contents))
    }

    @Test func hiddenTranscriptKeyLeavesTheContentsAlone() {
        // #283:关了文字稿键,目录回到功能块,不跟着一起消失。
        let book = Layout.default(for: .audiobook).settingShowsTranscriptToggle(false)
        let resolved = book.resolved(in: Self.bookPortrait(transcript: true))
        #expect(resolved.leadingSide == nil && resolved.trailingSide == nil)
        #expect(resolved.tiles.contains(.contents))
        #expect(book.menuFallback(for: resolved, context: Self.bookPortrait(transcript: true)) == [.transcript])
        // 明确放进格子的目录照样在。
        let placed = book.placing(.action(.contents), in: .trailingSide)
        #expect(placed.resolved(in: Self.bookPortrait(transcript: true)).trailingSide == .contents)
    }

    @Test func explicitButtonsFillTheEmptySides() {
        // 播客关了上一章 / 下一章,两侧换成语速与定时:紧挨快退快进,功能块不再重复。
        let podcast = Layout.default(for: .podcast)
            .settingShowsChapterButtons(false)
            .placing(.action(.speed), in: .leadingSide)
            .placing(.action(.sleepTimer), in: .trailingSide)
        let resolved = podcast.resolved(in: Self.genericPortrait(transcript: false))
        #expect(resolved.leadingSide == .speed && resolved.trailingSide == .sleepTimer)
        #expect(!resolved.showsInnerChapters)
        #expect(resolved.tiles == [.contents, .upNext])
        #expect(podcast.menuFallback(for: resolved, context: Self.genericPortrait(transcript: false)).isEmpty)
        #expect(Layout.decode(podcast.encoded(), kind: .podcast) == podcast)
        #expect(podcast.resettingSlots().slotsAreAutomatic)
    }

    @Test func moreAndLikeLeaveTheHeaderWhenPlaced() {
        // #283:「更多」挪到章节那一行(原来上一章 / 下一章的位置)。
        let book = Layout.default(for: .audiobook).placing(.action(.more), in: .partRow)
        let resolved = book.resolved(in: Self.bookPortrait(transcript: false))
        #expect(resolved.partRow == .more)
        #expect(!resolved.headerShowsMore)
        // 横屏等没有章节那一行的版面,「更多」回到右上角。
        let landscape = book.resolved(in: Context(hasTranscript: false, hasTiles: false))
        #expect(landscape.headerShowsMore)
        // 上滑文字稿收起控件时,右上角那一组全回来。
        let collapsed = book.resolved(in: Self.bookPortrait(transcript: true, collapsed: true))
        #expect(collapsed.headerShowsMore && collapsed.partRow == nil && collapsed.tiles.isEmpty)

        let liked = Layout.default(for: .audiobook).placing(.action(.like), in: .leadingSide)
        let likedResolved = liked.resolved(in: Self.bookPortrait(transcript: false))
        #expect(likedResolved.leadingSide == .like && !likedResolved.headerShowsLike)
        #expect(liked.menuFallback(for: likedResolved, context: Self.bookPortrait(transcript: false)).isEmpty)
        // 播客没有章节那一行,书没有「接下来」。
        let podcast = Layout.default(for: .podcast)
        #expect(podcast.placing(.action(.more), in: .partRow) == podcast)
        #expect(Layout.default(for: .audiobook).placing(.action(.upNext), in: .leadingSide) == Layout.default(for: .audiobook))
    }

    @Test func airPlayMovesIntoTheTiles() {
        let book = Layout.default(for: .audiobook)
        #expect(!book.isShown(.airPlay))
        let moved = book.settingTile(.airPlay, shown: true)
        let resolved = moved.resolved(in: Self.bookPortrait(transcript: false))
        #expect(resolved.tiles.last == .airPlay)
        #expect(!resolved.headerShowsAirPlay)
        // 没有功能块的版面隔空播放还在右上角。
        #expect(moved.resolved(in: Context(hasTranscript: false, hasTiles: false)).headerShowsAirPlay)
        #expect(Layout.decode(moved.encoded(), kind: .audiobook) == moved)
        // 老配置里没有隔空播放这一块:照默认留在右上角。
        let old = Layout.decode(#"{"order":["contents","speed","sleepTimer","bookmark"]}"#, kind: .audiobook)
        #expect(!old.isShown(.airPlay))
    }

    @Test func placingSwapsAndDeduplicates() {
        let book = Layout.default(for: .audiobook)
            .placing(.action(.bookmark), in: .leadingSide)
            .placing(.action(.speed), in: .trailingSide)
        // 书签换到右边:右边原来的语速对调到左边。
        let swapped = book.placing(.action(.bookmark), in: .trailingSide)
        #expect(swapped.choice(in: .leadingSide) == .action(.speed))
        #expect(swapped.choice(in: .trailingSide) == .action(.bookmark))
        // 上一章 / 下一章两侧各放一颗不算重复,章节那一行就不再放。
        let chapters = Layout.default(for: .audiobook)
            .placing(.action(.chapters), in: .leadingSide)
            .placing(.action(.chapters), in: .trailingSide)
        #expect(chapters.choice(in: .leadingSide) == .action(.chapters))
        let resolved = chapters.resolved(in: Self.bookPortrait(transcript: false))
        #expect(resolved.leadingSide == .chapters && resolved.trailingSide == .chapters)
        #expect(resolved.partRow == nil)
        // 明确选了文字稿,这一条没有文字稿时那一格空着。
        let text = Layout.default(for: .audiobook).placing(.action(.transcript), in: .leadingSide)
        #expect(text.resolved(in: Self.bookPortrait(transcript: false)).leadingSide == nil)
        // 空着与自动分得开,认不出的按钮当空着。
        let empty = Layout.default(for: .audiobook).placing(.empty, in: .partRow)
        #expect(empty.resolved(in: Self.bookPortrait(transcript: false)).partRow == nil)
        #expect(Layout.decode(empty.encoded(), kind: .audiobook).choice(in: .partRow) == .empty)
        let future = Layout.decode(#"{"slots":{"leadingSide":"hologram","futureSlot":"more"}}"#, kind: .audiobook)
        #expect(future.choice(in: .leadingSide) == .empty)
        #expect(future.settingShowsLike(false).encoded().contains("futureSlot"))
    }

    @Test func podcastTogglesMatchThePage() {
        // #320:有文字稿的播客关掉语速,书签不跟着消失;书签开关开、关看得出区别。
        let context = Self.genericPortrait(transcript: true)
        let noSpeed = Layout.default(for: .podcast).settingTile(.speed, shown: false)
        #expect(noSpeed.resolved(in: context).tiles == [.sleepTimer, .upNext])
        let withBookmark = Layout.default(for: .podcast).settingTile(.bookmark, shown: true)
        #expect(withBookmark.resolved(in: context).tiles == [.speed, .sleepTimer, .bookmark, .upNext])
        #expect(withBookmark.settingTile(.speed, shown: false).resolved(in: context).tiles
            == [.sleepTimer, .bookmark, .upNext])
    }

    @Test func headerAndSideKeysMoveIntoTheTiles() {
        let book = Layout.default(for: .audiobook)
        for tile in [SpokenWordControlTile.transcript, .like, .more] {
            #expect(!book.isShown(tile))
        }
        // 播客也有这几块,默认同样关着。
        let podcast = Layout.default(for: .podcast)
        #expect(podcast.order.contains(.like) && !podcast.isShown(.like) && !podcast.isShown(.more))

        let moved = book
            .settingTile(.like, shown: true)
            .settingTile(.more, shown: true)
            .settingTile(.transcript, shown: true)
        let resolved = moved.resolved(in: Self.bookPortrait(transcript: true))
        #expect(resolved.tiles == [.speed, .sleepTimer, .bookmark, .contents, .transcript, .like, .more])
        #expect(!resolved.headerShowsLike && !resolved.headerShowsMore)
        // 文字稿键挪到下面了,左边那一格按没有文字稿摆,目录也回到下面那一排。
        #expect(resolved.leadingSide == nil && resolved.trailingSide == nil)
        #expect(moved.menuFallback(for: resolved, context: Self.bookPortrait(transcript: true)).isEmpty)
        #expect(Layout.decode(moved.encoded(), kind: .audiobook) == moved)

        // 这一条没有文字稿:文字稿那一块不出现。
        #expect(!moved.resolved(in: Self.bookPortrait(transcript: false)).tiles.contains(.transcript))
        // 没有那一排的版面(手机横屏),喜欢、更多回到右上角,文字稿回到两侧。
        let landscape = moved.resolved(in: Context(hasTranscript: true, hasTiles: false))
        #expect(landscape.headerShowsLike && landscape.headerShowsMore)
        #expect(landscape.leadingSide == .transcript)
        // 明确摆进格子的优先,下面那一排不再重复。
        let slotted = moved.placing(.action(.like), in: .leadingSide)
        let slottedResolved = slotted.resolved(in: Self.bookPortrait(transcript: false))
        #expect(slottedResolved.leadingSide == .like)
        #expect(!slottedResolved.tiles.contains(.like))
    }

    @Test func oldConfigsKeepTheNewTilesWhereTheyWere() {
        // 老版本存的配置里没有文字稿、喜欢、更多这几块:照默认留在原处。
        let old = Layout.decode(#"{"order":["contents","speed","sleepTimer","bookmark","airPlay"],"hidden":["bookmark"]}"#, kind: .audiobook)
        #expect(old.order.suffix(3) == [.transcript, .like, .more])
        #expect(!old.isShown(.transcript) && !old.isShown(.like) && !old.isShown(.more))
        #expect(old.visibleTiles() == [.contents, .speed, .sleepTimer, .airPlay])
    }

    @Test func sourceLineToggleRoundTrips() {
        let book = Layout.default(for: .audiobook).settingShowsSource(false)
        #expect(!book.showsSource)
        #expect(!book.isDefault)
        #expect(Layout.decode(book.encoded(), kind: .audiobook) == book)
        #expect(book.settingShowsSource(true).isDefault)
    }
}
