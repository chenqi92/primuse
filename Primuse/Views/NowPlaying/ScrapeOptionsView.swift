import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 平台无关的 systemGray / systemGray2 替身 ── iOS 走 UIColor.systemGray*,
/// macOS 走 NSColor.secondaryLabelColor / tertiaryLabelColor (视觉接近)。
private extension Color {
    static var primuseScrapeGray: Color {
        #if os(iOS)
        return Color(UIColor.systemGray)
        #else
        return Color(NSColor.secondaryLabelColor)
        #endif
    }
    static var primuseScrapeGray2: Color {
        #if os(iOS)
        return Color(UIColor.systemGray2)
        #else
        return Color(NSColor.tertiaryLabelColor)
        #endif
    }
}

struct ScrapeOptionsView: View {
    let song: Song
    var onComplete: ((Song) -> Void)?
    /// macOS 上 ScrapeWindowController 把这个 view 装进独立 NSWindow,
    /// `@Environment(\.dismiss)` 关不掉那个窗口。传一个回调让 view 主动通知
    /// controller 收起窗口。iOS 路径不传, 走 `dismiss()`。
    var onCloseRequest: (() -> Void)? = nil

    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(SourceManager.self) private var sourceManager
    @Environment(\.dismiss) private var dismiss

    /// 取消按钮 / 完成时的统一收尾。优先走 onCloseRequest, 没传就走 dismiss。
    private func closeView() {
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
    /// 手动刮削时每个源单次返回的搜索结果上限,持久化保存,默认 20。
    /// 在选项页"手动刮削"按钮上方可调,避免搜出来不够看 / 拉太多浪费。
    /// 自动刮削不用这个参数(每个源固定取 first item, 拉 15 候选写死, limit
    /// 大没意义)。
    @AppStorage("scraperSearchLimit") private var searchLimit: Int = 20
    /// ID of the search-result row currently being fetched. Used to show a
    /// per-row spinner so users see immediate feedback after tapping —
    /// `selectManualResult` does network work (detail + cover + lyrics) and
    /// only flips `mode = .preview` once everything is downloaded.
    @State private var loadingItemID: String?

    // Per-field apply toggles (for preview)
    // 默认值：跟本地相同(unchanged)的字段不勾,跟本地不同(changed)的字段勾上,
    // 实际值在 autoScrape / selectManualResult 拉到结果后基于 changed 重新设。
    // 字段命中默认 true 是为了保留"跨设备/重刮覆盖旧值"的常见用法,避免每次
    // 都要手动勾 4-5 项。
    @State private var applyTitle = false
    @State private var applyArtist = false
    @State private var applyAlbum = false
    @State private var applyYear = false
    @State private var applyGenre = false
    @State private var applyCover = false
    @State private var applyLyrics = false

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
        #if os(macOS)
        macBody
        #else
        NavigationStack {
            Group {
                switch mode {
                case .options: optionsView
                case .preview: previewView
                case .manual: manualSearchView
                }
            }
            .navigationTitle("scrape_song")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { closeView() }
                }
            }
        }
        #endif
    }

    #if os(macOS)
    private var macBody: some View {
        VStack(spacing: 0) {
            macChrome
            Group {
                switch mode {
                case .options: macOptionsView
                case .preview: macPreviewView
                case .manual: macManualView
                }
            }
            macFooter
        }
        .frame(minWidth: 860, idealWidth: 940, minHeight: 560, idealHeight: 640)
        .background(PMColor.bg.ignoresSafeArea())
        .foregroundStyle(PMColor.text)
    }

    private var macChrome: some View {
        HStack(spacing: 14) {
            PMWindowTrafficLights()
            VStack(alignment: .leading, spacing: 2) {
                Text("刮削 · \(song.title)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text("META-07 · \(song.filePath)")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isScraping || isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private var macOptionsView: some View {
        HStack(spacing: 0) {
            macCandidateRail
                .frame(width: 320)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(PMColor.divider).frame(width: 0.5)
                }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    macSectionTitle("字段勾选")
                    VStack(spacing: 0) {
                        macToggleRow("scrape_metadata_toggle", isOn: $scrapeMetadata, detail: "标题、艺术家、专辑、年份、曲目号")
                        macToggleRow("scrape_cover_toggle", isOn: $scrapeCover, detail: "封面图会先预览, 确认后写入缓存")
                        macToggleRow("scrape_lyrics_toggle", isOn: $scrapeLyrics, detail: "支持 LRC 和逐字歌词候选")
                    }
                    .pmCard(cornerRadius: 10)

                    macSectionTitle("手动搜索")
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Text("search_limit_per_source")
                                .font(.system(size: 12.5, weight: .medium))
                            Spacer()
                            Picker("", selection: $searchLimit) {
                                ForEach([10, 20, 30, 50, 100], id: \.self) { Text("\($0)").tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .pmCard(cornerRadius: 10)

                    if let error = errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(PMColor.bad)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(PMColor.bad.opacity(0.12), in: .rect(cornerRadius: 8))
                    }
                }
                .padding(24)
            }

            macSidecarPane
                .frame(width: 280)
                .overlay(alignment: .leading) {
                    Rectangle().fill(PMColor.divider).frame(width: 0.5)
                }
        }
    }

    private var macManualView: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PMColor.brand)
                    TextField("search_query", text: $manualSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit { Task { await performManualSearch() } }
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(PMColor.card)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(PMColor.divider).frame(height: 0.5)
                }

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        if searchResults.isEmpty && !isSearching {
                            ContentUnavailableView("no_results",
                                                   systemImage: "magnifyingglass",
                                                   description: Text("no_scrape_results_desc"))
                                .frame(maxWidth: .infinity, minHeight: 280)
                        } else {
                            ForEach(searchResults) { item in
                                macManualCandidateRow(item)
                            }
                        }
                    }
                    .padding(.vertical, 14)
                }
            }
            .frame(width: 320)
            .overlay(alignment: .trailing) {
                Rectangle().fill(PMColor.divider).frame(width: 0.5)
            }

            VStack(alignment: .leading, spacing: 18) {
                macCoverCompare
                macSectionTitle("选择一个候选后预览字段差异")
                Text("从左侧候选列表选择结果后, Primuse 会拉取详情、封面和歌词, 然后进入字段勾选预览。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            macSidecarPane
                .frame(width: 280)
                .overlay(alignment: .leading) {
                    Rectangle().fill(PMColor.divider).frame(width: 0.5)
                }
        }
    }

    private var macPreviewView: some View {
        HStack(spacing: 0) {
            macCandidateRail
                .frame(width: 320)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(PMColor.divider).frame(width: 0.5)
                }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    macCoverCompare
                    macSectionTitle("字段勾选")
                    if let preview = previewResult {
                        VStack(spacing: 4) {
                            macFieldToggle(isOn: $applyTitle, label: "title", localValue: song.title, scrapedValue: preview.scrapedTitle)
                            macFieldToggle(isOn: $applyArtist, label: "artist", localValue: song.artistName ?? "-", scrapedValue: preview.scrapedArtist)
                            macFieldToggle(isOn: $applyAlbum, label: "album", localValue: song.albumTitle ?? "-", scrapedValue: preview.scrapedAlbum)
                            macFieldToggle(isOn: $applyYear, label: "year", localValue: song.year.map { "\($0)" } ?? "-", scrapedValue: preview.scrapedYear.map { "\($0)" })
                            macFieldToggle(isOn: $applyGenre, label: "genre", localValue: song.genre ?? "-", scrapedValue: preview.scrapedGenre)
                            if preview.hasCover {
                                macBooleanToggle(isOn: $applyCover, label: "cover", detail: "封面图 \(preview.coverData == nil ? "" : "已下载")")
                            }
                            if preview.hasLyrics {
                                macBooleanToggle(isOn: $applyLyrics, label: "lyrics_word", detail: "\(preview.lyricsCount) 行 · \(preview.lyricsIsWordLevel ? String(localized: "lyrics_word_level_badge") : "LRC")")
                            }
                        }
                    }
                }
                .padding(24)
            }

            macSidecarPane
                .frame(width: 280)
                .overlay(alignment: .leading) {
                    Rectangle().fill(PMColor.divider).frame(width: 0.5)
                }
        }
    }

    private var macCandidateRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                macSectionTitle("候选")
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                macCurrentSongCandidate
                ForEach(searchResults.prefix(4)) { item in
                    macManualCandidateRow(item)
                }
            }
            .padding(.vertical, 14)
        }
        .background(PMColor.bg)
    }

    private var macCurrentSongCandidate: some View {
        HStack(spacing: 10) {
            CachedArtworkView(coverRef: song.coverArtFileName,
                              songID: song.id,
                              size: 48,
                              cornerRadius: 5,
                              sourceID: song.sourceID,
                              filePath: song.filePath)
            VStack(alignment: .leading, spacing: 3) {
                Text("当前文件")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textFaint)
                    .textCase(.uppercase)
                Text(song.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(song.artistName ?? "-")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            Text("本地")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(PMColor.textFaint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(PMColor.brand.opacity(0.14))
        .overlay(alignment: .leading) {
            Rectangle().fill(PMColor.brand).frame(width: 3)
        }
    }

    private func macManualCandidateRow(_ item: SearchResultItem) -> some View {
        Button {
            Task { await selectManualResult(item) }
        } label: {
            HStack(spacing: 10) {
                ScraperCoverThumbnail(
                    urlString: item.coverUrl,
                    externalId: item.externalId,
                    sourceConfig: item.sourceConfig
                )
                .frame(width: 48, height: 48)
                .overlay {
                    if loadingItemID == item.id {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.45))
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.source)
                        .font(.system(size: 11.5))
                        .foregroundStyle(PMColor.textFaint)
                        .textCase(.uppercase)
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text([item.artist, item.album].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                if let duration = item.durationText {
                    Text(duration)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(PMColor.textMuted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isScraping)
    }

    private var macCoverCompare: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("current")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                CachedArtworkView(coverRef: song.coverArtFileName,
                                  songID: song.id,
                                  size: 120,
                                  cornerRadius: 6,
                                  sourceID: song.sourceID,
                                  filePath: song.filePath)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(previewSource == .manual ? "手动候选" : "候选")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
                if let preview = previewResult,
                   let data = preview.coverData,
                   let image = PlatformImage(data: data) {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(PMColor.rowHover)
                        .frame(width: 120, height: 120)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(PMColor.textFaint)
                        }
                }
            }
        }
    }

    private var macSidecarPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            macSectionTitle("Sidecar 回写")
            VStack(alignment: .leading, spacing: 8) {
                macSidecarRow("cover.jpg", enabled: scrapeCover || applyCover)
                macSidecarRow(".lrc", enabled: scrapeLyrics || applyLyrics)
                Text("写入到源目录旁路文件, 非主线程执行。")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .padding(.top, 4)
            }

            macSectionTitle("预览歌词")
            ScrollView(.vertical, showsIndicators: false) {
                Text(macLyricsPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(PMColor.text)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .background(PMColor.bgDeep)
    }

    private var macFooter: some View {
        HStack(spacing: 10) {
            if mode == .manual || mode == .preview {
                Button("back_to_options") { mode = .options }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
            }
            Spacer()
            Button("cancel") { closeView() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(PMColor.text)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(PMColor.cardBorder, lineWidth: 0.5) }

            switch mode {
            case .options:
                Button("manual_scrape") { Task { await manualSearch() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.text)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(PMColor.cardBorder, lineWidth: 0.5) }
                    .disabled(isSearching)

                Button("auto_scrape") { Task { await autoScrape() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(PMColor.brand, in: .rect(cornerRadius: 6))
                    .disabled(isScraping || (!scrapeMetadata && !scrapeCover && !scrapeLyrics))
            case .manual:
                Button("searching") { Task { await performManualSearch() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(PMColor.brand, in: .rect(cornerRadius: 6))
                    .disabled(manualSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            case .preview:
                Button("apply_changes") { applySelectedChanges() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background((hasAnySelectedChange ? PMColor.brand : PMColor.textFaint), in: .rect(cornerRadius: 6))
                    .disabled(!hasAnySelectedChange)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(PMColor.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private func macToggleRow(_ label: LocalizedStringKey, isOn: Binding<Bool>, detail: String) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(PMColor.divider).frame(height: 0.5) }
    }

    private func macFieldToggle(isOn: Binding<Bool>, label: LocalizedStringKey, localValue: String, scrapedValue: String?) -> some View {
        guard let scrapedValue else {
            return AnyView(EmptyView())
        }
        return AnyView(macBooleanToggle(
            isOn: isOn,
            label: label,
            detail: "\(localValue) → \(scrapedValue)"
        ))
    }

    private func macBooleanToggle(isOn: Binding<Bool>, label: LocalizedStringKey, detail: String) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.checkbox)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PMColor.text)
                .frame(width: 82, alignment: .leading)
            Text(verbatim: detail)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(PMColor.textMuted)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(PMColor.rowHover, in: .rect(cornerRadius: 5))
    }

    private func macSidecarRow(_ suffix: String, enabled: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? PMColor.ok : PMColor.textFaint)
            Text(verbatim: "\(song.title)-\(suffix)")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(PMColor.textMuted)
                .lineLimit(1)
        }
    }

    private func macSectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
    }

    private var macLyricsPreview: String {
        if let preview = previewResult,
           let lines = preview.lyricsLines,
           lines.isEmpty == false {
            return lines.prefix(8).map { line in
                "[\(formatDuration(line.timestamp))] \(line.text)"
            }.joined(separator: "\n")
        }
        return """
        [ar:\(song.artistName ?? "-")]
        [ti:\(song.title)]
        [00:00.00]\(song.title)
        [00:18.42]...
        [00:22.13]...
        """
    }
    #endif

    // MARK: - Options (what to scrape)

    private var optionsView: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: 56, cornerRadius: 8, sourceID: song.sourceID, filePath: song.filePath)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title).font(.subheadline).fontWeight(.semibold).lineLimit(1)
                        Text(song.artistName ?? "").font(.caption).foregroundStyle(Color.primuseScrapeGray).lineLimit(1)
                        if song.duration.sanitizedDuration > 0 {
                            Text(formatDuration(song.duration)).font(.caption2).foregroundStyle(Color.primuseScrapeGray2)
                        }
                    }
                }
            }

            Section("scrape_options") {
                Toggle("scrape_metadata_toggle", isOn: $scrapeMetadata)
                Toggle("scrape_cover_toggle", isOn: $scrapeCover)
                Toggle("scrape_lyrics_toggle", isOn: $scrapeLyrics)
            }

            Section {
                // Auto scrape (preview before apply)
                Button {
                    Task { await autoScrape() }
                } label: {
                    HStack {
                        Label("auto_scrape", systemImage: "wand.and.stars")
                            .fontWeight(.medium)
                        Spacer()
                        if isScraping { ProgressView() }
                    }
                }
                .disabled(isScraping || (!scrapeMetadata && !scrapeCover && !scrapeLyrics))

                // Manual search
                Button {
                    Task { await manualSearch() }
                } label: {
                    HStack {
                        Label("manual_scrape", systemImage: "magnifyingglass")
                        Spacer()
                        if isSearching { ProgressView() }
                    }
                }
                .disabled(isSearching)

                // 手动搜索每个源返回上限 — 持久化到 AppStorage
                Picker(selection: $searchLimit) {
                    ForEach([10, 20, 30, 50, 100], id: \.self) { Text("\($0)").tag($0) }
                } label: {
                    Label("search_limit_per_source", systemImage: "list.number")
                }
            }

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
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
                                Text("cover").font(.caption).foregroundStyle(Color.primuseScrapeGray)
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
                                Text("lyrics_word").font(.caption).foregroundStyle(Color.primuseScrapeGray).frame(width: 45, alignment: .leading)
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

                Section {
                    if previewSource == .manual {
                        Button { mode = .manual } label: {
                            Text(String(localized: "back_to_results"))
                        }
                    }
                    Button { mode = .options } label: { Text("back_to_options") }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("apply_changes") {
                    applySelectedChanges()
                }
                .fontWeight(.semibold)
                .disabled(!hasAnySelectedChange)
            }
        }
    }

    @ViewBuilder
    private func fieldToggle(isOn: Binding<Bool>, label: LocalizedStringKey, localValue: String, scrapedValue: String?, isChanged: Bool) -> some View {
        if let scraped = scrapedValue {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundStyle(Color.primuseScrapeGray)
                    if isChanged {
                        HStack(spacing: 4) {
                            Text(localValue).font(.caption2).foregroundStyle(Color.primuseScrapeGray).lineLimit(1)
                            Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(Color.primuseScrapeGray2)
                            Text(scraped).font(.caption2).fontWeight(.medium).foregroundStyle(.green).lineLimit(1)
                        }
                    } else {
                        Text(scraped).font(.caption2).foregroundStyle(.primary).lineLimit(1)
                    }
                }
            }
            .tint(isChanged ? .green : Color.primuseScrapeGray)
        }
    }

    @ViewBuilder
    private func statusBadge(hasLocal: Bool, hasScraped: Bool, isChanged: Bool) -> some View {
        if isChanged {
            HStack(spacing: 3) {
                Image(systemName: hasLocal ? "checkmark" : "xmark")
                    .font(.caption2).foregroundStyle(Color.primuseScrapeGray)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8)).foregroundStyle(Color.primuseScrapeGray2)
                Image(systemName: "checkmark")
                    .font(.caption2).foregroundStyle(.green)
            }
        } else {
            Text(String(localized: "unchanged")).font(.caption2).foregroundStyle(Color.primuseScrapeGray2)
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

        // Swift 编译器对长 || 链 type-check 超时, 拆成数组 reduce。
        let conditions: [Bool] = [
            titleChanged && applyTitle,
            artistChanged && applyArtist,
            albumChanged && applyAlbum,
            yearChanged && applyYear,
            genreChanged && applyGenre,
            p.hasCover && applyCover,
            p.hasLyrics && applyLyrics
        ]
        return conditions.contains(true)
    }

    // MARK: - Manual Search

    private var manualSearchView: some View {
        List {
            if searchResults.isEmpty && !isSearching {
                ContentUnavailableView("no_results", systemImage: "magnifyingglass",
                    description: Text("no_scrape_results_desc"))
            } else {
                ForEach(searchResults) { item in
                    Button {
                        Task { await selectManualResult(item) }
                    } label: {
                        HStack(spacing: 10) {
                            // Cover art thumbnail — overlay a spinner once tapped so
                            // the user sees immediate feedback while the detail /
                            // cover / lyrics requests are in flight.
                            ScraperCoverThumbnail(
                                urlString: item.coverUrl,
                                externalId: item.externalId,
                                sourceConfig: item.sourceConfig
                            )
                            .overlay {
                                if loadingItemID == item.id {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.black.opacity(0.45))
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                }
                            }
                            .opacity(loadingItemID == nil || loadingItemID == item.id ? 1 : 0.5)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.title).font(.subheadline).fontWeight(.medium).lineLimit(1)
                                    Spacer()
                                    if let dur = item.durationText {
                                        Text(dur).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                                HStack(spacing: 4) {
                                    if let artist = item.artist {
                                        Text(artist).font(.caption).foregroundStyle(Color.primuseScrapeGray)
                                    }
                                    if let album = item.album {
                                        Text("·").font(.caption).foregroundStyle(Color.primuseScrapeGray2)
                                        Text(album).font(.caption).foregroundStyle(Color.primuseScrapeGray2)
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
                            .opacity(loadingItemID == nil || loadingItemID == item.id ? 1 : 0.5)
                        }
                        .padding(.vertical, 2)
                    }
                    .disabled(isScraping)
                }
            }
        }
        .searchable(text: $manualSearchQuery, prompt: Text("search_query"))
        .onSubmit(of: .search) {
            Task { await performManualSearch() }
        }
        .overlay {
            if isSearching {
                ProgressView("searching").padding()
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("back_to_options") { mode = .options }
            }
        }
        .onChange(of: searchLimit) { _, _ in
            // 用户在选项页改了 limit 后回来再搜,自动用新值;此处保险:已搜过
            // 的话立刻重搜让结果数量同步。
            if !manualSearchQuery.isEmpty {
                Task { await performManualSearch() }
            }
        }
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

            // 跟本地相同的字段(unchanged)默认不勾,跟本地不同的(changed)默认勾。
            applyTitle = updated.title != song.title
            applyArtist = updated.artistName != song.artistName
            applyAlbum = updated.albumTitle != song.albumTitle
            applyYear = updated.year != song.year && updated.year != nil
            applyGenre = updated.genre != song.genre && updated.genre != nil
            applyCover = coverData != nil
            applyLyrics = lyricsLines != nil && !lyricsLines!.isEmpty

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
                    query: manualSearchQuery, artist: nil, album: nil, limit: searchLimit
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
        loadingItemID = item.id
        defer { loadingItemID = nil }

        plog("👉 selectManualResult: src=\(item.sourceConfig.type.rawValue) title='\(item.title)' externalId=\(item.externalId.prefix(60))")

        do {
            let scraper = MusicScraperFactory.create(for: item.sourceConfig)
            let detail = try await scraper.getDetail(externalId: item.externalId)
            plog("👉 detail returned: title='\(detail?.title ?? "nil")' artist='\(detail?.artist ?? "nil")'")

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

            // Download cover art if available (keep in memory, don't store to disk yet)
            var hasCover = false
            var coverData: Data?
            // Prefer search result's coverUrl if detail doesn't have one
            let coverUrl = detail?.coverUrl ?? item.coverUrl
            if let coverUrl,
               let data = try? await ConfigurableScraper.downloadResource(
                from: coverUrl,
                sourceConfig: item.sourceConfig,
                timeout: 10
               ) {
                coverData = data
                hasCover = true
            }

            // Download lyrics if available (keep in memory, don't store to disk yet)
            var hasLyrics = false
            var lyricsCount = 0
            var lyricsLines: [LyricLine]?
            let lyricsResult = try? await scraper.getLyrics(externalId: item.externalId)
            plog("👉 getLyrics returned: hasResult=\(lyricsResult != nil) hasLyrics=\(lyricsResult?.hasLyrics ?? false) lrcLen=\(lyricsResult?.lrcContent?.count ?? 0)")
            if let lyricsResult,
               lyricsResult.hasLyrics,
               let lrc = lyricsResult.lrcContent, !lrc.isEmpty {
                let parsed = LyricsParser.parse(lrc)
                plog("👉 LyricsParser parsed \(parsed.count) lines, wordLevel=\(parsed.contains { $0.isWordLevel })")
                if !parsed.isEmpty {
                    lyricsLines = parsed
                    hasLyrics = true
                    lyricsCount = parsed.count
                }
            }

            isScraping = false

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
            // 跟本地相同的字段(unchanged)默认不勾,跟本地不同的(changed)默认勾。
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
            isScraping = false
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

        let needsCover = preview.hasCover && applyCover
        let needsLyrics = preview.hasLyrics && applyLyrics
        let coverData = preview.coverData
        let lyricsLines = preview.lyricsLines

        // Compute filenames synchronously — `expected*FileName` is just a hash,
        // cheap to call before dismiss so `final` is fully populated.
        let coverFileName: String? = needsCover && coverData != nil
            ? MetadataAssetStore.shared.expectedCoverFileName(for: song.id)
            : song.coverArtFileName
        let lyricsFileName: String? = needsLyrics && lyricsLines != nil
            ? MetadataAssetStore.shared.expectedLyricsFileName(for: song.id)
            : song.lyricsFileName

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

        // 先 dismiss, 把 replaceSong (rebuildIndex/persistSnapshot/...)
        // 和 sidecar 网络写都挪到 sheet 关闭之后, 避免主线程阻塞导致用户
        // 觉得"应用修改卡死"。Sidecar Task 在后台跑 NAS 登录时若被 iOS
        // 强杀, 进程级清理会终结它, 不会留下半成品。
        let lib = library
        let sm = sourceManager
        let songID = song.id
        let onCompleteRef = onComplete
        closeView()

        Task { @MainActor in
            // Persist assets to disk (atomic, fast)
            if needsCover, let data = coverData {
                MetadataAssetStore.shared.storeCoverSync(data, for: songID)
                // cacheKey 基于 songID, 用 hash 文件名 invalidate 不命中。
                // 下面 onCompleteRef closure (line 264) 用 songID invalidate 才有效。
            }
            if needsLyrics, let lines = lyricsLines {
                let wordLevel = lines.filter { $0.isWordLevel }.count
                plog("👉 ScrapeOptionsView.apply lyrics=\(lines.count) wordLevelLines=\(wordLevel) firstSyllables=\(lines.first?.syllables?.count ?? -1)")
                MetadataAssetStore.shared.storeLyricsSync(lines, for: songID)
            }

            lib.replaceSong(final)
            // 通知正在播放的 mac NowPlaying / mini player / 桌面歌词刷新歌词
            // (它们 onAppear 时只读了一次, 不重新订阅 song id 的话拿不到新歌词)。
            NotificationCenter.default.post(name: .primuseLyricsDidChange, object: final.id)
            onCompleteRef?(final)

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
            if needsCover || needsLyrics {
                let titleSnapshot = final.title
                let songDir = (final.filePath as NSString).deletingLastPathComponent
                let baseNameNoExt = ((final.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
                let finalSnapshot = final
                Task.detached(priority: .utility) {
                    plog("📝 Sidecar: writing back to source for '\(titleSnapshot)'")
                    do {
                        try await Self.writeSidecarWithTimeout(
                            seconds: 30,
                            sourceManager: sm,
                            song: finalSnapshot,
                            coverData: needsCover ? coverData : nil,
                            lyricsLines: needsLyrics ? lyricsLines : nil
                        ) { writeResult in
                            plog("📝 Sidecar: result cover=\(writeResult.coverWritten) lyrics=\(writeResult.lyricsWritten)")

                            if writeResult.coverWritten {
                                let coverPath = (songDir as NSString).appendingPathComponent("\(baseNameNoExt)-cover.jpg")
                                var refSong = finalSnapshot
                                refSong.coverArtFileName = coverPath
                                // sidecar 已落盘 → 回写 hash cache 作为可信 mirror。
                                // 不要先 invalidate 再 cacheCover ── 制造空窗期, 期间 view
                                // reload 会拿不到本地 cache 被迫走 NAS, 拉到 HTTP 端缓存的旧
                                // 文件就显示旧封面。直接覆写。
                                if let data = coverData {
                                    await MetadataAssetStore.shared.cacheCover(data, forSongID: songID)
                                }
                                // 不要把 song.lyricsFileName 改成 NAS 的 .lrc 路径 ──
                                // 那只是给其他播放器看的备份, 内容是行级 (没字时间)。
                                // 字级数据在本地 App Support hash JSON 里, song 必须
                                // 一直指向那个, 否则下次读会从 NAS .lrc 拿行级歌词。
                                await MainActor.run {
                                    CachedArtworkView.invalidateCache(for: songID)
                                    lib.replaceSong(refSong)
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
    }

    // MARK: - Helpers

    /// 给 sidecar 写回流程加超时兜底。withThrowingTaskGroup race 真实工作和
    /// sleep, 谁先完成谁赢, 输的被 cancelAll 中断。
    ///
    /// 必须用 detached 调用方调用本函数 ── 否则 sleep 这条 task 会和 caller 共享
    /// main actor cooperative thread, 真 hang 时谁也跑不了。
    private static func writeSidecarWithTimeout(
        seconds: TimeInterval,
        sourceManager: SourceManager,
        song: Song,
        coverData: Data?,
        lyricsLines: [LyricLine]?,
        applyResult: @escaping @Sendable (SidecarWriteService.WriteResult) async -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // SourceManager 是 @MainActor, await 会切到 main actor 上跑
                // auxiliaryConnector / connect; 真正的 NAS IO (writeSidecars)
                // 走 SidecarWriteService actor (背景 executor), 不占 main actor。
                let connector = try await sourceManager.auxiliaryConnector(for: song)
                let writeResult = await SidecarWriteService.shared.writeSidecars(
                    for: song,
                    using: connector,
                    coverData: coverData,
                    lyricsLines: lyricsLines
                )
                await applyResult(writeResult)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            // 等任意一个先完成。如果是真实工作完成 → 第二个 sleep task 被 cancelAll
            // 中断; 如果是 sleep 先完成 (即 30s 超时) → 第二个 task 被 cancelAll
            // 中断, throw 也被 group 抛给外层 catch。
            try await group.next()
            group.cancelAll()
        }
    }

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
