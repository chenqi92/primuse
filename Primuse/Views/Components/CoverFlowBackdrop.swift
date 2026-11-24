import SwiftUI
import PrimuseKit

/// 卡片底下缓慢流动的背景,像 Apple Music 的动态背景:拿卡片里那几首歌的封面,
/// 后台缩成小图、大半径模糊、提饱和,叠三层各自慢慢转圈、绕着中心平移,上面铺一层细颗粒。
/// 颜色都来自真实的封面。一张封面都取不到时退回几首歌封面色拼成的网格渐变。
/// 首页顶部卡片、智能推荐页头上那张卡共用。
struct CoverFlowBackdrop: View {
    /// 封面取色(`CoverTintProvider`)。取不到封面时拼渐变用,也当最底下那层的底色。
    let palettes: [ImmersiveArtworkPalette]
    /// 卡片里的歌。前几首封面不同的拿来模糊铺底;不给时只画取色渐变。
    var songs: [Song] = []
    /// 不在屏幕正中、滑动中、页面不在前台时停住,省电。
    var isAnimating = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SourceManager.self) private var sourceManager
    @State private var elapsed: TimeInterval = 0
    @State private var started: TimeInterval?
    @State private var loaded: CoverFlowArtworkSet?

    var body: some View {
        let artworkSongs = CoverFlowArtwork.distinctArtworkSongs(songs, limit: CoverFlowArtwork.maximumLayers)
        let signature = CoverFlowArtwork.signature(of: artworkSongs)
        // 刚挂上(卡片划回来、页面重开)时先用内存里模糊好的那几张,不先闪一下渐变。
        let layers = loaded?.signature == signature
            ? loaded?.layers ?? []
            : CoverFlowArtwork.cachedLayers(for: artworkSongs)
        let colors = Self.meshColors(palettes)
        let base = palettes.first?.secondary ?? Color(white: 0.16)
        let moving = isAnimating && !reduceMotion && scenePhase == .active
        // 取色变了多半是封面换了或刚读到:重新对一遍,封面没变时都是内存里现成的。
        let loadKey: String = signature + "#" + colors.map(\.description).joined(separator: ",")
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moving)) { context in
            let time = elapsed + (started.map { context.date.timeIntervalSinceReferenceDate - $0 } ?? 0)
            if layers.isEmpty {
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: MeshBackdropPalettePolicy.liquidPoints(at: time),
                    colors: colors
                )
            } else {
                CoverFlowArtworkLayers(layers: layers, base: base, time: time)
            }
        }
        .overlay {
            if !layers.isEmpty { CoverFlowGrain() }
        }
        .onChange(of: moving, initial: true) { _, active in
            let now = Date().timeIntervalSinceReferenceDate
            if active {
                started = now
            } else if let started {
                elapsed += now - started
                self.started = nil
            }
        }
        .animation(.easeInOut(duration: 0.6), value: colors.map(\.description))
        .animation(.easeInOut(duration: 0.6), value: layers.map(\.key))
        .task(id: loadKey) {
            guard !artworkSongs.isEmpty else {
                if loaded != nil { loaded = nil }
                return
            }
            let manager = sourceManager
            let result = await Task.detached(priority: .utility) {
                await CoverFlowArtwork.load(artworkSongs, sourceManager: manager)
            }.value
            guard !Task.isCancelled else { return }
            let next = CoverFlowArtworkSet(signature: signature, layers: result)
            if loaded != next { loaded = next }
        }
        .accessibilityHidden(true)
    }

    /// 九个顶点:四角压深色,中间和四边放各首的亮色,一首歌也排得满。
    static func meshColors(_ palettes: [ImmersiveArtworkPalette]) -> [Color] {
        let source = palettes.isEmpty ? [ImmersiveArtworkPalette.fallback] : palettes
        let lights = source.map(\.primary)
        let darks = source.map(\.secondary)
        func light(_ index: Int) -> Color { lights[index % lights.count] }
        func dark(_ index: Int) -> Color { darks[index % darks.count] }
        return [
            dark(0), light(1), dark(2),
            light(2), light(0), light(3),
            dark(1), light(3), dark(3),
        ]
    }
}

/// 一层模糊好的封面。`key` 是这首歌的缓存键,换了封面就是另一张图。
struct CoverFlowArtworkLayer: @unchecked Sendable {
    let key: String
    let image: CGImage
}

struct CoverFlowArtworkSet: Equatable {
    let signature: String
    let layers: [CoverFlowArtworkLayer]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.signature == rhs.signature
            && lhs.layers.count == rhs.layers.count
            && zip(lhs.layers, rhs.layers).allSatisfy { $0.key == $1.key && $0.image === $1.image }
    }
}

/// 三层模糊封面各按自己的周期转圈、绕着卡片中心慢慢平移,只有变换随时间变,不重新解图。
/// 封面四周已经渐隐成透明,叠在一起转起来看不出方形的边;最底下垫一层取色的深色。
private struct CoverFlowArtworkLayers: View {
    let layers: [CoverFlowArtworkLayer]
    let base: Color
    let time: TimeInterval

    var body: some View {
        // 旋转放大的模糊图层不能直接放在 ZStack 里撑大自身尺寸，否则会触发父容器与几何回调循环。
        base
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                GeometryReader { proxy in
                    let width = proxy.size.width.isFinite ? max(0, proxy.size.width) : 0
                    let height = proxy.size.height.isFinite ? max(0, proxy.size.height) : 0
                    let diagonal: CGFloat = max(1, (width * width + height * height).squareRoot())
                    ZStack {
                        ForEach(CoverFlowArtwork.motions.indices, id: \.self) { index in
                            let motion = CoverFlowArtwork.motions[index]
                            let turn: Double = time / motion.period * 2 * Double.pi
                            let angle: Double = motion.spin * turn + motion.phase
                            let orbitAngle: Double = motion.phase - motion.spin * turn
                            let radius: CGFloat = motion.orbit * diagonal
                            let side: CGFloat = diagonal * motion.scale
                            Image(decorative: layers[index % layers.count].image, scale: 1)
                                .resizable()
                                .frame(width: side, height: side)
                                .rotationEffect(.radians(angle))
                                .offset(x: radius * CGFloat(cos(orbitAngle)), y: radius * CGFloat(sin(orbitAngle)))
                                .opacity(motion.opacity)
                        }
                    }
                    .frame(width: width, height: height)
                }
            }
            .clipped()
    }
}

/// 一层静止的细颗粒,压住放大后模糊图的色带。
private struct CoverFlowGrain: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let grain = CoverFlowArtwork.grain {
            Image(decorative: grain, scale: displayScale)
                .resizable(resizingMode: .tile)
                .blendMode(.overlay)
                .opacity(0.2)
                .allowsHitTesting(false)
        }
    }
}

enum CoverFlowArtwork {
    /// 最多叠几层,也就是最多取几张封面。
    static let maximumLayers = 3

    struct Motion {
        /// 边长是卡片对角线的几倍。最底下那层大到渐隐的边永远在卡片外面。
        let scale: CGFloat
        /// 转一圈、绕一圈要几秒。
        let period: Double
        /// 1 顺时针、-1 逆时针。绕圈的方向和自转相反。
        let spin: Double
        let phase: Double
        /// 绕圈的半径是对角线的几倍。
        let orbit: CGFloat
        let opacity: Double
    }

    static let motions: [Motion] = [
        Motion(scale: 2.2, period: 30, spin: 1, phase: 0, orbit: 0.06, opacity: 1),
        Motion(scale: 1.3, period: 24, spin: -1, phase: 2.1, orbit: 0.2, opacity: 0.85),
        Motion(scale: 1.0, period: 20, spin: 1, phase: 4.2, orbit: 0.26, opacity: 0.75),
    ]

    /// 封面各不相同的前几首:同一张专辑的几首只算一张,没有封面文件名的按专辑、再按歌区分。
    static func distinctArtworkSongs(_ songs: [Song], limit: Int) -> [Song] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var picked: [Song] = []
        for song in songs {
            let cover = song.coverArtFileName.flatMap { $0.isEmpty ? nil : $0 }
            guard seen.insert(cover ?? song.albumID ?? song.id).inserted else { continue }
            picked.append(song)
            if picked.count == limit { break }
        }
        return picked
    }

    static func signature(of songs: [Song]) -> String {
        songs.map { cacheKey(for: $0) }.joined(separator: "\n")
    }

    nonisolated static func cacheKey(for song: Song) -> String {
        "coverflow|\(song.id)|\(song.coverArtFileName ?? "")"
    }

    /// 内存里已经模糊好的那几张。缺一张就当没有,等后台读齐了再一起换上。
    static func cachedLayers(for songs: [Song]) -> [CoverFlowArtworkLayer] {
        var layers: [CoverFlowArtworkLayer] = []
        for song in songs {
            let key = cacheKey(for: song)
            guard let image = CoverFlowArtworkCache.shared.image(forKey: key) else { return [] }
            layers.append(CoverFlowArtworkLayer(key: key, image: image))
        }
        return layers
    }

    /// 在后台取每首的小封面(封面缓存的最小一档)、模糊。取到的封面和上次模糊用的是同一张时
    /// 直接用上次的结果;封面换了缓存会给出另一张图,这里跟着重新模糊。
    nonisolated static func load(_ songs: [Song], sourceManager: SourceManager) async -> [CoverFlowArtworkLayer] {
        _ = grain
        var layers: [CoverFlowArtworkLayer] = []
        for song in songs {
            guard !Task.isCancelled else { return [] }
            let cover = await CachedArtworkView.resolveImage(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 32,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat,
                sourceManager: sourceManager
            )
            guard let source = cover?.platformCGImage else { continue }
            let key = cacheKey(for: song)
            if let cached = CoverFlowArtworkCache.shared.image(forKey: key, source: source) {
                layers.append(CoverFlowArtworkLayer(key: key, image: cached))
                continue
            }
            guard let blurred = PlayerBackdropImaging.coverFlowLayer(from: source) else { continue }
            CoverFlowArtworkCache.shared.insert(blurred, source: source, forKey: key)
            layers.append(CoverFlowArtworkLayer(key: key, image: blurred))
        }
        return layers
    }

    /// 128 像素见方的灰度噪点,平铺在卡片上。只生成一次。
    nonisolated static let grain: CGImage? = {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side)
        var state: UInt32 = 0x9E37_79B9
        for index in pixels.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            pixels[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }()
}

/// 模糊好的封面按歌放在内存里,连同模糊时用的那张小封面:下次取到的还是同一张就不再模糊。
final class CoverFlowArtworkCache: @unchecked Sendable {
    nonisolated static let shared = CoverFlowArtworkCache()

    private final class Box {
        let source: CGImage
        let image: CGImage

        init(source: CGImage, image: CGImage) {
            self.source = source
            self.image = image
        }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 96
        return cache
    }()

    nonisolated func image(forKey key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    nonisolated func image(forKey key: String, source: CGImage) -> CGImage? {
        guard let box = cache.object(forKey: key as NSString), box.source === source else { return nil }
        return box.image
    }

    nonisolated func insert(_ image: CGImage, source: CGImage, forKey key: String) {
        cache.setObject(Box(source: source, image: image), forKey: key as NSString)
    }
}
