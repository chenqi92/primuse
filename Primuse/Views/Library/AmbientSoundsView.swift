import PrimuseKit
import SwiftUI

/// 环境音页(资料库的「环境音」分类、首页的「环境音」胶囊、iPad / Mac 侧栏)。
///
/// 白噪音、雨声、海浪这类声音不是「一首歌」,所以不排成歌曲列表:按专辑或目录分组,每段声音一张
/// 「声音卡」,点一下就循环着放。顶上一行快捷定时,选了就带着定时开播。
struct AmbientSoundsView: View {
    var body: some View {
        ScrollView {
            #if os(macOS)
            Text("listening_space_ambient")
                .font(.system(size: 32, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(PMColor.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PMSpace.xxxl)
                .padding(.top, 28)
                .padding(.bottom, 16)
            AmbientSoundBoard()
                .padding(.horizontal, PMSpace.xxxl)
                .padding(.bottom, 32)
            #else
            AmbientSoundBoard()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            #endif
        }
        #if os(macOS)
        .background(PMColor.bg.ignoresSafeArea())
        #endif
        #if os(iOS)
        .navigationTitle("listening_space_ambient")
        .navigationBarTitleDisplayMode(.inline)
        .minimalPageHeader {
            HStack(spacing: 4) {
                MinimalPageTitle("listening_space_ambient")
                Spacer(minLength: 8)
            }
        }
        #endif
    }
}

/// 环境音页的内容。首页筛到「环境音」时也直接摆它。
struct AmbientSoundBoard: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @AppStorage(AmbientQuickTimerRow.storageKey) private var quickTimerMinutes = 0
    @State private var playlistSong: Song?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 14)]

    var body: some View {
        let songs = library.ambientSongs
        let groups = AmbientSoundGrouping.groups(for: songs)
        let songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 22) {
            if MusicSessionMemoryStore.shared.memory != nil {
                AmbientBackToMusicButton()
            }
            if !songs.isEmpty {
                AmbientQuickTimerRow()
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    if groups.count > 1 || group.title != nil {
                        Text(verbatim: group.title ?? String(localized: "ambient_loose_group"))
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(group.songIDs, id: \.self) { songID in
                            if let song = songsByID[songID] {
                                card(song, queue: group.songIDs.compactMap { songsByID[$0] })
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            if songs.isEmpty {
                ContentUnavailableView(
                    "listening_space_ambient",
                    systemImage: ListeningSpace.ambient.systemImage,
                    description: Text("ambient_empty_hint")
                )
                .padding(.top, 40)
            }
        }
        .sheet(item: $playlistSong) { song in
            AddToPlaylistSheet(song: song)
        }
    }

    // MARK: 声音卡

    private func card(_ song: Song, queue: [Song]) -> some View {
        let isCurrent = player.currentSong?.id == song.id
        return Button {
            if isCurrent {
                player.togglePlayPause()
            } else {
                AmbientSoundPlayback.play(
                    song,
                    among: queue,
                    player: player,
                    timerMinutes: quickTimerMinutes > 0 ? quickTimerMinutes : nil
                )
            }
        } label: {
            AmbientSoundCard(song: song, isCurrent: isCurrent, isPlaying: isCurrent && player.isPlaying)
        }
        .buttonStyle(.plain)
        .loadsOfflineAudioSnapshot(for: song)
        .contextMenu {
            Button {
                if isCurrent {
                    player.togglePlayPause()
                } else {
                    AmbientSoundPlayback.play(song, among: queue, player: player, timerMinutes: nil)
                }
            } label: {
                if isCurrent && player.isPlaying {
                    Label("pause", systemImage: "pause.fill")
                } else {
                    Label("play", systemImage: "play.fill")
                }
            }
            Button {
                playlistSong = song
            } label: {
                Label("add_to_playlist", systemImage: "text.badge.plus")
            }
            Section {
                ListeningKindMoveButtons(current: .ambient) { kind in
                    SpokenWordStore.shared.move([song], to: kind)
                    library.refreshContentClassification()
                }
            }
            SongOfflineMenuSection(song: song)
        }
    }
}

/// 环境音页、Mac 播放页上那一行快捷定时:15 / 30 / 60 分钟、不限时。选了之后点卡开播时带着这个定时;
/// 正放着环境音时马上照它重新定时。放环境音时的睡眠定时面板顶上也是这一行,几处读写同一份选择。
struct AmbientQuickTimerRow: View {
    /// 选的是几分钟;0 是不限时。只存在本机。
    nonisolated static let storageKey = "primuse.ambient.quickTimerMinutes"

    /// 选过一颗之后(定时面板借它切回倒数的样子、Mac 的弹出面板借它收起)。
    var onChoose: (() -> Void)? = nil

    @Environment(AudioPlayerService.self) private var player
    @AppStorage(AmbientQuickTimerRow.storageKey) private var quickTimerMinutes = 0

    var body: some View {
        let highlighted = highlightedMinutes
        // 四颗一样宽、铺满一行:窄屏上也不必横着滑才看得到「不限时」,字长的语言自己缩一点。
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            ForEach(AmbientSoundPlaybackPolicy.quickTimerMinutes, id: \.self) { minutes in
                chip(minutes, isSelected: highlighted == (minutes ?? AmbientQuickTimerSelection.unlimitedMinutes))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("sleep_timer"))
    }

    /// 亮哪一颗:记下的选择;正放环境音、倒数的又不是这一档时哪颗都不亮。
    private var highlightedMinutes: Int? {
        var runningLength: TimeInterval?
        if player.currentItemIsAmbient,
           let end = player.sleepTimerEndDate,
           let start = player.sleepTimerStartDate {
            runningLength = end.timeIntervalSince(start)
        }
        return AmbientQuickTimerSelection.highlightedMinutes(
            storedMinutes: quickTimerMinutes,
            runningTimerLength: runningLength
        )
    }

    private func chip(_ minutes: Int?, isSelected: Bool) -> some View {
        let value = minutes ?? AmbientQuickTimerSelection.unlimitedMinutes
        let title = minutes.map { String(format: String(localized: "minutes_value_format"), $0) }
            ?? String(localized: "ambient_timer_unlimited")
        let tint = ListeningSpace.ambient.tint
        return Button {
            quickTimerMinutes = value
            if player.currentItemIsAmbient {
                if let minutes {
                    player.scheduleSleep(minutes: minutes)
                } else if player.isSleepTimerActive {
                    player.cancelSleep()
                }
            }
            onChoose?()
        } label: {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isSelected ? Color.white : tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(
                    Capsule().fill(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)))
                )
                .contentShape(Capsule())
                .animation(PMMotion.selection.animation, value: isSelected)
        }
        .buttonStyle(.pmPressable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 一段环境音的卡片:封面做底,压上环境音的颜色和声音名。正在放的那张一圈柔光在呼吸。
struct AmbientSoundCard: View {
    let song: Song
    let isCurrent: Bool
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cornerRadius: CGFloat = 22

    var body: some View {
        let tint = ListeningSpace.ambient.tint
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .background {
                // 没有封面的声音画自己的图案(雨、海浪、风扇…各有图标和颜色),有封面时封面盖在上面。
                AmbientSoundArtwork(song: song)
            }
            .overlay {
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 240,
                    cornerRadius: 0,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat,
                    showsPlaceholder: false,
                    fillsProposedSize: true
                )
            }
            .overlay {
                // 只压暗下半截托住字,不给封面整块染色。
                LinearGradient(stops: [
                    .init(color: .black.opacity(0), location: 0.42),
                    .init(color: .black.opacity(0.2), location: 0.66),
                    .init(color: .black.opacity(0.58), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                Text(song.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                    .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                if isCurrent {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(.black.opacity(0.28), in: Circle())
                        .padding(10)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(shape)
            .overlay {
                if isCurrent {
                    AmbientBreathingOutline(
                        shape: shape,
                        tint: tint,
                        isAnimating: isPlaying && !reduceMotion
                    )
                }
            }
            .contentShape(shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: song.title))
            .accessibilityValue(accessibilityState)
            .accessibilityAddTraits(.isButton)
    }
}

extension AmbientSoundCard {
    private var accessibilityState: Text {
        guard isCurrent else { return Text(verbatim: "") }
        return isPlaying ? Text("a11y_play") : Text("a11y_pause")
    }
}

/// 正在放的那张卡外面那一圈:放着时慢慢一明一暗,像呼吸;暂停或减少动态效果时停在中间那一档。
private struct AmbientBreathingOutline<S: InsettableShape>: View {
    let shape: S
    let tint: Color
    let isAnimating: Bool

    var body: some View {
        if isAnimating {
            outline(phase: 0.5)
                .phaseAnimator([0.0, 1.0]) { content, phase in
                    content
                        .opacity(0.45 + phase * 0.55)
                        .scaleEffect(1 + phase * 0.012)
                } animation: { _ in
                    .easeInOut(duration: 2.8)
                }
        } else {
            outline(phase: 0.5).opacity(0.7)
        }
    }

    private func outline(phase: Double) -> some View {
        shape
            .strokeBorder(tint, lineWidth: 2.5)
            .shadow(color: tint.opacity(0.55), radius: 10)
            .allowsHitTesting(false)
    }
}

/// 「回到音乐」:离开音乐来听环境音时记下的那份音乐队列,点一下从停下的地方接着放。
struct AmbientBackToMusicButton: View {
    @Environment(AudioPlayerService.self) private var player
    /// nil 时用音乐的颜色(主题色)。
    var tint: Color? = nil

    var body: some View {
        let color = tint ?? ListeningSpace.music.tint
        if let memory = MusicSessionMemoryStore.shared.memory {
            Button {
                Task { await player.resumeMusicSession() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .font(.subheadline.weight(.semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("ambient_back_to_music")
                            .font(.subheadline.weight(.semibold))
                        Text(verbatim: memory.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(color)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ambient.backToMusic")
        }
    }
}

/// 放一段环境音:同一组的几段一起进队列(锁屏、车机上能换着听),从点的这一段开始。
/// 单曲循环、不随机由 `ListeningPlayModeLedger` 在装队列时设好,音乐的设置挂起、回到音乐时还回去。
@MainActor
enum AmbientSoundPlayback {
    static func play(_ song: Song, among queue: [Song], player: AudioPlayerService, timerMinutes: Int?) {
        let songs = queue.contains(where: { $0.id == song.id }) ? queue : [song]
        let index = songs.firstIndex(where: { $0.id == song.id }) ?? 0
        Task {
            await player.play(queue: songs, startingAt: index)
            if let timerMinutes, timerMinutes > 0 {
                player.scheduleSleep(minutes: timerMinutes)
            }
        }
    }
}

/// 一段声音没有封面时的图案:按声音名挑的渐变底(`AmbientSoundMotif`),一角几圈淡淡的涟漪,中间是图标。
/// 声音卡、环境音播放页、搜索结果共用,同一段声音在哪儿都是同一个样子。
struct AmbientSoundArtwork: View {
    let song: Song
    /// 图标占边长的比例。
    var symbolScale: CGFloat = 0.28
    var showsRipples = true

    var body: some View {
        let motif = AmbientSoundMotif.motif(
            title: song.title, album: song.albumTitle, genre: song.genre, seed: song.id
        )
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                LinearGradient(
                    colors: [motif.topColor, motif.bottomColor],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [.white.opacity(0.22), .clear],
                    center: UnitPoint(x: 0.3, y: 0.22),
                    startRadius: 0,
                    endRadius: side * 0.7
                )
                if showsRipples {
                    ForEach(0..<3, id: \.self) { ring in
                        Circle()
                            .strokeBorder(.white.opacity(0.14 - Double(ring) * 0.04), lineWidth: max(side * 0.006, 0.75))
                            .frame(width: side * (0.5 + 0.32 * CGFloat(ring)), height: side * (0.5 + 0.32 * CGFloat(ring)))
                            .position(x: geometry.size.width * 0.82, y: geometry.size.height * 0.18)
                    }
                }
                Image(systemName: motif.symbol)
                    .font(.system(size: max(side * symbolScale, 12), weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.18), radius: side * 0.04, y: side * 0.015)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.44)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
    }
}

extension AmbientSoundMotif {
    /// 渐变上端的颜色(环境音播放页的光环也用它)。
    var topColor: Color { Self.color(colors.top) }
    var bottomColor: Color { Self.color(colors.bottom) }

    private static func color(_ hex: UInt32) -> Color {
        let rgb = ListeningSpaceTint.components(hex)
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

/// 搜索结果里环境音那一组的一行。
struct AmbientSoundSearchRow: View {
    let song: Song
    let isCurrent: Bool
    var compact = false

    var body: some View {
        let side: CGFloat = compact ? 36 : 44
        HStack(spacing: 12) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: side,
                cornerRadius: compact ? 6 : 8,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat,
                showsPlaceholder: false
            )
            .frame(width: side, height: side)
            .background {
                AmbientSoundArtwork(song: song, symbolScale: 0.42, showsRipples: false)
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(compact ? .system(size: 13, weight: .medium) : .subheadline)
                    .foregroundStyle(isCurrent ? ListeningSpace.ambient.tint : .primary)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: ListeningSpace.ambient.systemImage)
                .font(.caption)
                .foregroundStyle(ListeningSpace.ambient.tint)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if let album = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty { return album }
        return String(localized: "listening_space_ambient")
    }
}

extension ListeningSpaceSearchPolicy.AmbientCandidate {
    init(song: Song) {
        let folder = song.filePath.split(separator: "/").dropLast().last.map(String.init)
        self.init(
            id: song.id,
            title: song.title,
            album: song.albumTitle,
            artist: song.artistName,
            genre: song.genre,
            folder: folder
        )
    }
}
