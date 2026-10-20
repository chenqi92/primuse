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
        #expect(Layout.default.bar == [.lyrics, .airPlay, .queue])
        for item in NowPlayingStatusItem.allCases {
            #expect(Layout.default.showsStatusItem(item))
        }
    }

    @Test func placingAnUnplacedActionReplacesTheBarButton() {
        let layout = Layout.default.placing(.sleepTimer, at: .bar(0))
        #expect(layout.bar == [.sleepTimer, .airPlay, .queue])
        #expect(!layout.placedActions.contains(.lyrics))
        #expect(!layout.isDefault)
        #expect(Layout.decode(layout.encoded()) == layout)
    }

    @Test func placingAPlacedActionSwapsTheTwoPlaces() {
        let layout = Layout.default.placing(.queue, at: .slot(.header))
        #expect(layout.action(in: .header) == .queue)
        #expect(layout.bar == [.lyrics, .airPlay, .like])
        // 换回去就回到默认,存成空串。
        let back = layout.placing(.like, at: .slot(.header))
        #expect(back.isDefault)
        #expect(back.encoded() == "")
        // 一排里两颗对调。
        let swapped = Layout.default.placing(.queue, at: .bar(0))
        #expect(swapped.bar == [.queue, .airPlay, .lyrics])
    }

    @Test func barGrowsShrinksAndReorders() {
        let grown = Layout.default
            .placing(.sleepTimer, at: .bar(3))
            .placing(.equalizer, at: .bar(4))
        #expect(grown.bar == [.lyrics, .airPlay, .queue, .sleepTimer, .equalizer])
        #expect(Layout.decode(grown.encoded()) == grown)
        // 从单格挪过来:原处空着。
        let moved = grown.placing(.like, at: .bar(5))
        #expect(moved.bar.last == .like)
        #expect(moved.action(in: .header) == nil)
        // 已经在这一排里的添到最后就是挪到最后。
        #expect(grown.placing(.lyrics, at: .bar(5)).bar == [.airPlay, .queue, .sleepTimer, .equalizer, .lyrics])
        // 拿掉一颗,其余往前靠。
        let removed = grown.placing(nil, at: .bar(0))
        #expect(removed.bar == [.airPlay, .queue, .sleepTimer, .equalizer])
        #expect(!removed.canPlace(nil, at: .bar(9)))
        #expect(!removed.canPlace(.share, at: .bar(9)))
        // 挪顺序。
        let reordered = grown.movingBar(fromOffsets: [4], toOffset: 0)
        #expect(reordered.bar == [.equalizer, .lyrics, .airPlay, .queue, .sleepTimer])
        #expect(Layout.decode(reordered.encoded()) == reordered)
        // 挪回默认那一串就存成空串。
        let shrunk = grown.placing(nil, at: .bar(4)).placing(nil, at: .bar(3))
        #expect(shrunk.isDefault)
        #expect(shrunk.encoded() == "")
    }

    @Test func barCanBeEmptiedWhenAirPlayLivesInTheHeader() {
        var layout = Layout.default.placing(.airPlay, at: .slot(.header))
        #expect(layout.bar == [.lyrics, .like, .queue])
        layout = layout.placing(nil, at: .bar(0)).placing(nil, at: .bar(0)).placing(nil, at: .bar(0))
        #expect(layout.bar.isEmpty)
        let decoded = Layout.decode(layout.encoded())
        #expect(decoded == layout)
        #expect(decoded.bar.isEmpty)
        #expect(decoded.action(in: .header) == .airPlay)
    }

    @Test func airPlayCanMoveButNeverLeaveThePage() {
        let base = Layout.default
        #expect(!base.canPlace(nil, at: .bar(1)))
        #expect(!base.canPlace(.sleepTimer, at: .bar(1)))
        #expect(base.placing(.sleepTimer, at: .bar(1)) == base)
        // 和页面上另一处对调可以。
        #expect(base.canPlace(.queue, at: .bar(1)))
        #expect(base.placing(.queue, at: .bar(1)).bar == [.lyrics, .queue, .airPlay])
        #expect(base.canPlace(.like, at: .bar(1)))
        let toHeader = base.placing(.like, at: .bar(1))
        #expect(toHeader.action(in: .header) == .airPlay)
        // 换到两端不行:两端在手机横屏会让出来。
        #expect(!base.canPlace(.airPlay, at: .slot(.leadingEdge)))
        #expect(!base.canPlace(.shuffle, at: .bar(1)))
        // 自己挪到别处可以。
        let moved = base.placing(.airPlay, at: .slot(.header))
        #expect(moved.action(in: .header) == .airPlay)
        #expect(moved.bar == [.lyrics, .like, .queue])
        #expect(base.placing(.airPlay, at: .bar(3)).bar == [.lyrics, .queue, .airPlay])
        // 歌名旁是隔空播放时,只有从这一排换上来的才能顶替它。
        #expect(!moved.canPlace(nil, at: .slot(.header)))
        #expect(!moved.canPlace(.share, at: .slot(.header)))
        #expect(moved.canPlace(.queue, at: .slot(.header)))
        // 旧版底栏那三个名字不是位置。
        #expect(!base.canPlace(.share, at: .slot(.barLeading)))
    }

    @Test func slotsCanBeLeftEmpty() {
        let layout = Layout.default.placing(nil, at: .slot(.leadingEdge)).placing(nil, at: .slot(.header))
        #expect(layout.action(in: .leadingEdge) == nil)
        #expect(layout.action(in: .header) == nil)
        let decoded = Layout.decode(layout.encoded())
        #expect(decoded == layout)
        #expect(decoded.action(in: .leadingEdge) == nil)
    }

    @Test func unknownActionsFromOtherVersionsSurviveUnrelatedEdits() {
        let raw = #"{"slots":{"header":"futureThing"}}"#
        let layout = Layout.decode(raw)
        #expect(layout.action(in: .header) == nil)
        let edited = layout.placing(.sleepTimer, at: .slot(.leadingEdge))
        #expect(edited.encoded().contains("futureThing"))
        #expect(edited.action(in: .leadingEdge) == .sleepTimer)
        // 这一排里认不出的名字留在原位,换别的、挪顺序都不抹掉。
        let future = Layout.decode(#"{"bar":["lyrics","futureThing","airPlay","queue"]}"#)
        #expect(future.bar == [.lyrics, .airPlay, .queue])
        #expect(!future.isDefault)
        #expect(future.encoded().contains("futureThing"))
        let replaced = future.placing(.share, at: .bar(2))
        #expect(replaced.bar == [.lyrics, .airPlay, .share])
        #expect(replaced.encoded().contains("futureThing"))
        let reordered = future.movingBar(fromOffsets: [0], toOffset: 3)
        #expect(reordered.bar == [.airPlay, .queue, .lyrics])
        #expect(reordered.encoded().contains("futureThing"))
    }

    @Test func oldVersionConfigsReadIntoTheBarAndOldVersionsSeeTheFirstThree() {
        // 旧版本写的:左边换成定时,中间故意空着(隔空播放挪到了歌名旁)。
        let legacy = Layout.decode(#"{"slots":{"barLeading":"sleepTimer","barCenter":"","header":"airPlay"}}"#)
        #expect(legacy.bar == [.sleepTimer, .queue])
        #expect(legacy.action(in: .header) == .airPlay)
        // 只改单格时旧版三格原样留着。
        let edited = legacy.placing(nil, at: .slot(.leadingEdge))
        #expect(edited.bar == [.sleepTimer, .queue])
        // 存了整串之后,旧版三格照这一串写:旧版本读到的和以前一样分在两头。
        let grown = legacy.placing(.share, at: .bar(2)).placing(.karaoke, at: .bar(3))
        let encoded = grown.encoded()
        #expect(encoded.contains(#""bar":["sleepTimer","queue","share","karaoke"]"#))
        #expect(encoded.contains(#""barLeading":"sleepTimer""#))
        #expect(encoded.contains(#""barCenter":"queue""#))
        #expect(encoded.contains(#""barTrailing":"share""#))
        let two = Layout.default.placing(nil, at: .bar(0)).encoded()
        #expect(two.contains(#""barLeading":"airPlay""#))
        #expect(two.contains(#""barCenter":"""#))
        #expect(two.contains(#""barTrailing":"queue""#))
        // 读回来不看那三格。
        #expect(Layout.decode(encoded) == grown)
    }

    @Test func corruptStorageIsRepaired() {
        // 同一个按钮两处、隔空播放被拿掉又放进了两端。
        let raw = #"{"slots":{"header":"queue","leadingEdge":"airPlay"},"bar":["lyrics","sleepTimer","queue","sleepTimer"]}"#
        let layout = Layout.decode(raw)
        #expect(layout.action(in: .header) == .queue)
        #expect(layout.action(in: .leadingEdge) == nil)
        #expect(layout.bar == [.lyrics, .airPlay, .sleepTimer])
        guard case .bar = layout.position(of: .airPlay) else {
            Issue.record("AirPlay should be back in the bar")
            return
        }
        let values = NowPlayingControlSlot.single.compactMap { layout.action(in: $0) } + layout.bar
        #expect(values.count == Set(values).count)
        // 旧版三格里丢了隔空播放:补回正中。
        let legacy = Layout.decode(#"{"slots":{"barCenter":"sleepTimer"}}"#)
        #expect(legacy.bar == [.lyrics, .airPlay, .sleepTimer, .queue])
    }

    @Test func statusItemsToggleAndRoundTrip() {
        let layout = Layout.default.settingStatusItem(.source, visible: false)
        #expect(!layout.showsStatusItem(.source))
        #expect(layout.showsStatusItem(.output))
        #expect(!layout.isDefault)
        #expect(Layout.decode(layout.encoded()) == layout)
        #expect(layout.settingStatusItem(.source, visible: true).isDefault)
        // 恢复按钮不动状态行。
        let reset = layout.placing(.cast, at: .slot(.header)).placing(.share, at: .bar(3)).resettingActions()
        #expect(reset.actions == Layout.defaultActions)
        #expect(reset.bar == Layout.defaultBar)
        #expect(reset.buttonsAreDefault)
        #expect(!reset.showsStatusItem(.source))
    }

    @Test func encodingIsStable() {
        let layout = Layout.default
            .placing(.equalizer, at: .slot(.header))
            .placing(.karaoke, at: .bar(0))
            .placing(.dislike, at: .bar(3))
            .settingStatusItem(.output, visible: false)
            .settingStatusItem(.source, visible: false)
        let again = Layout.decode(layout.encoded())
        #expect(again.encoded() == layout.encoded())
        #expect(again == layout)
    }

    // MARK: 一排摆几颗

    @Test func capacityFollowsTheScreenWidth() {
        #expect(NowPlayingBarMetrics.capacity(forWidth: 375) == 6)
        #expect(NowPlayingBarMetrics.capacity(forWidth: 393) == 6)
        #expect(NowPlayingBarMetrics.capacity(forWidth: 402) == 7)
        #expect(NowPlayingBarMetrics.capacity(forWidth: 440) == 7)
        #expect(NowPlayingBarMetrics.capacity(forWidth: 320) == 5)
        #expect(NowPlayingBarMetrics.capacity(forWidth: 1024) == NowPlayingBarMetrics.maximumCount)
        #expect(NowPlayingBarMetrics.capacity(forWidth: 0) == 1)
    }

    @Test func centersKeepTheOldThreeAndSpreadTheRest() {
        // 三颗和原来一样:两头收进 46,左中右。
        #expect(NowPlayingBarMetrics.centers(count: 3, width: 393) == [68, 196.5, 325])
        #expect(NowPlayingBarMetrics.centers(count: 1, width: 393) == [196.5])
        #expect(NowPlayingBarMetrics.centers(count: 2, width: 393) == [68, 325])
        #expect(NowPlayingBarMetrics.centers(count: 2, width: 400, pair: .centerAndTrailing) == [200, 332])
        #expect(NowPlayingBarMetrics.centers(count: 0, width: 393).isEmpty)
        // 颗数多了两头收窄,间距不小于 8。
        let six = NowPlayingBarMetrics.centers(count: 6, width: 375)
        #expect(six.count == 6)
        #expect(six[0] - 22 >= NowPlayingBarMetrics.minimumInset)
        #expect(six[0] - 22 < NowPlayingBarMetrics.preferredInset)
        for index in 1..<six.count {
            #expect(six[index] - six[index - 1] >= 52 - 0.0001)
        }
        #expect(abs((375 - six[5]) - six[0]) < 0.0001)
        // 摆不下时不越界,只是挨得更近。
        let crowded = NowPlayingBarMetrics.centers(count: 8, width: 320)
        #expect(crowded.first! >= 22)
        #expect(crowded.last! <= 298)
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
            .placing(.sleepTimer, at: .bar(2))
            .placing(.equalizer, at: .slot(.header))
        #expect(layout.menuFallback(on: .portrait) == [.like, .queue])
        #expect(layout.menuSuppressed(on: .portrait) == [.sleepTimer, .equalizer])
        // 横屏歌词在右栏,歌词键拿掉也不用补。
        let noLyrics = Layout.default.placing(.karaoke, at: .bar(0))
        #expect(noLyrics.menuFallback(on: .portrait) == [.lyrics])
        #expect(noLyrics.menuFallback(on: .wideLandscape).isEmpty)
        #expect(noLyrics.menuFallback(on: .compactLandscape(showsTransportEdges: true)).isEmpty)
    }

    @Test func edgeActionsHiddenInNarrowLandscapeStayInTheMenu() {
        let layout = Layout.default.placing(.sleepTimer, at: .slot(.leadingEdge))
        #expect(layout.menuSuppressed(on: .portrait).contains(.sleepTimer))
        let narrow = NowPlayingControlSurface.compactLandscape(showsTransportEdges: false)
        #expect(!layout.menuSuppressed(on: narrow).contains(.sleepTimer))
        #expect(layout.menuFallback(on: narrow) == [.shuffle, .repeatMode])
    }

    @Test func landscapeChromeSkipsLyricsAndFullScreenAndKeepsAirPlayLast() {
        let layout = Layout.default
            .placing(.airPlay, at: .bar(0))
            .placing(.sleepTimer, at: .bar(1))
            .placing(.fullScreen, at: .slot(.header))
        #expect(layout.bar == [.airPlay, .sleepTimer, .queue])
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
            .placing(.sleepTimer, at: .slot(.header))
            .placing(.karaoke, at: .bar(2))
        #expect(layout.toolColumnGroups().middle == [.lyrics, .karaoke])
        #expect(layout.immersiveLyricsAction() == .sleepTimer)
        #expect(layout.menuFallback(on: .immersiveLyrics) == [.like])
        #expect(layout.menuSuppressed(on: .immersiveLyrics) == [.sleepTimer])
        let column = NowPlayingControlSurface.toolColumn(showsTransportEdges: true, headerOverflows: false)
        #expect(layout.menuFallback(on: column) == [.like, .queue])
        #expect(layout.menuSuppressed(on: column) == [.sleepTimer, .karaoke])
    }

    @Test func longerBarsShowEverywhereAndTheColumnCanCapIt() {
        let layout = Layout.default
            .placing(.sleepTimer, at: .bar(3))
            .placing(.equalizer, at: .bar(4))
            .placing(.fullScreen, at: .bar(5))
        #expect(layout.menuSuppressed(on: .portrait) == [.sleepTimer, .equalizer, .fullScreen])
        #expect(layout.wideLandscapeBar() == [.airPlay, .queue, .sleepTimer, .equalizer, .fullScreen])
        #expect(layout.compactLandscapeChrome().leading == [.queue, .sleepTimer, .equalizer, .airPlay])
        // 横屏那一排窄时从后往前让,AirPlay 留着;让掉的队列补进「更多」。
        #expect(layout.compactLandscapeChrome(leadingLimit: 2).leading == [.queue, .airPlay])
        #expect(layout.compactLandscapeChrome(leadingLimit: 1).leading == [.airPlay])
        let narrow = NowPlayingControlSurface.compactLandscape(showsTransportEdges: true, leadingLimit: 1)
        #expect(layout.menuFallback(on: narrow) == [.queue])
        #expect(layout.menuSuppressed(on: narrow).isEmpty)
        #expect(layout.toolColumnGroups().middle == [.lyrics, .queue, .sleepTimer, .equalizer, .fullScreen])
        // 竖栏那一列放不下时只摆前几颗,队列这种只能靠页面点到的补进「更多」。
        #expect(layout.toolColumnGroups(middleLimit: 1).middle == [.lyrics])
        let column = NowPlayingControlSurface.toolColumn(showsTransportEdges: true, headerOverflows: false, middleLimit: 1)
        #expect(layout.menuFallback(on: column) == [.queue])
        #expect(!layout.menuSuppressed(on: column).contains(.sleepTimer))
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
        #expect(decoded.placing(.sleepTimer, at: .slot(.header)).hiddenMenuItems == [.medley, .karaoke])
        #expect(layout.showingAllMenuItems().isDefault)
        // 别的版本写进来的菜单项名字原样保留。
        let future = Layout.decode(#"{"hiddenMenu":["futureItem","medley"]}"#)
        #expect(future.hiddenMenuItems == [.medley])
        #expect(future.settingMenuItem(.share, visible: false).encoded().contains("futureItem"))
    }
}
