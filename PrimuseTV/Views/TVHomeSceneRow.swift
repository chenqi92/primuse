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
/// 场景各用一张彩色唱片封套,左侧保留盒脊;聚焦时盒面抬起,映出首页封面色。
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
        return TVFocusButton(
            ring: false,
            action: { start(scene) },
            focusBinding: focusBinding,
            focusID: cardID(scene)
        ) { focused in
            TVSceneCaseLabel(
                scene: scene, title: title, subtitle: subtitle, count: count,
                focused: focused, isStarting: startingScene == scene, reflectionTint: reflectionTint
            )
            .scaleEffect(focused && !reduceMotion ? 1.05 : 1)
            .offset(y: focused && !reduceMotion ? -4 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: focused)
        }
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: "\(subtitle), \(count)"))
        .accessibilityIdentifier("tvHome.scene." + scene.rawValue)
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
}

/// 封套文字固定使用白色,不随系统浅色外观变成深色。
struct TVSceneCaseLabel: View {
    let scene: ListeningScene
    let title: String
    let subtitle: String
    let count: String
    var focused = false
    var isStarting = false
    var reflectionTint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: scene.symbolName)
                    .font(.system(size: 34, weight: .medium))
                Spacer(minLength: 8)
                if isStarting {
                    ProgressView().tint(.white)
                } else {
                    Text(verbatim: count)
                        .tvFont(.meta, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: title)
                .tvFont(.cardTitle, weight: .bold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(verbatim: subtitle)
                .tvFont(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 20)
        .padding(.leading, TVHomeSceneRow.hingeWidth + 16)
        .padding(.trailing, 16)
        .frame(width: TVHomeSceneRow.caseSize.width, height: TVHomeSceneRow.caseSize.height)
        .background { TVSceneJewelCase(scene: scene, focused: focused, reflectionTint: reflectionTint) }
    }
}

private struct TVSceneJewelCase: View {
    let scene: ListeningScene
    let focused: Bool
    let reflectionTint: Color

    private var ink: Color {
        switch scene {
        case .guests: Color(red: 0.53, green: 0.29, blue: 0.13)
        case .leisure: Color(red: 0.16, green: 0.35, blue: 0.27)
        case .night: Color(red: 0.20, green: 0.22, blue: 0.46)
        case .focus: Color(red: 0.11, green: 0.32, blue: 0.40)
        case .party: Color(red: 0.43, green: 0.20, blue: 0.37)
        }
    }

    var body: some View {
        let size = TVHomeSceneRow.caseSize
        let hinge = TVHomeSceneRow.hingeWidth
        let shape = RoundedRectangle(cornerRadius: TVHomeSceneRow.cornerRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            ink
            LinearGradient(colors: [.white.opacity(0.12), .clear, .black.opacity(0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            disc
                .frame(width: 170, height: 170)
                .offset(x: 124, y: 20)
            LinearGradient(colors: [.clear, ink.opacity(0.92), ink],
                           startPoint: .top, endPoint: .bottom)
            Rectangle()
                .fill(.black.opacity(0.35))
                .frame(width: hinge)
            Rectangle()
                .fill(.white.opacity(0.3))
                .frame(width: 1)
                .offset(x: hinge)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.12),
                    .init(color: .white.opacity(focused ? 0.22 : 0.09), location: 0.28),
                    .init(color: .clear, location: 0.42),
                    .init(color: reflectionTint.opacity(focused ? 0.16 : 0), location: 0.72),
                    .init(color: .clear, location: 0.9),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay { shape.inset(by: 4).strokeBorder(.white.opacity(0.13), lineWidth: 1) }
        .overlay { shape.strokeBorder(.white.opacity(focused ? 0.9 : 0.3), lineWidth: focused ? 2.5 : 1) }
        .shadow(color: .black.opacity(focused ? 0.32 : 0.18), radius: focused ? 16 : 6, y: focused ? 10 : 4)
        .accessibilityHidden(true)
    }

    private var disc: some View {
        ZStack {
            Circle().fill(AngularGradient(
                colors: [.white.opacity(0.08), .white.opacity(0.5), ink, .white.opacity(0.32), ink, .white.opacity(0.08)],
                center: .center, angle: .degrees(-35)
            ))
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1)
            Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1).padding(7)
            Circle().fill(ink.opacity(0.9)).frame(width: 52, height: 52)
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2).frame(width: 52, height: 52)
            Circle().fill(.black.opacity(0.35)).frame(width: 16, height: 16)
        }
        .rotationEffect(.degrees(focused ? 12 : 0))
    }
}
#endif
