import Foundation
import Testing
@testable import PrimuseKit

/// 断言用的视口表。点数与安全区：SE / mini / 17e / Pro / Pro Max 按官方规格；
/// 折叠屏外屏按 Duo 模拟器（Xcode 27.1 beta）实测：系统把工具栏竖排到侧边，竖握时右侧让出 84、
/// 横握时左侧让出 84，顶部安全区 0、底部 34，导航栏仍在顶部 24–82。内屏还没有实测，
/// 按官方像素推算的 890×626 与模拟器画面缓冲推算的 951×669 两种都断言。
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
    /// 实测的顶部遮挡（导航栏下沿），与「状态栏 + 导航栏」的推算不一样时写在这里。
    var measuredTop: Double? = nil

    var description: String { name }

    /// iOS 26 起的导航栏高度（玻璃圆钮那一排），iOS 18 是 44，取高的。
    static let navigationBar: Double = 54
    /// 手机横屏整段顶部安全区（iOS 27 模拟器实测）。
    static let landscapeTop: Double = 78
    /// iOS 18–26.0 经典外观：标签栏在安全区里，叠加式迷你条不在。页面按「安全区 + 叠加条」传底部遮挡。
    static let legacyTabBar: Double = 49

    func viewport(_ typeSize: LibraryDetailTypeSize) -> LibraryDetailHeroViewport {
        let top = measuredTop ?? (isCompactHeight ? Self.landscapeTop : statusTop + Self.navigationBar)
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
    // 竖握：466 宽里右侧 84 是系统竖栏，页面 382 宽。
    HeroDevice(name: "Duo 外屏", width: 466 - 84, height: 678, statusTop: 0, hardwareBottom: 34, measuredTop: 82),
    HeroDevice(name: "Duo 内屏", width: 890, height: 626, statusTop: 24, hardwareBottom: 20, isRegularWidth: true),
    HeroDevice(name: "iPad", width: 820, height: 1180, statusTop: 24, hardwareBottom: 20, isRegularWidth: true),
    HeroDevice(name: "Duo 内屏（模拟器）", width: 951, height: 669, statusTop: 24, hardwareBottom: 20, isRegularWidth: true),
]

/// 手机横屏：宽度是左右安全区以内。顶部一律按 78（刘海机实测）算，SE 没有刘海、实际只会更矮，算多不算少。
private let landscapeDevices: [HeroDevice] = [
    HeroDevice(name: "SE 横屏", width: 667, height: 375, statusTop: 0, hardwareBottom: 0, isCompactHeight: true),
    HeroDevice(name: "15 Pro 横屏", width: 852 - 59 - 59, height: 393, statusTop: 0, hardwareBottom: 21,
               isCompactHeight: true),
    HeroDevice(name: "Pro Max 横屏", width: 956 - 62 - 62, height: 440, statusTop: 0, hardwareBottom: 21,
               isCompactHeight: true),
    // 横握：左侧 84 是系统竖栏。
    HeroDevice(name: "Duo 外屏横握", width: 678 - 84, height: 466, statusTop: 0, hardwareBottom: 34,
               isCompactHeight: true, measuredTop: 82),
]

private let landscape = landscapeDevices[1]

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

/// 手机横屏下操作行底边离顶部安全区下沿多远（照抄视图层的横屏结构）。标题一行。
private func compactActionRowBottom(
    _ kind: String,
    layout: LibraryDetailHeroLayout,
    typeSize: LibraryDetailTypeSize
) -> Double {
    let tier = layout.titleTier
    let actions = layout.actionRowHeight
    let lines = Policy.compactTitleLineLimit
    func besideArtwork(artwork: Double, identity: Double) -> Double {
        switch layout.compactStyle {
        case .besideArtwork:
            return Policy.Compact.top + max(artwork, identity + Policy.Compact.identityToActions + actions)
        case .inline:
            return Policy.Compact.top + max(artwork, identity, actions)
        case nil:
            Issue.record("横屏必须给出头部排法")
            return .infinity
        }
    }
    switch kind {
    case "album":
        let identity = Policy.estimatedIdentityHeight(.album, tier: tier, typeSize: typeSize, titleLines: lines)
        return besideArtwork(artwork: layout.album.ideal, identity: identity)
    case "playlistCover":
        let identity = Policy.estimatedIdentityHeight(.playlistCover, tier: tier, typeSize: typeSize, titleLines: lines)
        return besideArtwork(artwork: layout.playlistCover.ideal, identity: identity)
    case "smartCover":
        // 规则摘要排在头部下面，不占首屏。
        let identity = Policy.estimatedIdentityHeight(.smartCover, tier: tier, typeSize: typeSize, titleLines: lines)
        return besideArtwork(artwork: layout.smartPlaylistCover.ideal, identity: identity)
    case "genre":
        let identity = Policy.estimatedIdentityHeight(.genre, tier: tier, typeSize: typeSize, titleLines: lines)
        return besideArtwork(artwork: layout.genreMosaic.ideal, identity: identity)
    case "artist":
        return layout.artistPosterHeight - Policy.Compact.overlayBottom
    case "playlistWall":
        return layout.playlistWallHeight - Policy.Compact.overlayBottom
    case "smartWall":
        return layout.smartPlaylistWallHeight - Policy.Compact.overlayBottom
    default:
        Issue.record("unknown kind \(kind)")
        return .infinity
    }
}

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

    @Test("手机横屏三种视口 × 字号：首屏露出整条操作行", arguments: landscapeDevices)
    fileprivate func compactLandscapeShowsActionRow(device: HeroDevice) {
        for typeSize in [LibraryDetailTypeSize.large, .xxxLarge] {
            let layout = Policy.layout(for: device.viewport(typeSize))
            #expect(layout.isCompactHeight)
            #expect(layout.actionRow == .singleRow)
            #expect(layout.bodyMaxWidth == nil)
            let limit = layout.firstScreenHeight - Policy.firstScreenMargin
            for kind in heroKinds {
                let bottom = compactActionRowBottom(kind, layout: layout, typeSize: typeSize)
                #expect(
                    bottom <= limit,
                    "\(device) \(typeSize) \(kind): 操作行底边 \(bottom) 超出首屏 \(limit)"
                )
            }
            // 压在海报 / 墙面下沿的那一行放得进头图里。
            let artistRow = Policy.estimatedArtistCompactRowHeight(typeSize: typeSize)
            #expect(artistRow + Policy.Compact.overlayBottom <= layout.artistPosterHeight, "\(device) \(typeSize)")
            let wallRow = Policy.estimatedWallCompactRowHeight(typeSize: typeSize)
            #expect(wallRow + Policy.Compact.overlayBottom <= layout.playlistWallHeight, "\(device) \(typeSize)")
        }
    }

    @Test("手机横屏默认字号：操作行挪进封面右栏，封面与右栏齐高")
    func compactLandscapeMovesActionsBesideArtwork() {
        for device in landscapeDevices {
            let layout = Policy.layout(for: device.viewport(.large))
            #expect(layout.compactStyle == .besideArtwork, "\(device)")
            let identity = Policy.estimatedIdentityHeight(.album, tier: layout.titleTier, typeSize: .large, titleLines: 1)
            let column = identity + Policy.Compact.identityToActions + layout.actionRowHeight
            #expect(layout.album.ideal == min(max(column, 112), 168).rounded(.down), "\(device)")
            #expect(layout.album.ideal >= 112, "\(device)")
        }
        // 15 Pro 与 Pro Max 用常规标题档；SE 首屏只有 177，标题降一档。
        #expect(Policy.layout(for: landscapeDevices[1].viewport(.large)).titleTier == .regular)
        #expect(Policy.layout(for: landscapeDevices[2].viewport(.large)).titleTier == .regular)
        #expect(Policy.layout(for: landscapeDevices[0].viewport(.large)).titleTier == .reduced)
        // 专辑页原来在 852×393 上只剩 3 点余量，现在操作行底下至少留出 16 + 12。
        let pro = Policy.layout(for: landscape.viewport(.large))
        let bottom = compactActionRowBottom("album", layout: pro, typeSize: .large)
        #expect(pro.firstScreenHeight - bottom >= Policy.firstScreenMargin + 12)
    }

    @Test("手机横屏大字号：右栏叠不下两层时排成一行")
    func compactLandscapeFallsBackToInlineRow() {
        let se = landscapeDevices[0]
        let layout = Policy.layout(for: se.viewport(.xxxLarge))
        #expect(layout.compactStyle == .inline)
        #expect(Policy.layout(for: se.viewport(.large)).compactStyle == .besideArtwork)
    }

    @Test("手机横屏的海报与封面墙按首屏收，大屏不超过原来的取值")
    func compactLandscapePosterAndWall() {
        let proMax = Policy.layout(for: landscapeDevices[2].viewport(.large))
        #expect(proMax.artistPosterHeight == 230)
        let pro = Policy.layout(for: landscape.viewport(.large))
        #expect(pro.artistPosterHeight < 230)
        #expect(pro.artistPosterHeight == (pro.firstScreenHeight - Policy.firstScreenMargin + Policy.Compact.overlayBottom).rounded(.down))
        for device in landscapeDevices {
            let layout = Policy.layout(for: device.viewport(.large))
            #expect(layout.playlistWallHeight >= 150, "\(device)")
            #expect(layout.playlistWallHeight <= 200, "\(device)")
            #expect(layout.smartPlaylistWallHeight == layout.playlistWallHeight, "\(device)")
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
        for device in portraitDevices + landscapeDevices {
            for typeSize in [LibraryDetailTypeSize.large, .accessibility1] {
                let layout = Policy.layout(for: device.viewport(typeSize))
                let lines = Policy.titleLineLimit(layout.titleTier)
                let albumIdentity = Policy.estimatedIdentityHeight(.album, tier: layout.titleTier, typeSize: typeSize, titleLines: 1)
                let cover = layout.album.resolvedExtent(identityHeight: albumIdentity)
                let limit = layout.firstScreenHeight - Policy.firstScreenMargin
                let fits = heroKinds.allSatisfy { kind in
                    let bottom = layout.isCompactHeight
                        ? compactActionRowBottom(kind, layout: layout, typeSize: typeSize)
                        : actionRowBottom(kind, layout: layout, typeSize: typeSize, titleLines: lines)
                    return bottom <= limit
                }
                let style = layout.compactStyle.map { "\t\($0)" } ?? ""
                rows.append("\(device.name)\t\(typeSize)\tF=\(Int(layout.firstScreenHeight))\tcover=\(Int(cover))/\(Int(layout.album.ideal))\tposter=\(Int(layout.artistPosterHeight))\twall=\(Int(layout.playlistWallHeight))\t\(layout.actionRow)\t\(layout.titleTier)\tfits=\(fits)\(style)")
            }
        }
        print("HERO_TABLE\n" + rows.joined(separator: "\n"))
    }
}
