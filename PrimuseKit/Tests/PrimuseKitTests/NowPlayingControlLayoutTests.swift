import Foundation
import Testing
@testable import PrimuseKit

@Suite struct NowPlayingControlLayoutTests {
    typealias Layout = NowPlayingControlLayout

    @Test func emptyOrGarbageStorageIsDefault() {
        #expect(Layout.decode("") == .default)
        #expect(Layout.decode("not json") == .default)
        #expect(Layout.default.encoded() == "")
        #expect(Layout.default.isDefault)
        #expect(Layout.default.actions == Layout.defaultActions)
        for item in NowPlayingStatusItem.allCases {
            #expect(Layout.default.showsStatusItem(item))
        }
    }

    @Test func placingAnUnplacedActionReplacesTheSlot() {
        let layout = Layout.default.placing(.sleepTimer, in: .barLeading)
        #expect(layout.action(in: .barLeading) == .sleepTimer)
        #expect(!layout.placedActions.contains(.lyrics))
        #expect(!layout.isDefault)
        #expect(Layout.decode(layout.encoded()) == layout)
    }

    @Test func placingAPlacedActionSwapsTheTwoSlots() {
        let layout = Layout.default.placing(.queue, in: .header)
        #expect(layout.action(in: .header) == .queue)
        #expect(layout.action(in: .barTrailing) == .like)
        // 换回去就回到默认,存成空串。
        let back = layout.placing(.like, in: .header)
        #expect(back.isDefault)
        #expect(back.encoded() == "")
    }

    @Test func airPlayCanMoveButNeverLeaveThePage() {
        let base = Layout.default
        #expect(!base.canPlace(nil, in: .barCenter))
        #expect(!base.canPlace(.sleepTimer, in: .barCenter))
        #expect(base.placing(.sleepTimer, in: .barCenter) == base)
        // 和页面上另一格对调可以。
        #expect(base.canPlace(.queue, in: .barCenter))
        let swapped = base.placing(.queue, in: .barCenter)
        #expect(swapped.action(in: .barTrailing) == .airPlay)
        // 换到两端不行:两端在手机横屏会让出来。
        #expect(!base.canPlace(.airPlay, in: .leadingEdge))
        #expect(!base.canPlace(.shuffle, in: .barCenter))
        // 自己挪到别的格可以。
        let moved = base.placing(.airPlay, in: .header)
        #expect(moved.action(in: .header) == .airPlay)
        #expect(moved.action(in: .barCenter) == .like)
    }

    @Test func slotsCanBeLeftEmpty() {
        let layout = Layout.default.placing(nil, in: .leadingEdge).placing(nil, in: .header)
        #expect(layout.action(in: .leadingEdge) == nil)
        #expect(layout.action(in: .header) == nil)
        let decoded = Layout.decode(layout.encoded())
        #expect(decoded == layout)
        #expect(decoded.action(in: .leadingEdge) == nil)
    }

    @Test func unknownActionsFromOtherVersionsSurviveUnrelatedEdits() {
        let raw = #"{"slots":{"barLeading":"futureThing"}}"#
        let layout = Layout.decode(raw)
        #expect(layout.action(in: .barLeading) == nil)
        let edited = layout.placing(.sleepTimer, in: .header)
        #expect(edited.encoded().contains("futureThing"))
        #expect(edited.action(in: .header) == .sleepTimer)
    }

    @Test func corruptStorageIsRepaired() {
        // 同一个按钮两格、隔空播放被拿掉又放进了两端。
        let raw = #"{"slots":{"header":"queue","barCenter":"sleepTimer","leadingEdge":"airPlay"}}"#
        let layout = Layout.decode(raw)
        #expect(layout.action(in: .header) == .queue)
        #expect(layout.action(in: .barTrailing) == nil || layout.action(in: .barTrailing) == .airPlay)
        #expect(layout.action(in: .leadingEdge) == nil)
        let airPlaySlot = layout.slot(of: .airPlay)
        #expect(airPlaySlot != nil)
        #expect(airPlaySlot?.isTransportEdge == false)
        let values = NowPlayingControlSlot.allCases.compactMap { layout.action(in: $0) }
        #expect(values.count == Set(values).count)
    }

    @Test func statusItemsToggleAndRoundTrip() {
        let layout = Layout.default.settingStatusItem(.source, visible: false)
        #expect(!layout.showsStatusItem(.source))
        #expect(layout.showsStatusItem(.output))
        #expect(!layout.isDefault)
        #expect(Layout.decode(layout.encoded()) == layout)
        #expect(layout.settingStatusItem(.source, visible: true).isDefault)
        // 恢复按钮不动状态行。
        let reset = layout.placing(.cast, in: .header).resettingActions()
        #expect(reset.actions == Layout.defaultActions)
        #expect(!reset.showsStatusItem(.source))
    }

    @Test func encodingIsStable() {
        let layout = Layout.default
            .placing(.equalizer, in: .header)
            .placing(.karaoke, in: .barLeading)
            .settingStatusItem(.output, visible: false)
            .settingStatusItem(.source, visible: false)
        let again = Layout.decode(layout.encoded())
        #expect(again.encoded() == layout.encoded())
    }

    // MARK: 各版面

    @Test func defaultLayoutKeepsTheOldMenuOnEverySurface() {
        let layout = Layout.default
        #expect(layout.menuFallback(on: .portrait).isEmpty)
        #expect(layout.menuSuppressed(on: .portrait).isEmpty)
        #expect(layout.menuFallback(on: .wideLandscape).isEmpty)
        #expect(layout.menuFallback(on: .compactLandscape(showsTransportEdges: true)).isEmpty)
        // 横屏右栏窄到摆不下两端时,随机与循环照旧补进「更多」。
        #expect(layout.menuFallback(on: .compactLandscape(showsTransportEdges: false)) == [.shuffle, .repeatMode])
        #expect(layout.menuFallback(on: .toolColumn(showsTransportEdges: false, headerOverflows: false)) == [.shuffle, .repeatMode])
        #expect(layout.menuFallback(on: .toolColumn(showsTransportEdges: true, headerOverflows: false)).isEmpty)
        // 竖栏放不下时心形收进「更多」(原来由竖栏自己补,现在走同一套兜底)。
        #expect(layout.menuFallback(on: .toolColumn(showsTransportEdges: true, headerOverflows: true)) == [.like])
        #expect(layout.menuFallback(on: .immersiveLyrics).isEmpty)
        #expect(layout.menuSuppressed(on: .immersiveLyrics).isEmpty)
        #expect(layout.menuSuppressed(on: .compactLandscape(showsTransportEdges: true)).isEmpty)
    }

    @Test func defaultLandscapeChromeMatchesTheOldRow() {
        let chrome = Layout.default.compactLandscapeChrome()
        #expect(chrome.leading == [.queue, .airPlay])
        #expect(chrome.trailing == .like)
        #expect(Layout.default.wideLandscapeBar() == [.airPlay, .queue])
    }

    @Test func removedPageOnlyActionsFallBackIntoTheMenu() {
        let layout = Layout.default
            .placing(.sleepTimer, in: .barTrailing)
            .placing(.equalizer, in: .header)
        #expect(layout.menuFallback(on: .portrait) == [.like, .queue])
        #expect(layout.menuSuppressed(on: .portrait) == [.sleepTimer, .equalizer])
        // 横屏歌词在右栏,歌词键拿掉也不用补。
        let noLyrics = Layout.default.placing(.karaoke, in: .barLeading)
        #expect(noLyrics.menuFallback(on: .portrait) == [.lyrics])
        #expect(noLyrics.menuFallback(on: .wideLandscape).isEmpty)
        #expect(noLyrics.menuFallback(on: .compactLandscape(showsTransportEdges: true)).isEmpty)
    }

    @Test func edgeActionsHiddenInNarrowLandscapeStayInTheMenu() {
        let layout = Layout.default.placing(.sleepTimer, in: .leadingEdge)
        #expect(layout.menuSuppressed(on: .portrait).contains(.sleepTimer))
        let narrow = NowPlayingControlSurface.compactLandscape(showsTransportEdges: false)
        #expect(!layout.menuSuppressed(on: narrow).contains(.sleepTimer))
        #expect(layout.menuFallback(on: narrow) == [.shuffle, .repeatMode])
    }

    @Test func landscapeChromeSkipsLyricsAndFullScreenAndKeepsAirPlayLast() {
        let layout = Layout.default
            .placing(.airPlay, in: .barLeading)
            .placing(.sleepTimer, in: .barCenter)
            .placing(.fullScreen, in: .header)
        let chrome = layout.compactLandscapeChrome()
        #expect(chrome.leading == [.sleepTimer, .queue, .airPlay])
        #expect(chrome.trailing == nil)
        #expect(layout.menuFallback(on: .compactLandscape(showsTransportEdges: true)) == [.like])
    }

    @Test func toolColumnAndImmersiveFollowTheLayout() {
        #expect(Layout.default.toolColumnGroups().middle == [.lyrics, .queue])
        #expect(Layout.default.toolColumnGroups().header == .like)
        #expect(Layout.default.immersiveLyricsAction() == .like)
        let layout = Layout.default
            .placing(.sleepTimer, in: .header)
            .placing(.karaoke, in: .barTrailing)
        #expect(layout.toolColumnGroups().middle == [.lyrics, .karaoke])
        #expect(layout.immersiveLyricsAction() == .sleepTimer)
        #expect(layout.menuFallback(on: .immersiveLyrics) == [.like])
        #expect(layout.menuSuppressed(on: .immersiveLyrics) == [.sleepTimer])
        let column = NowPlayingControlSurface.toolColumn(showsTransportEdges: true, headerOverflows: false)
        #expect(layout.menuFallback(on: column) == [.like, .queue])
        #expect(layout.menuSuppressed(on: column) == [.sleepTimer, .karaoke])
    }

    @Test func menuItemsCanBeHiddenAndRoundTrip() {
        #expect(Layout.default.hiddenMenuItems.isEmpty)
        let layout = Layout.default
            .settingMenuItem(.medley, visible: false)
            .settingMenuItem(.karaoke, visible: false)
        #expect(!layout.showsMenuItem(.medley))
        #expect(!layout.showsMenuItem(.karaoke))
        #expect(layout.showsMenuItem(.share))
        #expect(layout.hiddenMenuItems == [.medley, .karaoke])
        #expect(!layout.isDefault)
        let decoded = Layout.decode(layout.encoded())
        #expect(decoded == layout)
        // 换按钮不影响菜单的显隐,全部显示回来就是默认。
        #expect(decoded.placing(.sleepTimer, in: .header).hiddenMenuItems == [.medley, .karaoke])
        #expect(layout.showingAllMenuItems().isDefault)
        // 别的版本写进来的菜单项名字原样保留。
        let future = Layout.decode(#"{"hiddenMenu":["futureItem","medley"]}"#)
        #expect(future.hiddenMenuItems == [.medley])
        #expect(future.settingMenuItem(.share, visible: false).encoded().contains("futureItem"))
    }
}
