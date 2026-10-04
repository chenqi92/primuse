import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - 配色
//
// 年度报告从上往下一章接一章，每章一种底色：浅色模式下是很淡的奶油、杏、薰衣草、
// 薄荷，深色模式下是同一色相的深夜色，全部取自插画里的那几种颜色。每一章的底从自己
// 的颜色渐变到下一章的颜色，整页连成一条色带，不再是一张张拼起来的卡片。
// 正文用系统的主 / 次文字色，两种模式下都读得清。

enum YearlyReportPalette {
    /// 章节名、名次、按钮。浅色下是插画里的紫，深色下是插画里的橙（紫在深底上不够亮）。
    static let accent = Color(light: (92, 64, 192), dark: (246, 168, 86))
}

/// 每一章的底色。时段和月份跟着内容变：深夜一章是夜蓝，八月一章是盛夏的天蓝。
enum YearlyReportTone: Hashable, Sendable {
    case cover, firstSong, artists, songs, taste, moments, sources, personality, closing
    case time(ListeningDaypart)
    case month(Int)

    var color: Color {
        switch self {
        case .cover: Color(light: (255, 243, 228), dark: (34, 25, 52))
        case .firstSong: Color(light: (253, 235, 222), dark: (44, 26, 42))
        case .artists: Color(light: (244, 236, 255), dark: (32, 24, 62))
        case .songs: Color(light: (235, 238, 255), dark: (22, 27, 60))
        case .taste: Color(light: (233, 245, 238), dark: (16, 36, 42))
        case .moments: Color(light: (255, 243, 219), dark: (44, 33, 22))
        case .sources: Color(light: (238, 236, 255), dark: (26, 24, 56))
        case .personality: Color(light: (245, 234, 255), dark: (40, 22, 58))
        case .closing: Color(light: (255, 235, 225), dark: (46, 20, 30))
        case .time(let daypart):
            switch daypart {
            case .dawn: Color(light: (255, 237, 221), dark: (48, 30, 46))
            case .morning, .afternoon: Color(light: (229, 242, 255), dark: (17, 34, 58))
            case .evening: Color(light: (255, 232, 214), dark: (52, 28, 36))
            case .lateNight: Color(light: (232, 230, 251), dark: (15, 18, 44))
            }
        case .month(let month):
            switch month {
            case 3...5: Color(light: (239, 248, 229), dark: (24, 38, 30))
            case 6...8: Color(light: (230, 245, 255), dark: (15, 35, 56))
            case 9...11: Color(light: (255, 238, 221), dark: (50, 32, 24))
            default: Color(light: (235, 240, 252), dark: (22, 26, 48))
            }
        }
    }
}

private extension Color {
    /// 浅色、深色各一个值。
    init(light: (Int, Int, Int), dark: (Int, Int, Int)) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
            return NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        })
        #else
        self.init(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        })
        #endif
    }
}

// MARK: - 插画

/// 一章的插画：资源名、找不到图时的 SF Symbol，以及最大尺寸（宽图按宽、方图按高收）。
struct YearlyArt: Hashable {
    let name: String
    let fallbackSymbol: String
    var maxWidth: CGFloat = 320
    var maxHeight: CGFloat = 180
}

/// 插画统一是贴纸风格的透明 PNG（同一个戴耳机的角色、同一套紫橙配色），命名见
/// `personality_<CODE>` / `timeofday_<dawn|noon|dusk|night>` / `month_<01..12>` / `decor_<name>`。
/// 资源缺失时用一圈淡底加 SF Symbol 兜底，版面不塌。
struct YearlyArtView: View {
    let art: YearlyArt

    var body: some View {
        Group {
            if let image = Self.image(named: art.name) {
                image
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                fallback
            }
        }
        .frame(maxWidth: art.maxWidth, maxHeight: art.maxHeight)
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        let side = min(art.maxWidth, art.maxHeight) * 0.8
        return Circle()
            .fill(YearlyReportPalette.accent.opacity(0.10))
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: art.fallbackSymbol)
                    .font(.system(size: side * 0.36, weight: .light))
                    .foregroundStyle(YearlyReportPalette.accent.opacity(0.8))
            }
    }

    static func image(named name: String) -> Image? {
        #if os(iOS)
        UIImage(named: name).map { Image(uiImage: $0) }
        #else
        NSImage(named: name).map { Image(nsImage: $0) }
        #endif
    }
}

// MARK: - 一章

/// 每一章同一个版式：插画、章节名、大标题、一两句说明，下面是这一章的内容。
/// 标题和说明居中，成块的内容占满整栏。
struct YearlyChapter<Headline: View, Content: View>: View {
    let eyebrow: String
    let art: YearlyArt?
    let lead: [String]
    @ViewBuilder let headline: () -> Headline
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        eyebrow: String,
        art: YearlyArt?,
        lead: [String] = [],
        @ViewBuilder headline: @escaping () -> Headline,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.eyebrow = eyebrow
        self.art = art
        self.lead = lead
        self.headline = headline
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            if let art {
                YearlyArtView(art: art)
                    // 滚进视野时插画轻轻放大落位；「减少动态效果」下静止。
                    .scrollTransition(.interactive, axis: .vertical) { view, phase in
                        view
                            .scaleEffect(reduceMotion || phase.isIdentity ? 1 : 0.92)
                            .opacity(reduceMotion || phase.isIdentity ? 1 : 0.55)
                    }
                    .padding(.bottom, 22)
            }
            Text(verbatim: eyebrow)
                .font(.footnote.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(YearlyReportPalette.accent)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            headline()
                .padding(.top, 8)
            ForEach(Array(lead.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            content()
                .padding(.top, 24)
        }
        .frame(maxWidth: .infinity)
    }
}

extension YearlyChapter where Content == EmptyView {
    init(
        eyebrow: String,
        art: YearlyArt?,
        lead: [String] = [],
        @ViewBuilder headline: @escaping () -> Headline
    ) {
        self.init(eyebrow: eyebrow, art: art, lead: lead, headline: headline) { EmptyView() }
    }
}

/// 一章的大标题：歌名、艺人名、人格名都用它，长了换行，不缩成看不清的小字。
struct YearlyHeadline: View {
    let text: String
    var style: Font.TextStyle = .title

    var body: some View {
        Text(verbatim: text)
            .font(.system(style, design: .rounded, weight: .bold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 章与章之间的一小段竖线，把上一章接到下一章。
struct YearlyThread: View {
    var body: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [YearlyReportPalette.accent.opacity(0), YearlyReportPalette.accent.opacity(0.4)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 2, height: 40)
            .accessibilityHidden(true)
    }
}

// MARK: - 内容零件

/// 封面那一排数字：居中、平分整行，数字在上、说明在下。
struct YearlyFigureGrid: View {
    let figures: [RecapFigureRow.Figure]

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(figures) { figure in
                VStack(spacing: 4) {
                    Text(verbatim: figure.value)
                        .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(verbatim: figure.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .recapPanel(padding: 16)
    }
}

/// 一组「一句话」：图标加一句完整的话，放在一块衬底里。
struct YearlyFactList: View {
    struct Fact: Identifiable {
        let symbol: String
        let text: String
        var id: String { symbol + text }
    }

    let facts: [Fact]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(facts) { fact in
                RecapMomentRow(symbol: fact.symbol, text: fact.text)
            }
        }
        .recapPanel(padding: 16)
    }
}

/// 一张榜：编号、封面、名字，行尾是次数与时长，整行底色按相对榜首的播放占比铺开
/// （和首页的名次榜同一种行）。收起时露出几行，可以展开。
struct YearlyRankRows: View {
    var title: String?
    let items: [PlayHistoryStore.RankedItem]
    /// 榜首的播放次数，底色按它算占比。
    let leaderPlayCount: Int
    /// 第一行的名次（从 0 数）。
    var firstPosition = 0
    var isArtistRanking = false
    var collapsedCount = 4

    @Environment(MusicLibrary.self) private var library: MusicLibrary?
    @State private var isExpanded = false

    var body: some View {
        let visible = isExpanded ? items : Array(items.prefix(collapsedCount))
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(verbatim: title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { offset, item in
                    if offset > 0 {
                        Divider().padding(.leading, 53)
                    }
                    ListeningRankRowLabel(
                        position: firstPosition + offset,
                        title: item.title,
                        subtitle: item.subtitle,
                        playCount: item.playCount,
                        listenedSeconds: item.totalSec,
                        trend: nil,
                        share: HomeListeningRankBoardPolicy.share(playCount: item.playCount, leaderPlayCount: leaderPlayCount)
                    ) {
                        ListeningRankArtwork(song: song(for: item), size: 42, isArtist: isArtistRanking, cornerRadius: 8)
                    }
                }
                if items.count > collapsedCount {
                    Divider()
                    Button {
                        pmWithAnimation(.list) { isExpanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isExpanded ? LocalizedStringKey("update_show_less") : LocalizedStringKey("see_all"))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.primary.opacity(0.045))
            // 名次行的占比底色是直角的，靠衬底的圆角把四个角裁掉。
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
            }
        }
    }

    private func song(for item: PlayHistoryStore.RankedItem) -> Song? {
        item.artworkSongID.flatMap { library?.unobservedVisibleSong(id: $0) }
    }
}

/// 第一名的大封面（艺人是圆的、尽量用艺人自己的图）。
struct YearlyLeaderArtwork: View {
    let item: PlayHistoryStore.RankedItem
    var isArtist = false
    var size: CGFloat = 132

    @Environment(MusicLibrary.self) private var library: MusicLibrary?

    var body: some View {
        ListeningRankArtwork(
            song: item.artworkSongID.flatMap { library?.unobservedVisibleSong(id: $0) },
            size: size,
            isArtist: isArtist,
            cornerRadius: 18
        )
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
    }
}

/// 最常听的几张专辑：横着一排封面。
struct YearlyAlbumShelf: View {
    let title: String
    let items: [PlayHistoryStore.RankedItem]

    @Environment(MusicLibrary.self) private var library: MusicLibrary?
    private static let cover: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            ListeningRankArtwork(
                                song: item.artworkSongID.flatMap { library?.unobservedVisibleSong(id: $0) },
                                size: Self.cover,
                                cornerRadius: 12
                            )
                            Text(verbatim: item.title)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(verbatim: ListeningRankText.playCount(item.playCount))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: Self.cover, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .scrollClipDisabled()
        }
        .recapPanel(padding: 16)
    }
}

/// 音乐源一行：来源插画、名字、次数，行尾是时长占比。
struct YearlySourceRow: View {
    let share: YearlyReportData.SourceShare
    let percent: Int

    var body: some View {
        HStack(spacing: 14) {
            YearlyArtView(art: YearlyArt(
                name: share.kind.artworkName,
                fallbackSymbol: share.kind.fallbackSymbol,
                maxWidth: 46,
                maxHeight: 46
            ))
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: share.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(verbatim: String(format: String(localized: "yearly_card_genres_plays_format"), share.plays))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(verbatim: "\(percent)%")
                .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 一排标签：放得下就居中一行，放不下折行。
struct YearlyChipRow: View {
    let labels: [String]
    var isEmphasized = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            RecapFlowLayout(spacing: 6) { chips }
        }
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(labels, id: \.self) { RecapChip(text: $0, isEmphasized: isEmphasized) }
    }
}
