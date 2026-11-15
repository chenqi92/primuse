import Foundation
import Testing
@testable import PrimuseKit

@Suite("Minimal top tabs")
struct MinimalTopTabConfigurationTests {
    private let everythingAvailable: (MinimalTopTab) -> Bool = { _ in true }

    @Test("没调过时和原来一样：四格都在，首页照老的「显示首页」")
    func defaultsMatchThePreviousBehaviour() {
        let configuration = MinimalTopTabConfiguration.decode("")
        #expect(configuration.order == [.home, .music, .radio, .spoken])
        #expect(configuration.hidden == [])
        #expect(configuration.visibleTabs(isAvailable: everythingAvailable) == [.home, .music, .radio, .spoken])

        let homeOff = MinimalTopTabConfiguration.decode("", legacyShowsHome: false)
        #expect(homeOff.visibleTabs(isAvailable: everythingAvailable) == [.music, .radio, .spoken])
    }

    @Test("调过之后整份写下来，不再读老的「显示首页」")
    func customizedStopsReadingTheLegacyHomeToggle() {
        var configuration = MinimalTopTabConfiguration.decode("", legacyShowsHome: false)
        configuration.setShown(false, for: .radio)
        let raw = configuration.encoded()
        #expect(!raw.isEmpty)
        let decoded = MinimalTopTabConfiguration.decode(raw, legacyShowsHome: true)
        #expect(decoded == configuration)
        #expect(decoded.visibleTabs(isAvailable: everythingAvailable) == [.music, .spoken])
    }

    @Test("没内容的格打开了也不出现，关掉不看内容")
    func availabilityOnlyLimitsShownTabs() {
        var configuration = MinimalTopTabConfiguration()
        let noSpoken: (MinimalTopTab) -> Bool = { $0 != .spoken }
        #expect(configuration.visibleTabs(isAvailable: noSpoken) == [.home, .music, .radio])
        configuration.setShown(false, for: .radio)
        configuration.setShown(false, for: .music)
        #expect(configuration.visibleTabs(isAvailable: everythingAvailable) == [.home, .spoken])
    }

    @Test("音乐也能关，排在最前的格跟着顺序走")
    func musicCanBeHiddenAndReordered() {
        var configuration = MinimalTopTabConfiguration()
        configuration.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        configuration.setShown(false, for: .music)
        #expect(configuration.order == [.radio, .home, .music, .spoken])
        #expect(configuration.visibleTabs(isAvailable: everythingAvailable) == [.radio, .home, .spoken])
        let decoded = MinimalTopTabConfiguration.decode(configuration.encoded())
        #expect(decoded == configuration)
    }

    @Test("最后一格关不掉；没内容的格随时能关")
    func lastVisibleTabCannotBeHidden() {
        var configuration = MinimalTopTabConfiguration()
        for tab in [MinimalTopTab.home, .music, .radio] {
            configuration.setShown(false, for: tab)
        }
        #expect(!configuration.canHide(.spoken, isAvailable: everythingAvailable))
        #expect(configuration.canHide(.home, isAvailable: everythingAvailable))

        // 打开的另一格没内容：它撑不住顶栏，剩下那格仍然关不掉。
        configuration.setShown(true, for: .radio)
        let noRadio: (MinimalTopTab) -> Bool = { $0 != .radio }
        #expect(!configuration.canHide(.spoken, isAvailable: noRadio))
        #expect(configuration.canHide(.radio, isAvailable: noRadio))
        #expect(configuration.canHide(.spoken, isAvailable: everythingAvailable))
    }

    @Test("一格都摆不出来时摆音乐")
    func fallsBackToMusicWhenNothingIsLeft() {
        var configuration = MinimalTopTabConfiguration()
        for tab in [MinimalTopTab.home, .music, .spoken] {
            configuration.setShown(false, for: tab)
        }
        let noRadio: (MinimalTopTab) -> Bool = { $0 != .radio }
        #expect(configuration.visibleTabs(isAvailable: noRadio) == [.music])
    }

    @Test("读不出来的存盘按没调过算；缺的格补回默认位置，重复的去掉")
    func normalizesStoredOrder() {
        #expect(MinimalTopTabConfiguration.decode("not json") == MinimalTopTabConfiguration())
        let partial = MinimalTopTabConfiguration.decode(#"{"order":["radio","radio","home","future"],"hidden":["home","future"]}"#)
        #expect(partial.order == [.radio, .spoken, .home, .music])
        #expect(partial.hidden == [.home])
    }

    @Test("拖动排序与 Array.move 一致")
    func moveMatchesArrayMove() {
        let count = MinimalTopTabConfiguration.defaultOrder.count
        for source in 0..<count {
            for destination in 0...count {
                var configuration = MinimalTopTabConfiguration()
                configuration.move(fromOffsets: IndexSet(integer: source), toOffset: destination)
                var expected = MinimalTopTabConfiguration.defaultOrder
                let moved = expected.remove(at: source)
                expected.insert(moved, at: destination > source ? destination - 1 : destination)
                #expect(configuration.order == expected)
            }
        }
    }
}
