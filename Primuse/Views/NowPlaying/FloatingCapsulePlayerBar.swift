#if os(iOS)
import PrimuseKit
import SwiftUI

/// 底部播放条的「悬浮胶囊」实现(`SkinSlotVariant.BottomChrome.floatingCapsule`)。
///
/// 功能契约与其它播放条完全一致 —— 点按打开播放页、左右滑切歌、播放 / 暂停、下一首 ——
/// 这些都来自共用的 `MiniPlayerSwipeContent`,这里只负责画法,并补上两样原来没有的东西:
/// 播放键外圈的进度环,和直接打开播放队列的入口。
struct FloatingCapsulePlayerBar: View {
    var onTap: () -> Void
    var onOpenQueue: () -> Void
    /// 嵌在极简底栏的两颗圆键之间:外边距与宽度交给外层,队列键省掉(长按胶囊仍可在播放页里打开)。
    var embedded = false

    @Environment(\.skin) private var skin
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.pmHeightClass) private var heightClass
    @ScaledMetric(relativeTo: .subheadline) private var contentHeight: CGFloat = 44

    /// 大号无障碍字体下只留播放键,把宽度让给歌名。
    private var showsSecondaryControls: Bool { !dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        // 手机横屏下胶囊收窄并靠向尾侧,和极简皮肤的播放条一个口径:横贯七百多点的
        // 一条板会把只剩三百多点的版面压得更死,让开之后左侧内容仍然看得见。
        let capsuleWidth = heightClass.value(620, compact: 380)
        let capsuleAlignment = heightClass.pick(Alignment.center, compact: .trailing)
        return HStack(spacing: 0) {
            MiniPlayerSwipeContent(
                onTap: onTap,
                artworkSize: 40,
                artworkCornerRadius: 20,
                artworkTrailingSpacing: 10,
                titleFont: .subheadline,
                showsSubtitle: true,
                contentHeight: contentHeight
            )

            FloatingCapsulePlayButton()

            if showsSecondaryControls {
                if !player.isLiveRadio || player.canSwitchRadioStation {
                    nextButton
                }
                if !player.isLiveRadio && !embedded {
                    queueButton
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .frame(maxWidth: capsuleWidth)
        .background { capsuleFill }
        .overlay {
            Capsule()
                .strokeBorder(skin.color(.chromeBorder), lineWidth: skin.rawMetric(.borderWidth))
                .allowsHitTesting(false)
        }
        .contentShape(Capsule())
        .shadow(
            color: Color.black.opacity(Double(skin.rawMetric(.shadowOpacity))),
            radius: skin.rawMetric(.shadowRadius),
            y: 8
        )
        .modifier(FloatingCapsuleOuterLayout(
            embedded: embedded,
            alignment: capsuleAlignment,
            horizontalInset: skin.metric(.chromeHorizontalInset),
            top: heightClass.value(6, compact: 4),
            bottom: heightClass.value(8, compact: 6)
        ))
    }

    @ViewBuilder
    private var capsuleFill: some View {
        if reduceTransparency || skin.usesSolidChrome {
            Capsule().fill(skin.color(.canvasElevated))
        } else {
            // 样式的半透明底色叠在模糊之上:底下滚过的封面只透出一点颜色,文字始终可读。
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(skin.color(.chromeBackground))
            }
        }
    }

    private var nextButton: some View {
        Button {
            Task { await player.next() }
        } label: {
            Image(systemName: "forward.fill")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.skin(.textPrimary))
        .accessibilityLabel(
            player.isLiveRadio
                ? String(localized: "radio_next_station")
                : String(localized: "a11y_next_track")
        )
    }

    private var queueButton: some View {
        Button(action: onOpenQueue) {
            Image(systemName: "list.bullet")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.skin(.textSecondary))
        .accessibilityLabel(Text("queue_title"))
    }
}

private struct FloatingCapsulePlayButton: View {
    @Environment(AudioPlayerService.self) private var player

    private var isStoppableRadio: Bool {
        player.isLiveRadio && (player.isPlaybackActive || player.isLoading)
    }

    private var symbolName: String {
        if isStoppableRadio { return "stop.fill" }
        return player.isPlaybackActive ? "pause.fill" : "play.fill"
    }

    private var label: String {
        if isStoppableRadio { return String(localized: "radio_stop") }
        return player.isPlaybackActive
            ? String(localized: "a11y_pause")
            : String(localized: "a11y_play")
    }

    var body: some View {
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                FloatingCapsuleProgressRing()
                if player.isLoading && !player.isLiveRadio {
                    ProgressView().controlSize(.small)
                        .pmFadeTransition(motion: .control)
                } else {
                    Image(systemName: symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        // ProgressView 与 Image 之间 symbolEffect 不生效, 这一跳只能走透明度。
                        .pmFadeTransition(motion: .control)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.skin(.textPrimary))
        .disabled(player.isLoading && !player.isLiveRadio)
        .accessibilityLabel(label)
    }
}

/// 进度环单独成一个视图:`currentTime` 每半秒变一次,只让这一小块重绘,
/// 不牵连歌名、封面和整条播放条。
private struct FloatingCapsuleProgressRing: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.skin) private var skin

    private var fraction: CGFloat {
        let duration = player.duration
        let elapsed = player.currentTime
        guard !player.isLiveRadio, duration > 0, elapsed.isFinite else { return 0 }
        let ratio = min(max(elapsed / duration, 0), 1)
        return CGFloat(ratio)
    }

    var body: some View {
        let progress = fraction
        ZStack {
            Circle()
                .stroke(skin.color(.textQuaternary), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(skin.color(.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 36, height: 36)
        // 引擎每半秒报一次进度,用同样时长的线性动画把两次采样之间补平。
        .animation(skin.reduceMotion ? nil : .linear(duration: 0.5), value: progress)
        .accessibilityHidden(true)
    }
}
/// 独立放置时胶囊自己占满一行并留出外边距;嵌进极简底栏时这些都交给外层。
private struct FloatingCapsuleOuterLayout: ViewModifier {
    let embedded: Bool
    let alignment: Alignment
    let horizontalInset: CGFloat
    let top: CGFloat
    let bottom: CGFloat

    func body(content: Content) -> some View {
        if embedded {
            content
        } else {
            content
                .frame(maxWidth: .infinity, alignment: alignment)
                .padding(.horizontal, horizontalInset)
                .padding(.top, top)
                .padding(.bottom, bottom)
        }
    }
}

/// 极简基座的底栏:没有标签栏,左边是「首页 / 资料库」键,中间是悬浮播放胶囊,右边是搜索。
///
/// 左键点按在首页与资料库之间来回;在别的页面点按回首页。长按弹出全部去处
/// (首页、资料库各分类、电台、搜索、设置),所以没有标签栏也能一步到达任何地方。
struct MinimalBottomDock: View {
    enum Place: Equatable {
        case home, library, search, settings
    }

    let place: Place
    let showsPlayer: Bool
    let librarySections: [LibrarySection]
    let onHome: () -> Void
    let onLibrary: () -> Void
    let onLibrarySection: (LibrarySection) -> Void
    let onSearch: () -> Void
    let onSettings: () -> Void
    let onTapPlayer: () -> Void
    let onOpenQueue: () -> Void

    @Environment(\.skin) private var skin
    @Environment(\.pmHeightClass) private var heightClass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var buttonSize: CGFloat { heightClass.value(56, compact: 48) }

    var body: some View {
        HStack(spacing: 10) {
            destinationButton
            Group {
                if showsPlayer {
                    FloatingCapsulePlayerBar(onTap: onTapPlayer, onOpenQueue: onOpenQueue, embedded: true)
                        .pmSlideTransition(edge: .bottom, motion: .panel)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity)
            searchButton
        }
        .frame(maxWidth: heightClass.value(720, compact: 520))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, skin.metric(.chromeHorizontalInset))
        .padding(.top, heightClass.value(6, compact: 4))
        .padding(.bottom, heightClass.value(8, compact: 6))
    }

    /// 在首页时去资料库,在其它页面时回首页;图标随之变化。
    private var tapGoesToLibrary: Bool { place == .home }

    private var destinationButton: some View {
        Menu {
            Button(action: onHome) { Label("home_title", systemImage: "house") }
            Button(action: onLibrary) { Label("library_title", systemImage: "books.vertical") }
            Section {
                ForEach(librarySections, id: \.self) { section in
                    Button { onLibrarySection(section) } label: {
                        Label(section.title, systemImage: section.icon)
                    }
                }
            }
            Section {
                Button(action: onSearch) { Label("search_title", systemImage: "magnifyingglass") }
                Button(action: onSettings) { Label("settings_title", systemImage: "gearshape") }
            }
        } label: {
            dockCircle(systemImage: tapGoesToLibrary ? "books.vertical" : "house")
        } primaryAction: {
            if tapGoesToLibrary { onLibrary() } else { onHome() }
        }
        .accessibilityLabel(Text(tapGoesToLibrary ? "library_title" : "home_title"))
        .accessibilityHint(Text("minimal_dock_destinations_hint"))
    }

    private var searchButton: some View {
        Button(action: onSearch) {
            dockCircle(systemImage: "magnifyingglass", highlighted: place == .search)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("search_title"))
    }

    private func dockCircle(systemImage: String, highlighted: Bool = false) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: buttonSize * 0.36, weight: .semibold))
            .foregroundStyle(highlighted ? skin.color(.accent) : skin.color(.textPrimary))
            .frame(width: buttonSize, height: buttonSize)
            .background { circleFill }
            .overlay {
                Circle()
                    .strokeBorder(skin.color(.chromeBorder), lineWidth: skin.rawMetric(.borderWidth))
            }
            .contentShape(Circle())
            .shadow(
                color: Color.black.opacity(Double(skin.rawMetric(.shadowOpacity))),
                radius: skin.rawMetric(.shadowRadius),
                y: 8
            )
    }

    @ViewBuilder
    private var circleFill: some View {
        if reduceTransparency || skin.usesSolidChrome {
            Circle().fill(skin.color(.canvasElevated))
        } else {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().fill(skin.color(.chromeBackground))
            }
        }
    }
}
#endif
