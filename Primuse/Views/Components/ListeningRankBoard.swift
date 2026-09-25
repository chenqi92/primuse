import SwiftUI
import PrimuseKit

/// 听歌排行的公共零件。首页的「听歌排行」和统计页的榜单共用同一套领奖台、
/// 名次行、名次变化标记与大数字货架卡 —— 两处各画各的，样子迟早会走散。
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

    @ViewBuilder
    private var placeholder: some View {
        if isArtist {
            RoundedRectangle(cornerRadius: size / 2, style: .continuous)
                .fill(.quaternary)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "music.mic")
                        .font(.system(size: size * 0.36))
                        .foregroundStyle(.secondary)
                }
        } else {
            DefaultCoverArtwork()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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

// MARK: - 领奖台

/// 前三名的站位：亚军、冠军、季军，脚下一条台基。
struct ListeningRankPodium<Column: View>: View {
    let count: Int
    @ViewBuilder let column: (Int) -> Column

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(HomeListeningRankBoardPolicy.podiumOrder(count: count), id: \.self) { place in
                    column(place).frame(maxWidth: 156)
                }
            }
            .padding(.horizontal, 8)

            Capsule()
                .fill(.primary.opacity(0.1))
                .frame(height: 4)
        }
    }
}

struct ListeningRankPodiumMetrics {
    /// 冠军的封面边长。
    var championArtwork: CGFloat = 96
    var runnerUpArtwork: CGFloat = 74
    /// 冠军脚下那一级的高度，其余两级按 Kit 里的比例缩。
    var championStep: CGFloat = 62

    /// 手机横屏：整块要控制在视口的一半以内。
    static let compactHeight = ListeningRankPodiumMetrics(
        championArtwork: 72, runnerUpArtwork: 58, championStep: 44
    )
    /// 统计页的表单行里不需要首页那么大的排场。
    static let form = ListeningRankPodiumMetrics(
        championArtwork: 84, runnerUpArtwork: 66, championStep: 52
    )

    func artwork(place: Int) -> CGFloat {
        place == 0 ? championArtwork : runnerUpArtwork
    }

    func step(place: Int) -> CGFloat {
        let fraction = CGFloat(HomeListeningRankBoardPolicy.stepHeightFraction(place: place))
        return (championStep * fraction).rounded()
    }
}

/// 领奖台上的一位：上半截是 `ListeningRankPodiumHeadline`（由页面包成按钮），
/// 脚下一级写着名次的台阶。台阶不参与点击，这样上半截下面还能再放一排
/// 评分之类的控件，而不至于按钮套按钮。
struct ListeningRankPodiumColumn<Headline: View>: View {
    let place: Int
    /// 取色用哪首歌的封面。没有就用主题色 / 中性灰。
    let tintSong: Song?
    var metrics = ListeningRankPodiumMetrics()
    @ViewBuilder let headline: () -> Headline

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasRisen = false

    var body: some View {
        VStack(spacing: 8) {
            headline()
            ListeningRankPodiumStep(place: place, tintSong: tintSong, height: metrics.step(place: place))
        }
        .frame(maxWidth: .infinity)
        // 入场只动透明度和位移，不动布局：台阶真的从 0 长高会把下面的区块
        // 一路顶下去再弹回来。
        .opacity(hasRisen ? 1 : 0)
        .offset(y: hasRisen ? 0 : metrics.step(place: place) * 0.6)
        .animation(riseAnimation, value: hasRisen)
        .onAppear { hasRisen = true }
    }

    /// 季军先站上来，冠军压轴。
    private var riseAnimation: Animation? {
        PMMotion.selection.resolved(reduceMotion: reduceMotion)?
            .delay(Double(HomeListeningRankBoardPolicy.podiumSize - 1 - place) * 0.07)
    }
}

/// 领奖台一位的上半截：皇冠（仅冠军）、封面、名字、次数。
struct ListeningRankPodiumHeadline<Artwork: View>: View {
    let place: Int
    let title: String
    let subtitle: String
    let playCount: Int
    let trend: HomeListeningRankTrend?
    var metrics = ListeningRankPodiumMetrics()
    @ViewBuilder let artwork: (CGFloat) -> Artwork

    var body: some View {
        VStack(spacing: 3) {
            if place == 0 {
                Image(systemName: "crown.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.yellow.gradient)
                    .rotationEffect(.degrees(-8))
            }

            artwork(metrics.artwork(place: place))
                .shadow(color: .black.opacity(place == 0 ? 0.2 : 0.12), radius: place == 0 ? 9 : 5, y: 4)
                .padding(.bottom, 4)

            // 各列底边对齐，冠军的名字多占一行只是把它的封面再托高一点。
            Text(title)
                .font(place == 0 ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(place == 0 ? 2 : 1)

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 4) {
                ListeningRankTrendBadge(trend: trend)
                // 「%d reproducciones」这类译文在三分之一屏宽里放不下原字号。
                Text(ListeningRankText.playCount(playCount))
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            ListeningRankText.accessibilityLabel(
                position: place, title: title, playCount: playCount, trend: trend
            )
        )
    }
}

/// 台阶的颜色取自站在上面那张封面。单独成一个视图，是为了取色缓存一更新
/// 只重画这三小块，而不是整个排行区块。
private struct ListeningRankPodiumStep: View {
    let place: Int
    let tintSong: Song?
    let height: CGFloat
    @Environment(CoverTintProvider.self) private var tintProvider: CoverTintProvider?

    var body: some View {
        let tint = tintSong.flatMap { tintProvider?.tint(forSongID: $0.id) }
        UnevenRoundedRectangle(topLeadingRadius: 11, topTrailingRadius: 11, style: .continuous)
            .fill(fill(tint))
            .frame(height: height)
            .overlay {
                Text(verbatim: "\(place + 1)")
                    .font(.system(size: numeralSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(.primary.opacity(place == 0 ? 0.78 : 0.5))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .pmAnimation(.ambient, value: tint != nil)
            .accessibilityHidden(true)
            .task(id: tintSong?.id) {
                if let tintSong { tintProvider?.prepare([tintSong]) }
            }
    }

    private var numeralSize: CGFloat {
        min(30, max(15, height * 0.52))
    }

    private func fill(_ tint: Color?) -> LinearGradient {
        let base: Color = tint ?? (place == 0 ? Color.accentColor : Color.secondary)
        let strength: Double = place == 0 ? 1 : 0.72
        return LinearGradient(
            colors: [base.opacity(0.46 * strength), base.opacity(0.12 * strength)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - 名次行

/// 第四名起的一行。
struct ListeningRankRowLabel<Artwork: View>: View {
    enum ShareStyle {
        /// 整行底色按占比铺开 —— 榜单本身就是一张横向条形图。用在自绘的卡片里。
        case rowFill
        /// 标题下面一条细线。表单行的底色归系统管，铺不了整行。
        case underline
    }

    let position: Int
    let title: String
    let subtitle: String
    let playCount: Int
    let listenedSeconds: TimeInterval
    let trend: HomeListeningRankTrend?
    /// 相对榜首的播放占比，0...1。
    let share: Double
    var shareStyle: ShareStyle = .rowFill
    @ViewBuilder let artwork: () -> Artwork

    var body: some View {
        HStack(spacing: 11) {
            VStack(spacing: 2) {
                Text(verbatim: "\(position + 1)")
                    .font(.system(.subheadline, design: .rounded).weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                ListeningRankTrendBadge(trend: trend)
            }
            .frame(width: 30)

            artwork()

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

                if shareStyle == .underline {
                    shareBar.frame(height: 3).padding(.top, 2)
                }
            }

            Spacer(minLength: 6)

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
        .padding(.horizontal, shareStyle == .rowFill ? 12 : 0)
        .padding(.vertical, shareStyle == .rowFill ? 9 : 2)
        .background(alignment: .leading) {
            if shareStyle == .rowFill {
                GeometryReader { geometry in
                    let width: CGFloat = geometry.size.width * CGFloat(share)
                    Rectangle()
                        .fill(.tint.opacity(0.08))
                        .frame(width: width)
                }
                .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            ListeningRankText.accessibilityLabel(
                position: position, title: title, playCount: playCount, trend: trend
            )
        )
    }

    private var shareBar: some View {
        GeometryReader { geometry in
            let width: CGFloat = geometry.size.width * CGFloat(share)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(.tint.opacity(0.6)).frame(width: width)
            }
        }
        .accessibilityHidden(true)
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

    /// 前三名用主题色，往后退成中性灰 —— 一眼分得出领奖台和其余名次。
    private var numeralFill: LinearGradient {
        let base: Color = position < HomeListeningRankBoardPolicy.podiumSize ? Color.accentColor : Color.primary
        let top: Double = position < HomeListeningRankBoardPolicy.podiumSize ? 0.95 : 0.5
        return LinearGradient(
            colors: [base.opacity(top), base.opacity(top * 0.3)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - 统计页

/// 统计页「排行榜」一节的内容：前三名合成一行领奖台，第四名起逐行。
///
/// body 直接产出多行，由外层的 Form 分节去排。这里不能套 LazyVGrid 之类自适应
/// 高度的惰性容器 —— 表单行里的惰性网格会和 cell 的自适应高度形成布局反馈环，
/// 统计页的日历就因此崩过。
struct ListeningStatsRankList: View {
    let items: [PlayHistoryStore.RankedItem]
    let isArtistRanking: Bool
    /// 换榜（歌曲 / 艺人 / 专辑、时间范围）时变化，领奖台据此重新入场。
    let identity: String
    @Environment(MusicLibrary.self) private var library: MusicLibrary?

    var body: some View {
        let podiumCount = min(items.count, HomeListeningRankBoardPolicy.podiumSize)
        let leaderPlayCount = items.first?.playCount ?? 0

        ListeningRankPodium(count: podiumCount) { place in
            let item = items[place]
            ListeningRankPodiumColumn(place: place, tintSong: song(for: item), metrics: .form) {
                ListeningRankPodiumHeadline(
                    place: place, title: item.title, subtitle: item.subtitle,
                    playCount: item.playCount, trend: nil, metrics: .form
                ) { size in
                    ListeningRankArtwork(
                        song: song(for: item), size: size,
                        isArtist: isArtistRanking, cornerRadius: place == 0 ? 12 : 10
                    )
                }
            }
        }
        .id(identity)
        .padding(.top, 6)
        .listRowSeparator(.hidden, edges: .bottom)

        ForEach(Array(items.enumerated().dropFirst(HomeListeningRankBoardPolicy.podiumSize)), id: \.element.id) { position, item in
            ListeningRankRowLabel(
                position: position, title: item.title, subtitle: item.subtitle,
                playCount: item.playCount, listenedSeconds: item.totalSec, trend: nil,
                share: HomeListeningRankBoardPolicy.share(
                    playCount: item.playCount, leaderPlayCount: leaderPlayCount
                ),
                shareStyle: .underline
            ) {
                ListeningRankArtwork(song: song(for: item), size: 40, isArtist: isArtistRanking, cornerRadius: 7)
            }
        }
    }

    private func song(for item: PlayHistoryStore.RankedItem) -> Song? {
        item.artworkSongID.flatMap { library?.unobservedVisibleSong(id: $0) }
    }
}
