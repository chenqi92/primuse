import SwiftUI
import ImageIO
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ScrapeContentPreferences: DynamicProperty {
    @AppStorage private var storedParts: ScrapeParts

    init(defaults: UserDefaults? = nil) {
        _storedParts = AppStorage(wrappedValue: .all, "singleSongScrapeParts", store: defaults)
    }

    var parts: ScrapeParts { storedParts }

    func binding(for part: ScrapeParts) -> Binding<Bool> {
        Binding(
            get: { storedParts.contains(part) },
            set: { enabled in
                if enabled {
                    storedParts.insert(part)
                } else {
                    storedParts.remove(part)
                }
            }
        )
    }
}

@MainActor
@Observable
final class ScrapeOptionsTask {
    private var operationID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { operationID != nil }

    @discardableResult
    func start(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        cancel()
        let id = UUID()
        operationID = id
        let task = Task { @MainActor [weak self] in
            defer {
                // A cancelled request may finish after its replacement has started.
                if self?.operationID == id { self?.finish() }
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
        self.task = task
        return task
    }

    func cancel() {
        let pendingTask = task
        finish()
        pendingTask?.cancel()
    }

    func finish() {
        operationID = nil
        task = nil
    }
}

@MainActor
final class ScrapeReviewWindowActions {
    var request: ((@escaping () -> Void) -> Void)?
}

/// 一次结果页搜索用的刮哪几项、每个来源几条。
private struct ScrapeSearchScope: Equatable {
    let parts: ScrapeParts
    let limit: Int
}

/// 单曲刮削的入口为什么开不了。入口不置灰到点不动，点了用它说明原因、给去处。
private enum ScrapeEntryBlocker: Hashable {
    /// 标签、封面、歌词一项都没选。
    case noParts
    /// 选的这几项没有开着的刮削源。
    case noSource
    /// 自动刮削按规则走，选的这几项在刮削规则里都设成了「跳过」。
    case rulesSkipAll

    var title: LocalizedStringKey {
        switch self {
        case .noParts: "scrape_options"
        case .noSource: "scraper_no_source_title"
        case .rulesSkipAll: "auto_scrape"
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .noParts: "scrape_review_no_parts_message"
        case .noSource: "scraper_no_source_message"
        case .rulesSkipAll: "scrape_review_rules_skip_message"
        }
    }
}

struct ScrapeOptionsView: View {
    let song: Song
    var onComplete: ((Song) -> Void)?
    var onCloseRequest: (() -> Void)? = nil
    var windowActions: ScrapeReviewWindowActions? = nil

    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openScraperSettings) private var openScraperSettings
    private var contentPreferences = ScrapeContentPreferences()
    @AppStorage("scraperSearchLimit") private var searchLimit = 20
    @State private var draft: ScrapeReviewDraft?
    @State private var images = ScrapeReviewImages()
    @State private var showingReview = false
    @State private var query = ""
    @State private var searchTask = ScrapeOptionsTask()
    @State private var automaticID: UUID?
    @State private var showsDiscard = false
    @State private var pendingDiscard: (() -> Void)?
    @State private var errorMessage: String?
    @State private var blocker: ScrapeEntryBlocker?
    @State private var showsRules = false
    /// 结果页这份草稿是按哪几项、每个来源几条搜的；回选项页改了再回来就按新设置重搜。
    @State private var draftScope: ScrapeSearchScope?
    #if os(macOS)
    @State private var macDisplayTitle: String?
    @State private var macSidecarBaseNameOverride: String?
    @State private var macUsesMediaServerWriteback = false
    @State private var macSupportsSidecarWriteback = false
    @State private var macCoverEmbeddingMode: CoverEmbeddingMode = .off
    #endif

    private var parts: ScrapeParts { contentPreferences.parts }
    private var currentScope: ScrapeSearchScope { ScrapeSearchScope(parts: parts, limit: searchLimit) }
    private var loading: Bool { searchTask.isRunning || automaticID != nil }
    private var busy: Bool { loading }

    /// 手动搜索(结果页的搜索)为什么开不了：一项都没选，或者这几项没有开着的刮削源。
    /// 刮削规则里的「跳过」不拦它，结果页只是不预选那几项。
    private var manualBlocker: ScrapeEntryBlocker? {
        if parts.isEmpty { return .noParts }
        if scraperSettings.userRequestedSourceCount(for: parts) == 0 { return .noSource }
        return nil
    }

    /// 自动刮削按刮削规则走：要刮的几项在规则里都设成「跳过」时它开不了。
    private var automaticBlocker: ScrapeEntryBlocker? {
        if let manualBlocker { return manualBlocker }
        return scraperSettings.gateSourceCount(for: parts) == 0 ? .rulesSkipAll : nil
    }

    var body: some View {
        screen
            .onAppear { windowActions?.request = { action in protect(action) } }
            .task {
                let title = await scraperService.suggestedScrapeTitle(for: song)
                guard !Task.isCancelled else { return }
                if query.isEmpty { query = MusicScraperService.searchQuery(title: title, artist: song.artistName) }
                consumeAutomatic()
                #if os(macOS)
                macDisplayTitle = title
                macSidecarBaseNameOverride = await scraperService.suggestedSidecarBaseName(for: song)
                macUsesMediaServerWriteback = await sourceManager.supportsMediaServerWriteback(for: song)
                macSupportsSidecarWriteback = await sourceManager.supportsSidecarWriting(for: song)
                macCoverEmbeddingMode = await sourceManager.coverEmbeddingMode(for: song)
                if !showingReview && !Task.isCancelled { startInitialMacSearch() }
                #endif
            }
            .interactiveDismissDisabled(showingReview || busy)
            .onChange(of: scraperService.singleScrapeCompletionRevision) { _, _ in consumeAutomatic() }
            .onDisappear {
                searchTask.cancel()
                windowActions?.request = nil
            }
            .alert("lyrics_sources_discard_title", isPresented: $showsDiscard) {
                Button("lyrics_editor_keep_editing", role: .cancel) { pendingDiscard = nil }
                Button("lyrics_sources_discard", role: .destructive) {
                    let action = pendingDiscard
                    pendingDiscard = nil
                    action?()
                }
            }
            .alert("scrape_song_failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("ok", role: .cancel) { errorMessage = nil }
            } message: { Text(verbatim: errorMessage ?? "") }
            .alert(blocker?.title ?? "", isPresented: Binding(get: { blocker != nil }, set: { if !$0 { blocker = nil } }),
                   presenting: blocker) { reason in
                blockerActions(reason)
            } message: { reason in
                Text(reason.message)
            }
            .sheet(isPresented: $showsRules) { ScrapeRulesEditor(settings: scraperSettings) }
    }

    /// 入口开不了时点了说明原因，并给一键解决的去处。
    @ViewBuilder private func blockerActions(_ reason: ScrapeEntryBlocker) -> some View {
        switch reason {
        case .noParts:
            Button("ok", role: .cancel) {}
        case .noSource:
            Button("scraper_no_source_open_settings") { openSourceSettings() }
            Button("cancel", role: .cancel) {}
        case .rulesSkipAll:
            Button("scrape_field_rules") { showsRules = true }
            if manualBlocker == nil {
                Button("manual_scrape") { startSearch() }
            }
            Button("cancel", role: .cancel) {}
        }
    }

    private func present(_ reason: ScrapeEntryBlocker) {
        plog("ScrapeOptions: entry unavailable reason=\(reason) parts=\(parts.rawValue)")
        blocker = reason
    }

    /// iPhone 上设置页在刮削页后面，先收起刮削页再过去；Mac 的设置是另一个窗口，刮削窗口留着。
    private func openSourceSettings() {
        #if os(macOS)
        openScraperSettings()
        #else
        protect {
            closeView()
            openScraperSettings()
        }
        #endif
    }

    @ViewBuilder private var screen: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                PMStandardWindowButtonArea()
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: String(format: String(localized: "scrape_window_title_format"), macDisplayTitle ?? song.title))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(verbatim: song.filePath)
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            .frame(height: 44).padding(.horizontal, 14).pmWindowDragRegion()
            Divider()
            reviewBody
            Divider()
            HStack {
                Button("cancel") { protect(closeView) }.keyboardShortcut(.cancelAction)
                Spacer()
                saveButton.keyboardShortcut(.defaultAction)
            }.padding(14)
        }
        .background(PMColor.bg).ignoresSafeArea(.container, edges: .top)
        #else
        NavigationStack {
            Group { if showingReview { reviewBody } else { optionsView } }
                .navigationTitle("scrape_song").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("cancel") { protect(closeView) }
                    }
                    if showingReview {
                        // 回选项页改刮哪几项、每个来源搜几条；结果页挑到一半的留着，回来接着挑。
                        ToolbarItem(placement: .topBarLeading) {
                            Button { showingReview = false } label: {
                                Label("scrape_options", systemImage: "slider.horizontal.3")
                            }
                            .disabled(busy)
                            .accessibilityIdentifier("scrape.review.options")
                        }
                        ToolbarItem(placement: .confirmationAction) { saveButton }
                    }
                }
        }
        #endif
    }

    private var saveButton: some View {
        Button("save", action: saveDraft).disabled(busy || draft?.hasChanges != true)
            .accessibilityIdentifier("scrape.review.save")
    }

    private var reviewBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScrapeSearchBar(query: $query, isSearching: loading, isBusy: busy,
                                isAvailable: manualBlocker == nil,
                                onBlocked: { if let manualBlocker { present(manualBlocker) } }) { protect(startSearch) }
                #if os(macOS)
                macScopeBar
                #endif
                if let binding = Binding($draft), !binding.wrappedValue.fields.isEmpty {
                    ScrapeFieldReviewView(draft: binding, images: images, originalCover: {
                        // 封面流的卡片自己定大小、裁圆角，这里铺满卡片。
                        CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: 240, cornerRadius: 0,
                                          sourceID: song.sourceID, filePath: song.filePath, fileFormat: song.fileFormat,
                                          fillsProposedSize: true)
                    }, loadsOriginalLyrics: loadCurrentLyrics)
                    .disabled(busy)
                    .opacity(loading ? 0.55 : 1)
                    .animation(.easeOut(duration: 0.2), value: loading)
                    #if os(macOS)
                    writebackDetails
                    #endif
                } else if loading {
                    ProgressView("search_running")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("scrape_no_changes").font(.headline)
                        Text("no_scrape_results_desc").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var optionsView: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: 54, cornerRadius: 8,
                                      sourceID: song.sourceID, filePath: song.filePath, fileFormat: song.fileFormat)
                    VStack(alignment: .leading) {
                        Text(verbatim: song.title).font(.headline)
                        // 歌手 · 专辑 · 年份 · 时长：挑候选时拿时长对着看。
                        Text(verbatim: ScrapeReviewContext(song: song).subtitle(for: .title) ?? "")
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            if draft != nil {
                Section {
                    Button { returnToResults() } label: {
                        Label("back_to_results", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("scrape.options.backToResults")
                }
            }
            Section("scrape_options") {
                Toggle("scrape_metadata_toggle", isOn: contentPreferences.binding(for: .metadata))
                Toggle("scrape_cover_toggle", isOn: contentPreferences.binding(for: .cover))
                Toggle("scrape_lyrics_toggle", isOn: contentPreferences.binding(for: .lyrics))
            }
            Section {
                // 开不了的入口照样能点：看得出不可用，点了说明原因。
                Button { tapAutomatic() } label: { Label("auto_scrape", systemImage: "wand.and.stars") }
                    .foregroundStyle(automaticBlocker == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Button { tapManual() } label: { Label("manual_scrape", systemImage: "magnifyingglass") }
                    .foregroundStyle(manualBlocker == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Picker("search_limit_per_source", selection: $searchLimit) {
                    ForEach([10, 20, 30, 50, 100], id: \.self) { Text("\($0)").tag($0) }
                }
            }.disabled(busy)
        }
    }

    /// 回结果页。刮的内容或每个来源的条数改过、结果页也还没挑过时，按新设置重搜；挑过的不动它。
    private func returnToResults() {
        if draftScope != currentScope, draft?.isEdited != true, manualBlocker == nil {
            plog("ScrapeOptions: scope changed on the options page, searching again")
            startSearch()
        } else {
            showingReview = true
        }
    }

    private func tapAutomatic() {
        if let automaticBlocker { present(automaticBlocker) } else { protect(startAutomatic) }
    }

    private func tapManual() {
        if let manualBlocker { present(manualBlocker) } else { protect(startSearch) }
    }

    /// 结果页「当前」那份歌词按播放时的顺序读（缓存、歌旁边的歌词文件、内嵌），不走在线兜底。
    private func loadCurrentLyrics() async -> [LyricLine] {
        await LyricsLoader.load(for: song, sourceManager: sourceManager, allowsAutomaticOnlineLyrics: false)
    }

    private func protect(_ action: @escaping () -> Void) {
        if draft?.isEdited == true { pendingDiscard = action; showsDiscard = true } else { action() }
    }

    private func closeView() {
        searchTask.cancel()
        if let onCloseRequest { onCloseRequest() } else { dismiss() }
    }

    private func startAutomatic() {
        guard !busy else { return }
        switch scraperService.startSingleScrape(song: song, in: library, dryRun: true, parts: parts) {
        case .started(let id), .joined(let id): automaticID = id; showingReview = true
        case .busy:
            // 自动刮削要和批量刮削抢同一道门；结果页的搜索是只读的预览，不走那道门，照样能出结果。
            plog("ScrapeOptions: automatic preview is busy (batch running), using the review search instead")
            startSearch()
        case .noScraperSource: present(automaticBlocker ?? .noSource)
        }
    }

    #if os(macOS)
    /// Mac 打开窗口就直接进结果页：自动刮削开得了就用它，规则把要刮的几项都跳过了就用搜索；
    /// 一项都没选或没有刮削源时不弹窗，留在空白页，点搜索再说明原因。
    private func startInitialMacSearch() {
        switch automaticBlocker {
        case nil: startAutomatic()
        case .rulesSkipAll: startSearch()
        case .noParts, .noSource: break
        }
    }
    #endif

    private func consumeAutomatic() {
        guard automaticID != nil || (!showingReview && draft == nil),
              let completion = scraperService.consumeSingleScrapeCompletion(songID: song.id, purposes: [.metadataPreview, .lyricsPreview],
                                                                            matching: automaticID) else { return }
        automaticID = nil
        guard let result = completion.result else { errorMessage = completion.errorMessage; return }
        var catalog = result.review
        catalog.includeLocalResults(original: song, updated: result.song,
                                    fields: scraperSettings.snapshot().reviewFields(for: song, parts: parts).fields,
                                    cover: result.coverData, lyrics: result.lyrics)
        install(catalog)
    }

    private func startSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !text.isEmpty else { return }
        if let manualBlocker { present(manualBlocker); return }
        showingReview = true
        searchTask.start {
            let catalog = await scraperService.fieldReview(for: song, query: text, parts: parts, searchLimit: searchLimit)
            guard !Task.isCancelled else { return }
            if catalog.options.isEmpty, draft?.hasChanges == true { errorMessage = String(localized: "no_scrape_results_desc"); return }
            install(catalog)
        }
    }

    private func install(_ catalog: ScrapeReviewCatalog) {
        let settings = scraperSettings.snapshot()
        draft = ScrapeReviewDraft(song: song, catalog: catalog, request: settings.reviewFields(for: song, parts: parts),
                                  defaults: settings.reviewDefaults(for: song, parts: parts))
        draftScope = currentScope
        showingReview = true
    }

    /// 保存后立刻收起，写入交给 `ScrapeWritebackCenter` 在后台做，进度在 App 最上层的卡片里看。
    private func saveDraft() {
        guard let draft, draft.hasChanges, !busy else { return }
        let onComplete = onComplete
        ScrapeWritebackCenter.shared.startManual(.init(
            draft: draft,
            images: images,
            library: library,
            sourceManager: sourceManager,
            sourcesStore: sourcesStore,
            onApplied: { onComplete?($0) }
        ))
        closeView()
    }

    #if os(macOS)
    /// Mac 的刮削窗口直接进结果页，iPhone 选项页上的「刮哪几项」和「每个来源结果上限」放在搜索框下面，
    /// 存同一组设置；改了就按新设置重新搜一遍。
    private var macScopeBar: some View {
        HStack(spacing: 14) {
            Toggle("metadata", isOn: contentPreferences.binding(for: .metadata))
            Toggle("cover", isOn: contentPreferences.binding(for: .cover))
            Toggle("lyrics_title", isOn: contentPreferences.binding(for: .lyrics))
            Spacer(minLength: 8)
            Picker("search_limit_per_source", selection: $searchLimit) {
                ForEach([10, 20, 30, 50, 100], id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .disabled(busy)
        .onChange(of: parts) { _, _ in searchAgainAfterScopeChange() }
        .onChange(of: searchLimit) { _, _ in searchAgainAfterScopeChange() }
    }

    private func searchAgainAfterScopeChange() {
        // 一项都不选时不搜，搜索键看得出不可用，点了再说明。
        guard !busy, !parts.isEmpty else { return }
        plog("ScrapeOptions: scope changed on Mac parts=\(parts.rawValue) limit=\(searchLimit), searching again")
        protect(startSearch)
    }

    private var writebackDetails: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                if macUsesMediaServerWriteback {
                    macSectionTitle(String(localized: "scrape_writeback_media_server"))
                    macServerWritebackRow(
                        title: String(localized: "scrape_writeback_metadata"),
                        enabled: !(draft?.selected.keys.filter { ScrapeField.tags.contains($0) }.isEmpty ?? true)
                    )
                    macServerWritebackRow(
                        title: String(localized: "scrape_writeback_cover"),
                        enabled: draft?.cover != nil
                    )
                    macServerWritebackRow(
                        title: String(localized: "scrape_writeback_lyrics"),
                        enabled: draft?.lyrics != nil
                    )
                    Text("scrape_writeback_media_server_hint")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textFaint)
                        .padding(.top, 4)
                } else if macSupportsSidecarWriteback {
                    macSectionTitle(String(localized: "scrape_writeback_sidecar"))
                    if macCoverEmbeddingMode != .embedOnly {
                        macSidecarRow(suffix: "-cover.jpg",
                                      enabled: draft?.cover != nil)
                    }
                    if macCoverEmbeddingMode != .off {
                        macServerWritebackRow(
                            title: String(localized: "scrape_writeback_cover_embedded"),
                            enabled: draft?.cover != nil
                        )
                    }
                    macSidecarRow(suffix: ".lrc",
                                  enabled: draft?.lyrics != nil)
                    Text("scrape_writeback_sidecar_hint")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textFaint)
                        .padding(.top, 4)
                } else {
                    macSectionTitle(String(localized: "scrape_writeback_local"))
                    macServerWritebackRow(
                        title: String(localized: "scrape_writeback_metadata"),
                        enabled: !(draft?.selected.keys.filter { ScrapeField.tags.contains($0) }.isEmpty ?? true)
                    )
                    macServerWritebackRow(
                        title: String(localized: "scrape_writeback_cover"),
                        enabled: draft?.cover != nil
                    )
                    macServerWritebackRow(
                        title: String(localized: "scrape_writeback_lyrics"),
                        enabled: draft?.lyrics != nil
                    )
                    Text("scrape_writeback_local_hint")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textFaint)
                        .padding(.top, 4)
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func macSidecarRow(suffix: String, enabled: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? PMColor.ok : PMColor.textFaint)
            Text(verbatim: "\(macSidecarBaseName)\(suffix)")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(enabled ? PMColor.textMuted : PMColor.textFaint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func macServerWritebackRow(title: String, enabled: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? PMColor.ok : PMColor.textFaint)
            Text(verbatim: title)
                .font(.system(size: 11.5))
                .foregroundStyle(enabled ? PMColor.textMuted : PMColor.textFaint)
        }
    }

    /// Sidecar 文件名跟着源音频文件走 (`<basename>-cover.jpg` / `<basename>.lrc`),
    /// 不是歌曲标题 —— 跟 SidecarWriteService 实际写盘逻辑一致。
    private var macSidecarBaseName: String {
        macSidecarBaseNameOverride ?? MusicScraperService.sidecarBaseName(for: song)
    }

    private func macSectionTitle(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
    }

    #endif
}

/// 刮削结果页顶部：胶囊输入框（放大镜、清除键、聚焦描边）加一颗实心的搜索键，搜索中换成转圈。
private struct ScrapeSearchBar: View {
    @Binding var query: String
    let isSearching: Bool
    let isBusy: Bool
    /// 一项都没选或没有刮削源：键看得出不可用，但点了会说明原因。
    let isAvailable: Bool
    let onBlocked: () -> Void
    let onSearch: () -> Void

    @FocusState private var focused: Bool

    private var isDisabled: Bool {
        isBusy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            field
            searchButton
        }
        .animation(.easeOut(duration: 0.18), value: isSearching)
        .animation(.easeOut(duration: 0.18), value: query.isEmpty)
        .animation(.easeOut(duration: 0.18), value: focused)
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.medium))
                .foregroundStyle(focused ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            TextField("search_query", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit(submit)
                .accessibilityIdentifier("scrape.review.query")
            if !query.isEmpty {
                Button {
                    query = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("clear"))
                .transition(.opacity)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, query.isEmpty ? 14 : 6)
        .frame(height: 46)
        .background(Capsule().fill(.fill.tertiary))
        .overlay {
            Capsule().strokeBorder(focused ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(.clear), lineWidth: 1.5)
        }
        .contentShape(Capsule())
        .onTapGesture { focused = true }
    }

    private var searchButton: some View {
        Button(action: submit) {
            ZStack {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .opacity(isSearching ? 1 : 0)
                Text("search_title")
                    .font(.body.weight(.semibold))
                    .opacity(isSearching ? 0 : 1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 46)
            .background(Capsule().fill(.tint))
            .opacity((isDisabled || !isAvailable) && !isSearching ? 0.4 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityIdentifier("scrape.review.search")
    }

    private func submit() {
        guard !isDisabled else { return }
        focused = false
        if isAvailable { onSearch() } else { onBlocked() }
    }
}

#if DEBUG && os(iOS)
private extension ScrapeOptionsView {
    init(previewing draft: ScrapeReviewDraft, onComplete: @escaping (Song) -> Void) {
        self.init(song: draft.original, onComplete: onComplete)
        _draft = State(initialValue: draft)
        _showingReview = State(initialValue: true)
    }
}

struct ScrapeFieldReviewTestHost: View {
    private static let song = Song(id: "ui-scrape-field-review", title: "Paper Lanterns",
        albumTitle: "Home Edition", artistName: "Quay Ensemble", fileFormat: .flac,
        filePath: "fixture.flac", sourceID: "ui-scrape-field-review")
    @State private var library = MusicLibrary(storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ScrapeFieldReviewLibrary"))
    @State private var presented = false
    @State private var savedAlbum = ""

    var body: some View {
        VStack {
            Button("Open") { presented = true }.accessibilityIdentifier("scrape.fixture.open")
            Text(verbatim: savedAlbum).accessibilityIdentifier("scrape.fixture.saved")
        }
        // 和真实根视图一样铺满全屏，进度卡片与胶囊按整屏摆。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if library.song(id: Self.song.id) == nil { library.addSongs([Self.song], affectedSourceIDs: [Self.song.sourceID]) }
            else { library.replaceSong(Self.song) }
            // 截图取证：不经 UI 测试直接打开结果页，或摆出写入进度卡片的某一种状态。
            let environment = ProcessInfo.processInfo.environment
            if environment["PRIMUSE_SCRAPE_FIXTURE_AUTO_OPEN"] == "1" { presented = true }
            if let mode = environment["PRIMUSE_SCRAPE_FIXTURE_PROGRESS"], !mode.isEmpty {
                ScrapeWritebackCenter.shared.debugShowSample(song: Self.song, mode: mode)
            }
        }
        .sheet(isPresented: $presented) {
            ScrapeOptionsView(previewing: Self.draft) { updated in
                savedAlbum = library.storedSong(id: updated.id)?.albumTitle ?? ""
            }.environment(library)
        }
        .scrapeWritebackProgressHost()
    }

    private static var draft: ScrapeReviewDraft {
        var catalog = ScrapeReviewCatalog()
        for (id, color) in [("Amber", UIColor.systemOrange), ("Indigo", UIColor.systemIndigo)] {
            let rect = CGRect(x: 0, y: 0, width: 80, height: 80)
            let data = UIGraphicsImageRenderer(bounds: rect).pngData { context in
                color.setFill()
                context.fill(rect)
            }
            catalog.add(.init(id: id, source: id, value: .cover(.init(data: data))), for: .cover)
        }
        catalog.recommended[.cover] = "Amber"
        for album in ["Studio Edition", "Harbor Edition"] { catalog.addText(album, field: .album, source: "Quay Archive") }
        catalog.recommended[.album] = "Studio Edition"
        for raw in ["[00:01]<00:01>Paper <00:02>lanterns\n[00:03]<00:03>Trace <00:04>the quay",
                    "Cobalt windows\nRest above the tide\nA folded map\nA quiet stair\nAnd one last light"] {
            let lines = LyricsContentParser.parseText(raw)
            catalog.addLyrics(lines, source: "Quay Archive", raw: raw)
        }
        catalog.recommended[.lyrics] = catalog.options[.lyrics]?.first?.id
        let request = ScraperSettings().reviewFields(for: song, parts: .all)
        return ScrapeReviewDraft(song: song, catalog: catalog, request: request, defaults: request)
    }
}
#endif
