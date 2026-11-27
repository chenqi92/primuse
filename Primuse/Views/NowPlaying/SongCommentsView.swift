import PrimuseKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - 会话状态

/// 单曲评论列表会话状态：管理排序、多源切换、分页、本地过滤与加载状态。
@MainActor
@Observable
final class SongCommentsSession {

    var sort: SongCommentSort = .hot
    /// `nil` 表示按配置顺序自动回退；非空表示用户手动锁定某一个评论服务。
    var selectedServerID: String?
    private(set) var phase: Phase = .idle
    private(set) var activeServer: CommentAPIServer?
    private(set) var totalCount: Int?
    private(set) var hotComments: [SongCommentItem] = []
    private(set) var comments: [SongCommentItem] = []
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    private(set) var loadMoreError: String?
    private(set) var toastMessage: String?

    @ObservationIgnored private let service: SongCommentService
    @ObservationIgnored private var nextPage = 2
    @ObservationIgnored private var nextCursor: String?
    @ObservationIgnored private var loadedRequestSignature: RequestSignature?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var loadMoreTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(service: SongCommentService = .shared) {
        self.service = service
    }
}

extension SongCommentsSession {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case failed(String)
    }

    private struct RequestSignature: Equatable {
        let songID: String
        let serverID: String?
        let sort: SongCommentSort
        let storeRevision: UInt
    }

    /// 供界面渲染的「精彩热评」与「全部评论」（实时应用本地隐藏与屏蔽规则）。
    func visibleSections(using moderation: SongCommentModerationStore) -> (hot: [SongCommentItem], regular: [SongCommentItem]) {
        let filteredHot = moderation.filter(hotComments)
        let filteredRegular = moderation.filter(comments)
        if sort == .hot {
            if !filteredHot.isEmpty {
                let hotIDs = Set(filteredHot.map(\.id))
                let deduped = filteredRegular.filter { !hotIDs.contains($0.id) }
                return (filteredHot, deduped)
            }
            return ([], filteredRegular)
        } else {
            if !filteredRegular.isEmpty {
                return ([], filteredRegular)
            }
            return ([], filteredHot)
        }
    }

    func cancel() {
        fetchTask?.cancel()
        fetchTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) {
                self?.toastMessage = nil
            }
        }
    }

    /// 加载或刷新第一页评论。相同签名且非强制刷新时不重复请求。
    func load(
        query: SongCommentQuery?,
        store: CommentAPIServerStore,
        forceRefresh: Bool = false
    ) {
        guard let query else {
            cancel()
            resetContent(phase: .empty)
            loadedRequestSignature = nil
            return
        }
        let enabledServers = store.enabledServers
        guard !enabledServers.isEmpty else {
            cancel()
            resetContent(phase: .failed(String(localized: "comments_server_none")))
            loadedRequestSignature = nil
            return
        }
        if let selectedServerID, !enabledServers.contains(where: { $0.id == selectedServerID }) {
            self.selectedServerID = nil
        }

        let signature = RequestSignature(
            songID: query.songID,
            serverID: selectedServerID,
            sort: sort,
            storeRevision: store.revision
        )
        if !forceRefresh, signature == loadedRequestSignature, phase == .loaded || phase == .empty {
            return
        }

        fetchTask?.cancel()
        loadMoreTask?.cancel()
        isLoadingMore = false
        loadMoreError = nil

        let isSameSongSwitch = loadedRequestSignature?.songID == query.songID
        if !isSameSongSwitch || (hotComments.isEmpty && comments.isEmpty) {
            phase = .loading
            hotComments = []
            comments = []
            totalCount = nil
            hasMore = false
        } else {
            phase = .loading
        }

        let requestedSort = sort
        let preferredID = selectedServerID
        let targetService = service
        fetchTask = Task { [weak self] in
            do {
                let result = try await targetService.fetchFirstPage(
                    query: query,
                    servers: enabledServers,
                    preferredServerID: preferredID,
                    sort: requestedSort,
                    forceRefresh: forceRefresh
                )
                guard !Task.isCancelled, let self else { return }
                self.loadedRequestSignature = signature
                if let result {
                    self.activeServer = result.server
                    self.totalCount = result.page.total
                    self.hotComments = result.page.hotComments
                    self.comments = result.page.comments
                    self.hasMore = result.page.hasMore
                    self.nextCursor = result.page.nextCursor
                    self.nextPage = 2
                    self.phase = result.page.isEmpty ? .empty : .loaded
                } else {
                    self.activeServer = enabledServers.first(where: { $0.id == preferredID }) ?? enabledServers.first
                    self.totalCount = 0
                    self.hotComments = []
                    self.comments = []
                    self.hasMore = false
                    self.nextCursor = nil
                    self.nextPage = 2
                    self.phase = .empty
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.loadedRequestSignature = nil
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func loadMore(query: SongCommentQuery?) {
        guard hasMore, !isLoadingMore, let query, let server = activeServer else { return }
        isLoadingMore = true
        loadMoreError = nil
        let targetPage = nextPage
        let cursor = nextCursor
        let requestedSort = sort

        let targetService = service
        loadMoreTask?.cancel()
        loadMoreTask = Task { [weak self] in
            do {
                let page = try await targetService.fetchNextPage(
                    server: server,
                    query: query,
                    sort: requestedSort,
                    page: targetPage,
                    cursor: cursor
                )
                guard !Task.isCancelled, let self else { return }
                let existingIDs = Set(self.comments.map(\.id)).union(self.hotComments.map(\.id))
                let appended = page.comments.filter { !existingIDs.contains($0.id) }
                self.comments.append(contentsOf: appended)
                if let total = page.total { self.totalCount = total }
                self.nextCursor = page.nextCursor
                self.nextPage = targetPage + 1
                self.hasMore = page.hasMore && !appended.isEmpty
                self.isLoadingMore = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isLoadingMore = false
                self.loadMoreError = error.localizedDescription
            }
        }
    }

    private func resetContent(phase: Phase) {
        self.phase = phase
        activeServer = nil
        totalCount = nil
        hotComments = []
        comments = []
        hasMore = false
        isLoadingMore = false
        loadMoreError = nil
        nextPage = 2
        nextCursor = nil
    }
}

// MARK: - 底部弹框 / Mac 面板入口

/// 音乐播放页点「查看评论」弹出的底部弹框（iOS 半屏/全屏可拖拽 Sheet；macOS 独立样式弹窗）。
struct SongCommentsSheet: View {
    let song: Song?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var session: SongCommentsSession
    @State private var serverStore: CommentAPIServerStore
    @State private var moderationStore: SongCommentModerationStore

    init(
        song: Song?,
        service: SongCommentService = .shared,
        serverStore: CommentAPIServerStore = .shared,
        moderationStore: SongCommentModerationStore = .shared
    ) {
        self.song = song
        _session = State(initialValue: SongCommentsSession(service: service))
        _serverStore = State(initialValue: serverStore)
        _moderationStore = State(initialValue: moderationStore)
    }

    private var query: SongCommentQuery? {
        song.map(SongCommentQuery.init(song:))
    }

    var body: some View {
        #if os(macOS)
        macSheetBody
        #else
        iosSheetBody
        #endif
    }

    #if !os(macOS)
    private var iosSheetBody: some View {
        VStack(spacing: 0) {
            sheetSongHeader
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)

            SongCommentsToolbarBar(
                session: session,
                servers: serverStore.enabledServers,
                appearance: nil,
                onSelectSort: { sort in
                    session.sort = sort
                    session.load(query: query, store: serverStore)
                },
                onSelectServer: { serverID in
                    session.selectedServerID = serverID
                    session.load(query: query, store: serverStore, forceRefresh: true)
                }
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            Divider()
                .opacity(0.45)

            SongCommentsStreamBody(
                song: song,
                query: query,
                session: session,
                serverStore: serverStore,
                moderationStore: moderationStore,
                appearance: nil,
                isCarousel: false
            )
        }
        .overlay(alignment: .bottom) {
            if let toast = session.toastMessage {
                SongCommentsToastPill(message: toast)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: loadTaskKey) {
            session.load(query: query, store: serverStore)
        }
        .onDisappear { session.cancel() }
    }

    private var sheetSongHeader: some View {
        HStack(spacing: 12) {
            if let song {
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 40,
                    cornerRadius: 9,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("comments_title")
                        .font(.headline.weight(.semibold))
                    if let count = displayHeaderCount {
                        Text(verbatim: count)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.primary.opacity(0.08), in: Capsule())
                    }
                }
                if let song {
                    Text(verbatim: songSubtitle(song))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle().inset(by: -6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("close"))
        }
    }
    #endif

    #if os(macOS)
    private var macSheetBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let song {
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        size: 38,
                        cornerRadius: 8,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat
                    )
                    .frame(width: 38, height: 38)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("comments_title")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(PMColor.text)
                        if let count = displayHeaderCount {
                            Text(verbatim: count)
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(PMColor.textMuted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(PMColor.bgElev, in: Capsule())
                        }
                    }
                    if let song {
                        Text(verbatim: songSubtitle(song))
                            .font(.system(size: 12))
                            .foregroundStyle(PMColor.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    session.load(query: query, store: serverStore, forceRefresh: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 28, height: 28)
                        .background(PMColor.bgElev, in: Circle())
                }
                .buttonStyle(.plain)
                .help(Text("comments_refresh"))
                .disabled(session.phase == .loading)

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 26, height: 26)
                        .background(PMColor.bgElev, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(Text("close"))
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            SongCommentsToolbarBar(
                session: session,
                servers: serverStore.enabledServers,
                appearance: nil,
                onSelectSort: { sort in
                    session.sort = sort
                    session.load(query: query, store: serverStore)
                },
                onSelectServer: { serverID in
                    session.selectedServerID = serverID
                    session.load(query: query, store: serverStore, forceRefresh: true)
                }
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            SongCommentsStreamBody(
                song: song,
                query: query,
                session: session,
                serverStore: serverStore,
                moderationStore: moderationStore,
                appearance: nil,
                isCarousel: false
            )
        }
        .overlay(alignment: .bottom) {
            if let toast = session.toastMessage {
                SongCommentsToastPill(message: toast)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 540, idealHeight: 640)
        .background(PMColor.bg)
        .task(id: loadTaskKey) {
            session.load(query: query, store: serverStore)
        }
        .onDisappear { session.cancel() }
    }
    #endif

    private var loadTaskKey: String {
        "\(song?.id ?? "")|\(serverStore.revision)"
    }

    private var displayHeaderCount: String? {
        guard let total = session.totalCount, total > 0 else { return nil }
        return CommentAPIServerPolicy.compactLikeCount(total)
    }

    private func songSubtitle(_ song: Song) -> String {
        if let artist = song.artistName, !artist.isEmpty {
            return "\(song.title) · \(artist)"
        }
        return song.title
    }
}

// MARK: - iOS 播放页转轮「评论」面

#if os(iOS)
/// 转轮的「评论」一面：与底部弹框共享同一套评论会话与卡片排版，融入转轮玻璃底与 120Hz 手势防误触。
/// 停稳（`context.isSettled`）才发起网络请求，滑动预览期间保持轻盈零掉帧。
struct NowPlayingCarouselCommentsFace: View {
    let context: NowPlayingCarouselFaceContext
    let appearance: NowPlayingAppearance
    let songOverride: Song?

    @Environment(AudioPlayerService.self) private var player
    @State private var session: SongCommentsSession
    @State private var serverStore: CommentAPIServerStore
    @State private var moderationStore: SongCommentModerationStore

    init(
        context: NowPlayingCarouselFaceContext,
        appearance: NowPlayingAppearance,
        songOverride: Song? = nil,
        service: SongCommentService = .shared,
        serverStore: CommentAPIServerStore = .shared,
        moderationStore: SongCommentModerationStore = .shared
    ) {
        self.context = context
        self.appearance = appearance
        self.songOverride = songOverride
        _session = State(initialValue: SongCommentsSession(service: service))
        _serverStore = State(initialValue: serverStore)
        _moderationStore = State(initialValue: moderationStore)
    }

    private var currentSong: Song? { songOverride ?? player.currentSong }
    private var query: SongCommentQuery? { currentSong.map(SongCommentQuery.init(song:)) }

    var body: some View {
        if currentSong == nil {
            NowPlayingCarouselEmptyNote(
                symbol: "bubble.left.and.text.bubble.right",
                title: "player_carousel_nothing_playing",
                message: nil,
                appearance: appearance
            )
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    SongCommentsToolbarBar(
                        session: session,
                        servers: serverStore.enabledServers,
                        appearance: appearance,
                        onSelectSort: { sort in
                            session.sort = sort
                            session.load(query: query, store: serverStore)
                        },
                        onSelectServer: { serverID in
                            session.selectedServerID = serverID
                            session.load(query: query, store: serverStore, forceRefresh: true)
                        }
                    )

                    if let total = session.totalCount, total > 0 {
                        Text(verbatim: CommentAPIServerPolicy.compactLikeCount(total))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(appearance.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(appearance.primary.opacity(0.10), in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                SongCommentsStreamBody(
                    song: currentSong,
                    query: query,
                    session: session,
                    serverStore: serverStore,
                    moderationStore: moderationStore,
                    appearance: appearance,
                    isCarousel: true
                )
            }
            .overlay(alignment: .bottom) {
                if let toast = session.toastMessage {
                    SongCommentsToastPill(message: toast)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .task(id: "\(currentSong?.id ?? "")|\(context.isSettled)|\(serverStore.revision)") {
                guard context.isSettled else { return }
                session.load(query: query, store: serverStore)
            }
            .onDisappear { session.cancel() }
        }
    }
}
#endif

// MARK: - 排序栏与多源切换

private struct SongCommentsToolbarBar: View {
    let session: SongCommentsSession
    let servers: [CommentAPIServer]
    let appearance: NowPlayingAppearance?
    let onSelectSort: (SongCommentSort) -> Void
    let onSelectServer: (String?) -> Void

    @Namespace private var sortPillNamespace
    @Environment(\.nowPlayingCarouselTapGuard) private var tapGuard

    private var primaryColor: Color {
        appearance?.primary ?? .primary
    }

    private var secondaryColor: Color {
        appearance?.secondary ?? .secondary
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(SongCommentSort.allCases) { option in
                    let selected = session.sort == option
                    Button {
                        tapGuard.perform {
                            guard session.sort != option else { return }
                            withAnimation(.snappy(duration: 0.24)) {
                                onSelectSort(option)
                            }
                        }
                    } label: {
                        Text(option == .hot ? LocalizedStringKey("comments_sort_hot") : LocalizedStringKey("comments_sort_latest"))
                            .font(.subheadline.weight(selected ? .semibold : .medium))
                            .foregroundStyle(selected ? primaryColor : secondaryColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background {
                                if selected {
                                    Capsule()
                                        .fill(primaryColor.opacity(appearance == nil ? 0.12 : 0.18))
                                        .matchedGeometryEffect(id: "sortPill", in: sortPillNamespace)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(primaryColor.opacity(appearance == nil ? 0.06 : 0.09), in: Capsule())

            Spacer(minLength: 4)

            if servers.count > 1 {
                Menu {
                    Button {
                        onSelectServer(nil)
                    } label: {
                        if session.selectedServerID == nil {
                            Label("comments_source_auto", systemImage: "checkmark")
                        } else {
                            Text("comments_source_auto")
                        }
                    }
                    Divider()
                    ForEach(servers) { server in
                        Button {
                            onSelectServer(server.id)
                        } label: {
                            if session.selectedServerID == server.id {
                                Label(server.displayTitle, systemImage: "checkmark")
                            } else {
                                Text(verbatim: server.displayTitle)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "server.rack")
                            .font(.caption2.weight(.semibold))
                        Text(verbatim: activeServerChipLabel)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(secondaryColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(primaryColor.opacity(appearance == nil ? 0.07 : 0.11), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .nowPlayingCarouselHorizontalRegion()
    }

    private var activeServerChipLabel: String {
        if let selectedID = session.selectedServerID,
           let matched = servers.first(where: { $0.id == selectedID }) {
            return matched.displayTitle
        }
        if let active = session.activeServer {
            return active.displayTitle
        }
        return String(localized: "comments_source_auto")
    }
}

// MARK: - 评论内容流

private struct SongCommentsStreamBody: View {
    let song: Song?
    let query: SongCommentQuery?
    let session: SongCommentsSession
    let serverStore: CommentAPIServerStore
    let moderationStore: SongCommentModerationStore
    let appearance: NowPlayingAppearance?
    let isCarousel: Bool

    @Environment(\.nowPlayingCarouselTapGuard) private var tapGuard

    private var primaryColor: Color { appearance?.primary ?? .primary }
    private var secondaryColor: Color { appearance?.secondary ?? .secondary }
    private var tertiaryColor: Color { appearance?.tertiary ?? Color.secondary.opacity(0.72) }

    var body: some View {
        let sections = session.visibleSections(using: moderationStore)
        let hasVisibleItems = !sections.hot.isEmpty || !sections.regular.isEmpty

        Group {
            switch session.phase {
            case .idle where !hasVisibleItems, .loading where !hasVisibleItems:
                SongCommentSkeletonList(appearance: appearance, isCarousel: isCarousel)
            case .failed(let message) where !hasVisibleItems:
                stateView(
                    symbol: "exclamationmark.bubble",
                    title: LocalizedStringKey("comments_load_failed"),
                    detail: message,
                    actionTitle: LocalizedStringKey("comments_retry")
                ) {
                    session.load(query: query, store: serverStore, forceRefresh: true)
                }
            case .empty where !hasVisibleItems, .loaded where !hasVisibleItems:
                stateView(
                    symbol: "bubble.left.and.text.bubble.right",
                    title: LocalizedStringKey("comments_empty_title"),
                    detail: nil,
                    actionTitle: LocalizedStringKey("comments_refresh")
                ) {
                    session.load(query: query, store: serverStore, forceRefresh: true)
                }
            default:
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: isCarousel ? 10 : 0) {
                        if !sections.hot.isEmpty {
                            sectionHeader(
                                title: LocalizedStringKey("comments_section_hot"),
                                symbol: "flame.fill",
                                accent: Color.orange
                            )
                            ForEach(sections.hot) { item in
                                commentRow(item, showsDivider: !isCarousel)
                            }
                        }

                        if !sections.regular.isEmpty {
                            if !sections.hot.isEmpty {
                                sectionHeader(
                                    title: LocalizedStringKey("comments_section_all"),
                                    symbol: "text.bubble",
                                    accent: secondaryColor
                                )
                                .padding(.top, isCarousel ? 8 : 6)
                            }
                            ForEach(Array(sections.regular.enumerated()), id: \.element.id) { index, item in
                                commentRow(item, showsDivider: !isCarousel && index < sections.regular.count - 1)
                                    .onAppear {
                                        if index >= sections.regular.count - 3 {
                                            session.loadMore(query: query)
                                        }
                                    }
                            }
                        }

                        paginationFooter
                    }
                    .padding(.horizontal, isCarousel ? 14 : 0)
                    .padding(.top, isCarousel ? 2 : 4)
                    .padding(.bottom, 28)
                }
                #if os(iOS)
                .refreshable {
                    session.load(query: query, store: serverStore, forceRefresh: true)
                }
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(title: LocalizedStringKey, symbol: String, accent: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(primaryColor)
        }
        .padding(.horizontal, isCarousel ? 4 : 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func commentRow(_ item: SongCommentItem, showsDivider: Bool) -> some View {
        SongCommentCardView(
            item: item,
            appearance: appearance,
            isCarouselCard: isCarousel,
            showsDivider: showsDivider,
            onCopy: {
                copyComment(item.content)
                session.showToast(String(localized: "comments_copied"))
            },
            onHide: {
                withAnimation(.snappy(duration: 0.25)) {
                    moderationStore.hideComment(id: item.id)
                }
                session.showToast(String(localized: "comments_hidden_toast"))
            },
            onBlockAuthor: {
                withAnimation(.snappy(duration: 0.25)) {
                    moderationStore.blockAuthor(key: item.authorBlockKey, displayName: item.authorName)
                }
                session.showToast(String(localized: "comments_blocked_author_toast"))
            }
        )
    }

    @ViewBuilder
    private var paginationFooter: some View {
        HStack {
            Spacer()
            if session.isLoadingMore {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("comments_loading_more")
                        .font(.caption)
                        .foregroundStyle(tertiaryColor)
                }
                .padding(.vertical, 16)
            } else if let error = session.loadMoreError {
                Button {
                    tapGuard.perform { session.loadMore(query: query) }
                } label: {
                    Label(error, systemImage: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(secondaryColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(primaryColor.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 14)
            } else if session.hasMore {
                Button {
                    tapGuard.perform { session.loadMore(query: query) }
                } label: {
                    Text("comments_load_more")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(secondaryColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(primaryColor.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 14)
            } else {
                Text("comments_end_of_list")
                    .font(.caption)
                    .foregroundStyle(tertiaryColor)
                    .padding(.vertical, 16)
            }
            Spacer()
        }
    }

    private func stateView(
        symbol: String,
        title: LocalizedStringKey,
        detail: String?,
        actionTitle: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(tertiaryColor)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(primaryColor)
            if let detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(secondaryColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 28)
            }
            Button {
                tapGuard.perform(action)
            } label: {
                Text(actionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(primaryColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(primaryColor.opacity(0.11), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func copyComment(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - 单条评论卡片

private struct SongCommentCardView: View {
    let item: SongCommentItem
    let appearance: NowPlayingAppearance?
    let isCarouselCard: Bool
    let showsDivider: Bool
    let onCopy: () -> Void
    let onHide: () -> Void
    let onBlockAuthor: () -> Void

    @State private var isExpanded = false
    @State private var showsAllReplies = false
    @Environment(\.nowPlayingCarouselTapGuard) private var tapGuard

    private var primaryColor: Color { appearance?.primary ?? .primary }
    private var secondaryColor: Color { appearance?.secondary ?? .secondary }
    private var tertiaryColor: Color { appearance?.tertiary ?? Color.secondary.opacity(0.68) }

    /// 按字符宽幅（全角/CJK 计 2，半角计 1）与换行数判断评论是否可能超过 6 行折叠阈值。
    private var isLongContent: Bool {
        var lineCount = 1
        var weightedCount = 0
        for scalar in item.content.unicodeScalars {
            if scalar == "\n" {
                lineCount += 1
                if lineCount > 5 { return true }
            } else {
                weightedCount += scalar.value >= 0x2E80 ? 2 : 1
                if weightedCount > 190 { return true }
            }
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 11) {
                CommentAvatarView(urlString: item.avatarURL, authorName: item.authorName, size: 34)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 6) {
                    headerRow
                    bodyText
                    if !item.replies.isEmpty {
                        repliesBlock
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, isCarouselCard ? 14 : 18)
            .padding(.vertical, isCarouselCard ? 13 : 14)

            if showsDivider {
                Rectangle()
                    .fill(primaryColor.opacity(0.08))
                    .frame(height: 0.5)
                    .padding(.leading, 63)
                    .padding(.trailing, 18)
            }
        }
        .background {
            if isCarouselCard {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(primaryColor.opacity(appearance?.isLight == true ? 0.06 : 0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(primaryColor.opacity(0.08), lineWidth: 0.5)
                    }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            actionMenuButtons
        }
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: item.authorName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(primaryColor.opacity(0.92))
                        .lineLimit(1)

                    if item.isPinned {
                        tagPill(Text("comments_badge_pinned"), tint: .accentColor)
                    } else if let badge = item.badge, !badge.isEmpty {
                        tagPill(Text(verbatim: badge), tint: .orange)
                    }
                }

                let meta = formattedMetaLine
                if !meta.isEmpty {
                    Text(verbatim: meta)
                        .font(.caption2)
                        .foregroundStyle(tertiaryColor)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if let likes = item.likedCount, likes > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "hand.thumbsup")
                            .font(.system(size: 11, weight: .medium))
                        Text(verbatim: CommentAPIServerPolicy.compactLikeCount(likes))
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(tertiaryColor)
                }

                Menu {
                    actionMenuButtons
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tertiaryColor)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("more"))
            }
        }
    }

    private func tagPill(_ text: Text, tint: Color) -> some View {
        text
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private var bodyText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: item.content)
                .font(.system(size: 15))
                .lineSpacing(4.5)
                .foregroundStyle(primaryColor)
                .lineLimit(isExpanded ? nil : 6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if isLongContent {
                Button {
                    tapGuard.perform {
                        withAnimation(.snappy(duration: 0.24)) {
                            isExpanded.toggle()
                        }
                    }
                } label: {
                    Text(isExpanded ? LocalizedStringKey("player_carousel_show_less") : LocalizedStringKey("comments_expand"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var repliesBlock: some View {
        let previewLimit = 2
        let visibleReplies = showsAllReplies ? item.replies : Array(item.replies.prefix(previewLimit))
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(visibleReplies) { reply in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(verbatim: reply.authorName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(primaryColor.opacity(0.86))
                        if let target = reply.replyToAuthorName, !target.isEmpty {
                            Text("comments_reply_to \(target)")
                                .font(.caption2)
                                .foregroundStyle(tertiaryColor)
                        }
                    }
                    Text(verbatim: reply.content)
                        .font(.footnote)
                        .lineSpacing(3)
                        .foregroundStyle(secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if item.replies.count > previewLimit {
                Button {
                    tapGuard.perform {
                        withAnimation(.snappy(duration: 0.24)) {
                            showsAllReplies.toggle()
                        }
                    }
                } label: {
                    Text(showsAllReplies
                         ? LocalizedStringKey("player_carousel_show_less")
                         : LocalizedStringKey("comments_replies_more \(item.replies.count - previewLimit)"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(primaryColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.top, 2)
    }

    @ViewBuilder
    private var actionMenuButtons: some View {
        Button {
            onCopy()
        } label: {
            Label("comments_action_copy", systemImage: "doc.on.doc")
        }
        Button {
            onHide()
        } label: {
            Label("comments_action_hide", systemImage: "eye.slash")
        }
        Button(role: .destructive) {
            onBlockAuthor()
        } label: {
            Label("comments_action_block_author", systemImage: "person.crop.circle.badge.xmark")
        }
    }

    private var formattedMetaLine: String {
        var parts: [String] = []
        if let timeText = item.timeText, !timeText.isEmpty {
            parts.append(timeText)
        } else if let date = item.timestamp {
            parts.append(Self.formatDate(date))
        }
        if let location = item.location, !location.isEmpty {
            parts.append(location)
        }
        return parts.joined(separator: " · ")
    }

    private static func formatDate(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval >= 0, interval < 7 * 86_400 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - 头像、骨架屏与轻提示

struct CommentAvatarView: View {
    let urlString: String?
    let authorName: String
    let size: CGFloat

    @State private var loadedImage: CommentAvatarPlatformImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(Self.gradient(for: authorName))
            if let image = cachedOrLoadedImage {
                #if os(macOS)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                #else
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                #endif
            } else {
                Text(verbatim: Self.initial(for: authorName))
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .task(id: urlString) {
            guard let urlString, !urlString.isEmpty else {
                loadedImage = nil
                return
            }
            if let cached = CommentAvatarCache.shared.cachedImage(for: urlString) {
                loadedImage = cached
                return
            }
            loadedImage = await CommentAvatarCache.shared.loadImage(from: urlString)
        }
        .accessibilityHidden(true)
    }

    private var cachedOrLoadedImage: CommentAvatarPlatformImage? {
        if let loadedImage { return loadedImage }
        guard let urlString else { return nil }
        return CommentAvatarCache.shared.cachedImage(for: urlString)
    }

    private static func initial(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    private static func gradient(for name: String) -> LinearGradient {
        var hash: UInt64 = 5381
        for byte in name.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        let hue = Double(hash % 360) / 360.0
        let top = Color(hue: hue, saturation: 0.48, brightness: 0.78)
        let bottom = Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1.0), saturation: 0.56, brightness: 0.58)
        return LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct SongCommentSkeletonList: View {
    let appearance: NowPlayingAppearance?
    let isCarousel: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var fill: Color {
        (appearance?.primary ?? .primary).opacity(pulse ? 0.14 : 0.07)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: isCarousel ? 10 : 0) {
                ForEach(0..<5, id: \.self) { index in
                    HStack(alignment: .top, spacing: 11) {
                        Circle()
                            .fill(fill)
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(fill)
                                .frame(width: 108, height: 12)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(fill)
                                .frame(maxWidth: .infinity)
                                .frame(height: 13)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(fill)
                                .frame(width: index.isMultiple(of: 2) ? 210 : 165, height: 13)
                        }
                    }
                    .padding(.horizontal, isCarousel ? 14 : 18)
                    .padding(.vertical, 15)
                }
            }
            .padding(.top, 8)
        }
        .scrollDisabled(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

private struct SongCommentsToastPill: View {
    let message: String

    var body: some View {
        Text(verbatim: message)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
            .allowsHitTesting(false)
    }
}
