import SwiftUI
import PrimuseKit
import UniformTypeIdentifiers

/// 歌单导入页 — 走 .fileImporter 选 .m3u8 / .json, 解析 + 库匹配, 给
/// 用户看预览 (匹配成功 N 首 / 缺 M 首) → 用户改名后确认 → 创建歌单。
///
/// 三种状态:
/// - 还没选文件: 引导选文件
/// - 解析中 / 出错: 提示
/// - 已解析: 显示 preview, 让用户编辑名字 + 确认 / 取消
struct PlaylistImportView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var preview: PlaylistImporter.ImportPreview?
    @State private var playlistName: String = ""
    @State private var importError: String?
    @State private var showFileImporter = false
    @State private var importedFromName: String = ""
    @State private var showCSVExporter = false
    @State private var csvDocument = PlaylistImportCSVDocument()
    @State private var manualMatchEntry: PlaylistImporter.ImportEntry?
    @State private var manualMatchQuery = ""

    var body: some View {
        #if os(macOS)
        baseBody
            .sheet(item: $manualMatchEntry) { entry in
                manualMatchSheet(entry)
            }
        #else
        baseBody
        #endif
    }

    private var baseBody: some View {
        Group {
            #if os(macOS)
            macBody
            #else
            iosBody
            #endif
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: importableTypes()
        ) { result in
            handleFile(result)
        }
        .fileExporter(
            isPresented: $showCSVExporter,
            document: csvDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "\(importedFromName.isEmpty ? "unmatched-playlist" : importedFromName)-unmatched.csv"
        ) { result in
            if case .failure(let error) = result {
                importError = error.localizedDescription
            }
        }
        .alert(String(localized: "playlist_import_err_title"),
               isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("ok", role: .cancel) {}
        } message: { Text(importError ?? "") }
    }

    private var iosBody: some View {
        Form {
            if preview == nil {
                introSection
            } else if let preview {
                summarySection(preview)
                nameSection
                entriesSection(preview)
            }
        }
        .navigationTitle("playlist_import_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if preview == nil {
                // 没选文件时, 顶部一个明显的「选择文件」入口 —— Form 内的
                // .borderedProminent 按钮在 iOS 26 偶尔渲染成跟背景同色看
                // 不见, 工具栏入口更稳。
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("playlist_import_pick_file", systemImage: "folder")
                    }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("playlist_import_create") { confirm() }
                        .fontWeight(.semibold)
                        .disabled(playlistName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (preview?.matchedCount ?? 0) == 0)
                }
            }
        }
    }

    #if os(macOS)
    /// 整面板铺满 sheet (PMColor.bg 打底), 跟「重复清理 / Scrobble」两个弹框
    /// 一致 —— 不再是一张 760 宽、带阴影的浮动卡片浮在更大的窗口里 (那样会留
    /// 大片空白 + 卡片浮空感)。结构: 顶栏 + 内容(引导/预览) + 底栏。
    private var macBody: some View {
        VStack(spacing: 0) {
            macHeader

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            Group {
                if let preview {
                    macPreview(preview)
                } else {
                    macIntro
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)
            macFooter
        }
        .frame(width: 620, height: 680)
        .background(PMColor.bg)
    }

    private var macHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PMColor.brand.opacity(0.16))
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text("playlist_import_title")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text(verbatim: preview == nil ? String(localized: "playlist_import_mac_subtitle") : importedFromName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            if preview != nil {
                Text("READY")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 26, height: 26)
                    .background(PMColor.glassBtn, in: .circle)
            }
            .buttonStyle(.plain)
            .help(Text("close"))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var macIntro: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            Image(systemName: "doc.badge.plus")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(PMColor.brand)
            Text("playlist_import_mac_intro_title")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PMColor.text)
            Text("playlist_import_mac_intro_desc")
                .font(.system(size: 12.5))
                .foregroundStyle(PMColor.textMuted)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                macFormatPill("M3U8")
                macFormatPill("M3U")
                macFormatPill("JSON")
            }
            .padding(.top, 4)

            Button {
                showFileImporter = true
            } label: {
                Label("playlist_import_pick_file", systemImage: "folder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 34)
                    .background(PMColor.brand, in: .rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func macPreview(_ p: PlaylistImporter.ImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                MacImportStatusPill(text: String(format: String(localized: "playlist_import_matched_count_format"), p.matchedCount), color: PMColor.ok)
                MacImportStatusPill(text: String(format: String(localized: "playlist_import_pending_count_format"), p.missingCount), color: p.missingCount > 0 ? PMColor.warn : PMColor.textFaint)
                Spacer()
                Text(verbatim: String(format: String(localized: "playlist_import_entries_count_format"), p.entries.count))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(PMColor.textFaint)
            }

            macSegmentedProgress(p)

            VStack(alignment: .leading, spacing: 8) {
                Text("playlist_import_name_header")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PMColor.textMuted)
                TextField("playlist_name", text: $playlistName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(PMColor.card.opacity(0.78), in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                    }
            }

            macGroupedEntries(p)
        }
        .padding(22)
    }

    private func macSegmentedProgress(_ p: PlaylistImporter.ImportPreview) -> some View {
        let total = max(p.entries.count, 1)
        let matched = CGFloat(p.matchedCount) / CGFloat(total)
        let missing = CGFloat(p.missingCount) / CGFloat(total)

        return GeometryReader { geo in
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(PMColor.ok)
                    .frame(width: max(0, geo.size.width * matched))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(p.missingCount > 0 ? PMColor.warn : PMColor.textFaint.opacity(0.24))
                    .frame(width: max(0, geo.size.width * missing))
                if p.entries.isEmpty {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(PMColor.textFaint.opacity(0.18))
                }
            }
        }
        .frame(height: 5)
        .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
    }

    private func macGroupedEntries(_ p: PlaylistImporter.ImportPreview) -> some View {
        let matched = p.entries.filter { $0.matchedSong != nil }
        let unmatched = p.entries.filter { $0.matchedSong == nil }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("playlist_import_match_results")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PMColor.textMuted)
                Spacer()
                if p.missingCount > 0 {
                    Text("playlist_import_unmatched_skip_hint")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textFaint)
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    macEntryGroup(title: String(localized: "playlist_import_matched_group"), count: matched.count, color: PMColor.ok) {
                        ForEach(matched) { entry in
                            macEntryRow(entry, manualMatch: false)
                            if entry.id != matched.last?.id {
                                Divider().overlay(PMColor.divider).padding(.leading, 28)
                            }
                        }
                    }

                    macEntryGroup(title: String(localized: "playlist_import_unmatched_group"), count: unmatched.count, color: unmatched.isEmpty ? PMColor.textFaint : PMColor.warn) {
                        if unmatched.isEmpty {
                            Text("playlist_import_no_manual_items")
                                .font(.system(size: 12))
                                .foregroundStyle(PMColor.textFaint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        } else {
                            ForEach(unmatched) { entry in
                                macEntryRow(entry, manualMatch: true)
                                if entry.id != unmatched.last?.id {
                                    Divider().overlay(PMColor.divider).padding(.leading, 28)
                                }
                            }
                        }
                    }
                }
                .padding(1)
            }
            .frame(height: 300)
        }
    }

    private func macEntryGroup<Content: View>(title: String,
                                              count: Int,
                                              color: Color,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(verbatim: "\(title) (\(count))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(PMColor.bgElev.opacity(0.82))

            Divider().overlay(PMColor.divider)

            content()
        }
        .background(PMColor.card.opacity(0.62), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 设计稿 PL-06 底栏: 左「导出未匹配 → CSV」(仅有缺失时), 右「取消 + 仅创建
    /// 已匹配 (N)」。还没选文件时右侧主按钮换成「选择文件」。
    private var macFooter: some View {
        HStack(spacing: 10) {
            if let preview, preview.missingCount > 0 {
                Button {
                    exportUnmatchedCSV(preview)
                } label: {
                    Label("playlist_import_export_unmatched_csv", systemImage: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PMColor.text)
                .frame(height: 28)
                .padding(.horizontal, 12)
                .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
            } else if preview != nil {
                Button {
                    showFileImporter = true
                } label: {
                    Label("playlist_import_change_file", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PMColor.textMuted)
                .frame(height: 28)
                .padding(.horizontal, 12)
                .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
            }

            Spacer()

            Button("cancel") { dismiss() }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(PMColor.text)
                .frame(height: 28)
                .padding(.horizontal, 14)
                .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))

            // 引导态的「选择文件」主按钮在内容区里, 这里底栏不再重复; 只有
            // 解析出预览后才在底栏放「仅创建已匹配」主操作。
            if let preview {
                Button {
                    confirm()
                } label: {
                    Text(verbatim: String(format: String(localized: "playlist_import_create_matched_only_format"), preview.matchedCount))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(height: 28)
                        .padding(.horizontal, 14)
                        .background(canCreatePlaylist ? PMColor.brand : PMColor.textFaint.opacity(0.45), in: .rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!canCreatePlaylist)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var canCreatePlaylist: Bool {
        playlistName.trimmingCharacters(in: .whitespaces).isEmpty == false
            && (preview?.matchedCount ?? 0) > 0
    }

    private func macFormatPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(PMColor.textMuted)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(PMColor.glassBtn, in: .capsule)
    }

    private func macMetric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(PMColor.text)
                .monospacedDigit()
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(PMColor.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(color.opacity(0.12), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(color.opacity(0.20), lineWidth: 0.5)
        }
    }

    private func macEntryRow(_ entry: PlaylistImporter.ImportEntry, manualMatch: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.matchedSong == nil ? "questionmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(entry.matchedSong == nil ? PMColor.warn : PMColor.ok)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                if let artist = entry.displayArtist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let kind = entry.matchKind {
                Text(matchKindText(kind))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(matchKindColor(kind))
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(matchKindColor(kind).opacity(0.14), in: .capsule)
            } else if manualMatch {
                Button {
                    manualMatchQuery = [entry.displayTitle, entry.displayArtist]
                        .compactMap { $0 }
                        .joined(separator: " ")
                    manualMatchEntry = entry
                } label: {
                    Text("playlist_import_manual_match")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PMColor.brand)
                .padding(.horizontal, 9)
                .frame(height: 23)
                .background(PMColor.brand.opacity(0.12), in: .rect(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func matchKindText(_ kind: PlaylistImporter.ImportEntry.MatchKind) -> String {
        switch kind {
        case .songID: return "ID"
        case .basename: return "PATH"
        case .fuzzy: return "FUZZY"
        }
    }
    #endif

    // MARK: - Sections

    private var introSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                Text("playlist_import_intro_title").font(.headline)
                Text("playlist_import_intro_desc")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    showFileImporter = true
                } label: {
                    HStack {
                        Label("playlist_import_pick_file", systemImage: "folder")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private func summarySection(_ p: PlaylistImporter.ImportPreview) -> some View {
        Section {
            HStack {
                Label("playlist_import_matched", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Text("\(p.matchedCount)").monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                Label("playlist_import_missing", systemImage: "questionmark.circle")
                    .foregroundStyle(p.missingCount > 0 ? .orange : .secondary)
                Spacer()
                Text("\(p.missingCount)").monospacedDigit().foregroundStyle(.secondary)
            }
        } footer: {
            if p.missingCount > 0 {
                Text("playlist_import_missing_footer")
            }
        }
    }

    private var nameSection: some View {
        Section {
            TextField("playlist_name", text: $playlistName)
        } header: {
            Text("playlist_import_name_header")
        }
    }

    private func entriesSection(_ p: PlaylistImporter.ImportPreview) -> some View {
        Section {
            ForEach(p.entries) { entry in
                entryRow(entry)
            }
        } header: {
            Text("playlist_import_entries_header")
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: PlaylistImporter.ImportEntry) -> some View {
        HStack(spacing: 10) {
            statusIcon(for: entry)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                if let artist = entry.displayArtist, !artist.isEmpty {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let kind = entry.matchKind {
                Text(matchKindLabel(kind))
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(matchKindColor(kind).opacity(0.18)))
                    .foregroundStyle(matchKindColor(kind))
            }
        }
        .padding(.vertical, 2)
    }

    private func statusIcon(for entry: PlaylistImporter.ImportEntry) -> some View {
        if entry.matchedSong != nil {
            return AnyView(Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green))
        } else {
            return AnyView(Image(systemName: "questionmark.circle")
                .foregroundStyle(.orange))
        }
    }

    // MARK: - Actions

    private func handleFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let p = try PlaylistImporter.parseAndMatch(fileURL: url, library: library)
                preview = p
                playlistName = p.suggestedName
                importedFromName = url.deletingPathExtension().lastPathComponent
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func confirm() {
        guard let preview else { return }
        let name = playlistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        PlaylistImporter.createPlaylist(from: preview, named: name, library: library)
        dismiss()
    }

    #if os(macOS)
    private func exportUnmatchedCSV(_ preview: PlaylistImporter.ImportPreview) {
        let unmatched = preview.entries.filter { $0.matchedSong == nil }
        csvDocument = PlaylistImportCSVDocument(text: unmatchedCSV(for: unmatched))
        showCSVExporter = true
    }

    private func unmatchedCSV(for entries: [PlaylistImporter.ImportEntry]) -> String {
        let header = ["title", "artist", "reason"].map(csvEscape).joined(separator: ",")
        let rows = entries.map { entry in
            [
                entry.displayTitle,
                entry.displayArtist ?? "",
                "not_matched"
            ].map(csvEscape).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    private func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") {
            return "\"\(escaped)\""
        }
        return escaped
    }

    private func manualMatchSheet(_ entry: PlaylistImporter.ImportEntry) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text("playlist_import_manual_match_title")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(entry.displayTitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(18)

            Divider().overlay(PMColor.divider)

            TextField("playlist_import_search_library", text: $manualMatchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(PMColor.card.opacity(0.78), in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                }
                .padding(16)

            List(manualMatchResults, id: \.id) { song in
                Button {
                    applyManualMatch(entry: entry, song: song)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "music.note")
                            .foregroundStyle(PMColor.brand)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(PMColor.text)
                            Text([song.artistName, song.albumTitle].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11))
                                .foregroundStyle(PMColor.textFaint)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Divider().overlay(PMColor.divider)

            HStack {
                Spacer()
                Button("cancel") { manualMatchEntry = nil }
                    .keyboardShortcut(.cancelAction)
                Button("playlist_import_use_first_result") {
                    if let song = manualMatchResults.first {
                        applyManualMatch(entry: entry, song: song)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(manualMatchResults.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 520, height: 520)
        .background(PMColor.bg)
    }

    private var manualMatchResults: [Song] {
        let query = manualMatchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(library.songs.prefix(40)) }
        let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return library.songs
            .filter { song in
                [song.title, song.artistName, song.albumTitle]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(folded)
            }
            .prefix(40)
            .map { $0 }
    }

    private func applyManualMatch(entry: PlaylistImporter.ImportEntry, song: Song) {
        guard let current = preview else { return }
        let entries = current.entries.map { item in
            item.id == entry.id
                ? PlaylistImporter.ImportEntry(
                    displayTitle: item.displayTitle,
                    displayArtist: item.displayArtist,
                    matchedSong: song,
                    matchKind: .fuzzy
                )
                : item
        }
        preview = PlaylistImporter.ImportPreview(suggestedName: current.suggestedName, entries: entries)
        manualMatchEntry = nil
    }
    #endif

    // MARK: - Helpers

    private func importableTypes() -> [UTType] {
        var types: [UTType] = [.json]
        // m3u8 + m3u —— 用 mpeg4Audio 显然不对, 正确做法是 mpegURL/audio/x-mpegurl
        if let m3u8 = UTType(filenameExtension: "m3u8") { types.append(m3u8) }
        if let m3u = UTType(filenameExtension: "m3u") { types.append(m3u) }
        return types
    }

    private func matchKindLabel(_ kind: PlaylistImporter.ImportEntry.MatchKind) -> LocalizedStringKey {
        switch kind {
        case .songID: return "playlist_import_kind_id"
        case .basename: return "playlist_import_kind_path"
        case .fuzzy: return "playlist_import_kind_fuzzy"
        }
    }

    private func matchKindColor(_ kind: PlaylistImporter.ImportEntry.MatchKind) -> Color {
        switch kind {
        case .songID: return .green
        case .basename: return .blue
        case .fuzzy: return .orange
        }
    }
}

private struct PlaylistImportCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var text: String = ""

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let contents = String(data: data, encoding: .utf8) {
            text = contents
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

#if os(macOS)
private struct MacImportStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(verbatim: text)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(PMColor.text)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(color.opacity(0.12), in: .capsule)
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(color.opacity(0.22), lineWidth: 0.5)
        }
    }
}
#endif
