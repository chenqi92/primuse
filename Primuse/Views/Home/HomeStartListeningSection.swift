import SwiftUI
import PrimuseKit

/// 「开始听」横向卡片行:经典首页的区块、Mac 首页主卡下面、极简导航「歌曲」页顶上共用。
///
/// 第一张固定是「接着上次」(有能接着放的音乐队列时)或「随便听听」,然后是钉选的,
/// 其余按曲库点亮强度,最多十张,末尾「全部意图 ›」进整页。点卡片直接起播,
/// 长按可以下一首播放、加入队列、查看歌曲、钉选或隐藏。点亮在后台算好,这里只读结果。
struct StartListeningShelf: View {
    /// 标题与卡片行左右留多少。经典首页 20,Mac 首页由外层留白,所以给 0。
    var horizontalInset: CGFloat = 20
    var showsTitle = true
    /// Mac 首页的子页不走导航栈推页,由首页换成整页;nil 时用导航栈推。
    var onOpenAll: (() -> Void)? = nil
    var onOpenSongs: ((ListeningIntent) -> Void)? = nil

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsAllIntents = false
    @State private var songsIntent: ListeningIntent?
    /// 点下去到队列装好之间,那张卡片转个圈。
    @State private var startingIntentID: String?

    private var service: ListeningIntentService { .shared }

    var body: some View {
        let items = service.row(player: player)
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if showsTitle {
                        sectionTitle
                            .padding(.horizontal, horizontalInset)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(items) { item in
                                card(item)
                            }
                            allIntentsCard
                        }
                        .padding(.horizontal, horizontalInset)
                        .padding(.vertical, 2)
                    }
                    .scrollClipDisabled()
                }
                .transition(.opacity)
            } else if service.availability == nil, !library.musicSongs.isEmpty {
                placeholder
            }
        }
        .pmAnimation(.contentAppear, value: items.map(\.id))
        .task(id: library.searchRevision) {
            service.refresh(library: library)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { service.refresh(library: library) }
        }
        #if DEBUG
        .task { await openDebugPageIfRequested() }
        #endif
        .navigationDestination(isPresented: $showsAllIntents) {
            ListeningIntentsPage()
        }
        .navigationDestination(item: $songsIntent) { intent in
            ListeningIntentSongsView(intent: intent)
        }
    }

    /// 区块标题:手机、iPad 跟首页其它区块一样;Mac 跟 Mac 首页的区块标题一样。
    private var sectionTitle: some View {
        #if os(macOS)
        Text("home_section_start_listening")
            .font(.system(size: 17, weight: .semibold))
            .tracking(-0.3)
            .foregroundStyle(PMColor.text)
        #else
        Text("home_section_start_listening")
            .font(.title3.weight(.bold))
        #endif
    }

    private func card(_ item: ListeningIntentShelfItem) -> some View {
        let title = service.title(for: item.intent)
        let detail = ListeningIntentText.songCount(item.songCount)
        return Button {
            start(item.intent)
        } label: {
            ListeningIntentCard(
                title: title,
                symbolName: item.intent.symbolName,
                detail: detail,
                tint: item.intent.tint,
                badgeSymbol: item.isPinned ? "pin.fill" : nil,
                isWorking: startingIntentID == item.id
            )
        }
        .buttonStyle(.pmPressable)
        .contextMenu { menu(item) }
        .accessibilityLabel(Text(verbatim: "\(title), \(detail)"))
        .accessibilityIdentifier("home.startListening." + item.id)
    }

    private var allIntentsCard: some View {
        Button {
            if let onOpenAll { onOpenAll() } else { showsAllIntents = true }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    Text("listening_intent_all")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.primary)
            }
            .padding(10)
            .frame(width: ListeningIntentCard.size.width, height: ListeningIntentCard.size.height, alignment: .topLeading)
            .background(ListeningIntentCard.neutralSurface, in: RoundedRectangle(cornerRadius: ListeningIntentCard.cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: ListeningIntentCard.cornerRadius, style: .continuous))
        }
        .buttonStyle(.pmPressable)
        .accessibilityIdentifier("home.startListening.all")
    }

    @ViewBuilder
    private func menu(_ item: ListeningIntentShelfItem) -> some View {
        // 「接着上次」放的是之前那个队列,没有可抽的歌,也不能隐藏。
        if item.intent.habit != .resume {
            ListeningIntentMenuItems(
                item: item,
                showsArrangement: item.role != .lead,
                play: { start(item.intent) },
                showSongs: { openSongs(item.intent) }
            )
        }
    }

    private func openSongs(_ intent: ListeningIntent) {
        if let onOpenSongs { onOpenSongs(intent) } else { songsIntent = intent }
    }

    private func start(_ intent: ListeningIntent) {
        guard startingIntentID == nil else { return }
        startingIntentID = intent.id
        Task {
            await service.play(intent, player: player, library: library)
            startingIntentID = nil
        }
    }

    #if DEBUG
    @MainActor private static var didOpenDebugPage = false

    /// 截图钩子:`PRIMUSE_DEBUG_INTENTS=page` 打开「全部意图」,`songs:<内置意图 rawValue>` 打开它的「查看歌曲」。
    /// 等点亮算出来再开,只开一次。
    private func openDebugPageIfRequested() async {
        guard let request = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_INTENTS"],
              !Self.didOpenDebugPage else { return }
        for _ in 0..<60 where service.availability == nil {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
        }
        // 首页快照刷新会换掉这一块,被取消的那一份不算数,交给新出现的那一份去开。
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, !Self.didOpenDebugPage else { return }
        Self.didOpenDebugPage = true
        plog("🧪 Debug: open listening intents \(request)")
        if request == "page" {
            if let onOpenAll { onOpenAll() } else { showsAllIntents = true }
        } else if request.hasPrefix("songs:"),
                  let builtIn = BuiltInListeningIntent(rawValue: String(request.dropFirst("songs:".count))) {
            openSongs(.builtIn(builtIn))
        }
    }
    #endif

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsTitle {
                sectionTitle
                    .padding(.horizontal, horizontalInset)
                    .redacted(reason: .placeholder)
            }
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: ListeningIntentCard.cornerRadius, style: .continuous)
                        .fill(ListeningIntentCard.neutralSurface)
                        .frame(width: ListeningIntentCard.size.width, height: ListeningIntentCard.size.height)
                }
            }
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, 2)
        }
        .accessibilityHidden(true)
    }
}

/// 长按菜单:播放、下一首播放、加入队列、查看歌曲;非第一张还能钉选、挪位置、隐藏。
struct ListeningIntentMenuItems: View {
    let item: ListeningIntentShelfItem
    var showsArrangement = true
    /// 整页里钉选的那几张可以往前、往后挪。
    var showsMoveActions = false
    let play: () -> Void
    let showSongs: () -> Void

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player

    private var service: ListeningIntentService { .shared }

    var body: some View {
        if item.songCount > 0 {
            Button(action: play) {
                Label("play", systemImage: "play.fill")
            }
            Button {
                Task { await service.enqueue(item.intent, next: true, player: player, library: library) }
            } label: {
                Label("insert_next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                Task { await service.enqueue(item.intent, next: false, player: player, library: library) }
            } label: {
                Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            Button(action: showSongs) {
                Label("listening_intent_show_songs", systemImage: "music.note.list")
            }
        }
        if showsArrangement {
            Divider()
            Button {
                arrange { service.setPinned(!item.isPinned, intentID: item.id) }
            } label: {
                if item.isPinned {
                    Label("listening_intent_unpin", systemImage: "pin.slash")
                } else {
                    Label("listening_intent_pin", systemImage: "pin")
                }
            }
            if showsMoveActions, item.isPinned {
                Button {
                    arrange { service.movePinned(item.id, by: -1) }
                } label: {
                    Label("listening_intent_move_earlier", systemImage: "arrow.left")
                }
                Button {
                    arrange { service.movePinned(item.id, by: 1) }
                } label: {
                    Label("listening_intent_move_later", systemImage: "arrow.right")
                }
            }
            if item.isHidden {
                Button {
                    arrange { service.setHidden(false, intentID: item.id) }
                } label: {
                    Label("listening_intent_unhide", systemImage: "eye")
                }
            } else {
                Button(role: .destructive) {
                    arrange { service.setHidden(true, intentID: item.id) }
                } label: {
                    Label("listening_intent_hide", systemImage: "eye.slash")
                }
            }
        }
    }

    /// 钉选、隐藏、挪位置都会把这张卡片挪走或换掉。等长按菜单收起再动:菜单的宿主还在关闭时
    /// 被换掉,会留下野引用(1.9.7 的选择态崩溃就是这样)。
    private func arrange(_ change: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            pmWithAnimation(.list) { change() }
        }
    }
}

/// 一张意图卡片:左上图标,底部名字,右下小字曲数。
struct ListeningIntentCard: View {
    static let size = CGSize(width: 120, height: 88)
    static let cornerRadius: CGFloat = 14

    let title: String
    let symbolName: String
    let detail: String?
    let tint: Color
    var badgeSymbol: String? = nil
    var isWorking = false
    var isDimmed = false
    /// 整页网格里按列宽撑满;首页行里是固定的 120×88。
    var fillsWidth = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(height: 22)
                Spacer(minLength: 0)
                if isWorking {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else if let badgeSymbol {
                    Image(systemName: badgeSymbol)
                        .font(.caption2.weight(.semibold))
                        .opacity(0.9)
                }
            }
            Spacer(minLength: 4)
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(verbatim: detail)
                    .font(.caption2)
                    .monospacedDigit()
                    .opacity(0.85)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(
            width: fillsWidth ? nil : Self.size.width,
            height: Self.size.height,
            alignment: .topLeading
        )
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .topLeading)
        .background {
            // 黑底上叠主题色渐变:浅色、深色外观下都是同一种偏深的颜色,白字始终看得清。
            ZStack {
                Color.black
                LinearGradient(
                    colors: [tint, tint.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .opacity(isDimmed ? 0.42 : 1)
    }

    static var neutralSurface: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #elseif os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.gray.opacity(0.2)
        #endif
    }
}

/// 智能歌单的「钉为意图」/「从开始听移除」:钉上以后它就是「开始听」里的一张卡片。
struct SmartPlaylistIntentPinButton: View {
    let playlistID: String

    private var service: ListeningIntentService { .shared }

    var body: some View {
        let pinned = service.isSmartPlaylistPinned(playlistID)
        Button {
            pmWithAnimation(.list) { service.setSmartPlaylistPinned(!pinned, playlistID: playlistID) }
        } label: {
            if pinned {
                Label("listening_intent_unpin_smart_playlist", systemImage: "pin.slash")
            } else {
                Label("listening_intent_pin_smart_playlist", systemImage: "pin")
            }
        }
    }
}

private struct SongListShowsListeningIntentsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 歌曲页顶上要不要放「开始听」(极简导航的歌曲页)。
    var songListShowsListeningIntents: Bool {
        get { self[SongListShowsListeningIntentsKey.self] }
        set { self[SongListShowsListeningIntentsKey.self] = newValue }
    }
}

enum ListeningIntentText {
    static func songCount(_ count: Int) -> String {
        String(format: String(localized: "listening_intent_song_count %lld"), count)
    }
}

// MARK: - All intents

/// 「全部意图」整页:钉选的排最前(可拖动、可前后挪),其余按风格、年代、状态、习惯分组。
/// 曲库里不够的变暗,隐藏的带个标记,长按可以钉选、隐藏或重新显示。
struct ListeningIntentsPage: View {
    /// Mac 首页里整页替换时的返回;iOS 走导航栈,不传。
    var onBack: (() -> Void)? = nil
    var onOpenSongs: ((ListeningIntent) -> Void)? = nil

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @State private var songsIntent: ListeningIntent?
    @State private var startingIntentID: String?

    private var service: ListeningIntentService { .shared }

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                #if os(macOS)
                if let onBack { macHeader(onBack: onBack) }
                #endif
                ForEach(service.pageSections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(LocalizedStringKey(section.titleKey))
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(section.items) { item in
                                tile(item, inPinned: section.kind == .pinned)
                            }
                        }
                    }
                }
                Text("listening_intent_page_footer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .pmAnimation(.list, value: service.configuration)
        .task(id: library.searchRevision) {
            service.refresh(library: library)
        }
        #if os(iOS)
        .navigationTitle("listening_intent_page_title")
        .navigationBarTitleDisplayMode(.inline)
        .minimalNavigationDetail()
        #endif
        .navigationDestination(item: $songsIntent) { intent in
            ListeningIntentSongsView(intent: intent)
        }
    }

    private var horizontalPadding: CGFloat {
        #if os(macOS)
        PMSpace.xxxl
        #else
        20
        #endif
    }

    #if os(macOS)
    private func macHeader(onBack: @escaping () -> Void) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("home_section_start_listening")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(PMColor.textMuted)
                Text("listening_intent_page_title")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(PMColor.text)
            }
            Spacer(minLength: 16)
            MacNavigationBackButton(accessibilityIdentifier: "listeningIntents.back", action: onBack)
        }
        .padding(.top, 12)
    }
    #endif

    @ViewBuilder
    private func tile(_ item: ListeningIntentShelfItem, inPinned: Bool) -> some View {
        let title = service.title(for: item.intent)
        let detail = item.isLit || item.songCount > 0
            ? ListeningIntentText.songCount(item.songCount)
            : String(localized: "listening_intent_not_enough")
        let tile = Button {
            start(item)
        } label: {
            ListeningIntentCard(
                title: title,
                symbolName: item.intent.symbolName,
                detail: detail,
                tint: item.intent.tint,
                badgeSymbol: item.isHidden ? "eye.slash" : (item.isPinned ? "pin.fill" : nil),
                isWorking: startingIntentID == item.id,
                isDimmed: !item.isLit || item.isHidden,
                fillsWidth: true
            )
        }
        .buttonStyle(.pmPressable)
        .disabled(item.songCount == 0)
        .contextMenu {
            ListeningIntentMenuItems(
                item: item,
                showsMoveActions: inPinned,
                play: { start(item) },
                showSongs: { openSongs(item.intent) }
            )
        }
        .accessibilityLabel(Text(verbatim: "\(title), \(detail)"))
        .accessibilityIdentifier("listeningIntents." + item.id)

        if inPinned {
            // 钉选的可以拖到另一张钉选的上面换位置。
            tile
                // 拖动预览在独立宿主里渲染,给一张不读环境对象的卡片。
                .draggable(item.id) {
                    ListeningIntentCard(
                        title: title,
                        symbolName: item.intent.symbolName,
                        detail: detail,
                        tint: item.intent.tint
                    )
                }
                .dropDestination(for: String.self) { ids, _ in
                    guard let moved = ids.first, moved != item.id else { return false }
                    pmWithAnimation(.list) { service.movePinned(moved, onto: item.id) }
                    return true
                }
        } else {
            tile
        }
    }

    private func openSongs(_ intent: ListeningIntent) {
        if let onOpenSongs { onOpenSongs(intent) } else { songsIntent = intent }
    }

    private func start(_ item: ListeningIntentShelfItem) {
        guard startingIntentID == nil, item.songCount > 0 else { return }
        startingIntentID = item.id
        Task {
            await service.play(item.intent, player: player, library: library)
            startingIntentID = nil
        }
    }
}

// MARK: - Songs

/// 「查看歌曲」:这个意图在曲库里匹配到的歌,按曲库顺序,最多列一千首。只存 ID,
/// 行在懒加载栈里按需取歌,整库那么大的意图也不会一次登记全部行。
struct ListeningIntentSongsView: View {
    let intent: ListeningIntent
    var onBack: (() -> Void)? = nil

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @State private var songIDs: [String] = []
    @State private var total = 0
    @State private var isLoading = true

    private var service: ListeningIntentService { .shared }

    var body: some View {
        let ids = songIDs
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                #if os(macOS)
                if let onBack { macHeader(onBack: onBack) }
                #endif
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                } else if ids.isEmpty {
                    Text("listening_intent_songs_empty")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                } else {
                    Button {
                        Task { await service.play(intent, player: player, library: library) }
                    } label: {
                        Label("listening_intent_play_random", systemImage: "shuffle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    Divider().padding(.leading, 20)
                    ForEach(ids, id: \.self) { songID in
                        if let song = library.unobservedVisibleSong(id: songID) {
                            SongRowView(
                                song: song,
                                isPlaying: player.currentSong?.id == song.id,
                                context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
                            )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard let index = ids.firstIndex(of: songID) else { return }
                                Task { await player.play(queueIDs: ids, startingAt: index, playableOnly: false) }
                            }
                            Divider().padding(.leading, 66)
                        }
                    }
                    if total > ids.count {
                        Text(String(format: String(localized: "listening_intent_songs_partial %lld %lld"), ids.count, total))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .task(id: intent.id) {
            isLoading = true
            let result = await service.matchingSongIDs(for: intent, library: library)
            songIDs = result.ids
            total = result.total
            isLoading = false
        }
        #if os(iOS)
        .navigationTitle(service.title(for: intent))
        .navigationBarTitleDisplayMode(.inline)
        .minimalNavigationDetail()
        #endif
    }

    #if os(macOS)
    private func macHeader(onBack: @escaping () -> Void) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("listening_intent_page_title")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(PMColor.textMuted)
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    Text(verbatim: service.title(for: intent))
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(PMColor.text)
                    if total > 0 {
                        Text(verbatim: ListeningIntentText.songCount(total))
                            .font(.system(size: 12))
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
            }
            Spacer(minLength: 16)
            MacNavigationBackButton(accessibilityIdentifier: "listeningIntentSongs.back", action: onBack)
        }
        .padding(.horizontal, PMSpace.xxxl)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }
    #endif
}
