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
    private var contentPreferences = ScrapeContentPreferences()
    @AppStorage("scraperSearchLimit") private var searchLimit = 20
    @State private var draft: ScrapeReviewDraft?
    @State private var images = ScrapeReviewImages()
    @State private var showingReview = false
    @State private var query = ""
    @State private var searchTask = ScrapeOptionsTask()
    @State private var applyTask = ScrapeOptionsTask()
    @State private var automaticID: UUID?
    @State private var showsDiscard = false
    @State private var pendingDiscard: (() -> Void)?
    @State private var errorMessage: String?
    #if os(macOS)
    @State private var macSidecarBaseNameOverride: String?
    @State private var macUsesMediaServerWriteback = false
    @State private var macSupportsSidecarWriteback = false
    @State private var macCoverEmbeddingMode: CoverEmbeddingMode = .off
    #endif

    private var parts: ScrapeParts { contentPreferences.parts }
    private var canSearch: Bool { !scraperSettings.fieldRules.request(parts: parts, overwriteByDefault: false).fields.isEmpty }
    private var loading: Bool { searchTask.isRunning || automaticID != nil }
    private var busy: Bool { loading || applyTask.isRunning }

    var body: some View {
        screen
            .onAppear { windowActions?.request = { action in protect(action) } }
            .task {
                let title = await scraperService.suggestedScrapeTitle(for: song)
                guard !Task.isCancelled else { return }
                if query.isEmpty { query = MusicScraperService.searchQuery(title: title, artist: song.artistName) }
                consumeAutomatic()
                #if os(macOS)
                macSidecarBaseNameOverride = await scraperService.suggestedSidecarBaseName(for: song)
                macUsesMediaServerWriteback = await sourceManager.supportsMediaServerWriteback(for: song)
                macSupportsSidecarWriteback = await sourceManager.supportsSidecarWriting(for: song)
                macCoverEmbeddingMode = await sourceManager.coverEmbeddingMode(for: song)
                if !showingReview && !Task.isCancelled { startAutomatic() }
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
    }

    @ViewBuilder private var screen: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                PMStandardWindowButtonArea()
                Text(verbatim: song.title).font(.headline).lineLimit(1)
                Spacer()
            }
            .frame(height: 44).padding(.horizontal, 14).pmWindowDragRegion()
            Divider()
            reviewBody
            Divider()
            HStack {
                Button("cancel") { protect(closeView) }.keyboardShortcut(.cancelAction).disabled(applyTask.isRunning)
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
                        Button("cancel") { protect(closeView) }.disabled(applyTask.isRunning)
                    }
                    if showingReview { ToolbarItem(placement: .confirmationAction) { saveButton } }
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
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    TextField("search_query", text: $query).textFieldStyle(.roundedBorder)
                        .onSubmit { protect(startSearch) }
                    Button("search_title") { protect(startSearch) }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || !canSearch)
                }
                if loading { ProgressView("search_running").frame(maxWidth: .infinity) }
                if let binding = Binding($draft), !binding.wrappedValue.fields.isEmpty {
                    ScrapeFieldReviewView(draft: binding, images: images) {
                        CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: 136, cornerRadius: 8,
                                          sourceID: song.sourceID, filePath: song.filePath, fileFormat: song.fileFormat)
                    }
                    .disabled(busy)
                    #if os(macOS)
                    writebackDetails
                    #endif
                } else if !loading {
                    Label("scrape_no_changes", systemImage: "magnifyingglass").foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var optionsView: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: 54, cornerRadius: 8,
                                      sourceID: song.sourceID, filePath: song.filePath, fileFormat: song.fileFormat)
                    VStack(alignment: .leading) {
                        Text(verbatim: song.title).font(.headline)
                        Text(verbatim: song.artistName ?? "").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            Section("scrape_options") {
                Toggle("scrape_metadata_toggle", isOn: contentPreferences.binding(for: .metadata))
                Toggle("scrape_cover_toggle", isOn: contentPreferences.binding(for: .cover))
                Toggle("scrape_lyrics_toggle", isOn: contentPreferences.binding(for: .lyrics))
            }
            Section {
                Button { startAutomatic() } label: { Label("auto_scrape", systemImage: "wand.and.stars") }
                Button { startSearch() } label: { Label("manual_scrape", systemImage: "magnifyingglass") }
                Picker("search_limit_per_source", selection: $searchLimit) {
                    ForEach([10, 20, 30, 50, 100], id: \.self) { Text("\($0)").tag($0) }
                }
            }.disabled(!canSearch || busy)
        }
    }

    private func protect(_ action: @escaping () -> Void) {
        guard !applyTask.isRunning else { return }
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
        case .busy: errorMessage = String(localized: "intent_scrape_busy")
        case .noScraperSource: errorMessage = String(localized: "scraper_no_source_message")
        }
    }

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
                                  defaults: settings.request(for: song, parts: parts))
        showingReview = true
    }

    private func saveDraft() {
        guard let draft, draft.hasChanges, !busy else { return }
        applyTask.start {
            do {
                let coverData: Data?
                if let cover = draft.cover { coverData = try await images.data(for: cover) } else { coverData = nil }
                try Task.checkCancellation()
                let current = library.storedSong(id: song.id) ?? song
                await persist(draft, coverData: coverData, original: current)
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    #if os(macOS)
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
    private func persist(_ draft: ScrapeReviewDraft, coverData: Data?, original song: Song) async {
        let needsCover = coverData != nil
        let lyricsLines = draft.lyrics
        let lib = library
        let sm = sourceManager
        let store = sourcesStore
        let songID = song.id
        var savedLyricsSong: Song?
        if let lines = lyricsLines {
            let wordLevel = lines.filter { $0.isWordLevel }.count
            plog("👉 ScrapeOptionsView.apply lyrics=\(lines.count) wordLevelLines=\(wordLevel) firstSyllables=\(lines.first?.syllables?.count ?? -1)")
            let lyricsSong = song
            let payload: LyricsWriteback.EditablePayload
            let writebackMode: LyricsWriteback.Mode
            do {
                (payload, writebackMode) = try await AsyncOperationTimeout.run(seconds: 30) {
                    let payload = await LyricsWriteback.loadEditablePayload(
                        for: lyricsSong,
                        sourceManager: sm
                    )
                    try Task.checkCancellation()
                    let mode = await LyricsWriteback.resolveMode(
                        for: lyricsSong,
                        sourceManager: sm,
                        sourcesStore: store
                    )
                    try Task.checkCancellation()
                    return (payload, mode)
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                return
            }
            guard !Task.isCancelled else { return }
            let outcome = await LyricsWriteback.save(
                text: LyricsContentParser.serialize(lines),
                for: lyricsSong,
                mode: writebackMode,
                allowRemoval: false,
                structuredLines: lines,
                sourceSnapshot: payload.sourceSnapshot,
                cacheSnapshot: payload.cacheSnapshot,
                sourceManager: sm,
                library: lib
            )
            guard !Task.isCancelled else { return }
            if outcome.succeeded {
                savedLyricsSong = outcome.updatedSong
                if let embeddedCopyError = outcome.embeddedCopyError {
                    // 歌词文件与缓存都已落地，随身副本失败不拦这次应用。
                    plog("⚠️ ScrapeOptionsView.apply embedded lyrics copy failed: \(embeddedCopyError)")
                }
            } else {
                let message = outcome.errorMessage ?? String(localized: "scrape_song_failed")
                plog("⚠️ ScrapeOptionsView.apply lyrics writeback failed: \(message)")
                errorMessage = message
                return
            }
        }
        guard !Task.isCancelled else { return }
        let server = await sm.isServerLibrarySource(for: song)
        var coverReference: String?
        if needsCover, let coverData {
            guard let reference = await MetadataAssetStore.shared.storeAttributedCover(coverData, songID: songID, origin: .selected) else {
                errorMessage = String(localized: "scrape_song_failed")
                return
            }
            coverReference = reference
        }

        // A source write can take time. Apply the chosen fields to the latest library row.
        lib.flushPendingAssetReferencePatches()
        let current = lib.storedSong(id: songID) ?? savedLyricsSong ?? song
        var appliedFinal = current
        appliedFinal.applyScrapeFields(draft.proposedTags(on: current))
        if let coverReference {
            appliedFinal.coverArtFileName = coverReference
            CachedArtworkView.invalidateCache(for: songID)
            if let old = current.coverArtFileName { CachedArtworkView.invalidateCache(for: old) }
        }
        let tagsChanged = ScrapeField.tags.contains { $0.changed(from: current.scrapeFields, to: appliedFinal.scrapeFields) }
        if server {
            if tagsChanged { appliedFinal.userMetadataEditedAt = Date() }
        } else {
            appliedFinal = SongUserMetadataPolicy.stampingUserEdit(original: current, updated: appliedFinal)
        }
        if tagsChanged || appliedFinal.userMetadataEditedAt != current.userMetadataEditedAt {
            lib.replaceSong(appliedFinal)
        } else if coverReference != nil {
            lib.updateAssetReferences(songID: songID, coverRef: appliedFinal.coverArtFileName, lyricsRef: appliedFinal.lyricsFileName)
        }
        if coverReference != nil { SongTagEditStore.shared.recordUserChosenCovers(songIDs: [songID]) }
        onComplete?(appliedFinal)
        applyTask.finish()
        closeView()

        let usesMediaServerWriteback = await sm.supportsMediaServerWriteback(for: appliedFinal)
        if usesMediaServerWriteback {
            let originalSnapshot = current
            let finalSnapshot = appliedFinal
            Task.detached(priority: .utility) {
                let result = await sm.writeScrapedMetadataToMediaServer(
                    original: originalSnapshot,
                    updated: finalSnapshot,
                    coverData: needsCover ? coverData : nil,
                    lyricsLines: nil
                )
                if !result.errors.isEmpty {
                    plog("⚠️ Media-server writeback errors for '\(finalSnapshot.title)': \(result.errors)")
                }
                if !result.unsupported.isEmpty {
                    plog("ℹ️ Media-server writeback limitations for '\(finalSnapshot.title)': \(result.unsupported)")
                }
            }
        }

        // Sidecar (cover.jpg / .lrc) 写回 NAS — fire and forget。
        //
        // 关键: detached + 30s 超时。之前的实现是 Task { @MainActor in ... },
        // 这意味着整段 (包括 await connector.connect → NAS 网络握手, await
        // writeSidecars → NAS 上传) 都跑在 main actor 的 cooperative thread
        // 上。任意一个 await 异常挂起 (如 NAS 不响应也不超时), main actor
        // 上其他 Task 仍然能跑, 但代码路径里有 lib.replaceSong / cacheCover
        // 等回到 main actor 的同步点 ── 一旦 NAS 写回到一半挂起, 主 actor
        // 反应链卡住, 用户描述的 "UI 完全卡死、滑掉 app 第一次失败" 就是这种
        // main actor cooperative thread 死锁。
        //
        // detached 让网络写完全走背景 executor; 关键的"回写 main actor 状态"
        // (replaceSong / invalidateCache) 用 await MainActor.run 显式跳回,
        // 网络挂起的时候 main actor 不被持有。
        //
        // withTimeout 兜底: 30 秒后强制取消, 即使 NAS 端有 bug 也不会无限期
        // 占用 connector actor。
        let supportsSidecarWriteback = await sm.supportsSidecarWriting(for: appliedFinal)
        if supportsSidecarWriteback
            && !usesMediaServerWriteback
            && needsCover {
            let titleSnapshot = appliedFinal.title
            let finalSnapshot = appliedFinal
            let coverEmbeddingMode = await sm.coverEmbeddingMode(for: appliedFinal)
            Task.detached(priority: .utility) {
                // 选了嵌入时先整首替换（不套 30 秒超时），再写或只更新已有的封面文件；
                // 有的网盘替换后文件换了 ID，封面文件要跟着新文件走。
                var embeddedSnapshot: Song?
                if coverEmbeddingMode != .off, let data = coverData {
                    embeddedSnapshot = await MusicScraperService.embedScrapedCover(
                        data,
                        for: finalSnapshot,
                        sourceManager: sm,
                        library: lib
                    ).updatedSong
                }
                let sidecarSnapshot = embeddedSnapshot ?? finalSnapshot
                plog("📝 Sidecar: writing back to source for '\(titleSnapshot)'")
                do {
                    try await Self.writeSidecarWithTimeout(
                        seconds: 30,
                        sourceManager: sm,
                        song: sidecarSnapshot,
                        coverData: needsCover ? coverData : nil,
                        lyricsLines: nil,
                        createsCoverFile: coverEmbeddingMode != .embedOnly
                    ) { writeResult in
                        plog("📝 Sidecar: result cover=\(writeResult.coverWritten) lyrics=\(writeResult.lyricsWritten)")

                        if writeResult.coverWritten {
                            // sidecar 已落盘 → 回写 hash cache 作为可信 mirror。
                            // 不要先 invalidate 再 cacheCover ── 制造空窗期, 期间 view
                            // reload 会拿不到本地 cache 被迫走 NAS, 拉到 HTTP 端缓存的旧
                            // 文件就显示旧封面。直接覆写。
                            if let data = coverData {
                                await MetadataAssetStore.shared.cacheCover(data, forSongID: songID)
                            }
                await MainActor.run {
                    CachedArtworkView.invalidateCache(for: songID)
                    if let coverPath = MusicScraperService.sidecarReferencePath(for: sidecarSnapshot, suffix: "-cover.jpg") {
                        lib.updateAssetReferences(songID: sidecarSnapshot.id, coverRef: coverPath)
                    }
                }
            }
                        if !writeResult.errors.isEmpty {
                            plog("⚠️ Sidecar write errors: \(writeResult.errors)")
                        }
                    }
                } catch is CancellationError {
                    plog("⚠️ Sidecar write timed out (30s) for '\(titleSnapshot)' ── 网络挂起被强制中断, 本地 cache 仍然是新的, 仅 NAS sidecar 未写。")
                } catch {
                    plog("⚠️ Sidecar write failed for '\(titleSnapshot)': \(error.localizedDescription)")
                }
            }
        }
    }

    private static func writeSidecarWithTimeout(
        seconds: TimeInterval,
        sourceManager: SourceManager,
        song: Song,
        coverData: Data?,
        lyricsLines: [LyricLine]?,
        createsCoverFile: Bool = true,
        applyResult: @escaping @Sendable (SidecarWriteService.WriteResult) async -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                // Sidecar 写回使用独立 connector, 避免复用正在播放/离线缓存的
                // 云盘 connector 状态。
                let connector = try await sourceManager.sidecarWriteConnector(for: song)
                let writeResult = await SidecarWriteService.shared.writeSidecars(
                    for: song,
                    using: connector,
                    coverData: coverData,
                    lyricsLines: lyricsLines,
                    createsCoverFile: createsCoverFile
                )
                await sourceManager.invalidateReadCachesAfterSidecarWrite(
                    for: song,
                    paths: writeResult.touchedRemotePaths
                )
                if writeResult.coverWritten || writeResult.lyricsWritten {
                    await sourceManager.invalidateDownloadCacheAfterSidecarWrite(for: song)
                }
                await applyResult(writeResult)
            }
            group.addTask {
                let nanoseconds = (seconds * 1_000_000_000).finiteUInt64(or: 30_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw CancellationError()
            }
            // 等任意一个先完成。如果是真实工作完成 → 第二个 sleep task 被 cancelAll
            // 中断; 如果是 sleep 先完成 (即 30s 超时) → 第二个 task 被 cancelAll
            // 中断, throw 也被 group 抛给外层 catch。
            try await group.next()
        }
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
        .onAppear {
            if library.song(id: Self.song.id) == nil { library.addSongs([Self.song], affectedSourceIDs: [Self.song.sourceID]) }
            else { library.replaceSong(Self.song) }
        }
        .sheet(isPresented: $presented) {
            ScrapeOptionsView(previewing: Self.draft) { updated in
                savedAlbum = library.storedSong(id: updated.id)?.albumTitle ?? ""
            }.environment(library)
        }
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
