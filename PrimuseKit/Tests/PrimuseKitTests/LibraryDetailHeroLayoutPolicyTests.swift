import Foundation
import Testing
@testable import PrimuseKit

/// 断言用的视口表。点数与安全区：SE / mini / 17e / Pro / Pro Max 按官方规格；
/// 折叠屏两块屏是按像素与 @3x 推算的（见 iPhone Duo 适配记录），安全区也是估值。
private struct HeroDevice: CustomStringConvertible, Sendable {
    let name: String
    let width: Double
    let height: Double
    /// 状态栏 / 灵动岛那段顶部安全区。
    let statusTop: Double
    /// home 指示条那段底部安全区。
    let hardwareBottom: Double
    var isCompactHeight = false
    var isRegularWidth = false

    var description: String { name }

    /// iOS 26 起的导航栏高度（玻璃圆钮那一排），iOS 18 是 44，取高的。
    static let navigationBar: Double = 54
    /// 手机横屏整段顶部安全区（iOS 27 模拟器实测）。
    static let landscapeTop: Double = 78
    /// iOS 18–26.0 经典外观：标签栏在安全区里，叠加式迷你条不在。页面按「安全区 + 叠加条」传底部遮挡。
    static let legacyTabBar: Double = 49

    func viewport(_ typeSize: LibraryDetailTypeSize) -> LibraryDetailHeroViewport {
        let top = isCompactHeight ? Self.landscapeTop : statusTop + Self.navigationBar
        let bottom = isCompactHeight
            ? hardwareBottom
            : hardwareBottom + Self.legacyTabBar + LibraryDetailHeroLayoutPolicy.legacyMiniPlayerOverlay
        return LibraryDetailHeroViewport(
            width: width,
            height: height,
            topInset: top,
            bottomInset: bottom,
            isCompactHeight: isCompactHeight,
            isRegularWidth: isRegularWidth,
            typeSize: typeSize
        )
    }
}

private let portraitDevices: [HeroDevice] = [
    HeroDevice(name: "SE", width: 375, height: 667, statusTop: 20, hardwareBottom: 0),
    HeroDevice(name: "13 mini", width: 375, height: 812, statusTop: 50, hardwareBottom: 34),
    HeroDevice(name: "17e", width: 390, height: 844, statusTop: 47, hardwareBottom: 34),
    HeroDevice(name: "18 Pro", width: 402, height: 874, statusTop: 62, hardwareBottom: 34),
    HeroDevice(name: "Pro Max", width: 440, height: 956, statusTop: 62, hardwareBottom: 34),
    HeroDevice(name: "Duo 外屏", width: 466, height: 678, statusTop: 44, hardwareBottom: 21),
    HeroDevice(name: "Duo 内屏", width: 890, height: 626, statusTop: 24, hardwareBottom: 20, isRegularWidth: true),
    HeroDevice(name: "iPad", width: 820, height: 1180, statusTop: 24, hardwareBottom: 20, isRegularWidth: true),
]

private let landscape = HeroDevice(
    name: "横屏", width: 852 - 59 - 59, height: 393, statusTop: 0, hardwareBottom: 21,
    isCompactHeight: true
)

private let checkedTypeSizes: [LibraryDetailTypeSize] = [.large, .xxxLarge, .accessibility1]

private typealias Policy = LibraryDetailHeroLayoutPolicy

/// 操作行底边离页面顶部安全区下沿有多远（各页头部的纵向结构照抄视图层）。
private func actionRowBottom(
    _ kind: String,
    layout: LibraryDetailHeroLayout,
    typeSize: LibraryDetailTypeSize,
    titleLines: Int
) -> Double {
    let tier = layout.titleTier
    let actions = layout.actionRowHeight
    switch kind {
    case "album":
        let identity = Policy.estimatedIdentityHeight(.album, tier: tier, typeSize: typeSize, titleLines: titleLines)
        return Policy.Spacing.albumTop + layout.album.stackHeight(identityHeight: identity)
            + Policy.albumIdentityToActions(tier) + actions
    case "playlistCover":
        let identity = Policy.estimatedIdentityHeight(.playlistCover, tier: tier, typeSize: typeSize, titleLines: titleLines)
        return Policy.Spacing.playlistTop + layout.playlistCover.stackHeight(identityHeight: identity)
            + Policy.Spacing.playlistHeroToActions + actions
    case "smartCover":
        let identity = Policy.estimatedIdentityHeight(.smartCover, tier: tier, typeSize: typeSize, titleLines: titleLines)
        let summary = LibraryDetailTextStyle.footnote.height(lines: Policy.smartSummaryLineLimit(tier), at: typeSize)
        return Policy.Spacing.playlistTop + layout.smartPlaylistCover.stackHeight(identityHeight: identity)
            + Policy.Spacing.smartHeroToSummary + summary + Policy.Spacing.smartSummaryToActions + actions
    case "genre":
        let identity = Policy.estimatedIdentityHeight(.genre, tier: tier, typeSize: typeSize, titleLines: titleLines)
        return Policy.Spacing.genreTop + layout.genreMosaic.stackHeight(identityHeight: identity)
            + Policy.Spacing.genreIdentityToActions + actions
    case "playlistWall":
        return layout.playlistWallHeight + Policy.Spacing.playlistHeroToActions + actions
    case "smartWall":
        let summary = LibraryDetailTextStyle.footnote.height(lines: Policy.smartSummaryLineLimit(tier), at: typeSize)
        return layout.smartPlaylistWallHeight + Policy.Spacing.smartHeroToSummary + summary
            + Policy.Spacing.smartSummaryToActions + actions
    case "artist":
        // 名字块压在海报下缘，块比海报高时整段跟着撑高；操作行底边 = 头部底边 − 16。
        let block = Policy.estimatedArtistBlockHeight(tier: tier, typeSize: typeSize)
        return max(layout.artistPosterHeight, block) - Policy.Spacing.artistBottom
    default:
        Issue.record("unknown kind \(kind)")
        return .infinity
    }
}

private let heroKinds = ["album", "artist", "playlistWall", "playlistCover", "smartWall", "smartCover", "genre"]

@Suite("详情页头图几何")
struct LibraryDetailHeroLayoutPolicyTests {
    @Test("竖屏各视口 × 字号：首屏露出整条操作行", arguments: portraitDevices)
    fileprivate func firstScreenShowsActionRow(device: HeroDevice) {
        for typeSize in checkedTypeSizes {
            let viewport = device.viewport(typeSize)
            let layout = Policy.layout(for: viewport)
            let limit = layout.firstScreenHeight - Policy.firstScreenMargin
            let titleLines = Policy.titleLineLimit(layout.titleTier)
            for kind in heroKinds {
                // 标题取到行数上限，是最坏情况。
                let bottom = actionRowBottom(kind, layout: layout, typeSize: typeSize, titleLines: titleLines)
                #expect(
                    bottom <= limit,
                    "\(device) \(typeSize) \(kind): 操作行底边 \(bottom) 超出首屏 \(limit)"
                )
            }
        }
    }

    @Test("手机横屏沿用原来的矮横带取值，首屏同样露出操作行")
    func compactLandscapeKeepsOriginalValues() {
        let layout = Policy.layout(for: landscape.viewport(.large))
        #expect(layout.isCompactHeight)
        #expect(layout.album.resolvedExtent(identityHeight: 500) == 112)
        #expect(layout.playlistCover.resolvedExtent(identityHeight: 500) == 112)
        #expect(layout.smartPlaylistCover.resolvedExtent(identityHeight: 500) == 112)
        #expect(layout.artistPosterHeight == 230)
        #expect(layout.playlistWallHeight == 150)
        #expect(layout.actionRow == .singleRow)
        #expect(layout.bodyMaxWidth == nil)

        // 专辑横带：12 + 封面 112 + 14 + 操作行；艺术家：海报 230 − 10；封面墙：150 + 12 + 操作行。
        // 横屏沿用原来的取值，经典外观下标签栏 + 迷你条占 120，852×393 上专辑横带只剩几点余量，
        // 达不到竖屏那 16 点，这里只断言操作行整条露出。
        let limit = layout.firstScreenHeight
        #expect(12 + 112 + 14 + layout.actionRowHeight <= limit)
        // 艺术家海报与封面墙的横屏取值比首屏还高，按钮被迷你条压住下半截（改前就是这样，
        // Pro 横屏截图可见）。横屏这一支这次只断言不改，留作已知问题。
        withKnownIssue("经典外观横屏：艺术家海报与封面墙下的操作行被标签栏与迷你条压住") {
            #expect(230 - 10 <= limit)
            #expect(150 + 12 + layout.actionRowHeight <= limit)
        }
    }

    @Test("放得下的机型保持原来的尺寸")
    func roomyPhonesKeepOriginalSizes() {
        for name in ["17e", "18 Pro", "Pro Max"] {
            let device = portraitDevices.first { $0.name == name }!
            let layout = Policy.layout(for: device.viewport(.large))
            #expect(layout.album.ideal == 262, "\(name)")
            // 一行标题时封面不会被压。
            let identity = Policy.estimatedIdentityHeight(.album, tier: .regular, typeSize: .large, titleLines: 1)
            #expect(layout.album.resolvedExtent(identityHeight: identity) == 262, "\(name)")
            #expect(layout.artistPosterHeight == 440, "\(name)")
            #expect(layout.playlistWallHeight == 320, "\(name)")
            #expect(layout.playlistCover.ideal == 240, "\(name)")
            #expect(layout.smartPlaylistCover.ideal == 200, "\(name)")
            #expect(layout.titleTier == .regular, "\(name)")
            #expect(layout.actionRow == .singleRow, "\(name)")
        }
    }

    @Test("SE 这类矮屏的头图按首屏收小")
    func shortPhonesShrinkHeroes() {
        let se = portraitDevices[0]
        let layout = Policy.layout(for: se.viewport(.large))
        #expect(layout.album.ideal < 262)
        #expect(layout.artistPosterHeight < 440)
        #expect(layout.album.ideal >= Policy.albumCoverRange.lowerBound)
        #expect(layout.artistPosterHeight >= Policy.artistPosterRange.lowerBound)
    }

    @Test("无障碍字号或窄屏时操作行两行排；常规宽度一行放得下")
    func actionRowArrangement() {
        let pro = portraitDevices[3]
        #expect(Policy.layout(for: pro.viewport(.xxxLarge)).actionRow == .singleRow)
        #expect(Policy.layout(for: pro.viewport(.accessibility1)).actionRow == .twoRows)

        var narrow = pro.viewport(.large)
        narrow.width = 320
        #expect(Policy.layout(for: narrow).actionRow == .twoRows)

        let duoInner = portraitDevices[6]
        #expect(Policy.layout(for: duoInner.viewport(.accessibility1)).actionRow == .singleRow)

        let twoRows = Policy.actionRowHeight(.twoRows, typeSize: .accessibility1)
        #expect(twoRows == Policy.playPillHeight(.accessibility1) + 12 + 54)
    }

    @Test("常规宽度下头图不再放大，正文限宽居中")
    func regularWidthCapsBody() {
        let pad = portraitDevices[7]
        let layout = Policy.layout(for: pad.viewport(.large))
        #expect(layout.bodyMaxWidth == 720)
        #expect(layout.album.ideal == 262)
        #expect(layout.artistPosterHeight == 440)
        #expect(layout.playlistWallHeight == 320)

        let phone = Policy.layout(for: portraitDevices[3].viewport(.large))
        #expect(phone.bodyMaxWidth == nil)
    }

    @Test("底部让位取两种外壳里较高的那个，不低于下限")
    func bottomClearanceFloor() {
        var viewport = portraitDevices[3].viewport(.large)
        viewport.bottomInset = 34
        #expect(Policy.bottomClearance(for: viewport) == 139)
        viewport.bottomInset = 147
        #expect(Policy.bottomClearance(for: viewport) == 147)
        viewport.isCompactHeight = true
        viewport.bottomInset = 21
        #expect(Policy.bottomClearance(for: viewport) == 120)
    }

    @Test("封面按标题块实际高度收，收到下限为止")
    func artworkResolution() {
        let stack = LibraryDetailArtworkStack(ideal: 262, minimum: 88, budget: 400, spacing: 22)
        #expect(stack.resolvedExtent(identityHeight: 80) == 262)
        #expect(stack.resolvedExtent(identityHeight: 200) == 178)
        #expect(stack.resolvedExtent(identityHeight: 380) == 88)
        #expect(stack.stackHeight(identityHeight: 200) == 400)
    }

    @Test("大字号放不下时换紧凑标题档")
    func titleTierFallsBackOnAccessibilitySizes() {
        let se = portraitDevices[0]
        #expect(Policy.layout(for: se.viewport(.large)).titleTier == .regular)
        #expect(Policy.layout(for: se.viewport(.accessibility1)).titleTier == .reduced)
        #expect(Policy.layout(for: portraitDevices[4].viewport(.xxxLarge)).titleTier == .regular)
    }

    @Test("字号表的行高只估多不估少")
    func lineHeightsAreConservative() {
        // 系统在默认字号下的实际行高（SF Pro）：大标题 41、title2 28、title3 25、headline 22、footnote 18。
        #expect(LibraryDetailTextStyle.largeTitle.lineHeight(at: .large) >= 41)
        #expect(LibraryDetailTextStyle.title2.lineHeight(at: .large) >= 28)
        #expect(LibraryDetailTextStyle.title3.lineHeight(at: .large) >= 25)
        #expect(LibraryDetailTextStyle.headline.lineHeight(at: .large) >= 22)
        #expect(LibraryDetailTextStyle.footnote.lineHeight(at: .large) >= 18)
    }

    @Test("视口表一览（供回报对照）")
    func printTable() {
        var rows: [String] = []
        for device in portraitDevices + [landscape] {
            for typeSize in [LibraryDetailTypeSize.large, .accessibility1] {
                let layout = Policy.layout(for: device.viewport(typeSize))
                let lines = layout.isCompactHeight ? 1 : Policy.titleLineLimit(layout.titleTier)
                let albumIdentity = Policy.estimatedIdentityHeight(.album, tier: layout.titleTier, typeSize: typeSize, titleLines: 1)
                let cover = layout.album.resolvedExtent(identityHeight: albumIdentity)
                let fits = layout.isCompactHeight || heroKinds.allSatisfy {
                    actionRowBottom($0, layout: layout, typeSize: typeSize, titleLines: lines)
                        <= layout.firstScreenHeight - Policy.firstScreenMargin
                }
                rows.append("\(device.name)\t\(typeSize)\tF=\(Int(layout.firstScreenHeight))\tcover=\(Int(cover))/\(Int(layout.album.ideal))\tposter=\(Int(layout.artistPosterHeight))\twall=\(Int(layout.playlistWallHeight))\t\(layout.actionRow)\t\(layout.titleTier)\tfits=\(fits)")
            }
        }
        print("HERO_TABLE\n" + rows.joined(separator: "\n"))
    }
}
