import Foundation
import Testing
@testable import PrimuseKit

@Suite("Home filter bar")
struct HomeFilterBarConfigurationTests {
    private let sectionsOn: (ListeningSpace) -> Bool = { _ in true }
    private let everythingAvailable: (ListeningSpace) -> Bool = { _ in true }

    @Test("没调过时跟着区块开关走")
    func followsSectionsUntilCustomized() {
        let configuration = HomeFilterBarConfiguration.decode("")
        #expect(configuration.followsSections)
        #expect(configuration.encoded() == "")
        let radioOff: (ListeningSpace) -> Bool = { $0 != .radio && $0 != .podcast }
        #expect(
            configuration.visibleSpaces(sectionShown: radioOff, isAvailable: everythingAvailable)
                == [.music, .spokenWord]
        )
    }

    @Test("调过之后区块收起胶囊照样在")
    func customizedIgnoresSections() {
        var configuration = HomeFilterBarConfiguration.followingSections
            .customized { $0 != .podcast }
        #expect(!configuration.followsSections)
        #expect(configuration.hidden == [.podcast])
        configuration.setShown(true, for: .podcast)
        let sectionsOff: (ListeningSpace) -> Bool = { $0 == .music }
        #expect(
            configuration.visibleSpaces(sectionShown: sectionsOff, isAvailable: everythingAvailable)
                == [.music, .radio, .spokenWord, .podcast]
        )
    }

    @Test("顺序与显隐存盘后读回来一样")
    func roundTrips() {
        var configuration = HomeFilterBarConfiguration.followingSections.customized(sectionShown: sectionsOn)
        configuration.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        configuration.setShown(false, for: .radio)
        #expect(configuration.order == [.spokenWord, .music, .radio, .podcast])
        let decoded = HomeFilterBarConfiguration.decode(configuration.encoded())
        #expect(decoded == configuration)
        #expect(
            decoded.visibleSpaces(sectionShown: sectionsOn, isAvailable: everythingAvailable)
                == [.spokenWord, .music, .podcast]
        )
    }

    @Test("拖动排序与 Array.move 一致")
    func moveMatchesArrayMove() {
        for source in 0..<4 {
            for destination in 0...4 {
                var configuration = HomeFilterBarConfiguration.followingSections.customized(sectionShown: sectionsOn)
                configuration.move(fromOffsets: IndexSet(integer: source), toOffset: destination)
                var expected = HomeFilterBarConfiguration.defaultOrder
                let moved = expected.remove(at: source)
                expected.insert(moved, at: destination > source ? destination - 1 : destination)
                #expect(configuration.order == expected)
            }
        }
    }

    @Test("认不出的名字只丢那一项,缺的按默认邻居补回")
    func toleratesUnknownAndMissingNames() {
        let raw = #"{"order":["podcast","karaoke","music"],"hidden":["karaoke","music"]}"#
        let configuration = HomeFilterBarConfiguration.decode(raw)
        #expect(configuration.order == [.podcast, .music, .radio, .spokenWord])
        #expect(configuration.hidden == [.music])
    }

    @Test("当下筛不出东西的不出;只剩一颗时整排不出")
    func availabilityAndSingleChip() {
        let configuration = HomeFilterBarConfiguration.followingSections.customized(sectionShown: sectionsOn)
        let noSpokenWord: (ListeningSpace) -> Bool = { $0 != .spokenWord }
        #expect(
            configuration.visibleSpaces(sectionShown: sectionsOn, isAvailable: noSpokenWord)
                == [.music, .radio, .podcast]
        )
        var onlyMusic = configuration
        for space in [ListeningSpace.radio, .spokenWord, .podcast] { onlyMusic.setShown(false, for: space) }
        #expect(onlyMusic.visibleSpaces(sectionShown: sectionsOn, isAvailable: everythingAvailable).isEmpty)
    }
}
