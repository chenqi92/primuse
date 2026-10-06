#if os(iOS)
import SwiftUI
import PrimuseKit

/// 首页顶部的封面轮播:今天挑出的一圈音乐封面(见 `HomeHeroCarouselSelection`)左右滑着看,
/// 居中那张最大、两边的依次缩小并朝中间转开、叠在后面。首尾相接,往哪边都滑不到头:
/// 同一圈卡片在一条很长的虚拟序列上重复摆开(`HomeHeroCarouselLoop`),惰性堆栈只建
/// 滑到眼前的那几张。
///
/// - 点居中的封面:先放这一首,其余音乐随机接在后面。
/// - 点「随机播放」:整个音乐曲库洗一遍,不从封面那首开始(#185)。
/// - 点两边的封面:把它挪到中间。
/// - 点封面下面的歌名:前往专辑。
///
/// 立体效果只挂在每张定尺寸的卡片上(`visualEffect`),不挂在任何 ScrollView 或它的上层 ——
/// 把透视变换挂到滚动视图上在 iOS 27 上闪退过。
struct HomeHeroCarousel: View {
    let songs: [Song]
    /// 界面编辑里只看版面:不响应点击,也不接长按菜单。
    let isInteractive: Bool
    let playFromSong: (Song) -> Void
    let shuffleAll: () -> Void
    let playAll: () -> Void

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(CoverTintProvider.self) private var tintProvider
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 居中那张在虚拟序列里的格子(不是第几首歌,同一首歌每一圈各有一格)。
    @State private var centeredSlot: Int?
    @State private var viewportWidth: CGFloat = 0
    /// 刚挂上时先画和轮播同形状的骨架,等滚到居中那张、眼前三张封面也读好了(或者等够一会儿)
    /// 再整组淡进来:不露出还没滚到位的那一帧,封面也不一张张蹦出来。
    @State private var isRevealed = false
    @State private var isPositioned = false
    @State private var settledSlots: Set<Int> = []
    @State private var hasPreparedTints = false

    init(
        songs: [Song],
        isInteractive: Bool,
        playFromSong: @escaping (Song) -> Void,
        shuffleAll: @escaping () -> Void,
        playAll: @escaping () -> Void
    ) {
        self.songs = songs
        self.isInteractive = isInteractive
        self.playFromSong = playFromSong
        self.shuffleAll = shuffleAll
        self.playAll = playAll
        _centeredSlot = State(initialValue: Self.initialSlot(in: songs))
    }

    var body: some View {
        let metrics = HomeHeroCarouselMetrics(viewportWidth: viewportWidth)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                carousel(metrics)

                caption
                    .padding(.top, 4)
            }
            .opacity(isRevealed ? 1 : 0)
            .overlay(alignment: .top) {
                if !isRevealed {
                    LoadingSkeletonGroup {
                        HomeHeroCarouselSkeleton(metrics: metrics)
                    }
                    .transition(.opacity)
                }
            }

            buttons
                .padding(.top, HomeHeroCarouselMetrics.buttonsTopSpacing)
                .padding(.horizontal, 16)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            viewportWidth = width
        }
        .task(id: nearbySongs.map(\.id)) {
            // 只给居中和左右各两张取色;一圈几十张一次全取,第一圈光晕要等最后一张。
            // 甩一下连着滑过很多张时,停稳了才取,路过的不取。刚出现那一次不等,光晕和封面一起亮。
            if hasPreparedTints {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            hasPreparedTints = true
            tintProvider.prepare(nearbySongs)
        }
        .task {
            // 封面读得慢(远端源、没有盘缓存)也不一直挂着骨架:到点先亮出来,没到的封面各自淡入。
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            reveal()
        }
    }

    private func noteSettled(_ slot: Int) {
        guard !isRevealed, settledSlots.insert(slot).inserted else { return }
        revealIfReady()
    }

    private func revealIfReady() {
        let center = resolvedCenteredSlot
        guard isPositioned, (center - 1...center + 1).allSatisfy(settledSlots.contains) else { return }
        reveal()
    }

    private func reveal() {
        guard !isRevealed else { return }
        pmWithAnimation(.trackChange) { isRevealed = true }
    }

    private static func initialIndex(in songs: [Song]) -> Int {
        min(HomeHeroCarouselSelection.initialIndex(count: songs.count), max(0, songs.count - 1))
    }

    private static func initialSlot(in songs: [Song]) -> Int {
        HomeHeroCarouselLoop.middleSlot(forIndex: initialIndex(in: songs), itemCount: songs.count)
    }

    private var resolvedCenteredSlot: Int {
        centeredSlot ?? Self.initialSlot(in: songs)
    }

    private var centeredIndex: Int {
        HomeHeroCarouselLoop.index(ofSlot: resolvedCenteredSlot, itemCount: songs.count)
    }

    private var centeredSong: Song? {
        songs.indices.contains(centeredIndex) ? songs[centeredIndex] : nil
    }

    private var nearbySongs: [Song] {
        guard !songs.isEmpty else { return [] }
        let center = resolvedCenteredSlot
        var seen = Set<String>()
        return (-2...2).compactMap { offset in
            let song = songs[HomeHeroCarouselLoop.index(ofSlot: center + offset, itemCount: songs.count)]
            return seen.insert(song.id).inserted ? song : nil
        }
    }

    // MARK: - 轮播

    private func carousel(_ metrics: HomeHeroCarouselMetrics) -> some View {
        // visualEffect 的闭包是 @Sendable 的,读不到视图成员;用到的值先取成局部常量。
        let side = metrics.cardSide
        let step = metrics.step
        let viewport = metrics.viewportWidth
        let fallbackCenter = metrics.viewportWidth / 2 - metrics.sideMargin
        let reducesMotion = reduceMotion
        let centered = resolvedCenteredSlot
        let ids = songs.map(\.id)
        let count = songs.count
        return ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: metrics.spacing) {
                    ForEach(0..<HomeHeroCarouselLoop.slotCount(itemCount: count), id: \.self) { slot in
                        let song = songs[HomeHeroCarouselLoop.index(ofSlot: slot, itemCount: count)]
                        card(song, isCentered: slot == centered, side: side) {
                            pmWithAnimation(.selection) {
                                centeredSlot = slot
                                reader.scrollTo(slot, anchor: .center)
                            }
                        } onSettled: {
                            noteSettled(slot)
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
                        .zIndex(-Double(abs(slot - centered)))
                    }
                }
                .padding(.vertical, metrics.verticalBleed)
                .scrollTargetLayout()
            }
            // 甩得重就一口气滑过好几张,停下时对齐到最近的一张。
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .scrollPosition(id: $centeredSlot, anchor: .center)
            .contentMargins(.horizontal, metrics.sideMargin, for: .scrollContent)
            // 换了一组(隔天、加了新歌):原来居中的那首还在就停在它身上,不在了回到正中那张。
            // 格子号按新的一圈重新算,两组张数不同时同一个格子上放的已经不是同一首歌。
            .onChange(of: ids) { oldIDs, newIDs in
                let oldIndex = HomeHeroCarouselLoop.index(ofSlot: resolvedCenteredSlot, itemCount: oldIDs.count)
                let kept = oldIDs.indices.contains(oldIndex) ? newIDs.firstIndex(of: oldIDs[oldIndex]) : nil
                centeredSlot = HomeHeroCarouselLoop.middleSlot(
                    forIndex: kept ?? Self.initialIndex(in: songs),
                    itemCount: newIDs.count
                )
            }
            // scrollPosition 的初值不会把轮播滚过去(编译机模拟器上实测停在第一张,而居中记的是
            // 正中那张,叠放与压暗全按错的那张算),所以出现、换了一组、宽度变了都显式滚一次。
            .task(id: RecenterKey(ids: ids, width: viewport)) {
                // 等这一轮布局把卡片摆上去再滚,内容刚换的同一轮里滚动会落空。
                await Task.yield()
                guard !Task.isCancelled else { return }
                reader.scrollTo(resolvedCenteredSlot, anchor: .center)
                guard !isPositioned else { return }
                // 滚动要到下一轮布局才落地,再等两帧才算摆好,骨架才能换成封面。
                try? await Task.sleep(for: .milliseconds(32))
                guard !Task.isCancelled else { return }
                isPositioned = true
                revealIfReady()
            }
            // 真滑到了序列外侧:停稳后换到正中那一圈的同一张,两边又各有上千张可滑。
            // 两处摆的是同一首歌,换过去看不出来。
            .onScrollPhaseChange { _, phase in
                guard phase == .idle,
                      let recentered = HomeHeroCarouselLoop.recenteredSlot(resolvedCenteredSlot, itemCount: count)
                else { return }
                centeredSlot = recentered
                reader.scrollTo(recentered, anchor: .center)
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
        bringToCenter: @escaping () -> Void,
        onSettled: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: HomeHeroCarouselMetrics.cornerRadius, style: .continuous)
        return Button {
            if isCentered {
                playFromSong(song)
            } else {
                bringToCenter()
            }
        } label: {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: side,
                cornerRadius: HomeHeroCarouselMetrics.cornerRadius,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat,
                onResolutionChange: { _ in onSettled() }
            )
            // 换了一组(隔天、后台算完)同一个格子换歌:旧封面留到新封面到手再交叉淡入,不先闪空。
            .artworkCrossfade()
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
        let tint = centeredSong.flatMap { tintProvider.tint(forSongID: $0.id) }
        return ZStack {
            if let centeredSong, let tint {
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
        .pmAnimation(.ambient, value: centeredSong?.id)
        // 取色晚到一步时光晕也是淡进来,不是突然出现。
        .pmAnimation(.ambient, value: tint == nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - 歌名、按钮

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
        .pmAnimation(.trackChange, value: centeredSong?.id)
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

    private var buttons: some View {
        HStack(spacing: 10) {
            Button(action: shuffleAll) {
                Self.buttonLabel("shuffle", systemImage: "shuffle")
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())

            Button(action: playAll) {
                Self.buttonLabel("play_all", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .clipShape(Capsule())
        }
    }

    /// 骨架按同一个标签量高度,换成真按钮时下面的区块不跳。
    static func buttonLabel(_ titleKey: LocalizedStringKey, systemImage: String) -> some View {
        Label(titleKey, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
    }

    private func accessibilityText(for song: Song) -> String {
        guard let artist = library.artistDisplayName(for: song), !artist.isEmpty else { return song.title }
        return "\(song.title), \(artist)"
    }
}

/// 轮播的骨架:和轮播同样的位置、大小与转角。首页加载占位、轮播自己还没摆好时都画它,
/// 换成真封面时形状不动,封面在原位淡进来。
struct HomeHeroCarouselSkeleton: View {
    let metrics: HomeHeroCarouselMetrics
    /// 首页加载占位连下面两个按钮一起画;轮播自己的按钮一直是真的,不用画。
    var showsButtons = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fill: Color { Color(uiColor: .secondarySystemBackground) }

    var body: some View {
        VStack(spacing: 0) {
            cards

            captionBars
                .padding(.top, 4)

            if showsButtons {
                HStack(spacing: 10) {
                    placeholderButton(HomeHeroCarousel.buttonLabel("shuffle", systemImage: "shuffle"))
                    placeholderButton(HomeHeroCarousel.buttonLabel("play_all", systemImage: "play.fill"))
                }
                .padding(.top, HomeHeroCarouselMetrics.buttonsTopSpacing)
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    /// 居中一张、两边各三张,叠放、缩小、转角都走轮播同一个函数。
    private var cards: some View {
        let side = metrics.cardSide
        let step = metrics.step
        let reducesMotion = reduceMotion
        let shape = RoundedRectangle(cornerRadius: HomeHeroCarouselMetrics.cornerRadius, style: .continuous)
        return ZStack {
            ForEach(-3...3, id: \.self) { position in
                let offset = CGFloat(position) * step
                shape.fill(fill)
                    .overlay {
                        // 两边的压暗一点、描一道细边,叠在一起时分得出前后,和真封面的层次一样。
                        shape.fill(Color.black.opacity(position == 0 ? 0 : 0.06))
                    }
                    .overlay {
                        shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 6)
                    .frame(width: side, height: side)
                    .visualEffect { content, _ in
                        homeHeroCarouselEffect(
                            content,
                            offsetFromCenter: offset,
                            side: side,
                            step: step,
                            reduceMotion: reducesMotion
                        )
                    }
                    .offset(x: offset)
                    .zIndex(-Double(abs(position)))
            }
        }
        // 外面的脉动是整组改透明度;不先合成成一层,叠在后面的卡会从居中那张里透出来。
        .compositingGroup()
        .frame(maxWidth: .infinity)
        .padding(.vertical, metrics.verticalBleed)
    }

    /// 歌名、歌手两行:用同样字体的空白行撑出高度,条子画在中间。
    private var captionBars: some View {
        VStack(spacing: 2) {
            Text(verbatim: " ")
                .font(.headline)
                .hidden()
                .overlay {
                    Capsule().fill(fill).frame(width: metrics.cardSide * 0.5, height: 12)
                }
            Text(verbatim: " ")
                .font(.subheadline)
                .hidden()
                .overlay {
                    Capsule().fill(fill).frame(width: metrics.cardSide * 0.32, height: 10)
                }
        }
        .frame(maxWidth: .infinity)
    }

    private func placeholderButton(_ label: some View) -> some View {
        Button {} label: { label }
            .buttonStyle(.bordered)
            .clipShape(Capsule())
            .hidden()
            .overlay { Capsule().fill(fill) }
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
    /// 歌名与下面两个按钮之间的距离。
    static let buttonsTopSpacing: CGFloat = 16
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
