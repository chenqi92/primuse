#if os(macOS)
import SwiftUI
import AppKit
import PrimuseKit

/// 主窗口顶部 48pt 自定义 title bar:原生窗口按钮与侧栏开关、居中搜索,
/// 右侧是不占侧栏的几处 —— 收藏、智能推荐、听歌统计、工具。
struct PMTitleBar: View {
    @Binding var searchText: String
    @Binding var sidebarCollapsed: Bool
    /// 当前页。标题栏的 body 不读它(见 `MacTitleBarRouteObserver`), 只在点击、搜索时看一眼。
    let routeSwitch: MacRouteSwitch
    let onSelectRoute: (MacRoute) -> Void
    var isRecommendationsShown = false
    var onToggleRecommendations: () -> Void = {}
    var onOpenListeningStats: () -> Void = {}
    var onOpenTool: (MacTool) -> Void = { _ in }

    @Environment(\.pmAppearance) private var mode
    @Environment(MusicLibrary.self) private var library
    @AppStorage(AppleMusicFeatureSettings.catalogSearchEnabledKey)
    private var appleMusicCatalogSearchEnabled = true
    @FocusState private var searchFocused: Bool
    @State private var keyboardShortcuts = MacKeyboardShortcutStore.shared
    @State private var favoritesShown = false

    var body: some View {
        ZStack {
            // The traffic lights and the three trailing tools have different
            // widths. Putting the search field between two flexible gaps
            // therefore centered it in the leftover space, not in the window.
            // Keep the chrome in the base layer and pin search to the title
            // bar's geometric center.
            HStack(spacing: 8) {
                PMStandardWindowButtonArea()
                sidebarToggle
                windowDragSpacer
                trailingControls
            }

            // 设计稿对比: 搜索框比当前版本更窄 + 更高 (高/宽比约 30/25 = 1.2x)。
            // idealWidth 收到 320, maxWidth 380, 高度提到 36 让上下 padding 更松,
            // 视觉比例接近设计图。
            searchBox
                .frame(minWidth: 240, idealWidth: 320, maxWidth: 380)
                .frame(height: 36)
                .zIndex(1)
        }
        .padding(.horizontal, 14)
        .frame(height: PMSize.titlebar)
        .background(titlebarBackground.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    /// Use concrete AppKit views for the flexible title-bar gaps. Keeping the
    /// drag bridge in `.background` left it behind SwiftUI's hosting view, so
    /// clicks in those gaps could be swallowed before AppKit saw a double-click.
    private var windowDragSpacer: some View {
        PMWindowDragRegion()
            .frame(minWidth: 12, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 侧栏开关挨着红绿灯, 和访达、备忘录一样。
    private var sidebarToggle: some View {
        PMRoundBtn(icon: "sidebar.left", iconSize: 13, style: .plain, help: "sidebar_toggle") {
            pmWithAnimation(.panel) { sidebarCollapsed.toggle() }
        }
    }

    /// 输出设备在底栏, 加音乐源在侧栏音乐源分区, 这里只放不进侧栏的几处。
    private var trailingControls: some View {
        HStack(spacing: 8) {
            PMRoundBtn(
                icon: favoritesShown ? "heart.fill" : "heart",
                iconSize: 13, style: .glass, isActive: favoritesShown,
                help: "library_quick_access"
            ) {
                #if DEBUG
                PMWindowChromeTrace.start("favorites popover")
                #endif
                favoritesShown.toggle()
            }
            .popover(isPresented: $favoritesShown, arrowEdge: .bottom) {
                MacFavoritesPopover(
                    onNavigate: { route in
                        favoritesShown = false
                        onSelectRoute(route)
                    },
                    onDismiss: { favoritesShown = false }
                )
            }
            PMRoundBtn(
                icon: "sparkles", iconSize: 13, style: .glass, isActive: isRecommendationsShown,
                help: "library_recommendations_title", action: onToggleRecommendations
            )
            PMRoundBtn(
                icon: "chart.bar.xaxis", iconSize: 12, style: .glass,
                help: "stats_title", action: onOpenListeningStats
            )
            toolsMenu
        }
    }

    private var toolsMenu: some View {
        Menu {
            ForEach(MacTool.allCases) { tool in
                Button {
                    onOpenTool(tool)
                } label: {
                    Label(tool.title, systemImage: tool.systemImage)
                        .labelStyle(.titleAndIcon)
                }
            }
        } label: {
            PMTitleBarMenuIcon(icon: "wrench.and.screwdriver")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("mac_sidebar_tools"))
    }

    // MARK: - Search box

    /// 只搜已入库的曲库;开着 Apple Music 目录搜索时才写上它(以前写死了)。
    private var searchPromptKey: LocalizedStringKey {
        AppleMusicCatalogSearchAvailabilityPolicy.isEnabled(
            catalogSearchEnabled: appleMusicCatalogSearchEnabled,
            sourceInstalled: library.appleMusicSourceInstalled,
            disabledSourceIDs: library.disabledSourceIDs
        ) ? "search_placeholder_universal" : "search_placeholder_library"
    }

    private var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PMColor.textFaint)

            TextField("", text: $searchText, prompt: Text(searchPromptKey))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(PMColor.text)
                .focused($searchFocused)
                .onSubmit {
                    showSearchResults(for: searchText)
                    releaseSearchFocus()
                }
                .onExitCommand(perform: releaseSearchFocus)
                .onChange(of: searchText) { _, value in
                    showSearchResults(for: value)
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textFaint)
                }
                .buttonStyle(.plain)
            } else {
                Text(verbatim: keyboardShortcuts.shortcut(for: .focusSearch)?.displayString ?? "—")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint.opacity(0.7))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            // 设计稿 TitleBar 里搜索框是 *实白* 填充 (bg-elev), 不是玻璃覆盖 —
            // 之前用 glassBtn 半透黑叠在米色 titlebar 上呈现粉桃色, 跟设计稿不一致。
            // 圆角降到 7 (设计稿是接近矩形的圆角胶囊, 不是大圆 pill); 描边只在 focus
            // 时上 brand 高亮, 平时用极淡 divider 描一圈。
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(PMColor.bgElev)
                .shadow(color: Color.black.opacity(0.06), radius: 1, y: 0.5)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    searchFocused
                        ? PMColor.brand.opacity(0.55)
                        : PMColor.divider.opacity(0.6),
                    lineWidth: 0.5
                )
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseFocusSearch)) { _ in
            searchFocused = true
            if isOnSearch {
                revealSearchResults()
            } else {
                selectSearchRoute()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseDismissSearchFocus)) { _ in
            releaseSearchFocus()
        }
        .background {
            MacTitleBarRouteObserver(routeSwitch: routeSwitch, onChange: releaseSearchFocusIfNeeded)
        }
        .onAppear {
            releaseSearchFocusIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            releaseSearchFocusIfNeeded()
        }
    }

    private var isOnSearch: Bool {
        if case .search = routeSwitch.requested { return true }
        return false
    }

    @ViewBuilder
    private var titlebarBackground: some View {
        // 设计稿: TitleBar 背景 = var(--pm-bg) (浅色: #F3F4F6 冷中性灰, 深色: #161719) +
        // rgba(255,255,255,.04) 微亮覆盖, 跟整窗 bg 同色调。之前用 .headerView material
        // 会去 blend 窗外内容, 在浅色系统上偏纯白, 跟整窗中性灰 bg 不一致, 顶部看着像「贴
        // 了块白条」。直接用 PMColor.bg 实色就跟下面 detail 区无缝接上。
        if mode == .glass {
            ZStack {
                Rectangle().fill(PMColor.bg)
                Rectangle().fill(Color.white.opacity(0.04))
            }
        } else {
            Rectangle().fill(PMColor.bg)
        }
    }

    private func showSearchResults(for query: String) {
        if MacTitleBarSearchPolicy.shouldActivateSearch(for: query, isOnSearch: isOnSearch) {
            selectSearchRoute()
        } else if MacTitleBarSearchPolicy.shouldRevealSearchResults(for: query, isOnSearch: isOnSearch) {
            revealSearchResults()
        }
    }

    /// 已经在搜索栏, 但结果可能被点进去的专辑 / 艺人 / 歌单或播放页盖着。
    /// 只把它们收掉, 不重建搜索页 —— 筛选和滚动位置都还在。
    private func revealSearchResults() {
        NotificationCenter.default.post(name: .primuseRevealSearchResults, object: nil)
    }

    private func selectSearchRoute() {
        onSelectRoute(.search)
    }

    private func releaseSearchFocusIfNeeded() {
        guard MacTitleBarSearchPolicy.shouldReleaseFocus(isOnSearch: isOnSearch) else { return }
        releaseSearchFocus()
    }

    private func releaseSearchFocus() {
        searchFocused = false
        searchText = MacTitleBarSearchPolicy.queryAfterReleasingFocus(searchText)

        // SwiftUI's FocusState can say `false` while AppKit restores the field
        // editor as the real first responder after launch. Release it on the
        // next main-loop turn as well so an unmodified Space reaches the
        // playback shortcut instead of becoming invisible search whitespace.
        Task { @MainActor in
            await Task.yield()
            guard !searchFocused else { return }
            searchFocused = false
            guard let window = NSApp.keyWindow,
                  window.attachedSheet == nil,
                  window.sheetParent == nil,
                  Self.isTitleBarSearchFirstResponder(in: window) else {
                return
            }
            window.makeFirstResponder(nil)
        }
    }

    private static func isTitleBarSearchFirstResponder(in window: NSWindow) -> Bool {
        let field: NSTextField?
        if let directField = window.firstResponder as? NSTextField {
            field = directField
        } else if let fieldEditor = window.firstResponder as? NSTextView {
            field = fieldEditor.delegate as? NSTextField
        } else {
            field = nil
        }

        guard let field,
              field.window === window,
              let contentView = window.contentView else { return false }
        let frameInWindow = field.convert(field.bounds, to: nil)
        let titleBarFloor = contentView.convert(contentView.bounds, to: nil).maxY - PMSize.titlebar - 12
        return frameInWindow.midY >= titleBarFloor
    }
}

/// 菜单按钮的触发器, 长得和 `PMRoundBtn` 的玻璃圆钮一样。
private struct PMTitleBarMenuIcon: View {
    let icon: String
    @Environment(\.pmAppearance) private var mode
    @State private var hover = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(PMColor.text)
            .frame(width: PMSize.medBtn, height: PMSize.medBtn)
            .background(background, in: .circle)
            .overlay { Circle().strokeBorder(PMColor.cardBorder, lineWidth: 0.5) }
            .contentShape(Circle())
            .onHover { hover = $0 }
            .pmAnimation(.hover, value: hover)
    }

    private var background: Color {
        mode == .glass
            ? (hover ? PMColor.glassBtnHover : PMColor.glassBtn)
            : (hover ? PMColor.matBtnHover : PMColor.matBtn)
    }
}

/// 标题栏心形按钮弹出的收藏面板: 上面是「我喜欢」, 能直接播放或随机播放;
/// 下面是收藏的专辑、艺人、歌单和有声书。目录和完整列表在「查看全部」里。
struct MacFavoritesPopover: View {
    let onNavigate: (MacRoute) -> Void
    let onDismiss: () -> Void

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @AppStorage(LibraryPinStorage.defaultsKey) private var pinsRawValue = ""
    @AppStorage(HomeFolderPinStorage.key) private var folderPinsRawValue = ""

    private static let tileLimit = 8
    private static let tileSize: CGFloat = 66

    private var entries: [FavoriteCollectionEntry] {
        _ = pinsRawValue
        _ = folderPinsRawValue
        // 不给目录索引: 目录要等索引建好才对得上, 弹框里不等, 它们留在「查看全部」。
        return FavoriteCollectionResolver.entries(
            for: FavoriteCollectionStore.shared.references(library: library),
            library: library,
            folderIndex: nil
        )
        .filter { !$0.isLikedSongs }
    }

    var body: some View {
        let likedSongs = library.songs(forPlaylist: MusicLibrary.likedSongsPlaylistID)
        let entries = self.entries
        VStack(alignment: .leading, spacing: 0) {
            likedRow(likedSongs)
                .padding(14)
            Rectangle()
                .fill(PMColor.divider)
                .frame(height: 0.5)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("library_quick_access")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PMColor.textMuted)
                    Spacer()
                    Button {
                        onNavigate(.section(.favorites))
                    } label: {
                        HStack(spacing: 2) {
                            Text("see_all")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(PMColor.brand)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if entries.isEmpty {
                    Text("favorites_empty_description")
                        .font(.system(size: 11.5))
                        .foregroundStyle(PMColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(Self.tileSize), spacing: 12), count: 4),
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(entries.prefix(Self.tileLimit)) { entry in
                            tile(entry)
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 4 * Self.tileSize + 3 * 12 + 28)
    }

    private func likedRow(_ songs: [Song]) -> some View {
        HStack(spacing: 10) {
            Button {
                onNavigate(.liked)
            } label: {
                HStack(spacing: 12) {
                    FavoriteLikedSongsArtwork(size: 52, cornerRadius: 12)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("sidebar_liked_songs")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(PMColor.text)
                        Text("album_pick_tracks \(songs.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(PMColor.textFaint)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            PMRoundBtn(icon: "play.fill", size: 30, iconSize: 11, style: .accent, help: "play_all") {
                play(songs, shuffled: false)
            }
            .disabled(songs.isEmpty)
            PMRoundBtn(icon: "shuffle", size: 30, iconSize: 11, style: .glass, help: "shuffle_all") {
                play(songs, shuffled: true)
            }
            .disabled(songs.isEmpty)
        }
    }

    private func tile(_ entry: FavoriteCollectionEntry) -> some View {
        let title = FavoriteCollectionResolver.title(entry)
        return Button {
            open(entry)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                FavoriteCollectionArtwork(entry: entry, size: Self.tileSize, cornerRadius: 10)
                Text(verbatim: title)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                    .frame(width: Self.tileSize, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: title))
    }

    private func open(_ entry: FavoriteCollectionEntry) {
        switch entry {
        case .album(let album):
            onDismiss()
            NotificationCenter.default.post(name: .primuseDetailOpenAlbum, object: album)
        case .artist(let artist):
            onDismiss()
            NotificationCenter.default.post(name: .primuseDetailOpenArtist, object: artist)
        case .playlist(let playlist):
            onNavigate(.playlist(playlist))
        case .folder:
            onNavigate(.section(.favorites))
        case .book(let favorite):
            onDismiss()
            NotificationCenter.default.post(name: .primuseDetailOpenSpokenWordBook, object: favorite.book.id)
        }
    }

    private func play(_ songs: [Song], shuffled: Bool) {
        let playable = songs.filteredPlayable()
        let queue = shuffled ? player.shufflePlayOrder(playable) : playable
        guard !queue.isEmpty else { return }
        if shuffled { player.shuffleEnabled = true }
        SiriMediaInteractionDonor.donate(.playlist(id: MusicLibrary.likedSongsPlaylistID), shuffled: shuffled)
        onDismiss()
        Task { await player.play(queue: queue, startingAt: 0) }
    }
}

#if DEBUG
/// `PRIMUSE_DEBUG_FAVORITES_SNAPSHOT=<目录>`: 启动后把收藏弹框和选择播放设备弹框离屏渲染成
/// 浅色、深色各一张 PNG —— 弹框是单独的小窗口, 编译机上按主窗口截图拍不到它。封面是异步读的,
/// 图里可能是占位。
@MainActor
enum MacFavoritesPopoverDebugSnapshot {
    static func writeIfRequested() async {
        guard let path = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_FAVORITES_SNAPSHOT"],
              !path.isEmpty else { return }
        try? await Task.sleep(for: .seconds(8))
        let directory = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        render(directory: directory, prefix: "favorites") {
            MacFavoritesPopover(onNavigate: { _ in }, onDismiss: {})
        }
        render(directory: directory, prefix: "cast") {
            CastDevicePickerSheet()
        }
        plog("🧪 popover snapshots written to \(directory.path)")
    }

    private static func render<Content: View>(
        directory: URL,
        prefix: String,
        @ViewBuilder content: () -> Content
    ) {
        for (name, appearanceName, scheme) in [
            ("\(prefix)-light", NSAppearance.Name.aqua, ColorScheme.light),
            ("\(prefix)-dark", NSAppearance.Name.darkAqua, ColorScheme.dark),
        ] {
            let content = content()
                .fixedSize()
                .background(PMColor.bgElev)
                .applyPrimuseEnvironments()
                .environment(\.colorScheme, scheme)
            var png: Data?
            NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                png = renderer.cgImage.flatMap {
                    NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
                }
            }
            if let png {
                try? png.write(to: directory.appendingPathComponent("\(name).png"))
            } else {
                plog("🧪 popover snapshot \(name) failed")
            }
        }
    }
}
#endif

extension Notification.Name {
    static let primuseDetailGoBack    = Notification.Name("primuse.detail.goBack")
    static let primuseDetailGoForward = Notification.Name("primuse.detail.goForward")
    static let primuseFocusSearch     = Notification.Name("primuse.titlebar.focusSearch")
    static let primuseDismissSearchFocus = Notification.Name("primuse.titlebar.dismissSearchFocus")
    static let primuseRevealSearchResults = Notification.Name("primuse.titlebar.revealSearchResults")
}

/// 换页时收起搜索框的焦点。单独一个零尺寸视图读当前页: 写在标题栏自己身上的话,
/// 每换一页整条标题栏(搜索框、右侧几个按钮、工具菜单)都要跟着重算。
private struct MacTitleBarRouteObserver: View {
    let routeSwitch: MacRouteSwitch
    let onChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: routeSwitch.requested.stableID) { _, _ in onChange() }
    }
}

#endif
