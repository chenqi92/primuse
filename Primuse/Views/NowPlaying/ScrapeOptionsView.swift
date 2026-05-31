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
    @State private var applyTrack = false
    @State private var applyGenre = false
    @State private var applyCover = false
    @State private var applyLyrics = false

    #if os(macOS)
    /// 候选优先单页 (macOS): 窗口打开后只触发一次自动搜索 + 自动选中第一个候选。
    @State private var macDidInitialLoad = false
    /// 当前在左栏选中的候选 id, 用于高亮 + 取中栏封面对比的来源名。
    @State private var selectedItemID: String?
    #endif

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
        var scrapedTrackNumber: Int?
        var scrapedGenre: String?
        var hasCover: Bool
        var hasLyrics: Bool
        // 候选封面像素尺寸 / 字节数, 用于中栏封面对比下方的 "2400×2400 · 612 KB"。
        var coverPixelWidth: Int? = nil
        var coverPixelHeight: Int? = nil
        var lyricsIsWordLevel: Bool { lyricsLines?.contains(where: { $0.isWordLevel }) ?? false }
    }

    struct SearchResultItem: Identifiable {
        let id: String
        let title: String
        let artist: String?
        let album: String?
        let year: Int?
        let durationMs: Int?
        let coverUrl: String?
        let externalId: String
        let sourceConfig: ScraperSourceConfig
        /// 0...1 匹配度 (时长 + 标题 + 艺术家 归一化打分), 用于候选行右侧的 % 显示与排序。
        var confidence: Double = 0

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
            macScrapeBoard
            macFooter
        }
        // 三栏的硬最小宽度 ≈ 候选 320 + sidecar 280 + 封面对比两张 120 图 ≈ 906,
        // 所以窗口最小宽必须 ≥ 这个值, 否则内容被居中后左右两边都被窗口圆角裁掉
        // (左栏 "候选" 被切成 "选")。maxWidth/maxHeight 撑满窗口, 不用 idealWidth。
        .frame(minWidth: 920, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .background(PMColor.bg.ignoresSafeArea())
        .foregroundStyle(PMColor.text)
        // 自定义 44pt title bar 要占住真正的窗口顶边 —— 跟 MacContentView 一样
        // 忽略顶部 safe area, 否则 titlebar 上方会多出一条系统 gutter。
        .ignoresSafeArea(.container, edges: .top)
        .task {
            // 窗口打开 → 自动用智能 query 搜一遍候选并选中第一个。只跑一次,
            // 用户回到窗口 / view 重建不重复联网。
            guard !macDidInitialLoad else { return }
            macDidInitialLoad = true
            await macInitialLoad()
        }
    }

    private var macChrome: some View {
        HStack(spacing: 14) {
            PMWindowTrafficLights(closeOnly: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("刮削 · \(song.title)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(song.filePath)
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
        .pmWindowDragRegion()
        .overlay(alignment: .bottom) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    /// 候选优先单页: 左候选列表 / 中封面对比 + 字段勾选 / 右 Sidecar 预览。
    private var macScrapeBoard: some View {
        HStack(spacing: 0) {
            macCandidateRail
                .frame(width: 320)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(PMColor.divider).frame(width: 0.5)
                }

            macDiffPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            macSidecarPane
                .frame(width: 280)
                .overlay(alignment: .leading) {
                    Rectangle().fill(PMColor.divider).frame(width: 0.5)
                }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Left — candidates

    private var macSelectedItem: SearchResultItem? {
        searchResults.first { $0.id == selectedItemID }
    }

    private var macCandidateRail: some View {
        VStack(spacing: 0) {
            HStack {
                macSectionTitle("候选 (\(searchResults.count))")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            macRailSearchField
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if isSearching && searchResults.isEmpty {
                        macRailPlaceholder(icon: "magnifyingglass", text: "搜索候选中…")
                    } else if searchResults.isEmpty {
                        macRailPlaceholder(icon: "questionmark.magnifyingglass",
                                           text: String(localized: "no_scrape_results_desc"))
                    } else {
                        ForEach(searchResults) { item in
                            macCandidateRow(item)
                        }
                    }
                }
                .padding(.bottom, 14)
            }
        }
        .background(PMColor.bg)
    }

    private var macRailSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PMColor.textFaint)
            TextField("", text: $manualSearchQuery, prompt: Text(verbatim: "搜索候选"))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { Task { await macRunSearch() } }
            if !manualSearchQuery.isEmpty {
                Button { manualSearchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(PMColor.card, in: .rect(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(PMColor.cardBorder, lineWidth: 0.5) }
    }

    private func macRailPlaceholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(PMColor.textFaint)
            Text(verbatim: text)
                .font(.system(size: 12))
                .foregroundStyle(PMColor.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(.horizontal, 24)
    }

    private func macCandidateRow(_ item: SearchResultItem) -> some View {
        let isSelected = item.id == selectedItemID
        return Button {
            selectedItemID = item.id
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
                        RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.45))
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.source)
                        .font(.system(size: 11.5))
                        .foregroundStyle(PMColor.textFaint)
                        .textCase(.uppercase)
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(verbatim: macCandidateSubtitle(item))
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: "\(Int((item.confidence * 100).rounded()))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(item.confidence > 0.9 ? PMColor.ok : PMColor.brand)
                    if item.sourceConfig.type.supportsWordLevelLyrics {
                        Text("歌词")
                            .font(.system(size: 9.5))
                            .textCase(.uppercase)
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? PMColor.brand.opacity(0.14) : Color.clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? PMColor.brand : Color.clear)
                    .frame(width: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isScraping)
    }

    private func macCandidateSubtitle(_ item: SearchResultItem) -> String {
        var parts: [String] = []
        if let a = item.artist, !a.isEmpty { parts.append(a) }
        if let y = item.year { parts.append(String(y)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    // MARK: Middle — cover compare + field diff

    private var macDiffPane: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                macCoverCompare

                if let preview = previewResult {
                    VStack(alignment: .leading, spacing: 8) {
                        macSectionTitle("字段勾选")
                        VStack(spacing: 4) {
                            macFieldRows(preview)
                        }
                    }
                } else if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(PMColor.bad)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PMColor.bad.opacity(0.12), in: .rect(cornerRadius: 8))
                } else {
                    macDiffEmptyState
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// 中栏没有可预览的字段时的占位 —— 按真实状态区分: 搜索中 / 拉详情中 /
    /// 搜不到候选 / 有候选但还没选, 让用户知道下一步该干嘛。
    @ViewBuilder
    private var macDiffEmptyState: some View {
        VStack(spacing: 10) {
            if isSearching || isScraping {
                ProgressView().controlSize(.small)
                Text(verbatim: isSearching ? "正在搜索候选…" : "正在拉取候选详情…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
            } else if searchResults.isEmpty {
                Image(systemName: "questionmark.magnifyingglass")
                    .font(.system(size: 26))
                    .foregroundStyle(PMColor.textFaint)
                Text(verbatim: "没有搜到候选")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text(verbatim: "在左侧搜索框换个关键词重搜，或到设置里确认已启用刮削源。")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            } else {
                Image(systemName: "arrow.left")
                    .font(.system(size: 22))
                    .foregroundStyle(PMColor.textFaint)
                Text(verbatim: "从左侧候选中选择一个结果")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
        .padding(.top, 8)
    }

    private var macCoverCompare: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("当前")
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
                Text(verbatim: macCandidateCoverLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
                macCandidateCover
                if let meta = macCoverMeta {
                    Text(verbatim: meta)
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var macCandidateCoverLabel: String {
        if let src = macSelectedItem?.source { return "\(src) 候选" }
        return "候选"
    }

    /// 候选封面 + 写入开关: 点击封面切换是否写入 (默认开)。设计稿没有单独的
    /// "封面"勾选行, 用封面本身做开关, 右上角的勾表示会写入。
    @ViewBuilder
    private var macCandidateCover: some View {
        if let preview = previewResult, preview.hasCover,
           let data = preview.coverData, let image = PlatformImage(data: data) {
            Button { applyCover.toggle() } label: {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: applyCover ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(applyCover ? PMColor.ok : Color.white.opacity(0.85))
                            .padding(2)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                            .padding(5)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(applyCover ? PMColor.brand : Color.clear, lineWidth: 2)
                    }
                    .opacity(applyCover ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .help(applyCover ? "点击取消写入此封面" : "点击写入此封面")
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

    private var macCoverMeta: String? {
        guard let preview = previewResult, preview.hasCover, let data = preview.coverData else { return nil }
        let kb = max(1, data.count / 1024)
        if let w = preview.coverPixelWidth, let h = preview.coverPixelHeight {
            return "\(w)×\(h) · \(kb) KB"
        }
        return "\(kb) KB"
    }

    @ViewBuilder
    private func macFieldRows(_ preview: ScrapePreview) -> some View {
        macTextFieldRow(title: "标题", isOn: $applyTitle,
                        local: song.title, scraped: preview.scrapedTitle)
        macTextFieldRow(title: "艺术家", isOn: $applyArtist,
                        local: song.artistName, scraped: preview.scrapedArtist)
        macTextFieldRow(title: "专辑", isOn: $applyAlbum,
                        local: song.albumTitle, scraped: preview.scrapedAlbum)
        macTextFieldRow(title: "发行年", isOn: $applyYear,
                        local: song.year.map(String.init), scraped: preview.scrapedYear.map(String.init))
        macTextFieldRow(title: "曲目号", isOn: $applyTrack,
                        local: song.trackNumber.map(String.init), scraped: preview.scrapedTrackNumber.map(String.init))
        macTextFieldRow(title: "流派", isOn: $applyGenre,
                        local: song.genre, scraped: preview.scrapedGenre)
        if preview.hasLyrics {
            macCheckRow(title: "歌词 (.lrc)", isOn: $applyLyrics, diff: macLyricsDiff(preview))
        }
        if !hasAnyScrapeResult(preview) {
            Label(String(localized: "scrape_no_changes"), systemImage: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(PMColor.textMuted)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func macTextFieldRow(title: String, isOn: Binding<Bool>, local: String?, scraped: String?) -> some View {
        if let scraped, !scraped.isEmpty {
            let localText = (local?.isEmpty == false) ? local! : "?"
            let changed = local != scraped
            macCheckRow(title: title, isOn: isOn,
                        diff: changed ? "\(localText) → \(scraped)" : scraped)
        }
    }

    private func macLyricsDiff(_ preview: ScrapePreview) -> String {
        let from = song.lyricsFileName == nil ? "空" : "已有"
        var detail = "\(from) → \(preview.lyricsCount) 行"
        if let src = macSelectedItem?.source { detail += " · 来自 \(src)" }
        if preview.lyricsIsWordLevel { detail += " · 逐字" }
        return detail
    }

    private func macCheckRow(title: String, isOn: Binding<Bool>, diff: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 10) {
                macCheckbox(on: isOn.wrappedValue)
                Text(verbatim: title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .frame(width: 72, alignment: .leading)
                Text(verbatim: diff)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(PMColor.rowHover, in: .rect(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func macCheckbox(on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(on ? PMColor.brand : Color.clear)
            .frame(width: 14, height: 14)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(on ? PMColor.brand : PMColor.dividerStrong, lineWidth: 1)
            }
            .overlay {
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
    }

    // MARK: Right — sidecar

    private var macSidecarPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                macSectionTitle("Sidecar 回写")
                macSidecarRow(suffix: "-cover.jpg",
                              enabled: applyCover && (previewResult?.hasCover ?? false))
                macSidecarRow(suffix: ".lrc",
                              enabled: applyLyrics && (previewResult?.hasLyrics ?? false))
                Text("写入到源目录旁路文件 · 30s 超时 · 非主线程")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 8) {
                macSectionTitle("预览歌词")
                ScrollView(.vertical, showsIndicators: false) {
                    Text(verbatim: macLyricsPreview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(PMColor.text)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 让歌词预览撑满右栏剩余高度, 不再留大片空白; 只在最底边渐隐一小段,
                // 暗示"下面还有", 而不是把整段歌词都淡掉。
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.9),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PMColor.bgDeep)
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

    /// Sidecar 文件名跟着源音频文件走 (`<basename>-cover.jpg` / `<basename>.lrc`),
    /// 不是歌曲标题 —— 跟 SidecarWriteService 实际写盘逻辑一致。
    private var macSidecarBaseName: String {
        let last = (song.filePath as NSString).lastPathComponent
        let base = (last as NSString).deletingPathExtension
        return base.isEmpty ? song.title : base
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
            var out: [String] = []
            if let artist = preview.scrapedArtist ?? song.artistName, !artist.isEmpty {
                out.append("[ar:\(artist)]")
            }
            out.append("[ti:\(preview.scrapedTitle ?? song.title)]")
            if let album = preview.scrapedAlbum ?? song.albumTitle, !album.isEmpty {
                out.append("[al:\(album)]")
            }
            // 多展示一些行把右栏撑满 (可滚动), 不再只给 8 行。封顶 80 行防止
            // 个别超长歌词把文本渲染拖重。
            out += lines.prefix(80).map { line in
                "[\(formatDuration(line.timestamp))]\(line.text)"
            }
            return out.joined(separator: "\n")
        }
        return """
        [ar:\(song.artistName ?? "-")]
        [ti:\(song.title)]
        [00:00.00]\(song.title)
        [00:18.42]…
        [00:22.13]…
        """
    }

    // MARK: macOS footer & load

    private var macFooter: some View {
        HStack(spacing: 10) {
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

            Button("apply_changes") { applySelectedChanges() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background((hasAnySelectedChange ? PMColor.brand : PMColor.textFaint), in: .rect(cornerRadius: 6))
                .disabled(!hasAnySelectedChange)
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(PMColor.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private func macInitialLoad() async {
        manualSearchQuery = ScraperManager.searchTitle(song.title, artist: song.artistName)
        if let artist = song.artistName,
           !artist.isEmpty,
           ScraperManager.shouldAppendArtist(to: manualSearchQuery, artist: artist) {
            manualSearchQuery += " \(artist)"
        }
        await macRunSearch()
    }

    /// 搜一遍候选, 然后自动选中匹配度最高 (排序后第一个) 的候选并拉详情。
    private func macRunSearch() async {
        await performManualSearch()
        if let first = searchResults.first {
            selectedItemID = first.id
            await selectManualResult(first)
        } else {
            selectedItemID = nil
            previewResult = nil
        }
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
        let trackChanged = p.scrapedTrackNumber != nil && p.scrapedTrackNumber != song.trackNumber
        let genreChanged = p.scrapedGenre != nil && p.scrapedGenre != song.genre

        // Swift 编译器对长 || 链 type-check 超时, 拆成数组 reduce。
        let conditions: [Bool] = [
            titleChanged && applyTitle,
            artistChanged && applyArtist,
            albumChanged && applyAlbum,
            yearChanged && applyYear,
            trackChanged && applyTrack,
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
            let coverPx = coverData.flatMap { coverPixelSize(from: $0) }

            previewResult = ScrapePreview(
                updatedSong: updated, coverData: coverData, lyricsCount: lyricsCount,
                lyricsLines: lyricsLines,
                scrapedTitle: updated.title,
                scrapedArtist: updated.artistName,
                scrapedAlbum: updated.albumTitle,
                scrapedYear: updated.year,
                scrapedTrackNumber: updated.trackNumber,
                scrapedGenre: updated.genre,
                hasCover: coverData != nil,
                hasLyrics: lyricsLines != nil && !lyricsLines!.isEmpty,
                coverPixelWidth: coverPx?.0,
                coverPixelHeight: coverPx?.1
            )

            // 跟本地相同的字段(unchanged)默认不勾,跟本地不同的(changed)默认勾。
            applyTitle = updated.title != song.title
            applyArtist = updated.artistName != song.artistName
            applyAlbum = updated.albumTitle != song.albumTitle
            applyYear = updated.year != song.year && updated.year != nil
            applyTrack = updated.trackNumber != song.trackNumber && updated.trackNumber != nil
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
                        year: item.year,
                        durationMs: item.durationMs,
                        coverUrl: item.coverUrl,
                        externalId: item.externalId,
                        sourceConfig: config,
                        confidence: scrapeConfidence(title: item.title, artist: item.artist, durationMs: item.durationMs)
                    ))
                }
            } catch {
                plog("⚠️ Search failed for \(config.type.rawValue): \(ConfigurableScraper.describeNetworkError(error))")
            }
        }

        // 按匹配度 (时长 + 标题 + 艺术家 综合分) 降序, 高的排前面 —— 候选优先单页
        // 默认自动选中第一个, 所以排序直接决定首选候选。
        aggregatedResults.sort { $0.confidence > $1.confidence }

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
            let coverPx = coverData.flatMap { coverPixelSize(from: $0) }

            previewResult = ScrapePreview(
                updatedSong: updated, coverData: coverData, lyricsCount: lyricsCount,
                lyricsLines: lyricsLines,
                scrapedTitle: updated.title,
                scrapedArtist: updated.artistName,
                scrapedAlbum: updated.albumTitle,
                scrapedYear: updated.year,
                scrapedTrackNumber: updated.trackNumber,
                scrapedGenre: updated.genre,
                hasCover: hasCover,
                hasLyrics: hasLyrics,
                coverPixelWidth: coverPx?.0,
                coverPixelHeight: coverPx?.1
            )
            // 跟本地相同的字段(unchanged)默认不勾,跟本地不同的(changed)默认勾。
            applyTitle = updated.title != song.title
            applyArtist = updated.artistName != song.artistName
            applyAlbum = updated.albumTitle != song.albumTitle
            applyYear = updated.year != song.year && updated.year != nil
            applyTrack = updated.trackNumber != song.trackNumber && updated.trackNumber != nil
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
        let trackChanged = preview.scrapedTrackNumber != nil && preview.scrapedTrackNumber != song.trackNumber
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
            trackNumber: (trackChanged && applyTrack) ? u.trackNumber : song.trackNumber,
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
                CachedArtworkView.invalidateCache(for: songID)
                if let oldRef = song.coverArtFileName {
                    CachedArtworkView.invalidateCache(for: oldRef)
                }
                // cacheKey 基于 songID, 这里主动发全局 artwork invalidation,
                // 让全部歌曲列表、底栏播放器等已挂载封面位立即重新读取。
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

    /// 候选匹配度 0...1。镜像 ScraperManager.score 的权重 (时长 50 / 标题 30 /
    /// 艺术家 20), 按"当前可用的信号维度"归一化 —— 没时长 / 没艺术家信息时不会
    /// 因为拿不到那部分分而被压低百分比。仅用于显示与排序, 不参与实际写回。
    private func scrapeConfidence(title: String, artist: String?, durationMs: Int?) -> Double {
        var score = 0.0
        var maxScore = 0.0

        let targetMs = song.duration.sanitizedDuration > 0
            ? Int((song.duration.sanitizedDuration * 1000).rounded())
            : nil
        if let target = targetMs, let ms = durationMs {
            maxScore += 50
            let diff = abs(ms - target)
            if diff < 2000 { score += 50 }
            else if diff < 5000 { score += 30 }
            else if diff < 10000 { score += 10 }
            else { score -= 20 }
        }

        maxScore += 30
        let normTitle = Self.normalizedForMatch(song.title)
        let itemTitle = Self.normalizedForMatch(title)
        if !itemTitle.isEmpty && itemTitle == normTitle { score += 30 }
        else if !itemTitle.isEmpty && !normTitle.isEmpty &&
                    (itemTitle.contains(normTitle) || normTitle.contains(itemTitle)) { score += 15 }

        let normArtist = Self.normalizedForMatch(song.artistName ?? "")
        if !normArtist.isEmpty, let artist {
            let itemArtist = Self.normalizedForMatch(artist)
            if !itemArtist.isEmpty {
                maxScore += 20
                if itemArtist == normArtist { score += 20 }
                else if itemArtist.contains(normArtist) || normArtist.contains(itemArtist) { score += 10 }
            }
        }

        guard maxScore > 0 else { return 0 }
        return max(0, min(1, score / maxScore))
    }

    private static func normalizedForMatch(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    /// 解码封面字节流的真实像素尺寸 (NSBitmapImageRep / CGImage), 用于
    /// "2400×2400 · 612 KB" 这种信息展示。失败返回 nil。
    private func coverPixelSize(from data: Data) -> (Int, Int)? {
        #if os(macOS)
        if let rep = NSBitmapImageRep(data: data) {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        return nil
        #else
        if let cg = UIImage(data: data)?.cgImage {
            return (cg.width, cg.height)
        }
        return nil
        #endif
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
