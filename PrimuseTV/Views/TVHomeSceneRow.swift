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
/// 卡片画成一排小号透明 CD 盒:不聚焦时只有灰色细框,聚焦时盒面映出很淡的封面色。
/// 原来的整块场景色和上面的专辑封面抢眼,看着也不像 Apple TV 的东西。
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
            ring: false,
            action: { start(scene) },
            focusBinding: focusBinding,
            focusID: cardID(scene)
        ) { focused in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Image(systemName: scene.symbolName)
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(focused ? TVColor.text : TVColor.textMuted)
                    Spacer(minLength: 8)
                    if startingScene == scene {
                        ProgressView()
                            .tint(TVColor.text)
                    } else {
                        Text(verbatim: count)
                            .tvFont(.meta, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(TVColor.textFaint)
                    }
                }
                Spacer(minLength: 8)
                Text(verbatim: title)
                    .tvFont(.cardTitle, weight: .bold)
                    .foregroundStyle(TVColor.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(verbatim: subtitle)
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textMuted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .padding(.vertical, 20)
            .padding(.leading, Self.hingeWidth + 16)
            .padding(.trailing, 16)
            .frame(width: Self.caseSize.width, height: Self.caseSize.height, alignment: .topLeading)
            .background { TVSceneJewelCase(focused: focused, tint: reflectionTint) }
            // 不用通用的粗描边焦点:盒子本身的框变亮、浮起一点,反光就够认出来。
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

/// 透明 CD 盒:灰色细框、左边一道铰链、盒里隐约一张盘。
/// 聚焦时盒面铺一层很淡的封面色,斜着一道封面色反光,框线变亮。
private struct TVSceneJewelCase: View {
    let focused: Bool
    let tint: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TVHomeSceneRow.cornerRadius, style: .continuous)
        let size = TVHomeSceneRow.caseSize
        let hinge = TVHomeSceneRow.hingeWidth
        let disc = size.height - 28
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: focused
                    ? [tint.opacity(0.20), tint.opacity(0.05)]
                    : [TVColor.text.opacity(0.03), TVColor.text.opacity(0.012)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // 盒里的盘:外沿和中心两道细圈,透过盒面隐约看得见。
            ZStack {
                Circle().strokeBorder(discColor, lineWidth: 1.5)
                Circle().strokeBorder(discColor, lineWidth: 1.5)
                    .frame(width: disc * 0.3, height: disc * 0.3)
            }
            .frame(width: disc, height: disc)
            .position(x: hinge + (size.width - hinge) / 2, y: size.height / 2)
            Rectangle()
                .fill(TVColor.text.opacity(focused ? 0.08 : 0.045))
                .frame(width: hinge)
            Rectangle()
                .fill(TVColor.text.opacity(focused ? 0.3 : 0.14))
                .frame(width: 1)
                .offset(x: hinge)
            sheen
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay {
            // 内圈一道很淡的线,看着像有厚度的塑料边。
            shape.inset(by: 4).strokeBorder(TVColor.text.opacity(focused ? 0.1 : 0.05), lineWidth: 1)
        }
        .overlay {
            shape.strokeBorder(
                TVColor.text.opacity(focused ? 0.7 : 0.2),
                lineWidth: focused ? 2 : 1.5
            )
        }
    }

    private var discColor: Color {
        focused ? tint.opacity(0.4) : TVColor.text.opacity(0.07)
    }

    /// 两道斜向反光:宽的一道带封面色,窄的一道是白光。不聚焦时只剩一点塑料的亮。
    private var sheen: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.14),
                    .init(color: focused ? tint.opacity(0.32) : .white.opacity(0.04), location: 0.28),
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
    }
}
#endif
