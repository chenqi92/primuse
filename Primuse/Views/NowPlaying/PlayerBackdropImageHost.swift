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

    static func bandHeight(topSafeArea: CGFloat) -> CGFloat { topSafeArea + 44 }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [appearance.backgroundBase.opacity(0.42), appearance.backgroundBase.opacity(0)],
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

/// 只在背景选的是封面取色时铺：流动色彩、声音律动和背景图是用户特意选的，封面下面照旧露出它们。
struct FullBleedArtworkExtension: View {
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
        allowsLoading: Bool
    ) {
        self.song = song
        self.coverRevision = coverRevision
        self.artworkRect = artworkRect
        self.pageSize = pageSize
        self.isLight = isLight
        self.strength = strength
        self.usesIncreasedContrast = usesIncreasedContrast
        self.allowsLoading = allowsLoading
        // 播放页每次展开都重新挂载：备好的那张直接用上，不再淡入一遍。
        _shown = State(initialValue: song.flatMap {
            FullBleedArtworkExtensionImages.cached(song: $0, coverRevision: coverRevision)
        })
    }

    private struct LoadKey: Equatable {
        let cacheKey: String?
        let allowsLoading: Bool
    }

    var body: some View {
        let cacheKey = song.map {
            FullBleedArtworkExtensionImages.cacheKey(song: $0, coverRevision: coverRevision)
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
            if let cached = FullBleedArtworkExtensionImages.cached(song: song, coverRevision: coverRevision) {
                withAnimation(Self.crossfade) { shown = cached }
                return
            }
            // 换歌后新封面没好之前留着上一首的，好了再交叉淡入；取不到封面就退回色场。
            guard allowsLoading else { return }
            let loaded = await FullBleedArtworkExtensionImages.load(
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

    private func extensionLayer(_ images: FullBleedArtworkExtensionImages) -> some View {
        let width = max(artworkRect.width, pageSize.width)
        let fadeHeight = max(1, artworkRect.height * Self.fadeFraction)
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
            scrim(seam: fadeHeight / total, settle: min(1, fadeHeight * 1.6 / total))
        }
        .frame(width: width, height: total)
        .position(x: pageSize.width / 2, y: artworkRect.maxY - fadeHeight + total / 2)
    }

    /// 渐隐那段从无到有，封面下沿处到背景图遮罩的中段，再往下一点到底部那一档：
    /// 歌名、进度条和按钮压在上面和压在模糊封面背景上一样看得清。
    private func scrim(seam: CGFloat, settle: CGFloat) -> some View {
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
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// 铺满封面延伸底图（`PlayerBackdropImaging.fullBleedExtension`）切成的上下两半。
struct FullBleedArtworkExtensionImages: Sendable {
    let key: String
    let upper: CGImage
    let lower: CGImage

    private init?(key: String, combined: CGImage) {
        let half = combined.height / 2
        guard half > 0,
              let upper = combined.cropping(to: CGRect(x: 0, y: 0, width: combined.width, height: half)),
              let lower = combined.cropping(
                to: CGRect(x: 0, y: half, width: combined.width, height: combined.height - half)
              )
        else { return nil }
        self.key = key
        self.upper = upper
        self.lower = lower
    }

    static func cacheKey(song: Song, coverRevision: Int) -> String {
        "fullbleed|\(song.id)|\(song.coverArtFileName ?? "")|\(coverRevision)"
    }

    static func cached(song: Song, coverRevision: Int) -> FullBleedArtworkExtensionImages? {
        let key = cacheKey(song: song, coverRevision: coverRevision)
        guard let image = PlayerBackdropMemoryCache.shared.image(forKey: key) else { return nil }
        return FullBleedArtworkExtensionImages(key: key, combined: image)
    }

    /// 取封面小图、在后台做一次模糊，结果放进背景图的内存缓存。
    static func load(
        song: Song,
        coverRevision: Int,
        sourceManager: SourceManager
    ) async -> FullBleedArtworkExtensionImages? {
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
        let fraction = FullBleedArtworkExtension.fadeFraction
        let combined = await Task.detached(priority: .userInitiated) {
            PlayerBackdropImaging.fullBleedExtension(from: image, fraction: fraction)
        }.value
        guard let combined else { return nil }
        PlayerBackdropMemoryCache.shared.insert(combined, forKey: key)
        return FullBleedArtworkExtensionImages(key: key, combined: combined)
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
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 只有 iPhone 选了铺满封面、背景是封面取色时才用得上；电台的台标和 MV 不铺这一截，也不备。
    /// 播客单集看播客那一页选的样式。
    private func extensionKey(song: Song?, source: PlayerBackdropSource) -> ExtensionKey {
        let isPodcast = song.map { PodcastPlaybackSong.isEpisode($0) || SpokenWordStore.shared.isPodcast($0) } ?? false
        let applies = UIDevice.current.userInterfaceIdiom == .phone
            && PlayerAppearancePreferences.artworkStyle(
                rawValue: isPodcast ? podcastArtworkStyleRawValue : artworkStyleRawValue
            ) == .fullBleed
            && source == .coverAmbient
            && !player.isMusicVideoPlaybackActive
        return ExtensionKey(
            cacheKey: applies ? song.map {
                FullBleedArtworkExtensionImages.cacheKey(song: $0, coverRevision: player.coverRevision)
            } : nil,
            isSceneActive: applies && scenePhase == .active
        )
    }
}
#endif
