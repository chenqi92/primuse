#if os(tvOS)
import PrimuseKit
import SwiftUI

/// Apple TV 歌曲评论浮层：左侧为歌曲封面、排序与源切换，右侧为适配遥控器焦点的可读大字评论卡片列表。
struct TVSongCommentsView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var serverStore = CommentAPIServerStore.shared
    @State private var moderationStore = SongCommentModerationStore.shared
    @State private var sort: SongCommentSort = .hot
    @State private var selectedServerID: String?
    @State private var activeServer: CommentAPIServer?
    @State private var totalCount: Int?
    @State private var hotComments: [SongCommentItem] = []
    @State private var comments: [SongCommentItem] = []
    @State private var hasMore = false
    @State private var nextPage = 2
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var focusedCommentActionTarget: SongCommentItem?
    @State private var fetchTask: Task<Void, Never>?

    private var currentQuery: SongCommentQuery? {
        let np = store.nowPlaying
        let title = np.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let songID = store.currentSongID ?? np.songID
        let id = songID.isEmpty ? "\(title)|\(np.artist)" : songID
        return SongCommentQuery(
            songID: id,
            title: title,
            artist: np.artist.isEmpty ? nil : np.artist,
            album: np.album.isEmpty ? nil : np.album,
            duration: store.duration > 0 ? store.duration : nil
        )
    }

    private var visibleSections: (hot: [SongCommentItem], regular: [SongCommentItem]) {
        let filteredHot = moderationStore.filter(hotComments)
        let filteredRegular = moderationStore.filter(comments)
        if sort == .hot {
            if !filteredHot.isEmpty {
                let hotIDs = Set(filteredHot.map(\.id))
                return (filteredHot, filteredRegular.filter { !hotIDs.contains($0.id) })
            }
            return ([], filteredRegular)
        }
        return ([], filteredRegular.isEmpty ? filteredHot : filteredRegular)
    }

    var body: some View {
        let np = store.nowPlaying
        let colors = store.nowPlayingPresentationColors
        ZStack {
            TVAmbientBackdrop(tint: colors.primary, tint2: colors.secondary, strength: 0.5)
            TVColor.bg.opacity(0.56).ignoresSafeArea()

            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 44) {
                    leftColumn(np: np, colors: colors)
                        .frame(width: 340, alignment: .leading)
                        .focusSection()

                    rightColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .focusSection()
                }
                .padding(48)
                .frame(maxWidth: 1620, alignment: .leading)
                .frame(height: min(880, geometry.size.height - 64), alignment: .top)
                .tvPanel(radius: 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .padding(.horizontal, 60)
        }
        .foregroundStyle(TVColor.text)
        .onExitCommand { dismiss() }
        .task(id: "\(currentQuery?.songID ?? "")|\(sort.rawValue)|\(selectedServerID ?? "")|\(serverStore.revision)") {
            loadFirstPage(forceRefresh: false)
        }
        .onDisappear { fetchTask?.cancel() }
        .confirmationDialog(
            focusedCommentActionTarget?.authorName ?? "",
            isPresented: Binding(
                get: { focusedCommentActionTarget != nil },
                set: { if !$0 { focusedCommentActionTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let item = focusedCommentActionTarget {
                Button(String(localized: "comments_action_hide")) {
                    moderationStore.hideComment(id: item.id)
                    focusedCommentActionTarget = nil
                }
                Button(String(localized: "comments_action_block_author"), role: .destructive) {
                    moderationStore.blockAuthor(key: item.authorBlockKey, displayName: item.authorName)
                    focusedCommentActionTarget = nil
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {
                focusedCommentActionTarget = nil
            }
        } message: {
            if let item = focusedCommentActionTarget {
                Text(verbatim: item.content)
            }
        }
        .accessibilityIdentifier("tv.nowPlaying.commentsSheet")
    }

    private func leftColumn(np: TVNowPlaying, colors: (primary: Color, secondary: Color)) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TVEyebrow(text: String(localized: "comments_title"))
                .padding(.bottom, 18)

            TVArtworkView(
                coverKey: np.albumID,
                artist: np.artist,
                album: np.album,
                songID: np.songID,
                coverRef: np.coverRef,
                tint: colors.primary,
                tint2: colors.secondary,
                glyph: np.glyph,
                size: 260,
                radius: 18
            )
            .shadow(color: .black.opacity(0.4), radius: 22, y: 10)

            Text(verbatim: np.title)
                .tvFont(size: 32, weight: .bold, relativeTo: .title2)
                .foregroundStyle(TVColor.text)
                .lineLimit(2)
                .padding(.top, 20)

            if !np.artist.isEmpty {
                Text(verbatim: np.artist)
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textMuted)
                    .lineLimit(1)
                    .padding(.top, 4)
            }

            if let total = totalCount, total > 0 {
                Text(String(format: String(localized: "comments_total_count_format"),
                            CommentAPIServerPolicy.compactLikeCount(total)))
                    .tvFont(.meta)
                    .foregroundStyle(TVColor.textFaint)
                    .padding(.top, 6)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TVPillButton(
                        title: String(localized: "comments_sort_hot"),
                        systemImage: "flame.fill",
                        style: sort == .hot ? .solid : .glass,
                        isSelected: sort == .hot
                    ) {
                        sort = .hot
                    }
                    TVPillButton(
                        title: String(localized: "comments_sort_latest"),
                        systemImage: "clock",
                        style: sort == .latest ? .solid : .glass,
                        isSelected: sort == .latest
                    ) {
                        sort = .latest
                    }
                }

                if serverStore.enabledServers.count > 1 {
                    TVPillButton(
                        title: activeServerLabel,
                        systemImage: "server.rack"
                    ) {
                        cycleServer()
                    }
                }

                HStack(spacing: 12) {
                    TVPillButton(
                        title: String(localized: "comments_refresh"),
                        systemImage: "arrow.clockwise"
                    ) {
                        loadFirstPage(forceRefresh: true)
                    }
                    TVPillButton(
                        title: String(localized: "close"),
                        systemImage: "xmark"
                    ) {
                        dismiss()
                    }
                }
            }
            .padding(.top, 24)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var rightColumn: some View {
        let sections = visibleSections
        let hasItems = !sections.hot.isEmpty || !sections.regular.isEmpty

        if isLoading && !hasItems {
            VStack(spacing: 16) {
                ProgressView()
                Text(String(localized: "comments_loading"))
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, !hasItems {
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(TVColor.textFaint)
                Text(String(localized: "comments_load_failed"))
                    .tvFont(.cardTitle)
                Text(verbatim: errorMessage)
                    .tvFont(.meta)
                    .foregroundStyle(TVColor.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 640)
                TVPillButton(title: String(localized: "comments_retry"), systemImage: "arrow.clockwise") {
                    loadFirstPage(forceRefresh: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasItems {
            VStack(spacing: 16) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(TVColor.textFaint)
                Text(String(localized: "comments_empty_title"))
                    .tvFont(.cardTitle)
                    .foregroundStyle(TVColor.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if !sections.hot.isEmpty {
                        TVEyebrow(text: String(localized: "comments_section_hot"))
                        ForEach(sections.hot) { item in
                            tvCommentCard(item)
                        }
                    }

                    if !sections.regular.isEmpty {
                        if !sections.hot.isEmpty {
                            TVEyebrow(text: String(localized: "comments_section_all"))
                                .padding(.top, 12)
                        }
                        ForEach(sections.regular) { item in
                            tvCommentCard(item)
                        }
                    }

                    if hasMore {
                        HStack {
                            Spacer()
                            if isLoadingMore {
                                ProgressView()
                                    .padding(.vertical, 16)
                            } else {
                                TVPillButton(
                                    title: String(localized: "comments_load_more"),
                                    systemImage: "arrow.down.circle"
                                ) {
                                    loadMore()
                                }
                                .padding(.vertical, 12)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private func tvCommentCard(_ item: SongCommentItem) -> some View {
        Button {
            focusedCommentActionTarget = item
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    TVCommentAvatar(urlString: item.avatarURL, authorName: item.authorName, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text(verbatim: item.authorName)
                                .tvFont(size: 26, weight: .semibold, relativeTo: .headline)
                                .foregroundStyle(TVColor.text)
                                .lineLimit(1)
                            if item.isPinned {
                                Text(String(localized: "comments_badge_pinned"))
                                    .tvFont(size: 18, weight: .semibold, relativeTo: .caption2)
                                    .foregroundStyle(TVColor.brand)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 3)
                                    .background(TVColor.brand.opacity(0.18), in: Capsule())
                            } else if let badge = item.badge, !badge.isEmpty {
                                Text(verbatim: badge)
                                    .tvFont(size: 18, weight: .semibold, relativeTo: .caption2)
                                    .foregroundStyle(Color.orange)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 3)
                                    .background(Color.orange.opacity(0.18), in: Capsule())
                            }
                        }
                        let meta = metaLine(for: item)
                        if !meta.isEmpty {
                            Text(verbatim: meta)
                                .tvFont(.meta)
                                .foregroundStyle(TVColor.textFaint)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 12)
                    if let likes = item.likedCount, likes > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "hand.thumbsup")
                                .font(.system(size: 20, weight: .medium))
                            Text(verbatim: CommentAPIServerPolicy.compactLikeCount(likes))
                                .tvFont(.meta)
                                .monospacedDigit()
                        }
                        .foregroundStyle(TVColor.textMuted)
                    }
                }

                Text(verbatim: item.content)
                    .tvFont(size: 28, weight: .regular, relativeTo: .body)
                    .foregroundStyle(TVColor.text.opacity(0.94))
                    .lineSpacing(8)
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !item.replies.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(item.replies.prefix(2)) { reply in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: reply.authorName + ":")
                                    .tvFont(size: 22, weight: .semibold, relativeTo: .caption)
                                    .foregroundStyle(TVColor.text.opacity(0.85))
                                Text(verbatim: reply.content)
                                    .tvFont(size: 22, weight: .regular, relativeTo: .caption)
                                    .foregroundStyle(TVColor.textMuted)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.card)
    }

    private var activeServerLabel: String {
        if let selectedServerID,
           let server = serverStore.enabledServers.first(where: { $0.id == selectedServerID }) {
            return server.displayTitle
        }
        if let activeServer { return activeServer.displayTitle }
        return String(localized: "comments_source_auto")
    }

    private func cycleServer() {
        let enabled = serverStore.enabledServers
        guard enabled.count > 1 else { return }
        let choices: [String?] = [nil] + enabled.map(\.id)
        let currentIndex = choices.firstIndex(of: selectedServerID) ?? 0
        selectedServerID = choices[(currentIndex + 1) % choices.count]
    }

    private func metaLine(for item: SongCommentItem) -> String {
        var parts: [String] = []
        if let timeText = item.timeText, !timeText.isEmpty {
            parts.append(timeText)
        } else if let date = item.timestamp {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        if let location = item.location, !location.isEmpty {
            parts.append(location)
        }
        return parts.joined(separator: " · ")
    }

    private func loadFirstPage(forceRefresh: Bool) {
        fetchTask?.cancel()
        guard let query = currentQuery else {
            hotComments = []
            comments = []
            totalCount = nil
            hasMore = false
            isLoading = false
            errorMessage = nil
            return
        }
        let servers = serverStore.enabledServers
        guard !servers.isEmpty else {
            errorMessage = String(localized: "comments_server_none")
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        let requestedSort = sort
        let preferredID = selectedServerID
        fetchTask = Task {
            do {
                let result = try await SongCommentService.shared.fetchFirstPage(
                    query: query,
                    servers: servers,
                    preferredServerID: preferredID,
                    sort: requestedSort,
                    forceRefresh: forceRefresh
                )
                guard !Task.isCancelled else { return }
                if let result {
                    activeServer = result.server
                    totalCount = result.page.total
                    hotComments = result.page.hotComments
                    comments = result.page.comments
                    hasMore = result.page.hasMore
                    nextCursor = result.page.nextCursor
                    nextPage = 2
                } else {
                    activeServer = servers.first(where: { $0.id == preferredID }) ?? servers.first
                    totalCount = 0
                    hotComments = []
                    comments = []
                    hasMore = false
                    nextCursor = nil
                    nextPage = 2
                }
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func loadMore() {
        guard hasMore, !isLoadingMore, let query = currentQuery, let server = activeServer else { return }
        isLoadingMore = true
        let targetPage = nextPage
        let cursor = nextCursor
        let requestedSort = sort
        Task {
            do {
                let page = try await SongCommentService.shared.fetchNextPage(
                    server: server,
                    query: query,
                    sort: requestedSort,
                    page: targetPage,
                    cursor: cursor
                )
                guard !Task.isCancelled else { return }
                let existing = Set(comments.map(\.id)).union(hotComments.map(\.id))
                let appended = page.comments.filter { !existing.contains($0.id) }
                comments.append(contentsOf: appended)
                if let total = page.total { totalCount = total }
                nextCursor = page.nextCursor
                nextPage = targetPage + 1
                hasMore = page.hasMore && !appended.isEmpty
                isLoadingMore = false
            } catch {
                guard !Task.isCancelled else { return }
                isLoadingMore = false
            }
        }
    }
}

private struct TVCommentAvatar: View {
    let urlString: String?
    let authorName: String
    let size: CGFloat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(Self.gradient(for: authorName))
            if let img = image ?? (urlString.flatMap { CommentAvatarCache.shared.cachedImage(for: $0) }) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(verbatim: Self.initial(for: authorName))
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: urlString) {
            guard let urlString, !urlString.isEmpty else {
                image = nil
                return
            }
            if let cached = CommentAvatarCache.shared.cachedImage(for: urlString) {
                image = cached
                return
            }
            image = await CommentAvatarCache.shared.loadImage(from: urlString)
        }
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
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.48, brightness: 0.78),
                Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1.0), saturation: 0.56, brightness: 0.58),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
#endif
