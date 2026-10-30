#if os(iOS)
import SwiftUI
import PrimuseKit
import UIKit

struct MiniPlayerView: View {
    var onTap: (() -> Void)? = nil
    var showsNextButton = true
    var showsSubtitle = false

    @Environment(\.pmHeightClass) private var heightClass
    /// 固定条高跟随 Dynamic Type，与 PadNowPlayingAccessory 一致。
    @ScaledMetric(relativeTo: .subheadline) private var contentHeight: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            MiniPlayerSwipeContent(
                onTap: { onTap?() },
                artworkSize: 30,
                artworkCornerRadius: 6,
                artworkTrailingSpacing: 8,
                titleFont: .subheadline,
                showsSubtitle: showsSubtitle,
                contentHeight: contentHeight
            )

            MiniPlayerTransportControls(showsNextButton: showsNextButton)
        }
        .padding(.horizontal, 16)
        // 手机横屏只收上下留白。条高由 ScaledMetric 决定、传输键仍是 44×44 命中区，
        // 两者都不动，省下来的是纯粹的余白。
        .padding(.vertical, heightClass.value(6, compact: 3))
    }
}

/// 播放页收起、落到迷你条的那一刻。迷你条有好几种外壳（系统底部附件、iPad、极简停靠条），
/// 有的挂在另一个宿主里，收起的一方只管发信号，各处的封面自己接住。
@MainActor
@Observable
final class NowPlayingCollapseSignal {
    static let shared = NowPlayingCollapseSignal()
    private(set) var revision: UInt = 0

    private init() {}

    func landed() {
        revision &+= 1
    }
}

/// 迷你条胶囊在窗口里的位置:播放页从它长出来、收起时缩回它。iOS 26.1 起胶囊是系统的
/// 底部附件,和播放页不在同一个 SwiftUI 宿主里,SwiftUI 的坐标空间对不上,只能用 UIKit
/// 视图换算到窗口坐标。几种外壳(系统附件、iPad、极简停靠条、旧系统)各挂一个探针,
/// 用的时候取当前挂在窗口上、看得见的那一个。
@MainActor
final class NowPlayingCapsuleGeometry {
    static let shared = NowPlayingCapsuleGeometry()

    private final class WeakView {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    private var probes: [WeakView] = []

    private init() {}

    fileprivate func register(_ view: UIView) {
        probes.removeAll { $0.view == nil }
        probes.append(WeakView(view))
    }

    /// 胶囊在窗口坐标里的外框;没有看得见的胶囊时为 nil。
    func frameInWindow() -> CGRect? {
        probes.removeAll { $0.view == nil }
        for probe in probes.reversed() {
            guard let view = probe.view, view.window != nil, Self.isVisible(view) else { continue }
            let frame = view.convert(view.bounds, to: nil)
            if frame.width > 40, frame.height > 20 { return frame }
        }
        return nil
    }

    private static func isVisible(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate.isHidden || candidate.alpha < 0.01 { return false }
            current = candidate.superview
        }
        return true
    }
}

/// 挂在迷你条外壳背后、不接收触摸的探针视图。
struct NowPlayingCapsuleProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        NowPlayingCapsuleGeometry.shared.register(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 迷你条封面接住收起的播放页时轻轻弹一下。减少动态效果时不弹。
private struct MiniPlayerLandingPop: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.keyframeAnimator(
            initialValue: 1.0,
            trigger: reduceMotion ? 0 : NowPlayingCollapseSignal.shared.revision
        ) { view, scale in
            view.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(0.84, duration: 0.08)
                SpringKeyframe(1.0, duration: 0.5, spring: .bouncy(duration: 0.42, extraBounce: 0.12))
            }
        }
    }
}

struct MiniPlayerSwipeContent: View {
    var onTap: () -> Void
    var artworkSize: CGFloat
    var artworkCornerRadius: CGFloat
    var artworkTrailingSpacing: CGFloat = 10
    var titleFont: Font
    var showsSubtitle = false
    var contentHeight: CGFloat = 44
    /// 极简停靠条：字底下一道进度线，电台这一行写「正在直播」。
    var showsProgress = false

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var feedbackOffset: CGFloat = 0
    @State private var directionHint: MiniPlayerSwipeAction?
    @State private var contentWidth: CGFloat = 0
    /// 长按菜单收起后保存还在进行(Apple Music 歌加进资料库),所以放在迷你条上,不放在菜单里。
    @State private var libraryActions = NowPlayingLibraryActions()

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if isSpokenWord, !SpokenWordPlayerText.isPodcastEpisode(player) {
                    // 书是竖的:同一块槽位里放 3:4 的书封。播客单集的封面是方的,走下面那一支,
                    // 和音乐一样占满槽位、圆角一致。
                    SpokenWordBookCover(
                        song: player.currentSong,
                        width: SpokenWordCoverLayout.width(forHeight: artworkSize),
                        cornerRadius: max(3, artworkCornerRadius * 0.6),
                        decodeSize: artworkSize * 2
                    )
                    .frame(width: artworkSize, height: artworkSize)
                    .modifier(MiniPlayerLandingPop())
                    .padding(.trailing, artworkTrailingSpacing)
                } else {
                    CachedArtworkView(
                        coverRef: player.currentSong?.coverArtFileName,
                        songID: player.currentSong?.id ?? "",
                        size: artworkSize,
                        cornerRadius: artworkCornerRadius,
                        sourceID: player.currentSong?.sourceID,
                        filePath: player.currentSong?.filePath,
                        fileFormat: player.currentSong?.fileFormat,
                        placeholderIcon: isSpokenWord ? "antenna.radiowaves.left.and.right" : "music.note",
                        revisionToken: player.coverRevision
                    )
                    .artworkCrossfade()
                    .modifier(MiniPlayerLandingPop())
                    .padding(.trailing, artworkTrailingSpacing)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(isSpokenWord ? SpokenWordPlayerText.bookTitle(player) : (player.currentSong?.title ?? ""))
                        .font(titleFont)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                        .contentTransition(.opacity)

                    if showsSubtitle, let error = player.lastPlaybackError {
                        // A song picked from a list can fail with the player
                        // closed; this line is the only place left to say why.
                        Text(verbatim: error)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.orange)
                            .contentTransition(.opacity)
                    } else if showsSubtitle, isDownloadingFromICloud {
                        Label("playback_icloud_downloading", systemImage: "icloud.and.arrow.down")
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    } else if isSpokenWord {
                        // 有声内容总带这一行:第几章、本章还剩多久。书名已经在上面了。
                        MiniPlayerSpokenWordSubtitle()
                    } else if showsProgress, player.isLiveRadio {
                        MiniPlayerLiveRadioSubtitle()
                    } else if showsSubtitle,
                       let song = player.currentSong,
                       let artist = library.artistDisplayName(for: song),
                       !artist.isEmpty {
                        Text(artist)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }

                    if showsProgress, !player.isLiveRadio {
                        MiniPlayerProgressLine()
                            .padding(.top, 5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .pmAnimation(.trackChange, value: player.currentSong?.id)
            }
            .offset(x: feedbackOffset)

            if let directionHint {
                Image(systemName: directionHint == .next ? "forward.fill" : "backward.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: directionHint == .next ? .trailing : .leading)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: contentHeight, maxHeight: contentHeight)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            contentWidth = width
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .simultaneousGesture(swipeGesture(containerWidth: contentWidth))
        // 长按:不点开播放页也能喜欢 / 不喜欢这首、去它的专辑或艺人、设睡眠定时。
        .contextMenu { MiniPlayerMenuItems(libraryActions: libraryActions) }
        .nowPlayingLibraryActionAlert(libraryActions)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
        .accessibilityAction(named: Text("a11y_previous_track")) {
            perform(.previous)
        }
        .accessibilityAction(named: Text("a11y_next_track")) {
            perform(.next)
        }
    }

    private var accessibilityLabel: String {
        var parts = [
            String(localized: "now_playing"),
            isSpokenWord ? SpokenWordPlayerText.bookTitle(player) : (player.currentSong?.title ?? "")
        ]
        if isSpokenWord, let part = SpokenWordPlayerText.partTitle(player) {
            parts.append(part)
        }
        if showsSubtitle, let error = player.lastPlaybackError {
            return (parts + [error]).filter { !$0.isEmpty }.joined(separator: ": ")
        }
        if showsSubtitle, isDownloadingFromICloud {
            parts.append(String(localized: "playback_icloud_downloading"))
            return parts.filter { !$0.isEmpty }.joined(separator: ": ")
        }
        if showsSubtitle,
           let song = player.currentSong,
           let artist = library.artistDisplayName(for: song),
           !artist.isEmpty {
            parts.append(artist)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ": ")
    }

    /// 书不滑动换条目;播客可以:队列里的下一集就是下一档要听的节目。
    private var allowsSwipe: Bool {
        player.currentListeningSpace == .podcast
            || player.currentListeningSpace?.playbackFamily != .spokenWord
    }

    private var isSpokenWord: Bool {
        player.currentItemIsSpokenWord && !player.isLiveRadio
    }

    private var isDownloadingFromICloud: Bool {
        player.currentSong.map { player.iCloudDownloadingSongID == $0.id } ?? false
    }

    private func swipeGesture(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: MiniPlayerSwipePolicy.minimumGestureDistance)
            .onChanged { value in
                // 有声书不滑动换条目:下一条是另一集甚至另一本,误触代价太大(播客除外)。
                guard allowsSwipe else { return }
                let sample = swipeSample(value, containerWidth: containerWidth)
                directionHint = MiniPlayerSwipePolicy.directionHint(for: sample)
                feedbackOffset = MiniPlayerSwipePolicy.feedbackOffset(
                    for: sample,
                    reduceMotion: reduceMotion
                )
            }
            .onEnded { value in
                guard allowsSwipe else { return }
                let action = MiniPlayerSwipePolicy.action(
                    for: swipeSample(value, containerWidth: containerWidth)
                )
                resetFeedback()
                if let action {
                    perform(action)
                }
            }
    }

    private func swipeSample(
        _ value: DragGesture.Value,
        containerWidth: CGFloat
    ) -> MiniPlayerSwipeSample {
        MiniPlayerSwipeSample(
            translationX: value.translation.width,
            translationY: value.translation.height,
            velocityX: value.velocity.width,
            velocityY: value.velocity.height,
            startX: value.startLocation.x,
            containerWidth: containerWidth,
            isRightToLeft: layoutDirection == .rightToLeft
        )
    }

    private func resetFeedback() {
        if reduceMotion {
            feedbackOffset = 0
            directionHint = nil
        } else {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                feedbackOffset = 0
                directionHint = nil
            }
        }
    }

    private func perform(_ action: MiniPlayerSwipeAction) {
        Task { @MainActor in
            let didAdvance = switch action {
            case .previous:
                await player.previous()
            case .next:
                await player.next()
            }
            if didAdvance {
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
    }
}

/// 迷你条的长按菜单。单独一个视图:菜单弹出时才读喜欢状态、找专辑和艺人,
/// 迷你条平时跟着播放器刷新不用顺带算这些。
private struct MiniPlayerMenuItems: View {
    let libraryActions: NowPlayingLibraryActions
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(\.openLibraryDestination) private var openLibraryDestination
    @Environment(\.presentSleepTimer) private var presentSleepTimer

    var body: some View {
        if let song = player.currentSong {
            Section {
                if !player.isLiveRadio {
                    Button { toggleLike(song) } label: {
                        if isLiked(song) {
                            Label(String(localized: "a11y_unlike"), systemImage: "heart.fill")
                        } else {
                            Label(String(localized: "a11y_like"), systemImage: "heart")
                        }
                    }
                    .disabled(libraryActions.isBusy)
                }
                if player.canDislikeCurrentSong {
                    // 不喜欢(#193):记下来并切到下一首;已经不喜欢时再点只撤销。
                    Button { player.toggleDislikeForCurrentSong() } label: {
                        if library.isDisliked(songID: song.id) {
                            Label(String(localized: "song_undislike"), systemImage: "hand.thumbsdown.fill")
                        } else {
                            Label(String(localized: "song_dislike"), systemImage: "hand.thumbsdown")
                        }
                    }
                }
            }

            if !player.currentItemIsSpokenWord, !player.isLiveRadio, let openLibraryDestination {
                Section {
                    ShowCurrentSongInLibraryButton()
                    if let album = library.linkedAlbum(for: song)
                        ?? AppServices.shared.appleMusicLibrary.catalogAlbum(forCatalogOnlySong: song) {
                        Button { openLibraryDestination(.album(album)) } label: {
                            Label(String(localized: "go_to_album"), systemImage: "square.stack")
                        }
                    }
                    if let artist = library.linkedArtists(for: song).first {
                        Button { openLibraryDestination(.artist(artist)) } label: {
                            Label(String(localized: "go_to_artist"), systemImage: "music.mic")
                        }
                    }
                }
            }

            Section {
                Menu {
                    // 和播放页的睡眠定时同一组选项:电台只有分钟数,有声多出本章、本集、整本。
                    ForEach(sleepOptions, id: \.self) { option in
                        Button { player.applySleepOption(option) } label: {
                            if player.isSleepOptionArmed(option) {
                                Label(sleepOptionTitle(option), systemImage: "checkmark")
                            } else {
                                Text(verbatim: sleepOptionTitle(option))
                            }
                        }
                    }
                    // 自定义时长、到几点停、计时结束播完这首,都在定时面板里。
                    if let presentSleepTimer {
                        Button { presentSleepTimer() } label: {
                            Label(String(localized: "sleep_timer_custom_menu"), systemImage: "slider.horizontal.3")
                        }
                    }
                    if player.isSleepTimerActive {
                        Button(String(localized: "cancel_timer"), role: .destructive) { player.cancelSleep() }
                    }
                } label: {
                    Label {
                        Text("sleep_timer")
                        if let summary = SleepTimerStatusText.summary(player) {
                            Text(verbatim: summary)
                        }
                    } icon: {
                        Image(systemName: player.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
                    }
                }
            }
        }
    }

    private var sleepOptions: [SleepTimerOption] {
        SleepTimerOptionPolicy.options(
            for: player.currentListeningSpace ?? .music,
            hasChapters: player.hasChapters
        )
    }

    private func sleepOptionTitle(_ option: SleepTimerOption) -> String {
        switch option {
        case .minutes(let minutes):
            "\(minutes) " + String(localized: "minutes")
        case .endOfTrack:
            player.currentListeningSpace?.playbackFamily == .spokenWord
                ? String(localized: "sleep_at_item_end")
                : String(localized: "sleep_at_track_end")
        case .endOfChapter:
            String(localized: "sleep_at_chapter_end")
        case .endOfBook:
            String(localized: "sleep_at_book_end")
        }
    }

    /// 和播放页的心形一样:播客单集记在播客自己的喜欢里,别的进「我喜欢」。
    /// 搜索里点播的 Apple Music 歌先加进资料库、同步进曲库,再标在那一行上。
    private func isLiked(_ song: Song) -> Bool {
        if PodcastPlaybackSong.isEpisode(song) { return PodcastStore.shared.isLiked(episodeID: song.id) }
        return NowPlayingLibraryActions.isLiked(song, library: library)
    }

    private func toggleLike(_ song: Song) {
        let desired = !isLiked(song)
        if PodcastPlaybackSong.isEpisode(song) {
            PMHaptics.likeToggled(isLiked: desired)
            player.toggleLikeForCurrentPodcastEpisode()
            return
        }
        let actions = libraryActions
        let library = library
        Task {
            if await actions.perform(.like(desired), song: song, library: library) {
                PMHaptics.likeToggled(isLiked: desired)
            }
        }
    }
}

/// 迷你条上有声内容的第二行:「第 12 章 · 本章还剩约 18 分钟」。单独一个视图,
/// 播放时钟的高频刷新只落在这一行上。
private struct MiniPlayerSpokenWordSubtitle: View {
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        let parts = [
            // 只要章号:整本书的进度摘要要把每一章过一遍,这一行却随时钟每半秒重画一次。
            SpokenWordPlayerText.partPosition(player.spokenWordPartPosition),
            SpokenWordPlayerText.partRemaining(player),
        ].compactMap { $0 }
        Text(verbatim: parts.joined(separator: " · "))
            .font(.caption2.monospacedDigit())
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .contentTransition(.opacity)
    }
}

/// 停靠条上电台的第二行:红点「正在直播」,电台推了曲目名就接在后面。
private struct MiniPlayerLiveRadioSubtitle: View {
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text("minimal_radio_on_air")
                .foregroundStyle(Color.accentColor)
            if let title = player.radioMetadataTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                Text(verbatim: "· " + title)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .contentTransition(.opacity)
    }
}

/// 停靠条字底下的进度线。单独一个视图:播放时钟每半秒走一次,只重画这一条。
private struct MiniPlayerProgressLine: View {
    @Environment(AudioPlayerService.self) private var player

    private var fraction: CGFloat {
        guard player.duration > 0 else { return 0 }
        return CGFloat(min(max(player.currentTime / player.duration, 0), 1))
    }

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(maxWidth: 220)
            .accessibilityHidden(true)
    }
}

/// 极简停靠条右边:一颗辅助键(音乐是播放队列、电台是下一个台、有声是后退)和实心圆的大播放键。
struct MinimalDockTransportControls: View {
    let onShowQueue: () -> Void
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.colorScheme) private var colorScheme

    /// 大播放键要实色：玻璃底会把层级色（primary）淡成灰，这里按深浅色直接给黑白。
    private var playFill: Color { colorScheme == .dark ? .white : .black }
    private var playGlyph: Color { colorScheme == .dark ? .black : .white }

    var body: some View {
        HStack(spacing: 2) {
            secondaryButton
            playButton
        }
        .fixedSize()
    }

    @ViewBuilder
    private var secondaryButton: some View {
        if player.currentItemIsSpokenWord, !player.isLiveRadio {
            Button {
                PMHaptics.transportTapped()
                player.skipSpokenWordBackward()
            } label: {
                icon(player.spokenWordSkipBackwardSymbol)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "a11y_skip_backward"))
        } else if player.isLiveRadio {
            if player.canSwitchRadioStation {
                Button {
                    PMHaptics.transportTapped()
                    Task { await player.next() }
                } label: {
                    icon("forward.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "radio_next_station"))
            }
        } else {
            Button(action: onShowQueue) {
                icon("list.bullet")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "queue_title"))
            .accessibilityIdentifier("minimal.dock.queue")
        }
    }

    private func icon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .contentTransition(.symbolEffect(.replace))
    }

    private var isActive: Bool {
        player.isPlaybackActive || player.isLoading
    }

    private var playButton: some View {
        Button {
            guard !(player.isLoading && !player.isLiveRadio) else { return }
            PMHaptics.transportTapped()
            player.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(playFill)
                if player.showsLoadingIndicator && !player.isLiveRadio {
                    ProgressView()
                        .controlSize(.small)
                        .tint(playGlyph)
                        .pmFadeTransition(motion: .control)
                } else {
                    Image(systemName: player.isLiveRadio && isActive
                        ? "stop.fill"
                        : (isActive ? "pause.fill" : "play.fill"))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(playGlyph)
                        .contentTransition(.symbolEffect(.replace))
                        .pmFadeTransition(motion: .control)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(player.showsLoadingIndicator && !player.isLiveRadio)
        .accessibilityLabel(player.isLiveRadio && isActive
            ? String(localized: "radio_stop")
            : (isActive ? String(localized: "a11y_pause") : String(localized: "a11y_play")))
        .accessibilityIdentifier("minimal.dock.play")
    }
}

struct MiniPlayerTransportControls: View {
    var isInline = false
    var showsNextButton: Bool
    var regularIconSize: CGFloat = 20
    @Environment(AudioPlayerService.self) private var player

    private var iconFont: Font {
        isInline ? .subheadline : .system(size: regularIconSize, weight: .semibold)
    }

    var body: some View {
        HStack(spacing: isInline ? 0 : 4) {
            // 有声内容在播放键前放「后退」:漏听一句往回倒是听书最常按的键。
            // 前进与下一条目都不放 —— 下一条目是另一集甚至另一本,迷你条上误触代价太大。
            if player.currentItemIsSpokenWord, !player.isLiveRadio {
                Button {
                    PMHaptics.transportTapped()
                    player.skipSpokenWordBackward()
                } label: {
                    Image(systemName: player.spokenWordSkipBackwardSymbol)
                        .font(iconFont)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(String(localized: "a11y_skip_backward"))
            }

            Button {
                guard !(player.isLoading && !player.isLiveRadio) else { return }
                PMHaptics.transportTapped()
                player.togglePlayPause()
            } label: {
                ZStack {
                    Image(systemName: "play.fill")
                        .font(iconFont)
                        .opacity(0)
                    if player.showsLoadingIndicator && !player.isLiveRadio {
                        ProgressView().controlSize(.small)
                            .pmFadeTransition(motion: .control)
                    } else {
                        Image(systemName: player.isLiveRadio && (player.isPlaybackActive || player.isLoading)
                            ? "stop.fill"
                            : (player.isPlaybackActive || player.isLoading ? "pause.fill" : "play.fill"))
                            .font(iconFont)
                            .contentTransition(.symbolEffect(.replace))
                            // ProgressView 与 Image 之间 symbolEffect 不生效, 这一跳只能走透明度。
                            .pmFadeTransition(motion: .control)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .disabled(player.showsLoadingIndicator && !player.isLiveRadio)
            .accessibilityLabel(player.isLiveRadio && (player.isPlaybackActive || player.isLoading)
                ? String(localized: "radio_stop")
                : (player.isPlaybackActive || player.isLoading
                    ? String(localized: "a11y_pause")
                    : String(localized: "a11y_play")))

            if player.currentItemIsSpokenWord, !player.isLiveRadio {
                EmptyView()
            } else if showsNextButton && (!player.isLiveRadio || player.canSwitchRadioStation) {
                Button {
                    PMHaptics.transportTapped()
                    Task { await player.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(iconFont)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(player.isLiveRadio
                    ? String(localized: "radio_next_station")
                    : String(localized: "a11y_next_track"))
            }
        }
        .fixedSize()
    }
}
#endif
