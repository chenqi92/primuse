#if os(iOS)
import SwiftUI
import PrimuseKit

/// 首页顶部的封面轮播:今天挑出的几张音乐封面(见 `HomeHeroCarouselSelection`)左右滑着看,
/// 居中那张最大、两边的依次缩小并朝中间转开、叠在后面。
///
/// - 点居中的封面、或者点「随机播放」:先放这一首,其余音乐随机接在后面。
/// - 点两边的封面:把它挪到中间。
/// - 点封面下面的歌名:前往专辑。
///
/// 立体效果只挂在每张定尺寸的卡片上(`visualEffect`),不挂在任何 ScrollView 或它的上层 ——
/// 把透视变换挂到滚动视图上在 iOS 27 上闪退过。
struct HomeHeroCarousel: View {
    let songs: [Song]
    let greeting: String
    /// 界面编辑里只看版面:不响应点击,也不接长按菜单。
    let isInteractive: Bool
    let playFromSong: (Song) -> Void
    let playAll: () -> Void

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(CoverTintProvider.self) private var tintProvider
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var centeredID: String?
    @State private var viewportWidth: CGFloat = 0

    init(
        songs: [Song],
        greeting: String,
        isInteractive: Bool,
        playFromSong: @escaping (Song) -> Void,
        playAll: @escaping () -> Void
    ) {
        self.songs = songs
        self.greeting = greeting
        self.isInteractive = isInteractive
        self.playFromSong = playFromSong
        self.playAll = playAll
        _centeredID = State(initialValue: Self.initialID(in: songs))
    }

    var body: some View {
        let metrics = HomeHeroCarouselMetrics(viewportWidth: viewportWidth)
        VStack(spacing: 0) {
            Text(greeting)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)

            carousel(metrics)
                .padding(.top, 2)

            caption
                .padding(.top, 4)

            pageDots
                .padding(.top, 10)

            buttons
                .padding(.top, 14)
                .padding(.horizontal, 16)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            viewportWidth = width
        }
        .task(id: songs.map(\.id)) {
            tintProvider.prepare(songs)
        }
    }

    private static func initialID(in songs: [Song]) -> String? {
        guard !songs.isEmpty else { return nil }
        let index = HomeHeroCarouselSelection.initialIndex(count: songs.count)
        return songs[min(index, songs.count - 1)].id
    }

    private var centeredIndex: Int {
        if let centeredID, let index = songs.firstIndex(where: { $0.id == centeredID }) {
            return index
        }
        return min(HomeHeroCarouselSelection.initialIndex(count: songs.count), max(0, songs.count - 1))
    }

    private var centeredSong: Song? {
        songs.indices.contains(centeredIndex) ? songs[centeredIndex] : nil
    }

    // MARK: - 轮播

    private func carousel(_ metrics: HomeHeroCarouselMetrics) -> some View {
        // visualEffect 的闭包是 @Sendable 的,读不到视图成员;用到的值先取成局部常量。
        let side = metrics.cardSide
        let step = metrics.step
        let viewport = metrics.viewportWidth
        let fallbackCenter = metrics.viewportWidth / 2 - metrics.sideMargin
        let reducesMotion = reduceMotion
        let centered = centeredIndex
        let ids = songs.map(\.id)
        return ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: metrics.spacing) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        card(song, isCentered: index == centered, side: side) { id in
                            pmWithAnimation(.selection) {
                                centeredID = id
                                reader.scrollTo(id, anchor: .center)
                            }
                        }
                        .visualEffect { content, proxy in
                            // 离中线多远,在这张卡自己的坐标里量:`bounds(of:)` 给的是换算到本地坐标的
                            // 滚动视图范围。滚动视图坐标系的原点在内容边距以内,拿可见宽度的一半当中线
                            // 会把每张卡都算偏一个边距;本地坐标与滚动坐标混着减又会把距离算成两倍。
                            let space = NamedCoordinateSpace.scrollView(axis: .horizontal)
                            let offset: CGFloat
                            if let bounds = proxy.bounds(of: space) {
                                offset = proxy.size.width / 2 - bounds.midX
                            } else {
                                offset = proxy.frame(in: space).midX - fallbackCenter
                            }
                            return homeHeroCarouselEffect(
                                content,
                                offsetFromCenter: offset,
                                side: side,
                                step: step,
                                reduceMotion: reducesMotion
                            )
                        }
                        // 居中的叠在最上面,越往两边越靠后。
                        .zIndex(-Double(abs(index - centered)))
                    }
                }
                .padding(.vertical, metrics.verticalBleed)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $centeredID, anchor: .center)
            .contentMargins(.horizontal, metrics.sideMargin, for: .scrollContent)
            // scrollPosition 的初值不会把轮播滚过去(编译机模拟器上实测停在第一张,而居中记的是
            // 正中那张,叠放与压暗全按错的那张算),所以出现、换了一组、宽度变了都显式滚一次。
            .task(id: RecenterKey(ids: ids, width: viewport)) {
                // 换了一组(隔天、加了新歌):原来居中的那张还在就留着,不在了回到正中。
                if centeredID.map({ !ids.contains($0) }) ?? true {
                    centeredID = Self.initialID(in: songs)
                }
                // 等这一轮布局把卡片摆上去再滚,内容刚换的同一轮里滚动会落空。
                await Task.yield()
                guard !Task.isCancelled, let centeredID else { return }
                reader.scrollTo(centeredID, anchor: .center)
            }
        }
        .background { glow() }
    }

    private struct RecenterKey: Equatable {
        let ids: [String]
        let width: CGFloat
    }

    private func card(
        _ song: Song,
        isCentered: Bool,
        side: CGFloat,
        bringToCenter: @escaping (String) -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: HomeHeroCarouselMetrics.cornerRadius, style: .continuous)
        return Button {
            if isCentered {
                playFromSong(song)
            } else {
                bringToCenter(song.id)
            }
        } label: {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: side,
                cornerRadius: HomeHeroCarouselMetrics.cornerRadius,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
            .overlay {
                // 不在中间的压暗一点,视线自然落到正中那张上。
                shape.fill(Color.black.opacity(isCentered ? 0 : 0.22))
                    .pmAnimation(.control, value: isCentered)
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            }
            .contentShape(shape)
            .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
        }
        .buttonStyle(.pmPressable)
        .frame(width: side, height: side)
        .allowsHitTesting(isInteractive)
        .contextMenu {
            if isInteractive {
                Button {
                    _ = player.insertNextInQueue([song])
                } label: {
                    Label("insert_next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    player.appendToQueue([song])
                } label: {
                    Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            }
        }
        .accessibilityLabel(Text(verbatim: accessibilityText(for: song)))
        .accessibilityHint(isCentered ? Text("shuffle") : Text(""))
        .accessibilityAddTraits(isCentered ? .isSelected : [])
    }

    /// 居中封面的取色在背后晕开一圈,换到下一张时跟着淡过去。
    /// 椭圆贴着轮播的边框、到边上正好淡完,上下不留一道硬边。
    private func glow() -> some View {
        ZStack {
            if let centeredSong, let tint = tintProvider.tint(forSongID: centeredSong.id) {
                EllipticalGradient(
                    colors: [tint.opacity(0.45), tint.opacity(0.18), tint.opacity(0)],
                    center: .center,
                    startRadiusFraction: 0,
                    endRadiusFraction: 0.5
                )
                .id(centeredSong.id)
                .transition(.opacity)
            }
        }
        .pmAnimation(.ambient, value: centeredID)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - 歌名、圆点、按钮

    @ViewBuilder
    private var caption: some View {
        let song = centeredSong
        let label = VStack(spacing: 2) {
            Text(verbatim: song?.title ?? " ")
                .font(.headline)
                .foregroundStyle(.primary)
            Text(verbatim: song.flatMap { library.artistDisplayName(for: $0) } ?? " ")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .contentTransition(.opacity)
        .pmAnimation(.trackChange, value: centeredID)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)

        if isInteractive, let albumID = song?.albumID, let album = library.visibleAlbum(id: albumID) {
            NavigationLink(value: album) {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("go_to_album"))
        } else {
            label
        }
    }

    private var pageDots: some View {
        let current = centeredIndex
        return HStack(spacing: 7) {
            ForEach(songs.indices, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.32))
                    .frame(width: 6, height: 6)
            }
        }
        .pmAnimation(.selection, value: current)
        .accessibilityHidden(true)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button {
                if let centeredSong { playFromSong(centeredSong) }
            } label: {
                Label("shuffle", systemImage: "shuffle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())

            Button(action: playAll) {
                Label("play_all", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.bordered)
            .clipShape(Capsule())
        }
    }

    private func accessibilityText(for song: Song) -> String {
        guard let artist = library.artistDisplayName(for: song), !artist.isEmpty else { return song.title }
        return "\(song.title), \(artist)"
    }
}

/// 轮播的尺寸。首页加载占位也按它画,换成真内容时高度不跳。
struct HomeHeroCarouselMetrics {
    static let cornerRadius: CGFloat = 18
    /// 还没量到宽度的第一帧按常见手机宽度排。
    static let fallbackWidth: CGFloat = 393

    let viewportWidth: CGFloat
    let cardSide: CGFloat

    init(viewportWidth: CGFloat) {
        let width = viewportWidth > 0 ? viewportWidth : Self.fallbackWidth
        self.viewportWidth = width
        let proposed = (width * 0.5).rounded()
        cardSide = min(max(proposed, 160), 300)
    }

    /// 相邻两张在滚动方向上相隔的距离:手指挪多远,邻居就差不多挪到正中,不像隔着齿轮。
    var step: CGFloat { (cardSide * 0.56).rounded() }
    var spacing: CGFloat { step - cardSide }
    /// 第一张、最后一张也能停在正中。
    var sideMargin: CGFloat { max(0, (viewportWidth - cardSide) / 2) }
    /// 给阴影和转开后变高的近边留的上下空间。
    var verticalBleed: CGFloat { 16 }
    var carouselHeight: CGFloat { cardSide + verticalBleed * 2 }
}

/// 一张卡离中心越远:越往中间收拢(叠在居中那张后面)、越小、朝中间转开,太远的淡出。
///
/// 写成文件内的自由函数 —— `visualEffect` 的闭包不继承视图的 MainActor 隔离。
/// 开启「减少动态效果」时不转,只保留叠放与缩小。
private func homeHeroCarouselEffect(
    _ content: EmptyVisualEffect,
    offsetFromCenter: CGFloat,
    side: CGFloat,
    step: CGFloat,
    reduceMotion: Bool
) -> some VisualEffect {
    let position: CGFloat = step > 0 ? offsetFromCenter / step : 0
    let distance: CGFloat = min(abs(position), 6)
    let direction: CGFloat = position < 0 ? -1 : 1
    let spread: CGFloat = homeHeroCarouselInterpolate([0, 0.52, 0.74, 0.9, 1.02], at: distance, tail: 0.1)
    let shift: CGFloat = direction * spread * side - position * step
    let scale: CGFloat = homeHeroCarouselInterpolate([1, 0.8, 0.66, 0.56, 0.48], at: distance, tail: 0)
    let turn: CGFloat = max(-1, min(1, position))
    let degrees: Double = reduceMotion ? 0 : Double(turn) * -34
    let opacity: Double = distance <= 3 ? 1 : max(0, Double(4 - distance))
    return content
        .scaleEffect(scale)
        .rotation3DEffect(.degrees(degrees), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .offset(x: shift)
        .opacity(opacity)
}

/// 按整数位置上的取值做分段线性插值,超出最后一段按 `tail` 的斜率继续。
private func homeHeroCarouselInterpolate(_ anchors: [CGFloat], at distance: CGFloat, tail: CGFloat) -> CGFloat {
    guard let last = anchors.last else { return 0 }
    let lastIndex = anchors.count - 1
    let lower = Int(distance.rounded(.down))
    if lower >= lastIndex {
        return last + (distance - CGFloat(lastIndex)) * tail
    }
    let fraction: CGFloat = distance - CGFloat(lower)
    let start: CGFloat = anchors[lower]
    let end: CGFloat = anchors[lower + 1]
    return start + (end - start) * fraction
}
#endif
