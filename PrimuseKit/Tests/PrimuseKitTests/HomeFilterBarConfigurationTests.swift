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

    // MARK: 显示方式

    @Test("老数据没有显示方式:按自动解,存回去不多出字段")
    func legacyJSONDecodesAsAutomatic() {
        let raw = #"{"order":["podcast","music","radio","spokenWord"],"hidden":["radio"]}"#
        let configuration = HomeFilterBarConfiguration.decode(raw)
        #expect(!configuration.followsSections)
        #expect(configuration.labelStyle == .automatic)
        #expect(configuration.order == [.podcast, .music, .radio, .spokenWord])
        #expect(configuration.hidden == [.radio])
        #expect(!configuration.encoded().contains("labelStyle"))
        #expect(HomeFilterBarConfiguration.decode(configuration.encoded()) == configuration)
    }

    @Test("调过顺序后改显示方式,读回来顺序、显隐与显示方式都在")
    func labelStyleRoundTripsWithCustomOrder() {
        var configuration = HomeFilterBarConfiguration.followingSections.customized(sectionShown: sectionsOn)
        configuration.setShown(false, for: .podcast)
        for style in HomeFilterBarLabelStyle.allCases {
            configuration.labelStyle = style
            let decoded = HomeFilterBarConfiguration.decode(configuration.encoded())
            #expect(decoded == configuration)
            #expect(decoded.labelStyle == style)
            #expect(decoded.hidden == [.podcast])
        }
    }

    @Test("只改显示方式时显隐仍跟着区块走,老版本读到也当成跟着区块走")
    func labelStyleAloneKeepsFollowingSections() throws {
        var configuration = HomeFilterBarConfiguration.decode("")
        configuration.labelStyle = .iconOnly
        let raw = configuration.encoded()
        #expect(!raw.isEmpty)
        let decoded = HomeFilterBarConfiguration.decode(raw)
        #expect(decoded.followsSections)
        #expect(decoded.labelStyle == .iconOnly)
        let radioOff: (ListeningSpace) -> Bool = { $0 != .radio }
        #expect(
            decoded.visibleSpaces(sectionShown: radioOff, isAvailable: everythingAvailable)
                == [.music, .spokenWord, .podcast]
        )
        // 老版本的存档结构两个字段都是必有的:解不出来就回到跟着区块走,不会把全部胶囊当成调过。
        struct LegacyStored: Decodable {
            var order: [String]
            var hidden: [String]
        }
        #expect((try? JSONDecoder().decode(LegacyStored.self, from: Data(raw.utf8))) == nil)

        // 显示方式改回自动:又是空串。
        var automatic = decoded
        automatic.labelStyle = .automatic
        #expect(automatic.encoded() == "")
    }

    @Test("第一次调顺序、点「跟随首页区块」都留着显示方式")
    func customizingAndFollowingKeepLabelStyle() {
        var configuration = HomeFilterBarConfiguration.followingSections
        configuration.labelStyle = .titleOnly
        var customized = configuration.customized { $0 != .radio }
        #expect(customized.labelStyle == .titleOnly)
        customized.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        let following = customized.followingSectionsAgain()
        #expect(following.followsSections)
        #expect(following.order == HomeFilterBarConfiguration.defaultOrder)
        #expect(following.labelStyle == .titleOnly)
        #expect(HomeFilterBarConfiguration.decode(following.encoded()) == following)
        #expect(customized.customized(sectionShown: sectionsOn).followingSectionsAgain().labelStyle == .titleOnly)
    }

    @Test("认不出的显示方式按自动算,顺序与显隐照旧")
    func unknownLabelStyleFallsBackToAutomatic() {
        let raw = #"{"order":["radio","music"],"hidden":["music"],"labelStyle":"marquee"}"#
        let configuration = HomeFilterBarConfiguration.decode(raw)
        #expect(configuration.labelStyle == .automatic)
        #expect(configuration.order == [.radio, .spokenWord, .podcast, .music])
        #expect(configuration.hidden == [.music])
        let following = HomeFilterBarConfiguration.decode(#"{"labelStyle":"marquee"}"#)
        #expect(following == .followingSections)
    }

    // MARK: 自动退让

    /// 中文在 iPhone 13 mini / 15 Pro Max 上大致的胶囊宽度:图标加文字、只留文字、只留图标;选中多一个 ✕。
    private static func chineseChipWidth(
        _ space: ListeningSpace,
        _ content: HomeFilterBarChipContent,
        _ isSelected: Bool
    ) -> Double? {
        let icon: Double = switch space {
        case .music: 11
        case .radio: 24
        case .spokenWord: 18
        case .podcast: 25
        }
        let title: Double = space == .spokenWord ? 45 : 30
        var width: Double = 28
        switch content {
        case .iconAndTitle: width += icon + 6 + title
        case .titleOnly: width += title
        case .iconOnly: width += icon
        }
        return isSelected ? width + 15 : width
    }

    private func fit(
        _ available: Double?,
        selection: ListeningSpace?,
        style: HomeFilterBarLabelStyle = .automatic,
        spaces: [ListeningSpace] = HomeFilterBarConfiguration.defaultOrder,
        width: (ListeningSpace, HomeFilterBarChipContent, Bool) -> Double? = HomeFilterBarConfigurationTests.chineseChipWidth
    ) -> [HomeFilterBarChipContent] {
        let contents = HomeFilterBarFitPolicy.contents(
            spaces: spaces,
            selection: selection,
            labelStyle: style,
            availableWidth: available,
            spacing: 8,
            chipWidth: width
        )
        return spaces.map { contents[$0] ?? .iconAndTitle }
    }

    @Test("宽屏放得下:全部图标加文字,选没选都一样")
    func automaticFitsEverythingOnWideScreens() {
        // iPad 竖屏这一排约 800 点宽。
        #expect(fit(800, selection: nil) == [.iconAndTitle, .iconAndTitle, .iconAndTitle, .iconAndTitle])
        #expect(fit(800, selection: .radio) == [.iconAndTitle, .iconAndTitle, .iconAndTitle, .iconAndTitle])
    }

    @Test("放不下时选中的仍图标加文字,其余先只留文字、再只留图标")
    func automaticDegradesUnselectedChipsFirst() {
        // 375 点宽减两侧 16 点留白 = 343:全部图标加文字要 405,只留文字放得下。
        #expect(fit(343, selection: nil) == [.titleOnly, .titleOnly, .titleOnly, .titleOnly])
        #expect(fit(343, selection: .radio) == [.titleOnly, .iconAndTitle, .titleOnly, .titleOnly])
        // 再窄:只留图标,选中的那颗照样完整。
        #expect(fit(240, selection: .spokenWord) == [.iconOnly, .iconOnly, .iconAndTitle, .iconOnly])
        // 窄到只留图标也放不下:仍按最省的写法,剩下的交给横向滚动,选中的不截字。
        #expect(fit(120, selection: .podcast) == [.iconOnly, .iconOnly, .iconOnly, .iconAndTitle])
    }

    @Test("选中那颗在任何宽度下都是图标加文字")
    func selectedChipAlwaysKeepsIconAndTitle() {
        for available in stride(from: 60.0, through: 900, by: 7) {
            for selection in HomeFilterBarConfiguration.defaultOrder {
                let contents = fit(available, selection: selection)
                let index = HomeFilterBarConfiguration.defaultOrder.firstIndex(of: selection)!
                #expect(contents[index] == .iconAndTitle)
            }
        }
    }

    @Test("挑出来的排法放得下就一定不超宽,而且是能放下的里面最完整的")
    func automaticPicksTheRichestFittingStep() {
        let spaces = HomeFilterBarConfiguration.defaultOrder
        for available in stride(from: 150.0, through: 500, by: 3) {
            for selection in [nil] + spaces.map(Optional.some) {
                let contents = fit(available, selection: selection)
                let total = zip(spaces, contents).reduce(8.0 * 3) { sum, pair in
                    sum + Self.chineseChipWidth(pair.0, pair.1, pair.0 == selection)!
                }
                let allIconOnly = zip(spaces, contents).allSatisfy { $0.0 == selection || $0.1 == .iconOnly }
                #expect(total <= available + 0.5 || allIconOnly)
                // 图标加文字放得下时不会退成只留文字。
                let full = spaces.reduce(8.0 * 3) { sum, space in
                    sum + Self.chineseChipWidth(space, .iconAndTitle, space == selection)!
                }
                if full <= available {
                    #expect(contents.allSatisfy { $0 == .iconAndTitle })
                }
            }
        }
    }

    @Test("还没量到宽度或胶囊时按改版前的样子")
    func unmeasuredFallsBackToIconAndTitle() {
        #expect(fit(nil, selection: .radio) == [.iconAndTitle, .iconAndTitle, .iconAndTitle, .iconAndTitle])
        #expect(fit(0, selection: nil) == [.iconAndTitle, .iconAndTitle, .iconAndTitle, .iconAndTitle])
        let missingRadio: (ListeningSpace, HomeFilterBarChipContent, Bool) -> Double? = { space, content, selected in
            space == .radio ? nil : Self.chineseChipWidth(space, content, selected)
        }
        #expect(
            fit(200, selection: nil, width: missingRadio)
                == [.iconAndTitle, .iconAndTitle, .iconAndTitle, .iconAndTitle]
        )
    }

    @Test("固定写法不看宽度,选中的也照那一种写")
    func fixedStylesIgnoreWidth() {
        #expect(fit(100, selection: .music, style: .iconAndTitle).allSatisfy { $0 == .iconAndTitle })
        #expect(fit(900, selection: .music, style: .iconOnly).allSatisfy { $0 == .iconOnly })
        #expect(fit(nil, selection: nil, style: .titleOnly).allSatisfy { $0 == .titleOnly })
    }

    @Test("两颗胶囊也按同样的规则退让")
    func fewerChipsUseTheSameLadder() {
        let spaces: [ListeningSpace] = [.music, .spokenWord]
        #expect(fit(343, selection: .spokenWord, spaces: spaces) == [.iconAndTitle, .iconAndTitle])
        #expect(fit(180, selection: .spokenWord, spaces: spaces) == [.titleOnly, .iconAndTitle])
        #expect(fit(150, selection: .spokenWord, spaces: spaces) == [.iconOnly, .iconAndTitle])
    }
}
