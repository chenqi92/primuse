import Foundation
import Testing
@testable import PrimuseKit

@Suite struct TVTabBarConfigurationTests {
    @Test func emptyOrGarbageStorageIsDefault() {
        #expect(TVTabBarConfiguration.decode("") == .default)
        #expect(TVTabBarConfiguration.decode("not json") == .default)
        #expect(TVTabBarConfiguration.default.encoded() == "")
        #expect(TVTabBarConfiguration.default.order == TVTabBarConfiguration.defaultOrder)
    }

    @Test func roundTripsOrderAndHidden() {
        var config = TVTabBarConfiguration.default
        config.move(.search, by: -99)
        config.setShown(false, for: .playlists)
        let decoded = TVTabBarConfiguration.decode(config.encoded())
        #expect(decoded == config)
        #expect(decoded.order.first == .search)
        #expect(!decoded.isShown(.playlists))
    }

    @Test func unknownAndDuplicateEntriesAreDroppedAndMissingOnesReinserted() {
        let raw = #"{"order":["search","later","search","home"],"hidden":["gone","home"]}"#
        let config = TVTabBarConfiguration.decode(raw)
        #expect(config.order.count == TVTabBarItem.allCases.count)
        #expect(config.order.first == .search)
        // library 默认跟在 home 后面,补回来时也插在 home 后面。
        let home = config.order.firstIndex(of: .home)
        let library = config.order.firstIndex(of: .library)
        #expect(home != nil && library == home.map { $0 + 1 })
        #expect(!config.isShown(.home))
    }

    @Test func lastContentIndependentPageCannotBeHidden() {
        var config = TVTabBarConfiguration.default
        for item in [TVTabBarItem.home, .library, .nowPlaying, .playlists, .sources] {
            let hid = config.setShown(false, for: item)
            #expect(hid)
        }
        #expect(!config.canHide(.search))
        let hidSearch = config.setShown(false, for: .search)
        #expect(!hidSearch)
        #expect(config.isShown(.search))
        // 电台、有声依赖内容,关掉它们不受这条限制。
        #expect(config.canHide(.radio))
        let hidRadio = config.setShown(false, for: .radio)
        #expect(hidRadio)
    }

    @Test func corruptStorageHidingEverythingKeepsOnePageReachable() {
        let all = TVTabBarItem.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        let config = TVTabBarConfiguration.decode(#"{"order":[],"hidden":[\#(all)]}"#)
        #expect(config.isShown(.home))
        let visible = config.visibleItems { _ in true }
        #expect(visible == [.home])
    }

    @Test func visibleItemsRespectContentAvailability() {
        var config = TVTabBarConfiguration.default
        config.move(.radio, by: -2)
        let withoutRadio = config.visibleItems { $0 != .radio && $0 != .spokenWord }
        #expect(!withoutRadio.contains(.radio))
        let withRadio = config.visibleItems { $0 != .spokenWord }
        #expect(withRadio.first == .radio)
    }

    @Test func podcastsStartHiddenEvenForConfigsSavedBeforeThey() {
        #expect(!TVTabBarConfiguration.default.isShown(.podcasts))
        let order = TVTabBarConfiguration.default.order
        #expect(order.firstIndex(of: .podcasts) == order.firstIndex(of: .spokenWord).map { $0 + 1 })

        let legacy = #"{"order":["home","library","radio","spokenWord","nowPlaying","playlists","sources","search"],"hidden":["playlists"]}"#
        let upgraded = TVTabBarConfiguration.decode(legacy)
        #expect(!upgraded.isShown(.podcasts))
        #expect(!upgraded.isShown(.playlists))
        #expect(upgraded.isShown(.home))
        #expect(upgraded.order.firstIndex(of: .podcasts) == upgraded.order.firstIndex(of: .spokenWord).map { $0 + 1 })

        var shown = upgraded
        shown.setShown(true, for: .podcasts)
        let decoded = TVTabBarConfiguration.decode(shown.encoded())
        #expect(decoded.isShown(.podcasts))
        #expect(decoded == shown)
    }

    @Test func movingClampsAtTheEnds() {
        var config = TVTabBarConfiguration.default
        #expect(!config.canMove(.home, by: -1))
        #expect(config.canMove(.home, by: 1))
        #expect(!config.canMove(.search, by: 1))
        config.move(.home, by: -1)
        #expect(config == .default)
        config.move(.home, by: 1)
        #expect(Array(config.order.prefix(2)) == [.library, .home])
        config.move(.home, by: -1)
        #expect(config.isDefault)
    }
}

@Suite("Apple TV 换页过渡")
struct TVPageTransitionPolicyTests {
    private let order: [TVTabBarItem] = [.home, .library, .nowPlaying, .playlists, .search]

    private func transition(
        _ from: TVTabBarItem,
        _ to: TVTabBarItem,
        fromFull: Bool = false,
        toFull: Bool = false,
        reduceMotion: Bool = false,
        order: [TVTabBarItem]? = nil
    ) -> TVPageTransition {
        TVPageTransitionPolicy.transition(
            from: from, to: to, order: order ?? self.order,
            fromIsFullScreen: fromFull, toIsFullScreen: toFull, reduceMotion: reduceMotion
        )
    }

    @Test("顶栏往右换页时新页从右边进来,往左换从左边进来")
    func slideFollowsTabOrder() {
        #expect(transition(.home, .library) == .slide(forward: true))
        #expect(transition(.search, .library) == .slide(forward: false))
        // 没在放东西时播放页是顶栏上普通的一页。
        #expect(transition(.library, .nowPlaying) == .slide(forward: true))
    }

    @Test("进出全屏播放页是往里走一层、退回一层")
    func fullScreenPlayerChangesDepth() {
        #expect(transition(.library, .nowPlaying, toFull: true) == .deeper)
        #expect(transition(.search, .nowPlaying, toFull: true) == .deeper)
        #expect(transition(.nowPlaying, .home, fromFull: true) == .shallower)
    }

    @Test("减弱动态效果或没换页时直接换")
    func reduceMotionAndSamePageDoNotAnimate() {
        #expect(transition(.home, .library, reduceMotion: true) == .none)
        #expect(transition(.library, .nowPlaying, toFull: true, reduceMotion: true) == .none)
        #expect(transition(.home, .home) == .none)
    }

    @Test("不在顶栏上的页按默认顺序比前后")
    func pagesMissingFromTheBarUseTheDefaultOrder() {
        // 电台刚被删空、从顶栏消失:回首页是往左。
        #expect(transition(.radio, .home) == .slide(forward: false))
        #expect(transition(.home, .radio) == .slide(forward: true))
    }
}
