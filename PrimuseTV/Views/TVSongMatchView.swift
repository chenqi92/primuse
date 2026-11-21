#if os(tvOS)
import PrimuseKit
import SwiftUI
import UIKit

/// 「刮削数据」要打开的歌,给 `fullScreenCover(item:)` 用。
struct TVSongMatchTarget: Identifiable, Hashable {
    let id: String
}

// MARK: - 单曲刮削

struct TVSongMatchView: View {
    let songID: String

    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var draft: ScrapeReviewDraft?
    @State private var images = ScrapeReviewImages()
    @State private var isSearching = false
    @State private var isSaving = false
    @State private var searchTask: Task<Void, Never>?
    @State private var notice: String?
    @State private var pendingDiscard: (() -> Void)?
    @State private var showsDiscard = false
    /// 这次按什么搜：能刮整套就整套；只剩默认开着的纯歌词源时只找歌词（见 `SingleSongScrapePartsFallbackPolicy`）。
    @State private var searchParts: ScrapeParts = .all
    /// 一个能用的刮削源都没有：提示里给出去刮削源设置的入口。
    @State private var needsScraperSource = false
    @State private var showsScraperSettings = false

    private var song: Song? { store.library.song(id: songID) }

    var body: some View {
        let colors = store.nowPlayingPresentationColors
        ZStack {
            TVAmbientBackdrop(tint: colors.primary, tint2: colors.secondary, strength: 0.4)
            TVColor.bg.opacity(0.5).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("tv_scrape_match_title").tvFont(.pageTitle)
                        if let song {
                            Text(verbatim: [song.title, song.artistName].compactMap { $0 }.joined(separator: " · "))
                                .tvFont(.caption).foregroundStyle(TVColor.textMuted)
                        }
                    }
                    Spacer()
                    TVPillButton(title: String(localized: "cancel"), systemImage: "xmark") { protect { dismiss() } }
                    TVPillButton(title: String(localized: "save"), systemImage: "checkmark", style: .solid, action: save)
                        .disabled(isSaving || isSearching || draft?.hasChanges != true)
                }.focusSection()
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        HStack(spacing: 18) {
                            TVTextFieldBox {
                                TextField("search_query", text: $query).onSubmit { protect(search) }
                            }
                            TVPillButton(title: String(localized: "search_title"), systemImage: "magnifyingglass") { protect(search) }
                                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                        }.focusSection()
                        if isSearching { ProgressView("scrape_candidates_searching") }
                        if let notice { Text(verbatim: notice).foregroundStyle(TVColor.textMuted) }
                        if needsScraperSource || searchParts == .lyrics {
                            scraperSourceHint
                        }
                        if let binding = Binding($draft), let song {
                            ScrapeFieldReviewView(draft: binding, images: images) {
                                TVArtworkView(coverKey: song.albumID ?? song.id, artist: song.artistName ?? "",
                                    album: song.albumTitle ?? "", songID: song.id, coverRef: song.coverArtFileName,
                                    tint: TVColor.brand, tint2: TVColor.brandSecondary, glyph: "music.note", size: 190, radius: 10)
                            }.disabled(isSearching)
                        }
                    }.padding(24)
                }
                Text("tv_scrape_local_only_note").tvFont(.caption).foregroundStyle(TVColor.textMuted)
            }
            .disabled(isSaving)
            .padding(48)
            .frame(maxWidth: 1320)
            .tvPanel(radius: 26)
            .padding(.vertical, 45)
        }
        .task {
            guard let song, query.isEmpty else { return }
            query = TVMetadataScrapeService.suggestedQuery(title: song.title, artist: song.artistName)
            #if DEBUG
            if let text = ProcessInfo.processInfo.environment["TV_SCRAPE_DEBUG_QUERY"], !text.isEmpty { query = text }
            #endif
            search()
        }
        .onDisappear { searchTask?.cancel() }
        .onExitCommand { protect { dismiss() } }
        // 从这里去开刮削源，回来按新的设置重搜一次。
        .tvFullScreenCover(isPresented: $showsScraperSettings, onDismiss: { search() }) {
            TVScraperSettingsView().environment(store)
        }
        .alert("lyrics_sources_discard_title", isPresented: $showsDiscard) {
            Button("lyrics_editor_keep_editing", role: .cancel) { pendingDiscard = nil }
            Button("lyrics_sources_discard", role: .destructive) {
                let action = pendingDiscard
                pendingDiscard = nil
                action?()
            }
        }
        .accessibilityIdentifier("tv.scrape.match")
    }

    private func protect(_ action: @escaping () -> Void) {
        guard !isSaving else { return }
        if draft?.isEdited == true { pendingDiscard = action; showsDiscard = true } else { action() }
    }

    /// 只剩歌词源能用时说一句这次只找歌词；一个源都没有时说要先开源。两种都给去刮削源设置的按钮。
    private var scraperSourceHint: some View {
        HStack(alignment: .center, spacing: 24) {
            if !needsScraperSource {
                Text("scrape_entry_tv_lyrics_only_note")
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TVPillButton(title: String(localized: "scraper_no_source_open_settings"), systemImage: "gearshape") {
                protect { showsScraperSettings = true }
            }
        }
        .focusSection()
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let song, !text.isEmpty, !isSaving else { return }
        searchTask?.cancel()
        let settings = ScraperSettings.load()
        // 单曲匹配是用户点名要的：数源时不看刮削规则里的「跳过」，和手机端入口一致。
        let fullCount = store.scraperSettings.userRequestedSourceCount(for: .all)
        let lyricsCount = store.scraperSettings.userRequestedSourceCount(for: .lyrics)
        let plannedParts = SingleSongScrapePartsFallbackPolicy.parts(fullSourceCount: fullCount, lyricsSourceCount: lyricsCount)
        let plannedRequest = plannedParts.map { settings.reviewFields(for: song, parts: $0) }
        guard let parts = plannedParts, let request = plannedRequest, !request.fields.isEmpty else {
            plog("TV scrape: no usable scraper source full=\(fullCount) lyrics=\(lyricsCount)")
            isSearching = false
            needsScraperSource = true
            notice = String(localized: "scraper_no_source_message")
            return
        }
        if parts != searchParts || needsScraperSource {
            plog("TV scrape: search parts=\(parts == .lyrics ? "lyrics" : "all") full=\(fullCount) lyrics=\(lyricsCount)")
        }
        needsScraperSource = false
        searchParts = parts
        isSearching = true
        notice = nil
        searchTask = Task { @MainActor in
            let catalog = await store.metadataScraper.fieldReview(for: song, query: text, settings: settings)
            guard !Task.isCancelled else { return }
            isSearching = false
            if catalog.options.isEmpty { notice = String(localized: "scrape_no_changes"); return }
            draft = ScrapeReviewDraft(song: song, catalog: catalog, request: request,
                                      defaults: settings.reviewDefaults(for: song, parts: parts))
        }
    }

    private func save() {
        guard let draft, draft.hasChanges, !isSaving else { return }
        isSaving = true
        notice = nil
        Task { @MainActor in
            defer { isSaving = false }
            do {
                let data: Data?
                if let cover = draft.cover { data = try await images.data(for: cover) } else { data = nil }
                if await store.metadataScraper.apply(draft, coverData: data) {
                    dismiss()
                } else { notice = String(localized: "scrape_song_failed") }
            } catch { notice = error.localizedDescription }
        }
    }
}

// MARK: - 整张专辑补全

/// 为一张专辑补全缺失的标签、封面和歌词的面板。专辑详情页这样打开:
///
///     .tvFullScreenCover(isPresented: $showsAlbumScrape) {
///         TVAlbumScrapeView(albumID: album.id).environment(store)
///     }
///
/// 规则跟着刮削设置走:「只补全缺失字段」开着时只填空着的,关着时用可信的在线结果覆盖。
/// 改了专辑名的话这张专辑可能换一个 id,关掉面板后详情页按需要重新取专辑。
struct TVAlbumScrapeView: View {
    let albumID: String

    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case idle
        case running(TVAlbumScrapeProgress?)
        case finished(TVAlbumScrapeResult)
    }

    @State private var phase: Phase = .idle
    @State private var task: Task<Void, Never>?
    @State private var albumTitle = ""
    @State private var albumArtist = ""
    @State private var trackCount = 0
    @State private var didLoad = false

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.4)
            TVColor.bg.opacity(0.5).ignoresSafeArea()
            card
                .padding(.horizontal, 90)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onAppear(perform: load)
        .onExitCommand(perform: close)
        .onDisappear {
            task?.cancel()
            task = nil
        }
        .accessibilityIdentifier("tv.scrape.album")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "tv_scrape_album_title"))
                    .tvFont(.pageTitle)
                    .foregroundStyle(TVColor.text)
                Text(verbatim: [albumTitle, albumArtist].filter { !$0.isEmpty }.joined(separator: " · "))
                    .tvFont(.cardTitle)
                    .foregroundStyle(TVColor.textMuted)
                    .lineLimit(1)
            }
            Text(bodyText)
                .tvFont(.body)
                .foregroundStyle(TVColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            status

            buttons
                .focusSection()

            Label(String(localized: "tv_scrape_local_only_note"), systemImage: "appletv")
                .tvFont(.caption)
                .foregroundStyle(TVColor.textFaint)
        }
        .padding(.horizontal, 60).padding(.vertical, 46)
        .frame(maxWidth: 1100, alignment: .leading)
        .tvPanel(radius: 26)
    }

    private var bodyText: String {
        if store.scraperSettings.fieldRules != ScrapeFieldRules() {
            return String(format: String(localized: "tv_scrape_album_rules_format"), trackCount)
        }
        let format = store.scraperSettings.onlyFillMissingFields
            ? String(localized: "tv_scrape_album_body_fill_format")
            : String(localized: "tv_scrape_album_body_overwrite_format")
        return String(format: format, trackCount)
    }

    /// 默认开着的 AMLL 只管歌词：只有「仅歌词」能靠它开始，整套和仅封面还要另开一个源。
    private func hasEnabledSource(for parts: ScrapeParts) -> Bool {
        store.scraperSettings.gateSourceCount(for: parts) > 0
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .idle:
            if !hasEnabledSource(for: .all) {
                Label(String(localized: "scraper_no_source_message"), systemImage: "exclamationmark.triangle")
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.warn)
            }
        case .running(let progress):
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(
                    value: Double(max((progress?.index ?? 1) - 1, 0)),
                    total: Double(max(progress?.total ?? trackCount, 1))
                )
                Text(verbatim: progress.map {
                    String(
                        format: String(localized: "tv_scrape_album_progress_format"),
                        $0.index, $0.total, $0.songTitle
                    )
                } ?? " ")
                .tvFont(.caption)
                .foregroundStyle(TVColor.textMuted)
                .lineLimit(1)
            }
        case .finished(let result):
            Label(resultText(result), systemImage: result.noEnabledSource
                ? "exclamationmark.triangle" : "checkmark.circle")
                .tvFont(.body)
                .foregroundStyle(result.noEnabledSource ? TVColor.warn : TVColor.text)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 18) {
            switch phase {
            case .idle:
                TVPillButton(
                    title: String(localized: "tv_scrape_album_start"),
                    systemImage: "wand.and.stars",
                    style: .solid,
                    action: { start(parts: .all) }
                )
                .disabled(trackCount == 0 || !hasEnabledSource(for: .all))
                TVPillButton(
                    title: String(localized: "scrape_parts_lyrics_only"),
                    systemImage: "text.quote",
                    action: { start(parts: .lyrics) }
                )
                .disabled(trackCount == 0 || !hasEnabledSource(for: .lyrics))
                TVPillButton(
                    title: String(localized: "scrape_parts_cover_only"),
                    systemImage: "photo",
                    action: { start(parts: .cover) }
                )
                .disabled(trackCount == 0 || !hasEnabledSource(for: .cover))
                TVPillButton(title: String(localized: "cancel"), systemImage: "xmark", action: close)
            case .running:
                TVPillButton(title: String(localized: "tv_scrape_album_stop"), systemImage: "stop.circle", action: stop)
            case .finished:
                TVPillButton(title: String(localized: "done"), systemImage: "checkmark", style: .solid, action: close)
            }
        }
    }

    private func resultText(_ result: TVAlbumScrapeResult) -> String {
        if result.noEnabledSource { return String(localized: "scraper_no_source_message") }
        var counts = String(
            format: String(localized: "tv_scrape_album_result_format"),
            result.updated,
            result.unchanged
        )
        if result.failed > 0 {
            // 刮到了却没存下的单独说出来，不混进「没变」。
            counts += " · " + String(format: String(localized: "scrape_tally_save_failed_format"), result.failed)
        }
        return result.cancelled ? counts + " · " + String(localized: "tv_scrape_album_stopped") : counts
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let songs = store.library.songs(forAlbum: albumID)
        trackCount = songs.count
        if let album = store.album(albumID) {
            albumTitle = album.title
            albumArtist = album.artist
        } else {
            albumTitle = songs.first?.albumTitle ?? ""
            albumArtist = songs.first?.albumArtistName ?? songs.first?.artistName ?? ""
        }
    }

    private func start(parts: ScrapeParts) {
        guard task == nil else { return }
        phase = .running(nil)
        let scraper = store.metadataScraper
        let albumID = albumID
        task = Task { @MainActor in
            let result = await scraper.scrapeMissingMetadata(albumID: albumID, parts: parts) { progress in
                if case .running = phase { phase = .running(progress) }
            }
            task = nil
            phase = .finished(result)
        }
    }

    private func stop() {
        task?.cancel()
    }

    private func close() {
        task?.cancel()
        task = nil
        dismiss()
    }
}
#endif
