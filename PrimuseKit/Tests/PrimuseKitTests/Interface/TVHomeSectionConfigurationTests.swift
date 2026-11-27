import Foundation
import Testing
@testable import PrimuseKit

@Suite struct TVHomeSectionConfigurationTests {
    @Test func emptyOrGarbageStorageIsDefault() {
        #expect(TVHomeSectionConfiguration.decode("") == .default)
        #expect(TVHomeSectionConfiguration.decode("not json") == .default)
        #expect(TVHomeSectionConfiguration.default.encoded() == "")
        #expect(TVHomeSectionConfiguration.default.visibleSections == TVHomeSectionConfiguration.defaultOrder)
    }

    @Test func albumPickLeadsAndHomeScenesFollow() {
        let order = TVHomeSectionConfiguration.default.order
        #expect(order.prefix(2) == [.albumPick, .homeScenes])
        #expect(Set(order) == Set(TVHomeSection.allCases))
    }

    @Test func roundTripsOrderAndHidden() {
        var config = TVHomeSectionConfiguration.default
        config.move(.radio, by: -99)
        config.setShown(false, for: .likedAlbums)
        let decoded = TVHomeSectionConfiguration.decode(config.encoded())
        #expect(decoded == config)
        #expect(decoded.order.first == .radio)
        #expect(!decoded.isShown(.likedAlbums))
        #expect(!decoded.visibleSections.contains(.likedAlbums))
    }

    @Test func unknownAndDuplicateEntriesAreDroppedAndMissingOnesReinserted() {
        let raw = #"{"order":["radio","later","radio","albumPick"],"hidden":["gone","albumPick"]}"#
        let config = TVHomeSectionConfiguration.decode(raw)
        #expect(config.order.count == TVHomeSection.allCases.count)
        #expect(config.order.first == .radio)
        // 居家场景默认跟在今晚听后面,补回来时也插在它后面。
        let pick = config.order.firstIndex(of: .albumPick)
        let scenes = config.order.firstIndex(of: .homeScenes)
        #expect(pick != nil && scenes == pick.map { $0 + 1 })
        #expect(!config.isShown(.albumPick))
    }

    @Test func lastShownSectionCannotBeHidden() {
        var config = TVHomeSectionConfiguration.default
        for section in TVHomeSectionConfiguration.defaultOrder.dropLast() {
            let hid = config.setShown(false, for: section)
            #expect(hid)
        }
        #expect(!config.canHide(.radio))
        let hidLast = config.setShown(false, for: .radio)
        #expect(!hidLast)
        #expect(config.visibleSections == [.radio])
    }

    @Test func corruptStorageHidingEverythingKeepsOneSection() {
        let all = TVHomeSection.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        let config = TVHomeSectionConfiguration.decode(#"{"order":[],"hidden":[\#(all)]}"#)
        #expect(config.visibleSections == [.albumPick])
    }

    @Test func moveClampsAndReportsEdges() {
        var config = TVHomeSectionConfiguration.default
        #expect(!config.canMove(.albumPick, by: -1))
        #expect(config.canMove(.albumPick, by: 1))
        config.move(.albumPick, by: 1)
        #expect(config.order.prefix(2) == [.homeScenes, .albumPick])
        config.move(.homeScenes, by: 99)
        #expect(config.order.last == .homeScenes)
        #expect(!config.canMove(.homeScenes, by: 1))
    }
}
