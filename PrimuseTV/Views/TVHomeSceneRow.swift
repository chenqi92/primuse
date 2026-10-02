#if os(tvOS)
import SwiftUI
import PrimuseKit

/// 电视首页最上面一行「居家场景」:会客、休闲、夜间聆听、专注、派对。
///
/// 每个场景是一条听歌意图(`ListeningScene`),曲库里够歌的才出现,顺序固定(遥控器上好记)。
/// 点亮和手机「开始听」同一次后台遍历;按下场景卡在后台抽一批歌,装好队列直接进播放页,
/// 放完按相似歌曲续播。夜间聆听另把睡眠定时设为 60 分钟(电视设置里可关)。
/// 场景只决定放什么,不改首页其它内容。
struct TVHomeSceneRow: View {
    /// 夜间聆听起播时设睡眠定时;电视设置「播放」里的开关。
    static let nightSleepTimerKey = "primuse.tv.sceneNightSleepTimer"

    var focusBinding: FocusState<String?>.Binding
    /// 每张卡在首页焦点记忆里的 id。
    var cardID: (ListeningScene) -> String
    /// 队列装好以后:记下是哪张卡,再进播放页。
    var onStarted: (String) -> Void

    @Environment(TVStore.self) private var store
    @AppStorage(TVHomeSceneRow.nightSleepTimerKey) private var nightSleepTimer = true
    @State private var startingScene: ListeningScene?

    private var service: ListeningIntentService { .shared }

    /// 点亮由首页刷新(`ListeningIntentService.refresh`),这里只读结果。
    var body: some View {
        let entries = ListeningScene.shelf(availability: service.availability)
        if !entries.isEmpty {
            TVRow(label: String(localized: "listening_scene_row_title")) {
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
            radius: Self.cornerRadius,
            scale: 1.06,
            lift: 10,
            action: { start(scene) },
            focusBinding: focusBinding,
            focusID: cardID(scene)
        ) { _ in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Image(systemName: scene.symbolName)
                        .font(.system(size: 40, weight: .semibold))
                    Spacer(minLength: 8)
                    if startingScene == scene {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(verbatim: count)
                            .tvFont(.meta, weight: .semibold)
                            .monospacedDigit()
                            .opacity(0.85)
                    }
                }
                Spacer(minLength: 8)
                Text(verbatim: title)
                    .tvFont(.cardTitle, weight: .bold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(verbatim: subtitle)
                    .tvFont(.caption)
                    .opacity(0.86)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(.white)
            .padding(22)
            .frame(width: Self.cardSize.width, height: Self.cardSize.height, alignment: .topLeading)
            .background {
                // 黑底叠场景色:浅色、深色外观下都是同一种偏深的颜色,白字始终看得清。
                ZStack {
                    Color.black
                    LinearGradient(
                        colors: [scene.intent.tint, scene.intent.tint.opacity(0.68)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            }
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

    /// 五张正好排满一行(首页内容宽约 1600):不用左右滚就能看全所有场景。
    static let cardSize = CGSize(width: 288, height: 184)
    static let cornerRadius: CGFloat = 18
}
#endif
