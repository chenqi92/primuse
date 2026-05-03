import SwiftUI
import PrimuseKit

struct ScrapeOptionsView: View {
    let song: Song
    var onComplete: ((Song) -> Void)?
    /// macOS 独立窗口模式下,关闭走 NSWindow 自身的红灯而不是
    /// SwiftUI 的 .dismiss。callsite 注入这个闭包让 view 在 apply 完
    /// 之后能主动 close 宿主 window。sheet 模式下保持为 nil,view
    /// 自动 fallback 到 dismiss()。
    var onCloseRequest: (() -> Void)?

    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(SourceManager.self) private var sourceManager
    @Environment(\.dismiss) private var dismiss

    /// 关闭当前刮削视图 —— 优先走宿主注入的关闭回调 (window 红灯),
    /// 没有就回落到 SwiftUI 的环境 dismiss (sheet)。
    private func performClose() {
        if let onCloseRequest {
            onCloseRequest()
        } else {
            dismiss()
        }
    }

    @State private var mode: ScrapeMode = .options
    @State private var previewSource: ScrapeMode = .options
    @State private var scrapeMetadata = true
    @State private var scrapeCover = true
    @State private var scrapeLyrics = true
    @State private var isScraping = false
    @State private var previewResult: ScrapePreview?
    @State private var searchResults: [SearchResultItem] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var manualSearchQuery = ""
    /// 当前点了哪一条手动搜索结果。点完到 selectManualResult 完成 (跳到
    /// preview) 之间有 1~3 秒网络等待,锁住这个 id 来:
    ///   1) 在被点的 row 上画 ProgressView 提示进度
    ///   2) 阻止用户重复点其他 row
    @State private var loadingResultID: String?

    // Per-field apply toggles (for preview)
    @State private var applyTitle = true
    @State private var applyArtist = true
    @State private var applyAlbum = true
    @State private var applyYear = true
    @State private var applyGenre = true
    @State private var applyCover = true
    @State private var applyLyrics = true

    enum ScrapeMode {
        case options
        case preview
        case manual
    }

    struct ScrapePreview {
        var updatedSong: Song
        var coverData: Data?
        var lyricsCount: Int
        var lyricsLines: [LyricLine]?
        // Scraped values (always show these)
        var scrapedTitle: String?
        var scrapedArtist: String?
        var scrapedAlbum: String?
        var scrapedYear: Int?
        var scrapedGenre: String?
        var hasCover: Bool
        var hasLyrics: Bool
        var lyricsIsWordLevel: Bool { lyricsLines?.contains(where: { $0.isWordLevel }) ?? false }
    }

    struct SearchResultItem: Identifiable {
        let id: String
        let title: String
        let artist: String?
        let album: String?
        let durationMs: Int?
        let coverUrl: String?
        let externalId: String
        let sourceConfig: ScraperSourceConfig

        var source: String { sourceConfig.displayName }

        var durationText: String? {
            guard let ms = durationMs else { return nil }
            let s = ms / 1000
            return String(format: "%d:%02d", s / 60, s % 60)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    switch mode {
                    case .options: optionsView
                    case .preview: previewView
                    case .manual: manualSearchView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                bottomActionBar
            }
            .navigationTitle("scrape_song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        #if os(macOS)
        // 之前在 macOS 上裸 Form + 默认 sheet 大小,弹框被压成 ~520x420
        // 渲染歪斜（标题挤、checkbox 间距怪、自动刮削那一行变成全宽 row）。
        // 给 sheet 一个明确的 minSize,内容才能舒展开。
        .frame(minWidth: 520, idealWidth: 580, minHeight: 460, idealHeight: 540)
        #endif
    }

    /// macOS 上 (走 ScrapeWindowController) 关闭由 NSWindow 红灯负责,
    /// toolbar 不再放任何 X 按钮,iOS 端用 dismiss + xmark 兜底。
    /// macOS 下 toolbar 还需要一个 placeholder ToolbarItem 占位,
    /// 不然 ToolbarContentBuilder 认为整个 builder 空,result builder 报
    /// "expected expression of type 'Content'"。
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(macOS)
        // 占位 —— 实际不渲染任何按钮,关闭走 NSWindow 红灯。
        ToolbarItem(placement: .automatic) { Color.clear.frame(width: 0, height: 0) }
        #else
        ToolbarItem(placement: .cancellationAction) {
            Button {
                performClose()
            } label: {
                Image(systemName: "xmark")
            }
            .help(Text("close"))
            .keyboardShortcut(.cancelAction)
        }
        #endif
    }

    private var backButtonTitle: LocalizedStringKey {
        switch mode {
        case .options: return ""
        case .preview: return previewSource == .manual ? "back_to_results" : "back_to_options"
        case .manual: return "back_to_options"
        }
    }

    // MARK: - Bottom action bar

    /// 统一底部按钮栏,各级动作集中在这一行:
    ///   - 左: 返回 (非 options 级)
    ///   - 右: 当前级的主操作
    /// 这样无论第几级用户都能在同一位置找到完整的操作,不再需要切到
    /// toolbar 找按钮,也不会出现"取消/返回错位"的现象。
    @ViewBuilder
    private var bottomActionBar: some View {
        HStack(spacing: 10) {
            if mode != .options {
                Button {
                    switch mode {
                    case .preview:
                        mode = (previewSource == .manual) ? .manual : .options
                    case .manual:
                        mode = .options
                    case .options:
                        break
                    }
                } label: {
                    Label(backButtonTitle, systemImage: "chevron.backward")
                }
            }

            Spacer()

            switch mode {
            case .options:
                Button("manual_scrape") {
                    Task { await manualSearch() }
                }
                .disabled(isSearching || isScraping)

                Button("auto_scrape") {
                    Task { await autoScrape() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isScraping || isSearching || (!scrapeMetadata && !scrapeCover && !scrapeLyrics))

            case .preview:
                Button("apply_changes") { applySelectedChanges() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .fontWeight(.semibold)
                    .disabled(!hasAnySelectedChange)

            case .manual:
                EmptyView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Options (what to scrape)

    private var optionsView: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: 56, cornerRadius: 8, sourceID: song.sourceID, filePath: song.filePath)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title).font(.subheadline).fontWeight(.semibold).lineLimit(1)
                        Text(song.artistName ?? "").font(.caption).foregroundStyle(Color.secondary).lineLimit(1)
                        if song.duration.sanitizedDuration > 0 {
                            Text(formatDuration(song.duration)).font(.caption2).foregroundStyle(Color.secondary.opacity(0.7))
                        }
                    }
                    Spacer()
                    if isScraping || isSearching {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            Section("scrape_options") {
                Toggle("scrape_metadata_toggle", isOn: $scrapeMetadata)
                Toggle("scrape_cover_toggle", isOn: $scrapeCover)
                Toggle("scrape_lyrics_toggle", isOn: $scrapeLyrics)
            }

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    // MARK: - Preview (confirm before applying)

    private var previewView: some View {
        Form {
            if let preview = previewResult {
                // Always show all scraped fields
                Section("select_changes") {
                    // Title
                    fieldToggle(
                        isOn: $applyTitle,
                        label: "title",
                        localValue: song.title,
                        scrapedValue: preview.scrapedTitle,
                        isChanged: preview.scrapedTitle != nil && preview.scrapedTitle != song.title
                    )

                    // Artist
                    fieldToggle(
                        isOn: $applyArtist,
                        label: "artist",
                        localValue: song.artistName ?? "-",
                        scrapedValue: preview.scrapedArtist,
                        isChanged: preview.scrapedArtist != nil && preview.scrapedArtist != song.artistName
                    )

                    // Album
                    fieldToggle(
                        isOn: $applyAlbum,
                        label: "album",
                        localValue: song.albumTitle ?? "-",
                        scrapedValue: preview.scrapedAlbum,
                        isChanged: preview.scrapedAlbum != nil && preview.scrapedAlbum != song.albumTitle
                    )

                    // Year
                    fieldToggle(
                        isOn: $applyYear,
                        label: "year",
                        localValue: song.year.map { "\($0)" } ?? "-",
                        scrapedValue: preview.scrapedYear.map { "\($0)" },
                        isChanged: preview.scrapedYear != nil && preview.scrapedYear != song.year
                    )

                    // Genre
                    fieldToggle(
                        isOn: $applyGenre,
                        label: "genre",
                        localValue: song.genre ?? "-",
                        scrapedValue: preview.scrapedGenre,
                        isChanged: preview.scrapedGenre != nil && preview.scrapedGenre != song.genre
                    )

                    // Cover — show thumbnails for comparison
                    if preview.hasCover {
                        Toggle(isOn: $applyCover) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("cover").font(.caption).foregroundStyle(Color.secondary)
                                HStack(spacing: 8) {
                                    // Current cover
                                    VStack(spacing: 2) {
                                        CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: 56, cornerRadius: 6, sourceID: song.sourceID, filePath: song.filePath)
                                        Text("current").font(.system(size: 9)).foregroundStyle(.secondary)
                                    }
                                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                    // New cover (from in-memory data)
                                    VStack(spacing: 2) {
                                        if let data = preview.coverData, let img = PlatformImage(data: data) {
                                            Image(platformImage: img)
                                                .resizable().aspectRatio(contentMode: .fill)
                                                .frame(width: 56, height: 56)
                                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                        } else {
                                            CachedArtworkView(coverRef: preview.updatedSong.coverArtFileName, songID: preview.updatedSong.id, size: 56, cornerRadius: 6, sourceID: song.sourceID, filePath: song.filePath)
                                        }
                                        Text("new").font(.system(size: 9)).foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }

                    // Lyrics
                    if preview.hasLyrics {
                        Toggle(isOn: $applyLyrics) {
                            HStack(spacing: 6) {
                                Text("lyrics_word").font(.caption).foregroundStyle(Color.secondary).frame(width: 45, alignment: .leading)
                                statusBadge(hasLocal: song.lyricsFileName != nil, hasScraped: true,
                                            isChanged: preview.updatedSong.lyricsFileName != song.lyricsFileName)
                                if preview.lyricsCount > 0 {
                                    Text("(\(preview.lyricsCount))").font(.caption2).foregroundStyle(.secondary)
                                }
                                if preview.lyricsIsWordLevel {
                                    HStack(spacing: 2) {
                                        Image(systemName: "waveform").font(.system(size: 9))
                                        Text("lyrics_word_level_badge").font(.system(size: 10, weight: .semibold))
                                    }
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                }
                            }
                        }
                    }

                    if !hasAnyScrapeResult(preview) {
                        Label(String(localized: "scrape_no_changes"), systemImage: "info.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    @ViewBuilder
    private func fieldToggle(isOn: Binding<Bool>, label: LocalizedStringKey, localValue: String, scrapedValue: String?, isChanged: Bool) -> some View {
        if let scraped = scrapedValue {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundStyle(Color.secondary)
                    if isChanged {
                        HStack(spacing: 4) {
                            Text(localValue).font(.caption2).foregroundStyle(Color.secondary).lineLimit(1)
                            Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(Color.secondary.opacity(0.7))
                            Text(scraped).font(.caption2).fontWeight(.medium).foregroundStyle(.green).lineLimit(1)
                        }
                    } else {
                        Text(scraped).font(.caption2).foregroundStyle(.primary).lineLimit(1)
                    }
                }
            }
            .tint(isChanged ? .green : Color.secondary)
        }
    }

    @ViewBuilder
    private func statusBadge(hasLocal: Bool, hasScraped: Bool, isChanged: Bool) -> some View {
        if isChanged {
            HStack(spacing: 3) {
                Image(systemName: hasLocal ? "checkmark" : "xmark")
                    .font(.caption2).foregroundStyle(Color.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8)).foregroundStyle(Color.secondary.opacity(0.7))
                Image(systemName: "checkmark")
                    .font(.caption2).foregroundStyle(.green)
            }
        } else {
            Text(String(localized: "unchanged")).font(.caption2).foregroundStyle(Color.secondary.opacity(0.7))
        }
    }

    private func hasAnyScrapeResult(_ p: ScrapePreview) -> Bool {
        p.scrapedTitle != nil || p.scrapedArtist != nil || p.scrapedAlbum != nil ||
        p.scrapedYear != nil || p.scrapedGenre != nil || p.hasCover || p.hasLyrics
    }

    private var hasAnySelectedChange: Bool {
        guard let p = previewResult else { return false }
        let titleChanged = p.scrapedTitle != nil && p.scrapedTitle != song.title
        let artistChanged = p.scrapedArtist != nil && p.scrapedArtist != song.artistName
        let albumChanged = p.scrapedAlbum != nil && p.scrapedAlbum != song.albumTitle
        let yearChanged = p.scrapedYear != nil && p.scrapedYear != song.year
        let genreChanged = p.scrapedGenre != nil && p.scrapedGenre != song.genre

        return (titleChanged && applyTitle) || (artistChanged && applyArtist) ||
               (albumChanged && applyAlbum) || (yearChanged && applyYear) ||
               (genreChanged && applyGenre) || (p.hasCover && applyCover) ||
               (p.hasLyrics && applyLyrics)
    }

    // MARK: - Manual Search

    private var manualSearchView: some View {
        // 之前在 List 上挂 .searchable,macOS 下系统会把搜索框塞进
        // window 的 titlebar,跟 .navigationTitle 大标题分到上下两层,
        // 视觉上"标题/搜索框上下错位"。改成在 List 上方内嵌一个手写的
        // 搜索栏:跟 list 一起垂直排列,标题归标题、搜索归内容,layout
        // 跟 macOS 26 / iOS 26 原生 sheet 风格一致。
        VStack(spacing: 0) {
            inlineSearchField
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)

            List {
                if searchResults.isEmpty && !isSearching {
                    ContentUnavailableView("no_results", systemImage: "magnifyingglass",
                        description: Text("no_scrape_results_desc"))
                } else {
                    ForEach(searchResults) { item in
                        Button {
                            // 立刻锁住 row id 让 UI 出反馈;loadingResultID
                            // 在 selectManualResult 里清掉。
                            loadingResultID = item.id
                            Task { await selectManualResult(item) }
                        } label: {
                            HStack(spacing: 10) {
                                ScraperCoverThumbnail(
                                    urlString: item.coverUrl,
                                    externalId: item.externalId,
                                    sourceConfig: item.sourceConfig
                                )

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.title).font(.subheadline).fontWeight(.medium).lineLimit(1)
                                        Spacer()
                                        if loadingResultID == item.id {
                                            ProgressView().controlSize(.small)
                                        } else if let dur = item.durationText {
                                            Text(dur).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                        }
                                    }
                                    HStack(spacing: 4) {
                                        if let artist = item.artist {
                                            Text(artist).font(.caption).foregroundStyle(Color.secondary)
                                        }
                                        if let album = item.album {
                                            Text("·").font(.caption).foregroundStyle(Color.secondary.opacity(0.7))
                                            Text(album).font(.caption).foregroundStyle(Color.secondary.opacity(0.7))
                                        }
                                    }
                                    .lineLimit(1)
                                    HStack(spacing: 4) {
                                        Text(item.source).font(.caption2).foregroundStyle(.green)
                                        if item.sourceConfig.type.supportsWordLevelLyrics {
                                            HStack(spacing: 2) {
                                                Image(systemName: "waveform").font(.system(size: 8))
                                                Text("lyrics_word_level_badge")
                                                    .font(.system(size: 9, weight: .semibold))
                                            }
                                            .foregroundStyle(item.sourceConfig.type.themeColor)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Capsule().fill(item.sourceConfig.type.themeColor.opacity(0.15)))
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            // 当前正在加载的 row 高亮 + 其他 row 半透明,
                            // 让用户清楚"点击已生效,后台在跑"。
                            .opacity(loadingResultID == nil || loadingResultID == item.id ? 1 : 0.5)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.visible)
                        // 任何 row 在 loading 时整个 list 不接受点击,防止
                        // 重复触发 selectManualResult。
                        .disabled(loadingResultID != nil)
                    }
                    .disabled(isScraping)
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #endif
            .overlay {
                if isSearching {
                    ProgressView("searching").padding()
                }
            }
        }
    }

    /// 手写的搜索栏 —— 用 TextField + capsule 背景而不是 .searchable,
    /// 因为后者在 macOS 上会被系统挪进 titlebar,跟 navigationTitle 分两行。
    private var inlineSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "search_query"), text: $manualSearchQuery)
                .textFieldStyle(.plain)
                .onSubmit {
                    Task { await performManualSearch() }
                }
            if !manualSearchQuery.isEmpty {
                Button { manualSearchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.secondary, in: .capsule)
    }

    // MARK: - Logic

    private func autoScrape() async {
        isScraping = true
        errorMessage = nil

        do {
            let (updated, coverData, lyricsLines) = try await scraperService.scrapeSingle(song: song, in: library, dryRun: true)
            isScraping = false

            let lyricsCount = lyricsLines?.count ?? 0

            previewResult = ScrapePreview(
                updatedSong: updated, coverData: coverData, lyricsCount: lyricsCount,
                lyricsLines: lyricsLines,
                scrapedTitle: updated.title != song.title ? updated.title : updated.title,
                scrapedArtist: updated.artistName,
                scrapedAlbum: updated.albumTitle,
                scrapedYear: updated.year,
                scrapedGenre: updated.genre,
                hasCover: coverData != nil,
                hasLyrics: lyricsLines != nil && !lyricsLines!.isEmpty
            )

            // Default all toggles to on for changed fields, off for unchanged
            applyTitle = updated.title != song.title
            applyArtist = updated.artistName != song.artistName
            applyAlbum = updated.albumTitle != song.albumTitle
            applyYear = updated.year != song.year && updated.year != nil
            applyGenre = updated.genre != song.genre && updated.genre != nil
            applyCover = true
            applyLyrics = true

            previewSource = .options
            mode = .preview
        } catch {
            isScraping = false
            errorMessage = error.localizedDescription
        }
    }

    private func manualSearch() async {
        manualSearchQuery = ScraperManager.searchTitle(song.title, artist: song.artistName)
        if let artist = song.artistName,
           !artist.isEmpty,
           ScraperManager.shouldAppendArtist(to: manualSearchQuery, artist: artist) {
            manualSearchQuery += " \(artist)"
        }
        mode = .manual
        await performManualSearch()
    }

    private func performManualSearch() async {
        isSearching = true
        searchResults = []
        errorMessage = nil
        var aggregatedResults: [SearchResultItem] = []

        let settings = ScraperSettings.load()
        plog("🔍 Manual search query='\(manualSearchQuery)' enabled sources: \(settings.enabledSources.map { $0.type.rawValue })")

        for config in settings.enabledSources {
            guard canUseSourceInManualSearch(config) else { continue }
            do {
                let scraper = MusicScraperFactory.create(for: config)
                let result = try await scraper.search(
                    query: manualSearchQuery, artist: nil, album: nil, limit: 30
                )
                for item in result.items {
                    plog("🔍 Search result: \(config.type.rawValue) '\(item.title)' coverUrl=\(item.coverUrl ?? "nil")")
                    aggregatedResults.append(SearchResultItem(
                        id: "\(config.type.rawValue)_\(item.externalId)",
                        title: item.title,
                        artist: item.artist,
                        album: item.album,
                        durationMs: item.durationMs,
                        coverUrl: item.coverUrl,
                        externalId: item.externalId,
                        sourceConfig: config
                    ))
                }
            } catch {
                plog("⚠️ Search failed for \(config.type.rawValue): \(ConfigurableScraper.describeNetworkError(error))")
            }
        }

        // Sort by duration match
        if song.duration.sanitizedDuration > 0 {
            let targetMs = Int((song.duration.sanitizedDuration * 1000).rounded(.down))
            aggregatedResults.sort { a, b in
                let diffA = abs((a.durationMs ?? 0) - targetMs)
                let diffB = abs((b.durationMs ?? 0) - targetMs)
                return diffA < diffB
            }
        }

        searchResults = aggregatedResults
        isSearching = false
        mode = .manual
    }

    private func selectManualResult(_ item: SearchResultItem) async {
        isScraping = true
        // 整个流程结束 (success / fail) 都要解锁 row,defer 兜底。
        defer {
            isScraping = false
            loadingResultID = nil
        }

        do {
            let scraper = MusicScraperFactory.create(for: item.sourceConfig)

            // detail 必须先拿到才知道最终 coverUrl,但 lyrics 可以跟 detail
            // 并行,缩短一截网络等待。等 detail 回来后再启 cover 下载,
            // cover 跟 lyrics 也并行。整体从 N1+N2+N3 串行变成 N1 + max(N2,N3)。
            async let lyricsTask: ScraperLyricsResult? = (try? await scraper.getLyrics(externalId: item.externalId))
            let detail = try await scraper.getDetail(externalId: item.externalId)

            var updated = song
            if let detail {
                updated = Song(
                    id: song.id, title: detail.title,
                    albumID: song.albumID, artistID: song.artistID,
                    albumTitle: detail.album ?? song.albumTitle,
                    artistName: detail.artist ?? song.artistName,
                    trackNumber: detail.trackNumber ?? song.trackNumber,
                    discNumber: detail.discNumber ?? song.discNumber,
                    duration: song.duration, fileFormat: song.fileFormat,
                    filePath: song.filePath, sourceID: song.sourceID,
                    fileSize: song.fileSize, bitRate: song.bitRate,
                    sampleRate: song.sampleRate, bitDepth: song.bitDepth,
                    genre: detail.genres?.prefix(3).joined(separator: ", ") ?? song.genre,
                    year: detail.year ?? song.year,
                    dateAdded: song.dateAdded,
                    coverArtFileName: song.coverArtFileName,
                    lyricsFileName: song.lyricsFileName,
                    revision: song.revision
                )
            }

            // 用 detail 的 coverUrl,fallback 到 search result 的 coverUrl。
            let coverUrl = detail?.coverUrl ?? item.coverUrl
            async let coverTask: Data? = {
                guard let coverUrl else { return nil }
                return try? await ConfigurableScraper.downloadResource(
                    from: coverUrl,
                    sourceConfig: item.sourceConfig,
                    timeout: 10
                )
            }()

            let coverData = await coverTask
            let hasCover = coverData != nil

            // Lyrics
            var hasLyrics = false
            var lyricsCount = 0
            var lyricsLines: [LyricLine]?
            if let lyricsResult = await lyricsTask,
               lyricsResult.hasLyrics,
               let lrc = lyricsResult.lrcContent, !lrc.isEmpty {
                let parsed = LyricsParser.parse(lrc)
                if !parsed.isEmpty {
                    lyricsLines = parsed
                    hasLyrics = true
                    lyricsCount = parsed.count
                }
            }

            previewResult = ScrapePreview(
                updatedSong: updated, coverData: coverData, lyricsCount: lyricsCount,
                lyricsLines: lyricsLines,
                scrapedTitle: updated.title,
                scrapedArtist: updated.artistName,
                scrapedAlbum: updated.albumTitle,
                scrapedYear: updated.year,
                scrapedGenre: updated.genre,
                hasCover: hasCover,
                hasLyrics: hasLyrics
            )
            applyTitle = updated.title != song.title
            applyArtist = updated.artistName != song.artistName
            applyAlbum = updated.albumTitle != song.albumTitle
            applyYear = updated.year != song.year && updated.year != nil
            applyGenre = updated.genre != song.genre && updated.genre != nil
            applyCover = hasCover
            applyLyrics = hasLyrics
            previewSource = .manual
            mode = .preview
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applySelectedChanges() {
        guard let preview = previewResult else { return }
        let u = preview.updatedSong

        let titleChanged = preview.scrapedTitle != nil && preview.scrapedTitle != song.title
        let artistChanged = preview.scrapedArtist != nil && preview.scrapedArtist != song.artistName
        let albumChanged = preview.scrapedAlbum != nil && preview.scrapedAlbum != song.albumTitle
        let yearChanged = preview.scrapedYear != nil && preview.scrapedYear != song.year
        let genreChanged = preview.scrapedGenre != nil && preview.scrapedGenre != song.genre

        // Store cover and lyrics to disk NOW (only on apply, not during preview)
        var coverFileName = song.coverArtFileName
        var lyricsFileName = song.lyricsFileName

        if preview.hasCover && applyCover, let data = preview.coverData {
            Task {
                if let name = await MetadataAssetStore.shared.storeCover(data, for: song.id) {
                    coverFileName = name
                }
            }
            // Synchronous fallback: generate expected filename
            coverFileName = MetadataAssetStore.shared.expectedCoverFileName(for: song.id)
            // Store synchronously for immediate availability
            MetadataAssetStore.shared.storeCoverSync(data, for: song.id)
            // Invalidate memory cache so UI picks up the new cover
            CachedArtworkView.invalidateCache(for: coverFileName!)
        }

        if preview.hasLyrics && applyLyrics, let lines = preview.lyricsLines {
            MetadataAssetStore.shared.storeLyricsSync(lines, for: song.id)
            lyricsFileName = MetadataAssetStore.shared.expectedLyricsFileName(for: song.id)
        }

        // Build final song with only selected changes applied
        let final = Song(
            id: song.id,
            title: (titleChanged && applyTitle) ? u.title : song.title,
            albumID: song.albumID, artistID: song.artistID,
            albumTitle: (albumChanged && applyAlbum) ? u.albumTitle : song.albumTitle,
            artistName: (artistChanged && applyArtist) ? u.artistName : song.artistName,
            trackNumber: u.trackNumber ?? song.trackNumber,
            discNumber: u.discNumber ?? song.discNumber,
            duration: u.duration > 0 ? u.duration : song.duration,
            fileFormat: song.fileFormat,
            filePath: song.filePath, sourceID: song.sourceID,
            fileSize: song.fileSize,
            bitRate: u.bitRate ?? song.bitRate,
            sampleRate: u.sampleRate ?? song.sampleRate,
            bitDepth: u.bitDepth ?? song.bitDepth,
            genre: (genreChanged && applyGenre) ? u.genre : song.genre,
            year: (yearChanged && applyYear) ? u.year : song.year,
            dateAdded: song.dateAdded,
            coverArtFileName: coverFileName,
            lyricsFileName: lyricsFileName,
            revision: song.revision
        )

        library.replaceSong(final)

        // Write sidecar files (cover.jpg, .lrc) back to NAS source
        let coverDataToWrite = (preview.hasCover && applyCover) ? preview.coverData : nil
        let lyricsToWrite = (preview.hasLyrics && applyLyrics) ? preview.lyricsLines : nil
        if coverDataToWrite != nil || lyricsToWrite != nil {
            let songForWrite = final
            let songID = final.id
            let sm = sourceManager
            let lib = library
            Task { @MainActor in
                do {
                    plog("📝 Sidecar: writing back to source for '\(songForWrite.title)'")
                    let connector = try await sm.auxiliaryConnector(for: songForWrite)
                    let writeResult = await SidecarWriteService.shared.writeSidecars(
                        for: songForWrite, using: connector,
                        coverData: coverDataToWrite, lyricsLines: lyricsToWrite
                    )
                    plog("📝 Sidecar: result cover=\(writeResult.coverWritten) lyrics=\(writeResult.lyricsWritten)")

                    let songDir = (songForWrite.filePath as NSString).deletingLastPathComponent
                    let baseNameNoExt = ((songForWrite.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
                    var refSong = songForWrite
                    var needsUpdate = false

                    if writeResult.coverWritten {
                        let coverPath = (songDir as NSString).appendingPathComponent("\(baseNameNoExt)-cover.jpg")
                        refSong.coverArtFileName = coverPath
                        await MetadataAssetStore.shared.invalidateCoverCache(forSongID: songID)
                        needsUpdate = true
                    }
                    if writeResult.lyricsWritten {
                        let lrcPath = (songDir as NSString).appendingPathComponent("\(baseNameNoExt).lrc")
                        refSong.lyricsFileName = lrcPath
                        needsUpdate = true
                    }
                    if needsUpdate {
                        lib.replaceSong(refSong)
                    }
                    if !writeResult.errors.isEmpty {
                        plog("⚠️ Sidecar write errors: \(writeResult.errors)")
                    }
                } catch {
                    plog("⚠️ Sidecar write failed for '\(songForWrite.title)': \(error.localizedDescription)")
                }
            }
        }

        onComplete?(final)
        performClose()
    }

    // MARK: - Helpers

    private func formatDuration(_ t: TimeInterval) -> String {
        t.formattedDuration
    }

    private func canUseSourceInManualSearch(_ sourceConfig: ScraperSourceConfig) -> Bool {
        switch sourceConfig.type {
        case .custom(let configID):
            guard let config = ScraperConfigStore.shared.config(for: configID) else {
                plog("⚠️ Manual search skipping \(sourceConfig.type.rawValue): config '\(configID)' not found")
                return false
            }
            let canSearch = config.search != nil
            if !canSearch {
                plog("⚠️ Manual search skipping \(sourceConfig.type.rawValue): search endpoint missing")
            }
            return canSearch
        default:
            return sourceConfig.type.supportsMetadata
        }
    }
}

// MARK: - Scraper Cover Thumbnail

/// Loads cover thumbnails through the same config-aware request path as manual scraping.
private struct ScraperCoverThumbnail: View {
    let urlString: String?
    let externalId: String
    let sourceConfig: ScraperSourceConfig

    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "music.note").font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: "\(sourceConfig.id)|\(urlString ?? "")") {
            image = nil
            let resolvedURL = await resolveThumbnailURL()
            guard let resolvedURL, !resolvedURL.isEmpty else { return }

            if let data = try? await ConfigurableScraper.downloadResource(
                from: resolvedURL,
                sourceConfig: sourceConfig,
                timeout: 10
            ),
               let loaded = PlatformImage(data: data) {
                image = loaded
            }
        }
    }

    private func resolveThumbnailURL() async -> String? {
        if let urlString, !urlString.isEmpty {
            return urlString
        }

        let scraper = MusicScraperFactory.create(for: sourceConfig)
        if let cover = try? await scraper.getCoverArt(externalId: externalId).first {
            let fallbackURL = cover.thumbnailUrl ?? cover.coverUrl
            plog("🖼️ Thumbnail fallback via getCoverArt for \(sourceConfig.type.rawValue): \(fallbackURL)")
            return fallbackURL
        }

        if let detail = try? await scraper.getDetail(externalId: externalId),
           let fallbackURL = detail.coverUrl {
            plog("🖼️ Thumbnail fallback via getDetail for \(sourceConfig.type.rawValue): \(fallbackURL)")
            return fallbackURL
        }

        return nil
    }
}
