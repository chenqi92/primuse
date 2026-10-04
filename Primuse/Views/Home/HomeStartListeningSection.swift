import SwiftUI
import PrimuseKit

/// 「开始听」:经典首页的区块、Mac 首页主卡下面、极简导航「歌曲」页顶上共用。
///
/// 第一张固定是「接着上次」(有能接着放的音乐队列时)或「随便听听」,然后是钉选的,
/// 其余按曲库点亮强度。首页默认铺开成网格(收起时放设定的张数,凑满整行,其余点「展开」
/// 原地铺出来),也可以在首页编辑里换回横排;标题右边「全部」进整页。点卡片直接起播,
/// 长按可以下一首播放、加入队列、查看歌曲、钉选或隐藏。点亮在后台算好,这里只读结果。
struct StartListeningShelf: View {
    /// 卡片怎么摆。
    enum Arrangement: Equatable {
        /// 铺开:等宽色块,列数随宽度(手机两列,iPad、横屏、Mac 更多),
        /// 收起时放 `limit` 张并凑满整行,其余由「展开」铺出来。
        case grid(limit: Int)
        /// 横排:卡片横着滑,一行或几行,一共 `limit` 张。
        case carousel(rows: Int, limit: Int)

        /// 歌曲页顶上那一条:一行横排,不和下面的歌抢地方。
        static let compactRow = Arrangement.carousel(rows: 1, limit: ListeningIntentShelfPolicy.rowLimit)
    }

    var arrangement: Arrangement = .compactRow
    /// 标题与卡片左右留多少。经典首页 20,Mac 首页由外层留白,所以给 0。
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
    /// 网格那一块的宽度,定列数用;量到之前按两列排。
    @State private var gridWidth: CGFloat = 0
    /// 展开过就一直展开,直到再点「收起」。只记在本机。
    @AppStorage(ListeningIntentService.gridExpandedKey) private var isGridExpanded = false

    private static let gridSpacing: CGFloat = 8
    /// 上次量到的网格宽度:首页区块重建时先按它分列,不会在 iPad 上先排两列再跳成四列。
    @MainActor private static var lastGridWidth: CGFloat = 0
    private var service: ListeningIntentService { .shared }

    var body: some View {
        let items = service.row(player: player, limit: rowLimit)
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if showsTitle {
                        header
                            .padding(.horizontal, horizontalInset)
                    }
                    switch arrangement {
                    case .grid(let limit):
                        grid(items, limit: limit)
                    case .carousel(let rows, _):
                        carousel(items, rows: rows)
                    }
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

    /// 横排放多少张就取多少张;网格要知道一共有多少张,才说得出「展开」还藏着几张。
    private var rowLimit: Int {
        switch arrangement {
        case .grid: .max
        case .carousel(_, let limit): max(1, limit)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            sectionTitle
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(action: openAll) {
                viewAllLabel
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.startListening.all")
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

    private var viewAllLabel: some View {
        #if os(macOS)
        HStack(spacing: 3) {
            Text("home_section_view_all")
            Image(systemName: "chevron.right")
                .font(.system(size: 9.5, weight: .semibold))
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(PMColor.brand)
        .contentShape(Rectangle())
        #else
        Text("home_section_view_all")
            .font(.subheadline)
            .foregroundStyle(.tint)
            .contentShape(Rectangle())
        #endif
    }

    // MARK: Grid

    @ViewBuilder
    private func grid(_ items: [ListeningIntentShelfItem], limit: Int) -> some View {
        let columns = ListeningIntentShelfPolicy.gridColumns(
            width: Double(gridWidth > 0 ? gridWidth : Self.lastGridWidth),
            spacing: Double(Self.gridSpacing)
        )
        let collapsed = ListeningIntentShelfPolicy.collapsedGridCount(
            limit: limit,
            columns: columns,
            available: items.count
        )
        let hiddenCount = items.count - collapsed
        let shown = isGridExpanded || hiddenCount == 0 ? items : Array(items.prefix(collapsed))
        VStack(spacing: 4) {
            ListeningIntentEagerGrid(items: shown, columns: columns, spacing: Self.gridSpacing) { item in
                tile(item)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                Self.lastGridWidth = width
                if abs(width - gridWidth) > 0.5 { gridWidth = width }
            }
            if hiddenCount > 0 {
                expandToggle(hiddenCount: hiddenCount)
            }
        }
        .padding(.horizontal, horizontalInset)
    }

    private func tile(_ item: ListeningIntentShelfItem) -> some View {
        let title = service.title(for: item.intent)
        let detail = ListeningIntentText.songCount(item.songCount)
        return Button {
            start(item.intent)
        } label: {
            ListeningIntentTile(
                title: title,
                symbolName: item.intent.symbolName,
                detail: detail,
                tint: item.intent.tint,
                badgeSymbol: item.badgeSymbol,
                isWorking: startingIntentID == item.id
            )
        }
        .buttonStyle(.pmPressable)
        .contextMenu { menu(item) }
        .accessibilityLabel(Text(verbatim: "\(title), \(detail)"))
        .accessibilityIdentifier("home.startListening." + item.id)
    }

    private func expandToggle(hiddenCount: Int) -> some View {
        Button {
            pmWithAnimation(.list) { isGridExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                if isGridExpanded {
                    Text("listening_intent_show_less")
                } else {
                    Text(verbatim: String(format: String(localized: "listening_intent_show_more %lld"), hiddenCount))
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(isGridExpanded ? 180 : 0))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.startListening.expand")
    }

    // MARK: Carousel

    private func carousel(_ items: [ListeningIntentShelfItem], rows: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(
                rows: Array(
                    repeating: GridItem(.fixed(ListeningIntentCard.size.height), spacing: 10),
                    count: max(1, rows)
                ),
                spacing: 10
            ) {
                ForEach(items) { item in
                    card(item)
                }
                // 没有标题栏时「全部」就在这一行的末尾。
                if !showsTitle { allIntentsCard }
            }
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, 2)
        }
        // 自己留边距时滑动区已经铺满所在的那一块,不必越界;越界只会让卡片画到
        // 首页编辑的虚线框、两栏首页的另一栏上。外层留白(Mac 首页)时才让卡片滑进留白里。
        .scrollClipDisabled(horizontalInset == 0)
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
                badgeSymbol: item.badgeSymbol,
                isWorking: startingIntentID == item.id
            )
        }
        .buttonStyle(.pmPressable)
        .contextMenu { menu(item) }
        .accessibilityLabel(Text(verbatim: "\(title), \(detail)"))
        .accessibilityIdentifier("home.startListening." + item.id)
    }

    private var allIntentsCard: some View {
        Button(action: openAll) {
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
        .accessibilityIdentifier("home.startListening.allCard")
    }

    // MARK: Actions

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

    private func openAll() {
        if let onOpenAll { onOpenAll() } else { showsAllIntents = true }
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

    /// 截图钩子:`PRIMUSE_DEBUG_INTENTS=page` 打开「全部意图」,`songs:<内置意图 rawValue>` 打开它的「查看歌曲」,
    /// `toggleGrid` 带动画展开网格、两秒后再收起(看收起后有没有留空白)。
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
            openAll()
        } else if request == "toggleGrid" {
            pmWithAnimation(.list) { isGridExpanded = true }
            try? await Task.sleep(for: .seconds(2))
            pmWithAnimation(.list) { isGridExpanded = false }
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
            switch arrangement {
            case .grid(let limit):
                // 列数、行数与收起时的真网格一致(手机默认三行两列),换上真卡片时下面的区块不被顶开;
                // 宽度在占位上就量,iPad 不会先排两列再跳成四列。
                let columns = ListeningIntentShelfPolicy.gridColumns(
                    width: Double(gridWidth > 0 ? gridWidth : Self.lastGridWidth),
                    spacing: Double(Self.gridSpacing)
                )
                let rows = (max(1, limit) + columns - 1) / columns
                VStack(spacing: Self.gridSpacing) {
                    ForEach(0..<rows, id: \.self) { _ in
                        HStack(spacing: Self.gridSpacing) {
                            ForEach(0..<columns, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: ListeningIntentTile.cornerRadius, style: .continuous)
                                    .fill(ListeningIntentCard.neutralSurface)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: ListeningIntentTile.minHeight)
                            }
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    Self.lastGridWidth = width
                    if abs(width - gridWidth) > 0.5 { gridWidth = width }
                }
                .padding(.horizontal, horizontalInset)
            case .carousel(let rows, _):
                // 和真卡片一样放进横向滚动区:几张定宽卡片直接排在 HStack 里会比手机屏幕宽,
                // 冷启动时把整页撑宽、左右一起被裁。行数也照真卡片,换上来时高度不跳。
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(
                        rows: Array(
                            repeating: GridItem(.fixed(ListeningIntentCard.size.height), spacing: 10),
                            count: max(1, rows)
                        ),
                        spacing: 10
                    ) {
                        ForEach(0..<(4 * max(1, rows)), id: \.self) { _ in
                            RoundedRectangle(cornerRadius: ListeningIntentCard.cornerRadius, style: .continuous)
                                .fill(ListeningIntentCard.neutralSurface)
                                .frame(width: ListeningIntentCard.size.width, height: ListeningIntentCard.size.height)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, 2)
                }
                .scrollDisabled(true)
                .scrollClipDisabled(horizontalInset == 0)
            }
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
            Self.surface(tint: tint, cornerRadius: Self.cornerRadius)
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .opacity(isDimmed ? 0.42 : 1)
    }

    /// 黑底上叠主题色渐变:浅色、深色外观下都是同一种偏深的颜色,白字始终看得清。
    static func surface(tint: Color, cornerRadius: CGFloat) -> some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: [tint, tint.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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

/// 不懒加载的等宽网格:卡片只有几十张,直接一行行排好。懒加载网格嵌在首页的滚动视图里,
/// 展开、收起带动画改变高度之后会算错可见区域,卡片不再渲染,留下一片空白。
struct ListeningIntentEagerGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let columns: Int
    let spacing: CGFloat
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        let columns = max(1, columns)
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                let end = min(start + columns, items.count)
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(items[start..<end]) { item in
                        content(item)
                            .frame(maxWidth: .infinity)
                    }
                    // 最后一行不满时补空位,卡片宽度和上面几行一样。
                    ForEach(0..<(columns - (end - start)), id: \.self) { _ in
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: 0)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }
}

/// 铺开时的一格:左边图标,右边名字和曲数,撑满列宽。底色与横排卡片同一套。
struct ListeningIntentTile: View {
    static let minHeight: CGFloat = 56
    static let cornerRadius: CGFloat = 12

    let title: String
    let symbolName: String
    let detail: String?
    let tint: Color
    var badgeSymbol: String? = nil
    var isWorking = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.18))
                if isWorking {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: symbolName)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let detail {
                    Text(verbatim: detail)
                        .font(.caption2)
                        .monospacedDigit()
                        .opacity(0.82)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let badgeSymbol {
                Image(systemName: badgeSymbol)
                    .font(.caption2.weight(.semibold))
                    .opacity(0.9)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .leading)
        .background {
            ListeningIntentCard.surface(tint: tint, cornerRadius: Self.cornerRadius)
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
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

    /// 页面内容宽度,定列数用。
    @State private var contentWidth: CGFloat = 0
    private static let tileSpacing: CGFloat = 12

    private var columns: Int {
        ListeningIntentShelfPolicy.gridColumns(
            width: Double(contentWidth),
            spacing: Double(Self.tileSpacing),
            minimumTileWidth: 132
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                #if os(macOS)
                if let onBack { macHeader(onBack: onBack) }
                #endif
                let sections = service.pageSections
                let hasPersonal = sections.contains { $0.kind == .personal }
                if !hasPersonal, !sections.contains(where: { $0.kind == .pinned }) {
                    emptyPersonalSection
                }
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(LocalizedStringKey(section.titleKey))
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        ListeningIntentEagerGrid(items: section.items, columns: columns, spacing: Self.tileSpacing) { item in
                            tile(item, inPinned: section.kind == .pinned)
                        }
                        if section.kind == .personal {
                            PersonalIntentsFooter()
                        }
                    }
                    if section.kind == .pinned, !hasPersonal {
                        emptyPersonalSection
                    }
                }
                Text("listening_intent_page_footer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if abs(width - contentWidth) > 0.5 { contentWidth = width }
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

    /// 还没有「为你」意图时也留着这一块:说清楚它从哪来,开关也在这里。
    private var emptyPersonalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("listening_intent_group_personal")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("listening_intent_personal_empty")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PersonalIntentsFooter()
        }
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
                badgeSymbol: item.isHidden ? "eye.slash" : item.badgeSymbol,
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

/// 「为你」底下那行:谁整理的(AI 还是本机规则)、开关、重新整理。
struct PersonalIntentsFooter: View {
    private var service: ListeningIntentService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: statusSymbol)
                    .font(.footnote)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(verbatim: statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Toggle(isOn: Binding(
                    get: { service.isAICurationEnabled },
                    set: { enabled in pmWithAnimation(.list) { service.setAICurationEnabled(enabled) } }
                )) {
                    Text("listening_intent_ai_toggle")
                        .font(.footnote.weight(.semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("listeningIntents.aiToggle")
                Spacer(minLength: 0)
                if service.isAICurationEnabled, service.canCurateWithAI {
                    Button {
                        service.recurate()
                    } label: {
                        Label("listening_intent_ai_refresh", systemImage: "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .disabled(service.curationStatus == .working)
                    .accessibilityIdentifier("listeningIntents.recurate")
                }
            }
        }
        .padding(.top, 2)
    }

    private var statusSymbol: String {
        switch service.curationStatus {
        case .curated, .working: "sparkles"
        case .off, .local, .unavailable: "person.crop.circle"
        }
    }

    private var statusText: String {
        switch service.curationStatus {
        case .off, .local:
            String(localized: "listening_intent_ai_status_local")
        case .working:
            String(localized: "listening_intent_ai_status_working")
        case .curated(let provider, _):
            String(format: String(localized: "listening_intent_ai_status_curated %@"), provider)
        case .unavailable:
            String(localized: "listening_intent_ai_status_unavailable")
        }
    }
}

extension ListeningIntentShelfItem {
    /// 钉选的显示图钉;AI 整理出来的显示一点星光。
    var badgeSymbol: String? {
        if isPinned { return "pin.fill" }
        if intent.isAICurated == true { return "sparkles" }
        return nil
    }
}

/// 首页编辑里「开始听」那条操作条上的管理按钮:就是「全部意图」整页,多一个「完成」。
/// 在这里钉选、隐藏、挪位置,首页那一块跟着变。
struct ListeningIntentsManagementSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ListeningIntentsPage()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
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
        // 停用或重新启用音乐源时重新列一遍,停用的源里的歌不留在这里。
        .task(id: "\(intent.id)|\(library.disabledSourceIDs.sorted())") {
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
