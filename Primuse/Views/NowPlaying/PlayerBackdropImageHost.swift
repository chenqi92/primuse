import SwiftUI
import PrimuseKit

/// 原生播放页背景上的那张图（封面模糊 / 专辑封底 / 自选图片），叠在封面取色的色场之上。
/// 选的是封面取色、或者图还没准备好时什么也不画，色场照旧露出来。
///
/// 只放在原生播放页：全屏效果打开时整页换成全屏舞台，背景图不参与。
struct PlayerBackdropImageHost: View {
    let song: Song?
    let isLight: Bool
    let strength: Double
    let usesIncreasedContrast: Bool
    /// 播放页是当前正在看的那一面（定时轮播只在这时走）。
    let isSurfaceVisible: Bool
    /// 入场动画结束前不开始读盘解码。
    let allowsLoading: Bool

    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(\.displayScale) private var displayScale
    @State private var store = PlayerBackdropSettingsStore.shared
    @State private var resolver = PlayerBackdropResolver.shared
    /// 挂载时手里已经有的那张。播放页每次展开都是重新挂载，这张再淡入一遍，整个入场
    /// 露的都是底下的浅色底；之后换上的图照常淡入。
    @State private var frameIDOnAppear = PlayerBackdropResolver.shared.displayedFrameID

    private struct TimerKey: Equatable {
        let isActive: Bool
        let interval: Int
    }

    var body: some View {
        let settings = store.settings
        let source = store.effectiveSource

        GeometryReader { geometry in
            let longSide = Double(max(geometry.size.width, geometry.size.height) * displayScale)
            let request = PlayerBackdropResolver.Request(
                source: source,
                rotation: settings.rotation,
                step: resolver.rotation.step,
                song: song,
                customImageIDs: store.customImageIDs,
                maxPixel: PlayerBackdropPixelPolicy.storagePixel(forDisplayLongSide: longSide),
                allowsLoading: allowsLoading
            )
            imageLayer(size: geometry.size, source: source)
                .onChange(of: request, initial: true) { _, request in
                    resolver.update(request, sourceManager: sourceManager, sourcesStore: sourcesStore)
                }
        }
        .onChange(of: song?.id, initial: true) { _, songID in
            resolver.observeSong(songID, rotation: settings.rotation)
        }
        .onChange(of: resolver.frame?.id) {
            // 轮播转回挂载时那张也要淡入，不能直接盖在上一张上。
            frameIDOnAppear = nil
        }
        .task(id: TimerKey(
            isActive: isSurfaceVisible && settings.rotation == .timed && source.supportsRotation,
            interval: settings.intervalSeconds
        )) {
            guard isSurfaceVisible, settings.rotation == .timed, source.supportsRotation else { return }
            let interval = max(PlayerBackdropSettings.intervalChoices.first ?? 15, settings.intervalSeconds)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                resolver.advanceTimer(rotation: .timed)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 外层 ZStack 一直在（没有图时是空的），挂在它上面的 onChange 才始终有效。
    private func imageLayer(size: CGSize, source: PlayerBackdropSource) -> some View {
        ZStack {
            if let frame = resolver.frame, frame.source == source {
                // 上一张垫在下面，新图淡入时不先闪出底色。
                if let previous = resolver.previousFrame, previous.source == source {
                    backdropImage(previous.image, size: size)
                }
                let image = backdropImage(frame.image, size: size).id(frame.id)
                if frame.id == frameIDOnAppear {
                    image
                } else {
                    image.pmAppearFade(.ambient)
                }
                scrim
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func backdropImage(_ image: CGImage, size: CGSize) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    private var scrim: some View {
        let value = PlayerBackdropScrimPolicy.scrim(
            isLight: isLight,
            strength: strength,
            usesIncreasedContrast: usesIncreasedContrast
        )
        let base: Color = isLight ? .white : .black
        return LinearGradient(
            stops: [
                .init(color: base.opacity(value.topOpacity), location: 0),
                .init(color: base.opacity(value.middleOpacity), location: 0.5),
                .init(color: base.opacity(value.bottomOpacity), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// 铺满封面（「封面样式」选了铺满）下面那一截：封面下沿接着往下延伸的模糊镜像，盖住封面取色
/// 色场的下半。色场下半是封面里另挑的第二种颜色再压暗，跟封面下沿往往不是一个色，渐隐处像接了
/// 一块别的底（暖色封面常常压成一片棕）；换成封面自己的像素，渐隐就是封面慢慢化开。
/// 遮罩和背景图共用一套规则，跟着「背景浓淡」走。
///
/// 铺满封面下沿那一截渐隐的蒙版：smoothstep 取五个点，起止两头都是平的。电台铺满的台标与设置里的预览用它；
/// 播放页的音乐、播客封面在 `LyricsArtworkFlight` 里按同样的点画（那边还要随飞行收到 0）。
struct FullBleedArtworkFadeMask: View {
    var body: some View {
        let fade = FullBleedArtworkExtension.fadeFraction
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 1 - fade),
                .init(color: .black.opacity(0.844), location: 1 - fade * 0.75),
                .init(color: .black.opacity(0.5), location: 1 - fade * 0.5),
                .init(color: .black.opacity(0.156), location: 1 - fade * 0.25),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// 铺满封面（台标）顶上那一截：状态栏和下拉把手压在封面上，垫一道背景色的淡底让时间看得清。
/// 音乐、播客、电台的播放页与设置里的预览共用这一份，一个样子。宽度跟父视图，高度是 `bandHeight`。
///
/// 把手照旧常驻（下拉收起要看得出来），但不再是一根亮白的条：压到和状态栏图标差不多的分量，
/// 浅色封面上靠一层很淡的影子分开，像系统面板顶上的把手一样是界面的一部分，不像贴在照片上（#338）。
/// 宽度和版面里那根一样，切到歌词时两根交叉淡变，看不出换了一根。
struct FullBleedTopChrome: View {
    let topSafeArea: CGFloat
    let appearance: NowPlayingAppearance
    /// 底下垫着模糊的封面(`FullBleedArtworkTopSoftening`):时间已经看得清,淡底减轻,不再压出一道灰。
    var softened = false

    static func bandHeight(topSafeArea: CGFloat) -> CGFloat { topSafeArea + 44 }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [appearance.backgroundBase.opacity(softened ? 0.24 : 0.42), appearance.backgroundBase.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.bandHeight(topSafeArea: topSafeArea))

            Capsule()
                .fill(appearance.primary.opacity(appearance.isLight ? 0.3 : 0.36))
                .frame(width: 48, height: 5)
                .shadow(color: .black.opacity(appearance.isLight ? 0 : 0.16), radius: 1.5)
                .padding(.top, topSafeArea + 6)
        }
        .frame(height: Self.bandHeight(topSafeArea: topSafeArea), alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 播放页铺满封面顶上那一截：柔化（设置里开着时）、淡底和把手，摆在封面 `artworkRect` 的顶端。
/// 只在铺满时挂上，那个开关也只在这时被观察，不让整个播放页跟着它重算。
struct FullBleedArtworkTop: View {
    let song: Song?
    let coverRevision: Int
    let artworkRect: CGRect
    let topSafeArea: CGFloat
    let appearance: NowPlayingAppearance
    let allowsLoading: Bool

    @AppStorage(PlayerAppearancePreferences.fullBleedTopSofteningKey)
    private var softens = PlayerAppearancePreferences.fullBleedTopSofteningByDefault

    var body: some View {
        let band = FullBleedTopChrome.bandHeight(topSafeArea: topSafeArea)
        ZStack {
            if softens {
                FullBleedArtworkTopSoftening(
                    song: song,
                    coverRevision: coverRevision,
                    artworkRect: artworkRect,
                    height: FullBleedArtworkTopSoftening.height(topSafeArea: topSafeArea),
                    allowsLoading: allowsLoading
                )
            }
            FullBleedTopChrome(topSafeArea: topSafeArea, appearance: appearance, softened: softens)
                .frame(width: artworkRect.width)
                .position(x: artworkRect.midX, y: artworkRect.minY + band / 2)
        }
    }
}

/// 铺满封面顶上那一截的柔化（「播放页样式与按钮」里可关，#338）：状态栏和把手底下换成同一张封面的
/// 模糊版，往下渐渐露出清楚的封面，像底部渐隐进背景那样，顶上也不再是一刀切的照片边。模糊图在后台
/// 做好一次放进背景图缓存，播放页上只是一张静态图加一道渐变遮罩，不做实时模糊。
///
/// 摆在 `artworkRect` 顶上、和封面同宽，高度 `height`；图按封面同样的边长居中裁切，和下面的封面对齐。
struct FullBleedArtworkTopSoftening: View {
    let song: Song?
    let coverRevision: Int
    let artworkRect: CGRect
    let height: CGFloat
    /// 入场动画结束前不开始取图；内存里已经有的照样立刻用。
    let allowsLoading: Bool

    @Environment(SourceManager.self) private var sourceManager
    @State private var shown: FullBleedTopSofteningImage?

    init(song: Song?, coverRevision: Int, artworkRect: CGRect, height: CGFloat, allowsLoading: Bool) {
        self.song = song
        self.coverRevision = coverRevision
        self.artworkRect = artworkRect
        self.height = height
        self.allowsLoading = allowsLoading
        _shown = State(initialValue: song.flatMap {
            FullBleedTopSofteningImage.cached(song: $0, coverRevision: coverRevision)
        })
    }

    /// 顶上实打实模糊那一截占的比例，再往下渐隐到 `height` 处变回清楚的封面。
    static let solidFraction: CGFloat = 0.42

    private struct LoadKey: Equatable {
        let cacheKey: String?
        let allowsLoading: Bool
    }

    var body: some View {
        let cacheKey = song.map { FullBleedTopSofteningImage.cacheKey(song: $0, coverRevision: coverRevision) }
        let visibleHeight = max(1, min(height, artworkRect.height))
        ZStack {
            if let shown {
                let side = max(artworkRect.width, artworkRect.height)
                Image(decorative: shown.image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: side, height: side)
                    .frame(width: artworkRect.width, height: artworkRect.height)
                    .clipped()
                    .frame(width: artworkRect.width, height: visibleHeight, alignment: .top)
                    .clipped()
                    .mask { Self.mask }
                    .id(shown.key)
                    .transition(.opacity)
            }
        }
        .frame(width: artworkRect.width, height: visibleHeight)
        .position(x: artworkRect.midX, y: artworkRect.minY + visibleHeight / 2)
        .task(id: LoadKey(cacheKey: cacheKey, allowsLoading: allowsLoading)) {
            guard let song, let cacheKey, shown?.key != cacheKey else { return }
            if let cached = FullBleedTopSofteningImage.cached(song: song, coverRevision: coverRevision) {
                withAnimation(Self.crossfade) { shown = cached }
                return
            }
            // 换歌后新封面没好之前留着上一首的，好了再交叉淡入。
            guard allowsLoading else { return }
            let loaded = await FullBleedTopSofteningImage.load(
                song: song,
                coverRevision: coverRevision,
                sourceManager: sourceManager
            )
            guard !Task.isCancelled else { return }
            withAnimation(Self.crossfade) { shown = loaded }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let crossfade = Animation.easeInOut(duration: 0.35)

    /// 上面一截实色，往下按 smoothstep 取的五个点渐隐，看不出从哪一行开始变清楚。
    static var mask: LinearGradient {
        let solid = solidFraction
        let fade = 1 - solid
        return LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: solid),
                .init(color: .black.opacity(0.844), location: solid + fade * 0.25),
                .init(color: .black.opacity(0.5), location: solid + fade * 0.5),
                .init(color: .black.opacity(0.156), location: solid + fade * 0.75),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 柔化那一截从封面顶端往下多高：状态栏、把手，再往下留一段渐隐。
    static func height(topSafeArea: CGFloat) -> CGFloat { topSafeArea + 72 }
}

/// 顶部柔化用的模糊封面，和铺满延伸底图共用背景图的内存缓存。
struct FullBleedTopSofteningImage: Sendable {
    let key: String
    let image: CGImage

    static func cacheKey(song: Song, coverRevision: Int) -> String {
        "fullbleedtop|\(song.id)|\(song.coverArtFileName ?? "")|\(coverRevision)"
    }

    static func cached(song: Song, coverRevision: Int) -> FullBleedTopSofteningImage? {
        let key = cacheKey(song: song, coverRevision: coverRevision)
        guard let image = PlayerBackdropMemoryCache.shared.image(forKey: key) else { return nil }
        return FullBleedTopSofteningImage(key: key, image: image)
    }

    /// 取封面小图、在后台模糊一次，结果放进背景图的内存缓存。
    static func load(
        song: Song,
        coverRevision: Int,
        sourceManager: SourceManager
    ) async -> FullBleedTopSofteningImage? {
        if let cached = cached(song: song, coverRevision: coverRevision) { return cached }
        let key = cacheKey(song: song, coverRevision: coverRevision)
        let cover = await CachedArtworkView.resolveImage(
            coverRef: song.coverArtFileName,
            songID: song.id,
            size: 256,
            sourceID: song.sourceID,
            filePath: song.filePath,
            fileFormat: song.fileFormat,
            sourceManager: sourceManager,
            cacheDiscriminator: String(coverRevision)
        )
        guard !Task.isCancelled, let image = cover?.platformCGImage else { return nil }
        let softened = await Task.detached(priority: .userInitiated) {
            PlayerBackdropImaging.fullBleedTopSoftening(from: image)
        }.value
        guard let softened else { return nil }
        PlayerBackdropMemoryCache.shared.insert(softened, forKey: key)
        return FullBleedTopSofteningImage(key: key, image: softened)
    }
}

/// 只在背景选的是封面取色时铺：流动色彩、声音律动和背景图是用户特意选的，封面下面照旧露出它们。
/// 竖屏的铺满封面往下延伸；手机横屏的铺满封面在左、歌名和控件在右，往右延伸。
struct FullBleedArtworkExtension: View {
    /// 往封面哪一边延伸。
    enum Edge: Sendable {
        /// 竖屏：封面下沿往下铺到屏幕底。
        case bottom
        /// 手机横屏：封面右沿往右铺到屏幕边。
        case trailing
    }

    /// 封面下沿渐隐那一截占封面高度的比例，播放页的铺满封面位用同一个值。
    nonisolated static let fadeFraction: CGFloat = 0.4

    let song: Song?
    let coverRevision: Int
    /// 铺满封面在这一层坐标里的位置。
    let artworkRect: CGRect
    let pageSize: CGSize
    let isLight: Bool
    let strength: Double
    let usesIncreasedContrast: Bool
    /// 入场动画结束前不开始取图；内存里已经有的照样立刻用。
    let allowsLoading: Bool
    let edge: Edge
    /// 封面靠这一边渐隐那一截占封面高度（往右延伸时是宽度）的比例，和封面位的渐隐一致。
    let fadeFraction: CGFloat

    @Environment(SourceManager.self) private var sourceManager
    @State private var shown: FullBleedArtworkExtensionImages?

    init(
        song: Song?,
        coverRevision: Int,
        artworkRect: CGRect,
        pageSize: CGSize,
        isLight: Bool,
        strength: Double,
        usesIncreasedContrast: Bool,
        allowsLoading: Bool,
        edge: Edge = .bottom,
        fadeFraction: CGFloat = FullBleedArtworkExtension.fadeFraction
    ) {
        self.song = song
        self.coverRevision = coverRevision
        self.artworkRect = artworkRect
        self.pageSize = pageSize
        self.isLight = isLight
        self.strength = strength
        self.usesIncreasedContrast = usesIncreasedContrast
        self.allowsLoading = allowsLoading
        self.edge = edge
        self.fadeFraction = fadeFraction
        // 播放页每次展开都重新挂载：备好的那张直接用上，不再淡入一遍。
        _shown = State(initialValue: song.flatMap {
            FullBleedArtworkExtensionImages.cached(song: $0, coverRevision: coverRevision, edge: edge)
        })
    }

    private struct LoadKey: Equatable {
        let cacheKey: String?
        let allowsLoading: Bool
    }

    var body: some View {
        let cacheKey = song.map {
            FullBleedArtworkExtensionImages.cacheKey(song: $0, coverRevision: coverRevision, edge: edge)
        }
        ZStack {
            if let shown {
                extensionLayer(shown)
                    .id(shown.key)
                    .transition(.opacity)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .task(id: LoadKey(cacheKey: cacheKey, allowsLoading: allowsLoading)) {
            guard let song, let cacheKey, shown?.key != cacheKey else { return }
            if let cached = FullBleedArtworkExtensionImages.cached(song: song, coverRevision: coverRevision, edge: edge) {
                withAnimation(Self.crossfade) { shown = cached }
                return
            }
            // 换歌后新封面没好之前留着上一首的，好了再交叉淡入；取不到封面就退回色场。
            guard allowsLoading else { return }
            let loaded = await FullBleedArtworkExtensionImages.load(
                song: song,
                coverRevision: coverRevision,
                sourceManager: sourceManager,
                edge: edge,
                fraction: fadeFraction
            )
            guard !Task.isCancelled else { return }
            withAnimation(Self.crossfade) { shown = loaded }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let crossfade = Animation.easeInOut(duration: 0.35)

    @ViewBuilder
    private func extensionLayer(_ images: FullBleedArtworkExtensionImages) -> some View {
        switch edge {
        case .bottom: bottomLayer(images)
        case .trailing: trailingLayer(images)
        }
    }

    private func bottomLayer(_ images: FullBleedArtworkExtensionImages) -> some View {
        let width = max(artworkRect.width, pageSize.width)
        let fadeHeight = max(1, artworkRect.height * fadeFraction)
        // 往屏幕底外多铺一截，版面比窗口略矮时底边也不露缝。
        let lowerHeight = max(1, pageSize.height - artworkRect.maxY + 40)
        let total = fadeHeight + lowerHeight
        return VStack(spacing: 0) {
            Image(decorative: images.upper, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: width, height: fadeHeight)
            Image(decorative: images.lower, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: width, height: lowerHeight)
        }
        .overlay {
            scrim(seam: fadeHeight / total, settle: min(1, fadeHeight * 1.6 / total), along: .vertical)
        }
        .frame(width: width, height: total)
        .position(x: pageSize.width / 2, y: artworkRect.maxY - fadeHeight + total / 2)
    }

    /// 横屏：左半垫在封面渐隐那段底下，右半一直铺到屏幕边（多铺一截，版面比窗口略窄时也不露缝）。上下铺满整页。
    private func trailingLayer(_ images: FullBleedArtworkExtensionImages) -> some View {
        let height = max(artworkRect.height, pageSize.height)
        let fadeWidth = max(1, artworkRect.width * fadeFraction)
        let farWidth = max(1, pageSize.width - artworkRect.maxX + 40)
        let total = fadeWidth + farWidth
        return HStack(spacing: 0) {
            Image(decorative: images.upper, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: fadeWidth, height: height)
            Image(decorative: images.lower, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: farWidth, height: height)
        }
        .overlay {
            scrim(seam: fadeWidth / total, settle: min(1, fadeWidth * 1.6 / total), along: .horizontal)
        }
        .frame(width: total, height: height)
        .position(x: artworkRect.maxX - fadeWidth + total / 2, y: pageSize.height / 2)
    }

    /// 渐隐那段从无到有，封面下沿处到背景图遮罩的中段，再往下一点到底部那一档：
    /// 歌名、进度条和按钮压在上面和压在模糊封面背景上一样看得清。
    private func scrim(seam: CGFloat, settle: CGFloat, along axis: Axis) -> some View {
        let value = PlayerBackdropScrimPolicy.scrim(
            isLight: isLight,
            strength: strength,
            usesIncreasedContrast: usesIncreasedContrast
        )
        let base: Color = isLight ? .white : .black
        return LinearGradient(
            stops: [
                .init(color: base.opacity(0), location: 0),
                .init(color: base.opacity(value.middleOpacity), location: seam),
                .init(color: base.opacity(value.bottomOpacity), location: max(seam, settle)),
                .init(color: base.opacity(value.bottomOpacity), location: 1),
            ],
            startPoint: axis == .vertical ? .top : .leading,
            endPoint: axis == .vertical ? .bottom : .trailing
        )
    }
}

/// 铺满封面延伸底图（`PlayerBackdropImaging.fullBleedExtension`）切成的上下两半。
struct FullBleedArtworkExtensionImages: Sendable {
    let key: String
    /// 垫在封面渐隐那段底下的半张（竖屏是上半，横屏是左半）。
    let upper: CGImage
    /// 往外铺到屏幕边的半张。
    let lower: CGImage

    private init?(key: String, combined: CGImage, edge: FullBleedArtworkExtension.Edge) {
        let near: CGRect
        let far: CGRect
        switch edge {
        case .bottom:
            let half = combined.height / 2
            guard half > 0 else { return nil }
            near = CGRect(x: 0, y: 0, width: combined.width, height: half)
            far = CGRect(x: 0, y: half, width: combined.width, height: combined.height - half)
        case .trailing:
            let half = combined.width / 2
            guard half > 0 else { return nil }
            near = CGRect(x: 0, y: 0, width: half, height: combined.height)
            far = CGRect(x: half, y: 0, width: combined.width - half, height: combined.height)
        }
        guard let upper = combined.cropping(to: near), let lower = combined.cropping(to: far) else { return nil }
        self.key = key
        self.upper = upper
        self.lower = lower
    }

    static func cacheKey(song: Song, coverRevision: Int, edge: FullBleedArtworkExtension.Edge = .bottom) -> String {
        let prefix = edge == .bottom ? "fullbleed" : "fullbleed-trailing"
        return "\(prefix)|\(song.id)|\(song.coverArtFileName ?? "")|\(coverRevision)"
    }

    static func cached(
        song: Song,
        coverRevision: Int,
        edge: FullBleedArtworkExtension.Edge = .bottom
    ) -> FullBleedArtworkExtensionImages? {
        let key = cacheKey(song: song, coverRevision: coverRevision, edge: edge)
        guard let image = PlayerBackdropMemoryCache.shared.image(forKey: key) else { return nil }
        return FullBleedArtworkExtensionImages(key: key, combined: image, edge: edge)
    }

    /// 取封面小图、在后台做一次模糊，结果放进背景图的内存缓存。
    static func load(
        song: Song,
        coverRevision: Int,
        sourceManager: SourceManager,
        edge: FullBleedArtworkExtension.Edge = .bottom,
        fraction: CGFloat = FullBleedArtworkExtension.fadeFraction
    ) async -> FullBleedArtworkExtensionImages? {
        if let cached = cached(song: song, coverRevision: coverRevision, edge: edge) { return cached }
        let key = cacheKey(song: song, coverRevision: coverRevision, edge: edge)
        let cover = await CachedArtworkView.resolveImage(
            coverRef: song.coverArtFileName,
            songID: song.id,
            size: 256,
            sourceID: song.sourceID,
            filePath: song.filePath,
            fileFormat: song.fileFormat,
            sourceManager: sourceManager,
            cacheDiscriminator: String(coverRevision)
        )
        guard !Task.isCancelled, let image = cover?.platformCGImage else { return nil }
        let combined = await Task.detached(priority: .userInitiated) {
            switch edge {
            case .bottom: PlayerBackdropImaging.fullBleedExtension(from: image, fraction: fraction)
            case .trailing: PlayerBackdropImaging.fullBleedTrailingExtension(from: image, fraction: fraction)
            }
        }.value
        guard let combined else { return nil }
        PlayerBackdropMemoryCache.shared.insert(combined, forKey: key)
        return FullBleedArtworkExtensionImages(key: key, combined: combined, edge: edge)
    }
}

#if os(iOS)
/// 播放页没打开时先把背景图备好。播放页是点迷你条才挂载的，宿主要等入场动画结束才开始读图，
/// 第一次展开（以及换歌后再展开）整个入场露的都是底下的色场。这里按宿主会算出的同一份请求
/// 提前准备，展开时拿到的就是现成的那张。
///
/// 专辑封底要列音乐源目录、下载原图，只用已经在内存里的，不为它发请求。
struct PlayerBackdropPrewarmer: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = PlayerBackdropSettingsStore.shared
    @State private var resolver = PlayerBackdropResolver.shared
    @AppStorage(PlayerAppearancePreferences.artworkStyleKey)
    private var artworkStyleRawValue = NowPlayingArtworkStyle.card.rawValue
    @AppStorage(PlayerAppearancePreferences.podcastArtworkStyleKey)
    private var podcastArtworkStyleRawValue = NowPlayingArtworkStyle.card.rawValue
    @AppStorage(PlayerAppearancePreferences.fullBleedTopSofteningKey)
    private var fullBleedTopSoftening = PlayerAppearancePreferences.fullBleedTopSofteningByDefault

    private struct PrewarmKey: Equatable {
        let request: PlayerBackdropResolver.Request
        let isSceneActive: Bool
    }

    /// 铺满封面下面那截延伸（`FullBleedArtworkExtension`）也提前备好。
    private struct ExtensionKey: Equatable {
        let cacheKey: String?
        let isSceneActive: Bool
    }

    var body: some View {
        let settings = store.settings
        let source = store.effectiveSource
        let song = player.isLiveRadio ? nil : player.currentSong

        // 和播放页一样铺满整个窗口，算出的像素档位才对得上。
        GeometryReader { geometry in
            let longSide = Double(max(geometry.size.width, geometry.size.height) * displayScale)
            let request = PlayerBackdropResolver.Request(
                source: source,
                rotation: settings.rotation,
                step: resolver.rotation.step,
                song: song,
                customImageIDs: store.customImageIDs,
                maxPixel: PlayerBackdropPixelPolicy.storagePixel(forDisplayLongSide: longSide),
                allowsLoading: source != .albumBack
            )
            Color.clear
                .onChange(
                    of: PrewarmKey(request: request, isSceneActive: scenePhase == .active),
                    initial: true
                ) { _, key in
                    // 退到后台连播时不跟着每首歌解图，回到前台再补。
                    guard key.isSceneActive else { return }
                    resolver.update(key.request, sourceManager: sourceManager, sourcesStore: sourcesStore)
                }
        }
        .ignoresSafeArea()
        // 按歌轮播要先记下换了歌，备好的才是展开后宿主要的那一张。
        .onChange(of: song?.id, initial: true) { _, songID in
            resolver.observeSong(songID, rotation: settings.rotation)
        }
        .task(id: extensionKey(song: song, source: source)) {
            guard let song, extensionKey(song: song, source: source).isSceneActive else { return }
            _ = await FullBleedArtworkExtensionImages.load(
                song: song,
                coverRevision: player.coverRevision,
                sourceManager: sourceManager
            )
        }
        // 顶部柔化那张模糊封面同样提前备好，展开时顶上不会晚一拍才淡入。它不看背景选的是什么。
        .task(id: topSofteningKey(song: song)) {
            guard let song, topSofteningKey(song: song).isSceneActive else { return }
            _ = await FullBleedTopSofteningImage.load(
                song: song,
                coverRevision: player.coverRevision,
                sourceManager: sourceManager
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 只有 iPhone 选了铺满封面、背景是封面取色时才用得上；电台的台标和 MV 不铺这一截，也不备。
    /// 播客单集看播客那一页选的样式。
    private func extensionKey(song: Song?, source: PlayerBackdropSource) -> ExtensionKey {
        let applies = usesFullBleedArtwork(song: song) && source == .coverAmbient
        return ExtensionKey(
            cacheKey: applies ? song.map {
                FullBleedArtworkExtensionImages.cacheKey(song: $0, coverRevision: player.coverRevision)
            } : nil,
            isSceneActive: applies && scenePhase == .active
        )
    }

    private func topSofteningKey(song: Song?) -> ExtensionKey {
        let applies = usesFullBleedArtwork(song: song) && fullBleedTopSoftening
        return ExtensionKey(
            cacheKey: applies ? song.map {
                FullBleedTopSofteningImage.cacheKey(song: $0, coverRevision: player.coverRevision)
            } : nil,
            isSceneActive: applies && scenePhase == .active
        )
    }

    private func usesFullBleedArtwork(song: Song?) -> Bool {
        let isPodcast = song.map { PodcastPlaybackSong.isEpisode($0) || SpokenWordStore.shared.isPodcast($0) } ?? false
        return UIDevice.current.userInterfaceIdiom == .phone
            && PlayerAppearancePreferences.artworkStyle(
                rawValue: isPodcast ? podcastArtworkStyleRawValue : artworkStyleRawValue
            ) == .fullBleed
            && !player.isMusicVideoPlaybackActive
    }
}
#endif
