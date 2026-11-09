#if os(tvOS)
import SwiftUI
import PrimuseKit

/// 电视首页最上面一行「居家场景」:会客、休闲、夜间聆听、专注、派对。
///
/// 每个场景是一条听歌意图(`ListeningScene`),曲库里够歌的才出现,顺序固定(遥控器上好记)。
/// 点亮和手机「开始听」同一次后台遍历;按下场景卡在后台抽一批歌,装好队列直接进播放页,
/// 放完按相似歌曲续播。夜间聆听另把睡眠定时设为 60 分钟(电视设置里可关)。
/// 场景只决定放什么,不改首页其它内容。
///
/// 卡片画成一排小号透明 CD 盒,盒里那张封面纸是这个场景里几张不同专辑的封面拼成的,
/// 像一张合辑。不聚焦时封面压暗、褪一点色,不和上面的专辑封面抢;聚焦时封面亮起来,
/// 盒面扫过一道反光。场景里的歌都没有封面时还是空的透明盒,聚焦时映出首页封面色。
struct TVHomeSceneRow: View {
    /// 夜间聆听起播时设睡眠定时;电视设置「播放」里的开关。
    static let nightSleepTimerKey = "primuse.tv.sceneNightSleepTimer"

    var focusBinding: FocusState<String?>.Binding
    /// 每张卡在首页焦点记忆里的 id。
    var cardID: (ListeningScene) -> String
    /// 首页主视觉的封面色(跟随「封面取色」设置):聚焦的盒子映出这层颜色,和上面的封面连成一片。
    var reflectionTint: Color
    /// 队列装好以后:记下是哪张卡,再进播放页。
    var onStarted: (String) -> Void

    @Environment(TVStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(TVHomeSceneRow.nightSleepTimerKey) private var nightSleepTimer = true
    @State private var startingScene: ListeningScene?

    private var service: ListeningIntentService { .shared }

    /// 点亮由首页刷新(`ListeningIntentService.refresh`),这里只读结果。
    var body: some View {
        let entries = ListeningScene.shelf(availability: service.availability)
        if !entries.isEmpty {
            TVRow(label: String(localized: "listening_scene_row_title"), rule: true) {
                ForEach(entries) { entry in
                    sceneCard(entry)
                }
            }
            #if DEBUG
            .task { startDebugSceneIfRequested(entries) }
            #endif
        }
    }

    #if DEBUG
    @MainActor private static var didStartDebugScene = false

    /// 截图钩子:`TV_DEBUG_SCENE=<场景 rawValue>` 在这个场景点亮后替你按一下(只按一次)。
    private func startDebugSceneIfRequested(_ entries: [ListeningSceneEntry]) {
        guard !Self.didStartDebugScene,
              let raw = ProcessInfo.processInfo.environment["TV_DEBUG_SCENE"],
              let scene = ListeningScene(rawValue: raw),
              entries.contains(where: { $0.scene == scene }) else { return }
        Self.didStartDebugScene = true
        start(scene)
    }
    #endif

    private func sceneCard(_ entry: ListeningSceneEntry) -> some View {
        let scene = entry.scene
        let title = String(localized: String.LocalizationValue(scene.titleKey))
        let subtitle = scene == .night && nightSleepTimer
            ? String(format: String(localized: "listening_scene_night_timer_hint %lld"), ListeningScene.nightSleepTimerMinutes)
            : String(localized: String.LocalizationValue(scene.subtitleKey))
        let count = String(format: String(localized: "listening_intent_song_count %lld"), entry.songCount)
        let covers = coverSongs(for: scene)
        // 有封面时字压在封面纸的暗角上,固定用白字;空盒子透出首页底色,字跟外观走。
        let ink = TVSceneCaseInk(onArtwork: !covers.isEmpty)
        return TVFocusButton(
            ring: false,
            action: { start(scene) },
            focusBinding: focusBinding,
            focusID: cardID(scene)
        ) { focused in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Image(systemName: scene.symbolName)
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(focused ? ink.primary : ink.secondary)
                    Spacer(minLength: 8)
                    if startingScene == scene {
                        ProgressView()
                            .tint(ink.primary)
                    } else {
                        Text(verbatim: count)
                            .tvFont(.meta, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(ink.faint)
                    }
                }
                Spacer(minLength: 8)
                Text(verbatim: title)
                    .tvFont(.cardTitle, weight: .bold)
                    .foregroundStyle(ink.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(verbatim: subtitle)
                    .tvFont(.caption)
                    .foregroundStyle(ink.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .shadow(color: .black.opacity(covers.isEmpty ? 0 : 0.35), radius: 3, y: 1)
            .padding(.vertical, 20)
            .padding(.leading, Self.hingeWidth + 16)
            .padding(.trailing, 16)
            .frame(width: Self.caseSize.width, height: Self.caseSize.height, alignment: .topLeading)
            .background { TVSceneJewelCase(focused: focused, tint: reflectionTint, covers: covers) }
            // 不用通用的粗描边焦点:盒子本身的框变亮、浮起一点,反光就够认出来。
            .scaleEffect(focused && !reduceMotion ? 1.05 : 1)
            .offset(y: focused && !reduceMotion ? -4 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: focused)
        }
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: "\(subtitle), \(count)"))
        .accessibilityIdentifier("tvHome.scene." + scene.rawValue)
    }

    /// 点亮时给每个场景挑好的几首歌(不同专辑、都有封面,每天换一批),拿来拼盒里的封面纸。
    private func coverSongs(for scene: ListeningScene) -> [TVSong] {
        (service.availability?.coverSongIDs(for: scene.intent) ?? [])
            .prefix(ListeningIntentEngine.coverSampleLimit)
            .compactMap { store.song($0) }
    }

    /// 按下:后台抽一批歌,装好队列进播放页。派对开着随机;夜间聆听按设置定时 60 分钟。
    private func start(_ scene: ListeningScene) {
        guard startingScene == nil else { return }
        startingScene = scene
        Task {
            let ids = await service.queueSongIDs(for: scene.intent, library: store.library)
            startingScene = nil
            guard !ids.isEmpty,
                  store.playResolvedQueue(songIDs: ids, shuffled: scene.turnsShuffleOn) else { return }
            if nightSleepTimer, let minutes = scene.intent.playback.sleepTimerMinutes {
                store.setSleepTimer(minutes: minutes)
            }
            plog("🎯 TV scene \(scene.rawValue) queued \(ids.count) sleep=\(nightSleepTimer && scene == .night)")
            onStarted(cardID(scene))
        }
    }

    /// 五张正好排满一行(首页内容宽约 1600),不用左右滚;这个宽度中文副标题一行放得下。
    /// 高度比 CD 盒(142 × 125 mm)略矮一点,免得这一排把下面的推荐挤出屏幕。
    static let caseSize = CGSize(width: 288, height: 228)
    static let cornerRadius: CGFloat = 10
    /// 盒子左边铰链那一窄条。
    static let hingeWidth: CGFloat = 12
    /// 封面纸四周露出的透明塑料边。
    static let rimWidth: CGFloat = 5
}

/// 卡片上的字色:压在封面纸上用白字,空盒子跟系统外观。
private struct TVSceneCaseInk {
    let primary: Color
    let secondary: Color
    let faint: Color

    init(onArtwork: Bool) {
        if onArtwork {
            primary = .white
            secondary = .white.opacity(0.82)
            faint = .white.opacity(0.72)
        } else {
            primary = TVColor.text
            secondary = TVColor.textMuted
            faint = TVColor.textFaint
        }
    }
}

/// CD 盒:灰色细框、左边一道铰链和上下两个铰链扣,盒面是透明塑料。
/// 夹着封面纸时四周露出一圈透明边;空盒子里隐约一张盘,聚焦时盒面铺一层很淡的首页封面色。
/// 聚焦时框线变亮、盒面从左往右扫过一道光。
private struct TVSceneJewelCase: View {
    let focused: Bool
    let tint: Color
    var covers: [TVSong] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 扫过盒面那道光:false 停在盒子左边外面,true 扫到右边外面。
    @State private var glintSwept = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TVHomeSceneRow.cornerRadius, style: .continuous)
        let size = TVHomeSceneRow.caseSize
        ZStack(alignment: .topLeading) {
            if covers.isEmpty {
                emptyTray(size: size)
            } else {
                insert(size: size)
            }
            hinge(size: size)
            sheen
            glint(size: size)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay {
            // 内圈一道很淡的线,看着像有厚度的塑料边。
            shape.inset(by: 4).strokeBorder(innerRimColor, lineWidth: 1)
        }
        .overlay {
            shape.strokeBorder(
                TVColor.text.opacity(focused ? 0.7 : 0.2),
                lineWidth: focused ? 2 : 1.5
            )
        }
        // 空盒子是透明的,不投影;夹着封面纸的盒子浮起来时影子跟着深。
        .shadow(
            color: .black.opacity(covers.isEmpty ? 0 : (focused ? 0.34 : 0.14)),
            radius: focused ? 18 : 6,
            y: focused ? 12 : 4
        )
        .accessibilityHidden(true)
        .onChange(of: focused) { _, focused in
            sweepGlint(focused)
        }
    }

    private var innerRimColor: Color {
        covers.isEmpty
            ? TVColor.text.opacity(focused ? 0.1 : 0.05)
            : .white.opacity(focused ? 0.24 : 0.12)
    }

    /// 空盒子:盒面一层很淡的灰(聚焦时是首页封面色),盒里那张盘只看得见外沿和中心两道细圈。
    private func emptyTray(size: CGSize) -> some View {
        let hinge = TVHomeSceneRow.hingeWidth
        let disc = size.height - 28
        let discColor = focused ? tint.opacity(0.4) : TVColor.text.opacity(0.07)
        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: focused
                    ? [tint.opacity(0.20), tint.opacity(0.05)]
                    : [TVColor.text.opacity(0.03), TVColor.text.opacity(0.012)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            ZStack {
                Circle().strokeBorder(discColor, lineWidth: 1.5)
                Circle().strokeBorder(discColor, lineWidth: 1.5)
                    .frame(width: disc * 0.3, height: disc * 0.3)
            }
            .frame(width: disc, height: disc)
            .position(x: hinge + (size.width - hinge) / 2, y: size.height / 2)
        }
        .frame(width: size.width, height: size.height)
    }

    /// 封面纸:比盒子小一圈,和四周、铰链之间露出透明塑料。不聚焦时压暗、褪一点色;
    /// 上下两头各压一道暗角,白字压在上面读得清。
    private func insert(size: CGSize) -> some View {
        let hinge = TVHomeSceneRow.hingeWidth
        let rim = TVHomeSceneRow.rimWidth
        let paper = CGSize(width: size.width - hinge - rim * 2, height: size.height - rim * 2)
        return ZStack(alignment: .topLeading) {
            // 透过盒底看到的那一点灰,跟系统外观走。
            TVColor.text.opacity(0.05)
            TVSceneCaseInsert(covers: covers, size: paper)
                .saturation(focused ? 1 : 0.72)
                .overlay { Color.black.opacity(focused ? 0 : 0.2) }
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.42), location: 0),
                            .init(color: .clear, location: 0.34),
                            .init(color: .clear, location: 0.4),
                            .init(color: .black.opacity(0.78), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .offset(x: hinge + rim, y: rim)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// 左边的铰链:一窄条磨砂塑料,右缘一道亮线,上下各一个铰链扣。
    private func hinge(size: CGSize) -> some View {
        let hinge = TVHomeSceneRow.hingeWidth
        let knuckleHeight: CGFloat = 26
        let knuckle = TVColor.text.opacity(focused ? 0.2 : 0.11)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(TVColor.text.opacity(focused ? 0.08 : 0.045))
                .frame(width: hinge, height: size.height)
            Rectangle()
                .fill(TVColor.text.opacity(focused ? 0.3 : 0.14))
                .frame(width: 1, height: size.height)
                .offset(x: hinge)
            Capsule()
                .fill(knuckle)
                .frame(width: hinge - 5, height: knuckleHeight)
                .offset(x: 2.5, y: 14)
            Capsule()
                .fill(knuckle)
                .frame(width: hinge - 5, height: knuckleHeight)
                .offset(x: 2.5, y: size.height - 14 - knuckleHeight)
        }
    }

    /// 盒面的反光:宽的一道、窄的一道斜着。空盒子聚焦时宽的那道带首页封面色;
    /// 夹着封面纸时都是白光,不往封面上再铺颜色。不聚焦时只剩一点塑料的亮。
    private var sheen: some View {
        let broad: Color = covers.isEmpty
            ? (focused ? tint.opacity(0.32) : .white.opacity(0.04))
            : .white.opacity(focused ? 0.16 : 0.07)
        return ZStack {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.14),
                    .init(color: broad, location: 0.28),
                    .init(color: .clear, location: 0.42),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.47),
                    .init(color: .white.opacity(focused ? 0.14 : 0.03), location: 0.5),
                    .init(color: .clear, location: 0.53),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .allowsHitTesting(false)
    }

    /// 聚焦那一下从左往右扫过盒面的一道光。只动位移,老款 Apple TV 上也只是多一层合成。
    private func glint(size: CGSize) -> some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.36),
                .init(color: .white.opacity(0.26), location: 0.5),
                .init(color: .clear, location: 0.64),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .frame(width: size.width, height: size.height)
        .offset(x: glintSwept ? size.width : -size.width)
        .opacity(focused ? 1 : 0)
        .allowsHitTesting(false)
    }

    /// 聚焦时扫一次;离开时不带动画地放回左边,下次聚焦再扫。「减弱动态效果」打开时不扫。
    private func sweepGlint(_ focused: Bool) {
        guard focused, !reduceMotion else {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { glintSwept = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.85).delay(0.05)) { glintSwept = true }
    }
}

/// 封面纸:一张封面铺满;两张左右各半;三张时左边一大张、右边上下两小张。
private struct TVSceneCaseInsert: View {
    let covers: [TVSong]
    let size: CGSize

    var body: some View {
        let width = size.width
        let height = size.height
        let side = height / 2
        Group {
            switch covers.count {
            case 0:
                Color.clear
            case 1:
                TVSceneCover(song: covers[0], width: width, height: height)
            case 2:
                HStack(spacing: 0) {
                    TVSceneCover(song: covers[0], width: width / 2, height: height)
                    TVSceneCover(song: covers[1], width: width / 2, height: height)
                }
            default:
                HStack(spacing: 0) {
                    TVSceneCover(song: covers[0], width: width - side, height: height)
                    VStack(spacing: 0) {
                        TVSceneCover(song: covers[1], width: side, height: side)
                        TVSceneCover(song: covers[2], width: side, height: side)
                    }
                }
            }
        }
        .frame(width: width, height: height)
    }
}

/// 封面纸上的一格:场景里一首歌的封面,铺满这一格。
private struct TVSceneCover: View {
    @Environment(TVStore.self) private var store
    let song: TVSong
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let album = store.albumOf(song)
        TVArtworkView(
            coverKey: song.albumID,
            artist: song.artist,
            album: album?.title ?? "",
            songID: song.id,
            coverRef: song.coverRef,
            tint: album?.tint ?? TVColor.brand,
            tint2: album?.tint2 ?? .black,
            glyph: album?.glyph ?? "♪",
            size: width,
            height: height
        )
    }
}
#endif
