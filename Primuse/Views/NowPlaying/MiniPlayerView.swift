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

struct MiniPlayerSwipeContent: View {
    var onTap: () -> Void
    var artworkSize: CGFloat
    var artworkCornerRadius: CGFloat
    var artworkTrailingSpacing: CGFloat = 10
    var titleFont: Font
    var showsSubtitle = false
    var contentHeight: CGFloat = 44

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var feedbackOffset: CGFloat = 0
    @State private var directionHint: MiniPlayerSwipeAction?
    @State private var contentWidth: CGFloat = 0

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
        .contextMenu { MiniPlayerMenuItems() }
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
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(\.openLibraryDestination) private var openLibraryDestination

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
                    if let album = library.linkedAlbum(for: song) {
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
                    if player.isSleepTimerActive {
                        Button(String(localized: "cancel_timer"), role: .destructive) { player.cancelSleep() }
                    }
                } label: {
                    Label(
                        String(localized: "sleep_timer"),
                        systemImage: player.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz"
                    )
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
    private func isLiked(_ song: Song) -> Bool {
        if PodcastPlaybackSong.isEpisode(song) { return PodcastStore.shared.isLiked(episodeID: song.id) }
        return library.isLiked(songID: song.id)
    }

    private func toggleLike(_ song: Song) {
        if PodcastPlaybackSong.isEpisode(song) {
            player.toggleLikeForCurrentPodcastEpisode()
        } else {
            library.toggleLiked(songID: song.id)
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
