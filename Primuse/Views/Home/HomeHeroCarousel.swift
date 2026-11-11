#if os(iOS)
import SwiftUI
import PrimuseKit

enum HomeHeroStyle: String, CaseIterable {
    static let storageKey = "primuse.home.heroStyle.v1"

    case carousel
    case featured
    case medium

    var title: LocalizedStringKey {
        switch self {
        case .carousel: "home_hero_style_carousel"
        case .featured: "home_hero_style_large"
        case .medium: "home_hero_style_medium"
        }
    }
}

struct HomeHeroFeaturedMetrics {
    let cardWidth: CGFloat
    let artworkSide: CGFloat
    let isCompact: Bool

    init(viewportWidth: CGFloat, compactCanvasHeight: CGFloat? = nil, medium: Bool = false) {
        let width = viewportWidth > 0 ? viewportWidth : HomeHeroCarouselMetrics.fallbackWidth
        isCompact = compactCanvasHeight != nil
        if let height = compactCanvasHeight {
            cardWidth = min(max(width - 64, 240), medium ? 280 : 340)
            artworkSide = min(max(height * (medium ? 0.32 : 0.4), 100), medium ? 120 : 150)
        } else {
            cardWidth = medium ? min(max((width - 40) * 0.48, 150), 240) : min(max((width - 40) * 0.76, 200), 360)
            artworkSide = cardWidth
        }
    }

    func cardHeight(captionHeight: CGFloat) -> CGFloat {
        isCompact ? max(artworkSide, captionHeight) : artworkSide + captionHeight
    }
}

struct HomeHeroFeaturedSkeleton: View {
    let metrics: HomeHeroFeaturedMetrics
    @ScaledMetric(relativeTo: .body) private var captionHeight: CGFloat = 84

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(0..<3) { _ in
                    block(width: metrics.cardWidth, height: metrics.cardHeight(captionHeight: captionHeight), cornerRadius: 18)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .scrollDisabled(true)
        .accessibilityHidden(true)
    }

    private func block(width: CGFloat, height: CGFloat, cornerRadius: CGFloat = 5) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(HomeHeroCarouselSkeletonCards.fill)
            .frame(width: width, height: height)
    }
}

/// 首页顶部的封面轮播:今天挑出的一圈音乐封面(见 `HomeHeroCarouselSelection`)左右滑着看,
/// 居中那张最大、两边的依次缩小并朝中间转开、叠在后面。首尾相接,往哪边都滑不到头:
/// 固定数量的卡片随滑动循环复用，移出视野后才换成下一张封面。
///
/// - 点居中的封面:先放这一首,其余音乐随机接在后面。
/// - 点「随机播放」:整个音乐曲库洗一遍,不从封面那首开始(#185)。
/// - 点两边的封面:把它挪到中间。
/// - 点封面下面的歌名:前往专辑。
///
/// 立体效果只挂在每张定尺寸的卡片上,不挂在任何 ScrollView 或它的上层 ——
/// 把透视变换挂到滚动视图上在 iOS 27 上闪退过。
///
/// 手机横屏、iPhone Duo 外屏横握(紧凑高度)时竖着摆放不下,改成歌名与两个按钮在左边一栏、
/// 小一号的轮播在右边(`HomeHeroLayout`),整块压在视口四成以内。
struct HomeHeroCarousel: View {
    let songs: [Song]
    /// 紧凑高度时首页画布有多高(按它定封面大小);nil 是竖屏、iPad 的摆法。
    let compactCanvasHeight: CGFloat?
    /// 界面编辑里只看版面:不响应点击,也不接长按菜单。
    let isInteractive: Bool
    let playFromSong: (Song) -> Void
    let shuffleAll: () -> Void
    let playAll: () -> Void

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(CoverTintProvider.self) private var tintProvider
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var centeredIndex: Int
    @State private var viewportWidth: CGFloat = 0
    /// 上次量到的宽度。首页顶部切到电台、有声书再切回来时轮播是重建的,第一帧按它定卡片大小,
    /// 不先按 393 排、量到实际宽度后再重排并重新居中一次(#283)。
    @MainActor private static var lastViewportWidth: CGFloat = 0
    /// 刚挂上时先画和轮播同形状的骨架,等滚到居中那张、眼前三张封面也读好了(或者等够一会儿)
    /// 再整组淡进来:不露出还没滚到位的那一帧,封面也不一张张蹦出来。
    @State private var isRevealed = false
    @State private var isPositioned = false
    @State private var settledSongIDs: Set<String> = []
    @State private var hasPreparedTints = false

    init(
        songs: [Song],
        compactCanvasHeight: CGFloat? = nil,
        isInteractive: Bool,
        playFromSong: @escaping (Song) -> Void,
        shuffleAll: @escaping () -> Void,
        playAll: @escaping () -> Void
    ) {
        self.songs = songs
        self.compactCanvasHeight = compactCanvasHeight
        self.isInteractive = isInteractive
        self.playFromSong = playFromSong
        self.shuffleAll = shuffleAll
        self.playAll = playAll
        _centeredIndex = State(initialValue: Self.initialIndex(in: songs))
    }

    var body: some View {
        let metrics = HomeHeroCarouselMetrics(
            viewportWidth: viewportWidth > 0 ? viewportWidth : Self.lastViewportWidth,
            compactCanvasHeight: compactCanvasHeight
        )
        // 骨架分别盖在轮播和歌名上,和它们同位置同大小;按钮一直是真的。
        HomeHeroLayout(metrics: metrics) {
            carousel(metrics)
                .opacity(isRevealed ? 1 : 0)
                .overlay {
                    if !isRevealed {
                        LoadingSkeletonGroup {
                            HomeHeroCarouselSkeletonCards(metrics: metrics)
                        }
                        .transition(.opacity)
                    }
                }

            caption(metrics)
                .opacity(isRevealed ? 1 : 0)
                .overlay {
                    if !isRevealed {
                        LoadingSkeletonGroup {
                            HomeHeroCarouselSkeletonCaption(metrics: metrics)
                        }
                        .transition(.opacity)
                    }
                }

            buttons(metrics)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            Self.lastViewportWidth = width
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

    private func noteSettled(_ songID: String) {
        guard !isRevealed, settledSongIDs.insert(songID).inserted else { return }
        revealIfReady()
    }

    private func revealIfReady() {
        guard !songs.isEmpty, isPositioned, (-1...1).allSatisfy({ offset in
            let index = HomeHeroCarouselLoop.index(ofSlot: centeredIndex + offset, itemCount: songs.count)
            return settledSongIDs.contains(songs[index].id)
        }) else { return }
        reveal()
    }

    private func reveal() {
        guard !isRevealed else { return }
        pmWithAnimation(.trackChange) { isRevealed = true }
    }

    private static func initialIndex(in songs: [Song]) -> Int {
        min(HomeHeroCarouselSelection.initialIndex(count: songs.count), max(0, songs.count - 1))
    }

    private var centeredSong: Song? {
        songs.indices.contains(centeredIndex) ? songs[centeredIndex] : nil
    }

    private var nearbySongs: [Song] {
        guard !songs.isEmpty else { return [] }
        let center = centeredIndex
        var seen = Set<String>()
        return (-2...2).compactMap { offset in
            let song = songs[HomeHeroCarouselLoop.index(ofSlot: center + offset, itemCount: songs.count)]
            return seen.insert(song.id).inserted ? song : nil
        }
    }

    // MARK: - 轮播

    private func carousel(_ metrics: HomeHeroCarouselMetrics) -> some View {
        HomeHeroRecyclingCarousel(
            songIDs: songs.map(\.id), initialIndex: Self.initialIndex(in: songs), metrics: metrics,
            onSelection: { centeredIndex = $0 },
            onPositioned: {
                isPositioned = true
                revealIfReady()
            }
        ) { index, isCentered, bringToCenter in
            let song = songs[index]
            card(song, isCentered: isCentered, side: metrics.cardSide,
                 bringToCenter: bringToCenter, onSettled: { noteSettled(song.id) })
        }
        .frame(height: metrics.carouselHeight)
        .pmHorizontalClipExtendingUnderVerticalBar()
        .background { glow() }
    }

    private func card(
        _ song: Song,
        isCentered: Bool,
        side: CGFloat,
        bringToCenter: @escaping () -> Void,
        onSettled: @escaping () -> Void
    ) -> some View {
        #if DEBUG
        HomeHeroCarouselDiagnostics.didBuildCard?()
        #endif
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

    /// 竖屏在封面下面居中;横屏在左边一栏靠左。
    @ViewBuilder
    private func caption(_ metrics: HomeHeroCarouselMetrics) -> some View {
        let song = centeredSong
        let alignment: HorizontalAlignment = metrics.isCompactHeight ? .leading : .center
        let label = VStack(alignment: alignment, spacing: 2) {
            Text(verbatim: song?.title ?? " ")
                .font(.headline)
                .foregroundStyle(.primary)
            Text(verbatim: song.flatMap { library.artistDisplayName(for: $0) } ?? " ")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .multilineTextAlignment(metrics.isCompactHeight ? .leading : .center)
        .contentTransition(.opacity)
        .pmAnimation(.trackChange, value: centeredSong?.id)
        .padding(.horizontal, metrics.isCompactHeight ? 0 : 32)
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))

        if isInteractive, let albumID = song?.albumID, let album = library.visibleAlbum(id: albumID) {
            NavigationLink(value: album) {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 和首页其它专辑入口一样,专辑页从这里放大展开、返回时缩回来。
            .mediaZoomSource(.album, id: album.id)
            .accessibilityHint(Text("go_to_album"))
        } else {
            label
        }
    }

    private func buttons(_ metrics: HomeHeroCarouselMetrics) -> some View {
        Self.playbackButtons(metrics, shuffleAll: shuffleAll, playAll: playAll)
    }

    /// 「随机播放」「全部播放」两颗。曲库还没装好时照样能点:首页先把这次播放记下,装好再放
    /// (`LibraryStartupPlaybackCoordinator`)。首页加载占位用的也是这两颗,换上轮播时原地不动。
    static func playbackButtons(
        _ metrics: HomeHeroCarouselMetrics,
        shuffleAll: @escaping () -> Void,
        playAll: @escaping () -> Void
    ) -> some View {
        buttonRow(metrics) {
            Button(action: shuffleAll) {
                buttonLabel("shuffle", systemImage: "shuffle")
            }
            .buttonStyle(.borderedProminent)
            .prominentLabelOnAccent()
            .clipShape(Capsule())

            Button(action: playAll) {
                buttonLabel("play_all", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .clipShape(Capsule())
        }
    }

    /// 两个按钮的一行:竖屏平分整行(左右各留 16);横屏左边那一栏够宽时并排,
    /// 窄了(Duo 外屏)上下叠,长文案的语言也不至于缩到看不清。骨架共用。
    static func buttonRow<Content: View>(
        _ metrics: HomeHeroCarouselMetrics,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let layout = metrics.stacksButtons
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout(content)
            .padding(.horizontal, metrics.isCompactHeight ? 0 : 16)
    }

    /// 骨架按同一个标签量高度,换成真按钮时下面的区块不跳。
    /// 两颗平分一行:窄屏或长文案的语言里字略缩一点,不折成两行把按钮撑高。
    static func buttonLabel(_ titleKey: LocalizedStringKey, systemImage: String) -> some View {
        Label(titleKey, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
    }

    private func accessibilityText(for song: Song) -> String {
        guard let artist = library.artistDisplayName(for: song), !artist.isEmpty else { return song.title }
        return "\(song.title), \(artist)"
    }
}

private struct HomeHeroRecyclingCarousel<Card: View>: UIViewControllerRepresentable {
    let songIDs: [String]
    let initialIndex: Int
    let metrics: HomeHeroCarouselMetrics
    let onSelection: (Int) -> Void
    let onPositioned: () -> Void
    @ViewBuilder let card: (Int, Bool, @escaping () -> Void) -> Card

    func makeUIViewController(context: Context) -> HomeHeroCarouselController {
        HomeHeroCarouselController()
    }

    func updateUIViewController(_ controller: HomeHeroCarouselController, context: Context) {
        let environment = context.environment
        controller.update(
            songIDs: songIDs, initialIndex: initialIndex, metrics: metrics,
            reduceMotion: environment.accessibilityReduceMotion,
            direction: environment.layoutDirection == .rightToLeft ? -1 : 1,
            onSelection: onSelection, onPositioned: onPositioned
        ) { index, centered, select in
            AnyView(card(index, centered, select).id(songIDs[index]).environment(\.self, environment))
        }
    }
}

/// 在同一布局周期内平移滚动原点和现有卡片，手指与惯性滚动都不会碰到循环边界。
final class HomeHeroCarouselScrollView: UIScrollView {
    var layoutCards: (() -> Void)?
    var moveSelection: ((Int) -> Void)?
    private(set) var centeredItemIndex = 0
    private(set) var cardStep: CGFloat = 1

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutCards?()
    }

    func recordSelection(_ index: Int, step: CGFloat) {
        centeredItemIndex = index
        cardStep = step
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        switch direction {
        case .left, .next: moveSelection?(1)
        case .right, .previous: moveSelection?(-1)
        default: return super.accessibilityScroll(direction)
        }
        return true
    }
}

private final class HomeHeroCarouselController: UIViewController, UIScrollViewDelegate {
    @MainActor
    private final class Cell {
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        var itemIndex = -1
        var centered = false
    }

    private let scroll = HomeHeroCarouselScrollView()
    private var cells: [Cell] = []
    private var songIDs: [String] = []
    private var anchorIndex = 0
    private var metrics = HomeHeroCarouselMetrics(viewportWidth: 0)
    private var previousStep: CGFloat = 0
    private var previousSize = CGSize.zero
    private var reduceMotion = false
    private var direction = 1
    private var layingOut = false
    private var animatingSelection = false
    private var needsContentUpdate = true
    private var publishedIndex: Int?
    private var publicationPending = false
    private var hasPositioned = false
    private var onSelection: (Int) -> Void = { _ in }
    private var onPositioned: () -> Void = {}
    private var makeCard: ((Int, Bool, @escaping () -> Void) -> AnyView)?

    override func loadView() {
        view = scroll
        scroll.backgroundColor = .clear
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast
        scroll.alwaysBounceHorizontal = true
        scroll.clipsToBounds = false
        scroll.delegate = self
        scroll.accessibilityIdentifier = "home.hero.carousel"
        scroll.layoutCards = { [weak self] in self?.layoutCards() }
        scroll.moveSelection = { [weak self] delta in
            guard let self else { return }
            let position = self.scroll.contentOffset.x / self.metrics.step - CGFloat(self.cells.count / 2)
            self.select(offset: Int(position.rounded()) + delta)
        }
    }

    func update(
        songIDs: [String], initialIndex: Int, metrics: HomeHeroCarouselMetrics,
        reduceMotion: Bool, direction: Int, onSelection: @escaping (Int) -> Void,
        onPositioned: @escaping () -> Void,
        makeCard: @escaping (Int, Bool, @escaping () -> Void) -> AnyView
    ) {
        loadViewIfNeeded()
        let itemsChanged = self.songIDs != songIDs
        if itemsChanged {
            let selectedID = self.songIDs.indices.contains(scroll.centeredItemIndex)
                ? self.songIDs[scroll.centeredItemIndex] : nil
            anchorIndex = selectedID.flatMap { songIDs.firstIndex(of: $0) }
                ?? min(initialIndex, max(0, songIDs.count - 1))
            self.songIDs = songIDs
            previousStep = 0
            publishedIndex = nil
            animatingSelection = false
        }
        if self.direction != direction {
            if !itemsChanged { anchorIndex = scroll.centeredItemIndex }
            previousStep = 0
        }
        self.metrics = metrics
        self.reduceMotion = reduceMotion
        self.direction = direction
        self.onSelection = onSelection
        self.onPositioned = onPositioned
        self.makeCard = makeCard
        needsContentUpdate = true
        let count = HomeHeroCarouselLoop.slotCount(itemCount: songIDs.count)
        while cells.count > count {
            let cell = cells.removeLast()
            cell.host.willMove(toParent: nil)
            cell.host.view.removeFromSuperview()
            cell.host.removeFromParent()
        }
        while cells.count < count {
            let cell = Cell()
            addChild(cell.host)
            cell.host.view.backgroundColor = .clear
            cell.host.safeAreaRegions = []
            cell.host.view.accessibilityIdentifier = "home.hero.card"
            scroll.addSubview(cell.host.view)
            cell.host.didMove(toParent: self)
            cells.append(cell)
        }
        scroll.setNeedsLayout()
    }

    private func itemIndex(at offset: Int) -> Int {
        HomeHeroCarouselLoop.index(ofSlot: anchorIndex + offset * direction, itemCount: songIDs.count)
    }

    private func layoutCards() {
        guard !layingOut, !cells.isEmpty, scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
        layingOut = true
        defer { layingOut = false }
        let middle = cells.count / 2
        let step = metrics.step
        let origin = CGFloat(middle) * step
        if previousStep != step || previousSize != scroll.bounds.size {
            let fraction = previousStep > 0
                ? (scroll.contentOffset.x - CGFloat(middle) * previousStep) / previousStep : 0
            scroll.contentSize = CGSize(width: scroll.bounds.width + CGFloat(cells.count - 1) * step,
                                        height: scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: origin + fraction * step, y: 0), animated: false)
            previousStep = step
            previousSize = scroll.bounds.size
        }
        var displacement = (scroll.contentOffset.x - origin) / step
        if !animatingSelection, abs(displacement) >= 1 {
            let shift = Int(displacement.rounded(.towardZero))
            anchorIndex = itemIndex(at: shift)
            // 已在屏内的 hosting view 保持身份，仅把离屏端的卡片搬到另一端。
            let rotation = HomeHeroCarouselLoop.index(ofSlot: shift, itemCount: cells.count)
            cells = Array(cells[rotation...]) + Array(cells[..<rotation])
            scroll.contentOffset.x -= CGFloat(shift) * step
            displacement -= CGFloat(shift)
        }
        let nearest = Int(displacement.rounded())
        let selected = itemIndex(at: nearest)
        scroll.recordSelection(selected, step: step)
        let side = metrics.cardSide
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (slot, cell) in cells.enumerated() {
            let offset = slot - middle
            let index = itemIndex(at: offset)
            let centered = offset == nearest
            if needsContentUpdate || cell.itemIndex != index || cell.centered != centered {
                cell.itemIndex = index
                cell.centered = centered
                cell.host.rootView = makeCard?(index, centered, { [weak self, weak cell] in
                    guard let self, let cell, let slot = self.cells.firstIndex(where: { $0 === cell }) else { return }
                    self.select(offset: slot - self.cells.count / 2)
                }) ?? AnyView(EmptyView())
            }
            let position = CGFloat(offset) - displacement
            let distance = min(abs(position), 6)
            let spread = homeHeroCarouselInterpolate([0, 0.52, 0.74, 0.9, 1.02], at: distance, tail: 0.1)
            let scale = homeHeroCarouselInterpolate([1, 0.8, 0.66, 0.56, 0.48], at: distance, tail: 0)
            let angle = reduceMotion ? 0 : max(-1, min(1, position)) * -.pi * 34 / 180
            var transform = CATransform3DIdentity
            transform.m34 = -0.5 / side
            transform = CATransform3DRotate(transform, angle, 0, 1, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)
            cell.host.view.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            cell.host.view.center = CGPoint(
                x: scroll.bounds.midX + (position < 0 ? -1 : 1) * spread * side,
                y: scroll.bounds.height / 2
            )
            cell.host.view.layer.transform = transform
            cell.host.view.alpha = distance <= 3 ? 1 : max(0, 4 - distance)
            cell.host.view.isHidden = distance >= 4
            cell.host.view.layer.zPosition = -distance
        }
        // UIKit 命中测试按 subview 顺序遍历，需要与视觉叠放顺序一致。
        for cell in cells.sorted(by: { $0.host.view.layer.zPosition < $1.host.view.layer.zPosition }) {
            scroll.bringSubviewToFront(cell.host.view)
        }
        CATransaction.commit()
        needsContentUpdate = false
        publishSelection()
    }

    private func publishSelection() {
        guard !publicationPending, publishedIndex != scroll.centeredItemIndex || !hasPositioned else { return }
        publicationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publicationPending = false
            let index = self.scroll.centeredItemIndex
            guard self.songIDs.indices.contains(index) else { return }
            if self.publishedIndex != index {
                self.publishedIndex = index
                self.onSelection(index)
            }
            if !self.hasPositioned {
                self.hasPositioned = true
                self.onPositioned()
            }
        }
    }

    private func select(offset: Int) {
        let x = CGFloat(cells.count / 2 + offset) * metrics.step
        animatingSelection = !reduceMotion && abs(scroll.contentOffset.x - x) > 0.1
        scroll.setContentOffset(CGPoint(x: x, y: 0), animated: animatingSelection)
        scroll.setNeedsLayout()
    }

    private func settleSelection() {
        let position = scroll.contentOffset.x / metrics.step - CGFloat(cells.count / 2)
        select(offset: Int(position.rounded()))
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        animatingSelection = false
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                  targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        targetContentOffset.pointee.x = (targetContentOffset.pointee.x / metrics.step).rounded() * metrics.step
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settleSelection() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        // 惯性期间重置滚动原点后，UIKit 的终点可能偏离卡片中心。
        settleSelection()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        animatingSelection = false
        scroll.setNeedsLayout()
    }
}

#if DEBUG
@MainActor
enum HomeHeroCarouselDiagnostics {
    static var didBuildCard: (() -> Void)?
}
#endif

/// 轮播的骨架:和轮播同样的位置、大小与转角。首页加载占位画整套(连两个按钮);
/// 轮播自己还没摆好时只在封面和歌名上各盖一块(`HomeHeroCarouselSkeletonCards` /
/// `HomeHeroCarouselSkeletonCaption`),换成真封面时形状不动,封面在原位淡进来。
///
/// 封面与歌名各自一组呼吸;给了 `playback` 时两颗按钮是真的(曲库还没装好也能先点),
/// 和轮播里的同一个位置、同一个样子,就绪换上轮播时不动也不闪;没给时画两块占位。
struct HomeHeroCarouselSkeleton: View {
    struct Playback {
        let shuffleAll: () -> Void
        let playAll: () -> Void
    }

    let metrics: HomeHeroCarouselMetrics
    var playback: Playback?

    var body: some View {
        HomeHeroLayout(metrics: metrics) {
            LoadingSkeletonGroup {
                HomeHeroCarouselSkeletonCards(metrics: metrics)
            }
            LoadingSkeletonGroup {
                HomeHeroCarouselSkeletonCaption(metrics: metrics)
            }
            if let playback {
                HomeHeroCarousel.playbackButtons(
                    metrics,
                    shuffleAll: playback.shuffleAll,
                    playAll: playback.playAll
                )
            } else {
                LoadingSkeletonGroup {
                    HomeHeroCarousel.buttonRow(metrics) {
                        placeholderButton(HomeHeroCarousel.buttonLabel("shuffle", systemImage: "shuffle"))
                        placeholderButton(HomeHeroCarousel.buttonLabel("play_all", systemImage: "play.fill"))
                    }
                }
            }
        }
    }

    private func placeholderButton(_ label: some View) -> some View {
        Button {} label: { label }
            .buttonStyle(.bordered)
            .clipShape(Capsule())
            .hidden()
            .overlay { Capsule().fill(HomeHeroCarouselSkeletonCards.fill) }
    }
}

/// 居中一张、两边各三张,叠放、缩小、转角都走轮播同一个函数。
struct HomeHeroCarouselSkeletonCards: View {
    let metrics: HomeHeroCarouselMetrics

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static var fill: Color { Color(uiColor: .secondarySystemBackground) }

    var body: some View {
        let side = metrics.cardSide
        let step = metrics.step
        let reducesMotion = reduceMotion
        let shape = RoundedRectangle(cornerRadius: HomeHeroCarouselMetrics.cornerRadius, style: .continuous)
        ZStack {
            ForEach(-3...3, id: \.self) { position in
                let offset = CGFloat(position) * step
                shape.fill(Self.fill)
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
        .accessibilityHidden(true)
    }
}

/// 歌名、歌手两行:用同样字体的空白行撑出高度,条子画在中间(横屏靠左)。
struct HomeHeroCarouselSkeletonCaption: View {
    let metrics: HomeHeroCarouselMetrics

    var body: some View {
        let alignment: HorizontalAlignment = metrics.isCompactHeight ? .leading : .center
        let fill = HomeHeroCarouselSkeletonCards.fill
        VStack(alignment: alignment, spacing: 2) {
            Text(verbatim: " ")
                .font(.headline)
                .hidden()
                .frame(width: metrics.cardSide * 0.5)
                .overlay {
                    Capsule().fill(fill).frame(width: metrics.cardSide * 0.5, height: 12)
                }
            Text(verbatim: " ")
                .font(.subheadline)
                .hidden()
                .frame(width: metrics.cardSide * 0.32)
                .overlay {
                    Capsule().fill(fill).frame(width: metrics.cardSide * 0.32, height: 10)
                }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .accessibilityHidden(true)
    }
}

/// 轮播、歌名、两个按钮怎么摆。竖屏从上到下;紧凑高度时歌名和按钮是左边一栏,
/// 在轮播旁边竖向居中。转屏只换摆法、不换视图:封面上挂着长按菜单,菜单关闭途中
/// 换掉承载它的视图会闪退。子视图依次是轮播、歌名、按钮(没有按钮也行)。
struct HomeHeroLayout: Layout {
    let metrics: HomeHeroCarouselMetrics

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? metrics.layoutWidth
        return CGSize(width: width, height: arrangement(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrangement(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        func height(_ index: Int, width: CGFloat) -> CGFloat {
            guard subviews.indices.contains(index) else { return 0 }
            return subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        let carouselHeight = metrics.carouselHeight
        let hasButtons = subviews.count > 2
        if metrics.isCompactHeight {
            let infoX = HomeHeroCarouselMetrics.compactInfoLeading
            let infoWidth = min(metrics.infoWidth, max(0, width - infoX))
            let carouselX = infoX + infoWidth + HomeHeroCarouselMetrics.compactGap
            let captionHeight = height(1, width: infoWidth)
            let buttonsHeight = height(2, width: infoWidth)
            let gap = hasButtons ? HomeHeroCarouselMetrics.compactButtonsTopSpacing : 0
            let infoHeight = captionHeight + gap + buttonsHeight
            let total = max(carouselHeight, infoHeight)
            let infoTop = ((total - infoHeight) / 2).rounded()
            return ([
                CGRect(
                    x: carouselX,
                    y: ((total - carouselHeight) / 2).rounded(),
                    width: max(0, width - carouselX),
                    height: carouselHeight
                ),
                CGRect(x: infoX, y: infoTop, width: infoWidth, height: captionHeight),
                CGRect(x: infoX, y: infoTop + captionHeight + gap, width: infoWidth, height: buttonsHeight),
            ], total)
        }
        let captionTop = carouselHeight + HomeHeroCarouselMetrics.captionTopSpacing
        let captionHeight = height(1, width: width)
        let buttonsTop = captionTop + captionHeight + HomeHeroCarouselMetrics.buttonsTopSpacing
        let buttonsHeight = height(2, width: width)
        return ([
            CGRect(x: 0, y: 0, width: width, height: carouselHeight),
            CGRect(x: 0, y: captionTop, width: width, height: captionHeight),
            CGRect(x: 0, y: buttonsTop, width: width, height: buttonsHeight),
        ], hasButtons ? buttonsTop + buttonsHeight : captionTop + captionHeight)
    }
}

/// 轮播的尺寸。首页加载占位也按它画,换成真内容时高度不跳。
struct HomeHeroCarouselMetrics {
    static let cornerRadius: CGFloat = 18
    /// 还没量到宽度的第一帧按常见手机宽度排。
    static let fallbackWidth: CGFloat = 393

    /// 整块的宽度。
    let layoutWidth: CGFloat
    /// 轮播那一块的宽度:竖屏就是整块,紧凑高度时是左边一栏以外的部分。
    let viewportWidth: CGFloat
    let cardSide: CGFloat
    /// 紧凑高度(手机横屏、Duo 外屏横握):歌名和按钮在左边一栏。
    let isCompactHeight: Bool
    /// 左边一栏的宽度,竖屏时为 0。
    let infoWidth: CGFloat

    /// - Parameter compactCanvasHeight: 紧凑高度时首页画布的高度;nil 是竖屏、iPad。
    init(viewportWidth: CGFloat, compactCanvasHeight: CGFloat? = nil) {
        let width = viewportWidth > 0 ? viewportWidth : Self.fallbackWidth
        layoutWidth = width
        guard let compactCanvasHeight else {
            self.viewportWidth = width
            let proposed = (width * 0.5).rounded()
            cardSide = min(max(proposed, 160), 300)
            isCompactHeight = false
            infoWidth = 0
            return
        }
        isCompactHeight = true
        // 封面加上下留给阴影的地方压在画布高度的四成以内;轮播那块宽到放得下两边各几张,
        // 剩下的给左边一栏(太宽时按钮会拉得很长,封顶 360,多出来的还给轮播)。
        let height = compactCanvasHeight > 0 ? compactCanvasHeight : Self.fallbackWidth
        let available = max(0, width - Self.compactInfoLeading - Self.compactGap)
        var side = min(max((height * 0.4 - 2 * Self.verticalBleed).rounded(), 96), 150)
        var carousel = min((side * 2.6).rounded(), max(0, available - Self.compactMinimumInfoWidth))
        let info = min(available - carousel, Self.compactMaximumInfoWidth)
        carousel = available - info
        side = min(side, (carousel / 2.5).rounded(.down))
        self.viewportWidth = carousel
        cardSide = max(side, 0)
        infoWidth = info
    }

    /// 相邻两张在滚动方向上相隔的距离:手指挪多远,邻居就差不多挪到正中,不像隔着齿轮。
    var step: CGFloat { (cardSide * 0.56).rounded() }
    var spacing: CGFloat { step - cardSide }
    /// 第一张、最后一张也能停在正中。
    var sideMargin: CGFloat { max(0, (viewportWidth - cardSide) / 2) }
    /// 给阴影和转开后变高的近边留的上下空间。
    var verticalBleed: CGFloat { Self.verticalBleed }
    private static let verticalBleed: CGFloat = 16
    /// 封面与下面歌名之间的距离。
    static let captionTopSpacing: CGFloat = 4
    /// 歌名与下面两个按钮之间的距离。
    static let buttonsTopSpacing: CGFloat = 16
    var carouselHeight: CGFloat { cardSide + verticalBleed * 2 }

    /// 紧凑高度时左边一栏离边缘多远(和下面各区块的标题对齐)、和轮播隔多远、歌名与按钮隔多远。
    static let compactInfoLeading: CGFloat = 20
    static let compactGap: CGFloat = 8
    static let compactButtonsTopSpacing: CGFloat = 14
    private static let compactMinimumInfoWidth: CGFloat = 200
    private static let compactMaximumInfoWidth: CGFloat = 360
    /// 左边一栏窄于这个宽度时两个按钮上下叠。
    private static let sideBySideButtonsMinimumWidth: CGFloat = 320

    var stacksButtons: Bool {
        isCompactHeight && infoWidth < Self.sideBySideButtonsMinimumWidth
    }
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
