import SwiftUI
import PrimuseKit

/// 听歌排行的公共零件：第一名聚光、编号名次行、名次变化标记与大数字货架卡。
/// 首页「听歌排行」和听歌统计的榜单共用 —— 两处各画各的，样子迟早会走散。
///
/// 这里只管「长什么样」：点了播什么、跳到哪，由各自的页面包一层 Button /
/// NavigationLink 决定。名次怎么排、台阶多高、露出几名都在 Kit 的
/// `HomeListeningRankBoardPolicy` 里。
enum ListeningRankText {
    static func playCount(_ count: Int) -> String {
        String(format: HomeDiscoveryText.string("play_count"), count)
    }

    /// 单次播放可能只有三四十秒，只给「时、分」会显示成 0 分钟。
    static func duration(_ seconds: TimeInterval) -> String {
        let bounded: TimeInterval = seconds.isFinite ? max(0, seconds) : 0
        let units: Set<Duration.UnitsFormatStyle.Unit> = bounded < 60 ? [.seconds] : [.hours, .minutes]
        return Duration.seconds(bounded).formatted(.units(allowed: units, width: .abbreviated))
    }

    static func trendDescription(_ trend: HomeListeningRankTrend?) -> String? {
        switch trend {
        case .up(let positions):
            return String(format: HomeDiscoveryText.string("positions_gained"), positions)
        case .down(let positions):
            return String(format: HomeDiscoveryText.string("positions_lost"), positions)
        case .newEntry:
            return HomeDiscoveryText.string("new_entry")
        case .steady, .none:
            return nil
        }
    }

    static func accessibilityLabel(
        position: Int, title: String, playCount: Int, trend: HomeListeningRankTrend?
    ) -> String {
        var parts = ["\(position + 1)", title, Self.playCount(playCount)]
        if let trend = trendDescription(trend) { parts.append(trend) }
        return parts.joined(separator: ", ")
    }
}

/// 一名上榜项目的封面。艺人榜用圆形，并尽量换成艺人自己的图 —— 歌曲封面裁成
/// 圆的只是退路。
struct ListeningRankArtwork: View {
    let song: Song?
    let size: CGFloat
    var isArtist = false
    var cornerRadius: CGFloat = 9
    // 统计页会出现在设置、资料库等好几个入口下。可选读取在缺环境对象的宿主里
    // 只是退成占位图，不会像必读那样当场闪退。
    @Environment(MusicLibrary.self) private var library: MusicLibrary?
    @Environment(SourceManager.self) private var sourceManager: SourceManager?

    var body: some View {
        Group {
            if library == nil || sourceManager == nil {
                placeholder
            } else if isArtist, let artistID = song?.artistID,
                      let artist = library?.visibleArtist(id: artistID) {
                ArtistArtworkView(artist: artist, size: size, cornerRadius: size / 2)
            } else {
                CachedArtworkView(
                    coverRef: song?.coverArtFileName, songID: song?.id, size: size,
                    cornerRadius: isArtist ? size / 2 : cornerRadius,
                    sourceID: song?.sourceID, filePath: song?.filePath, fileFormat: song?.fileFormat,
                    placeholderIcon: isArtist ? "music.mic" : "music.note"
                )
            }
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: isArtist ? size / 2 : cornerRadius, style: .continuous)
            .fill(.quaternary)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: isArtist ? "music.mic" : "music.note")
                    .font(.system(size: size * 0.36))
                    .foregroundStyle(.secondary)
            }
    }
}

/// 与上一个周期相比升了、降了还是新上榜。
///
/// 上升用主题色、下降用灰：红绿在这里没有通行的含义（榜单惯例是绿升红降，
/// 行情惯例在国内正好反过来），用了反而要让人想一下。
struct ListeningRankTrendBadge: View {
    let trend: HomeListeningRankTrend?

    var body: some View {
        switch trend {
        case .up(let positions):
            movement("arrow.up", positions).foregroundStyle(.tint)
        case .down(let positions):
            movement("arrow.down", positions).foregroundStyle(.secondary)
        case .steady:
            Image(systemName: "minus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
        case .newEntry:
            Text(HomeDiscoveryText.string("new_entry"))
                .font(.system(size: 9, weight: .bold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.tint)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(.tint.opacity(0.14), in: Capsule())
        case .none:
            EmptyView()
        }
    }

    private func movement(_ symbol: String, _ positions: Int) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol).font(.system(size: 8, weight: .heavy))
            Text(verbatim: "\(positions)").font(.system(size: 10, weight: .bold).monospacedDigit())
        }
        .fixedSize()
    }
}

// MARK: - 大数字货架

/// 横排里的一张卡：名次是一个和封面差不多高的大数字，封面压住它半边。
struct ListeningRankShelfCard<Artwork: View>: View {
    let position: Int
    let title: String
    let subtitle: String
    let playCount: Int
    let trend: HomeListeningRankTrend?
    let artworkSize: CGFloat
    @ViewBuilder let artwork: (CGFloat) -> Artwork

    private var isTwoDigit: Bool { position + 1 >= 10 }

    /// 数字自己占的宽度。两位数要宽一些，字号也得收一档，否则 10 以后的卡会
    /// 比前面宽出一大截。
    private var numeralWidth: CGFloat {
        (artworkSize * (isTwoDigit ? 0.74 : 0.5)).rounded()
    }

    private var numeralSize: CGFloat {
        (artworkSize * (isTwoDigit ? 0.66 : 0.92)).rounded()
    }

    /// 封面往数字身上压多少。
    private var overlap: CGFloat { (artworkSize * 0.12).rounded() }

    private var textInset: CGFloat { numeralWidth - overlap }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // 数字的基线对齐封面下沿；外面这层定高把数字基线以下的空白裁出布局，
            // 不然标题会被一截看不见的字母下伸部分顶开。
            HStack(alignment: .lastTextBaseline, spacing: -overlap) {
                Text(verbatim: "\(position + 1)")
                    .font(.system(size: numeralSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(numeralFill)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: numeralWidth, alignment: .trailing)
                    .accessibilityHidden(true)

                artwork(artworkSize)
                    .shadow(color: .black.opacity(0.16), radius: 6, y: 3)
            }
            .frame(height: artworkSize, alignment: .top)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    ListeningRankTrendBadge(trend: trend)
                    Text(ListeningRankText.playCount(playCount))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: artworkSize, alignment: .leading)
            .padding(.leading, textInset)
        }
        .frame(width: textInset + artworkSize, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            ListeningRankText.accessibilityLabel(
                position: position, title: title, playCount: playCount, trend: trend
            )
        )
    }

    /// 前三名用主题色，往后退成中性灰 —— 一眼分得出前三和其余名次。
    private var numeralFill: LinearGradient {
        let base: Color = position < HomeListeningRankBoardPolicy.highlightedPlaces ? Color.accentColor : Color.primary
        let top: Double = position < HomeListeningRankBoardPolicy.highlightedPlaces ? 0.95 : 0.5
        return LinearGradient(
            colors: [base.opacity(top), base.opacity(top * 0.3)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - 第一名聚光与编号行

/// 统计页的榜单：第一名单独一块（大封面、大号名次、播放数据），第二名起是编号行。
/// 不画占比条 —— 播放次数已经写在行尾，再铺一条横条只是噪音。
struct ListeningRankSpotlightList: View {
    let items: [PlayHistoryStore.RankedItem]
    let isArtistRanking: Bool
    /// 换榜（歌曲 / 艺人 / 专辑、时间范围）时变化：收起展开，第一名重新入场。
    let identity: String
    /// 收起时露出几名（含第一名）。
    var collapsedCount = 6
    var spotlightArtwork: CGFloat = 116
    @Environment(MusicLibrary.self) private var library: MusicLibrary?
    @State private var isExpanded = false

    var body: some View {
        let others = Array(items.dropFirst())
        let visible = isExpanded ? others : Array(others.prefix(max(0, collapsedCount - 1)))

        VStack(alignment: .leading, spacing: 0) {
            if let leader = items.first {
                ListeningRankSpotlight(
                    title: leader.title,
                    subtitle: leader.subtitle,
                    playCount: leader.playCount,
                    listenedSeconds: leader.totalSec,
                    artworkSize: spotlightArtwork
                ) { size in
                    ListeningRankArtwork(
                        song: song(for: leader), size: size,
                        isArtist: isArtistRanking, cornerRadius: 16
                    )
                }
                .id(identity)
                .pmAppearFade(.contentAppear)
                .padding(.bottom, visible.isEmpty ? 0 : 14)
            }

            ForEach(Array(visible.enumerated()), id: \.element.id) { offset, item in
                if offset > 0 {
                    Rectangle()
                        .fill(.primary.opacity(0.07))
                        .frame(height: 0.5)
                        .padding(.leading, ListeningRankNumberedRow<EmptyView>.textLeading)
                }
                ListeningRankNumberedRow(
                    position: offset + 1,
                    title: item.title,
                    subtitle: item.subtitle,
                    playCount: item.playCount,
                    listenedSeconds: item.totalSec
                ) {
                    ListeningRankArtwork(
                        song: song(for: item), size: ListeningRankNumberedRow<EmptyView>.artworkSize,
                        isArtist: isArtistRanking, cornerRadius: 8
                    )
                }
            }

            if others.count > collapsedCount - 1 {
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
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .onChange(of: identity) { _, _ in isExpanded = false }
    }

    private func song(for item: PlayHistoryStore.RankedItem) -> Song? {
        item.artworkSongID.flatMap { library?.unobservedVisibleSong(id: $0) }
    }
}

/// 第一名：大封面在左，右边一个大号「1」、名字和这段时间听了多少。
struct ListeningRankSpotlight<Artwork: View>: View {
    let title: String
    let subtitle: String
    let playCount: Int
    let listenedSeconds: TimeInterval
    var trend: HomeListeningRankTrend? = nil
    var artworkSize: CGFloat = 116
    @ViewBuilder let artwork: (CGFloat) -> Artwork

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            artwork(artworkSize)
                .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 10)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text(verbatim: "1")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(.tint)
                    ListeningRankTrendBadge(trend: trend)
                }
                .padding(.bottom, -2)
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(verbatim: ListeningRankText.playCount(playCount) + "  ·  " + ListeningRankText.duration(listenedSeconds))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            ListeningRankText.accessibilityLabel(position: 0, title: title, playCount: playCount, trend: trend)
        )
    }
}

/// 第二名起的一行：名次数字、封面、名字，行尾是次数与时长。
struct ListeningRankNumberedRow<Artwork: View>: View {
    static var artworkSize: CGFloat { 46 }
    static var numberWidth: CGFloat { 30 }
    /// 分隔线从文字开始的位置起画。
    static var textLeading: CGFloat { numberWidth + 10 + artworkSize + 12 }

    let position: Int
    let title: String
    let subtitle: String
    let playCount: Int
    let listenedSeconds: TimeInterval
    var trend: HomeListeningRankTrend? = nil
    @ViewBuilder let artwork: () -> Artwork

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(position + 1)")
                    .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                ListeningRankTrendBadge(trend: trend)
            }
            .frame(width: Self.numberWidth, alignment: .leading)
            .padding(.trailing, 10)

            artwork()
                .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(ListeningRankText.playCount(playCount))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text(ListeningRankText.duration(listenedSeconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            ListeningRankText.accessibilityLabel(position: position, title: title, playCount: playCount, trend: trend)
        )
    }
}
