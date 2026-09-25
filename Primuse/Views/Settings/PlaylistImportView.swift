import SwiftUI
import PrimuseKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// 歌单导入页 — 三种来源: .fileImporter 选 .m3u8 / .json、粘贴其他音乐 App 的
/// 歌单分享链接、粘贴「歌名 - 歌手」文本清单。解析 + 库匹配后给用户看预览
/// (匹配成功 N 首 / 缺 M 首) → 用户改名后确认 → 创建歌单。没对上的歌默认以
/// 置灰占位保留在歌单里, 以后曲库里有了会自动点亮。
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
    /// 预选值来自文件本身(导出标记或歌单名), 用户可以改。
    @State private var destination: PlaylistImportDestination = .newPlaylist
    @State private var importError: String?
    @State private var showFileImporter = false
    @State private var importedFromName: String = ""
    @State private var showCSVExporter = false
    @State private var csvDocument = PlaylistImportCSVDocument()
    @State private var manualMatchEntry: PlaylistImporter.ImportEntry?
    @State private var manualMatchQuery = ""
    /// 解析 + 库匹配在后台跑期间为 true, 用来显示进度并阻止重复触发。
    @State private var isParsing = false
    @State private var sourceMode: ImportSourceMode = .file
    @State private var linkText = ""
    @State private var listText = ""
    @State private var listOrder: ExternalPlaylistTextParser.Order = .titleFirst
    /// 没对上的歌以置灰占位保留(只对新建歌单有效; 「我喜欢」只收对上的)。
    @State private var keepMissing = true
    @State private var loadTask: Task<Void, Never>?
    /// 对方只公开了歌单的一部分时的提示(平台名 + 读到的条数)。
    @State private var partialImportNote: String?

    enum ImportSourceMode: String, CaseIterable, Identifiable {
        case file
        case link
        case text

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .file: "playlist_import_mode_file"
            case .link: "playlist_import_mode_link"
            case .text: "playlist_import_mode_text"
            }
        }
    }

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
            Task { await handleFile(result) }
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
        .onDisappear { loadTask?.cancel() }
        .alert(String(localized: "playlist_import_err_title"),
               isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("ok", role: .cancel) {}
        } message: { Text(importError ?? "") }
    }

    private var iosBody: some View {
        SkinForm {
            // 成对分支: 引导那一侧直接消失、预览这一侧淡入。交叉淡入会让两段
            // 同时排在 Form 里, 把内容顶开再弹回。
            if preview == nil {
                sourceModeSection
                    .pmAppearFade(.pageSwitch)
                switch sourceMode {
                case .file:
                    introSection
                        .pmAppearFade(.pageSwitch)
                case .link:
                    linkSection
                        .pmAppearFade(.pageSwitch)
                case .text:
                    textSection
                        .pmAppearFade(.pageSwitch)
                }
            } else if let preview {
                summarySection(preview)
                    .pmAppearFade(.pageSwitch)
                destinationSection
                    .pmAppearFade(.pageSwitch)
                entriesSection(preview)
                    .pmAppearFade(.pageSwitch)
            }
        }
        .navigationTitle("playlist_import_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("cancel") { dismiss() }
            }
            if preview == nil, sourceMode == .file {
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
            } else if preview != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { confirm() } label: { Text(confirmTitleKey) }
                        .fontWeight(.semibold)
                        .disabled(!canConfirmImport)
                }
            }
        }
    }

    /// 加入「我喜欢」不需要名字, 至少要匹配到一首; 新建歌单需要名字, 保留置灰条目时
    /// 一首都没对上也可以建 —— 以后曲库里有了会自己亮。
    private var canConfirmImport: Bool {
        guard let preview else { return false }
        if destination == .likedSongs { return preview.matchedCount > 0 }
        guard !playlistName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return preview.matchedCount > 0 || (keepsMissingEntries && !preview.entries.isEmpty)
    }

    private var keepsMissingEntries: Bool {
        destination == .newPlaylist && keepMissing
    }

    /// 显式标成 LocalizedStringKey: 直接把三元表达式塞给 Text / Button 会被推断成
    /// String, 文案就不走本地化了。
    private var confirmTitleKey: LocalizedStringKey {
        destination == .likedSongs ? "add" : "playlist_import_create"
    }

    private var likedDestinationNote: String {
        String(
            format: String(localized: "playlist_import_liked_footer_format"),
            String(localized: "playlist_liked_name")
        )
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
                        .pmAppearFade(.pageSwitch)
                } else {
                    macIntro
                        .pmAppearFade(.pageSwitch)
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
                Text("playlist_import_ready_badge")
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
        VStack(spacing: 0) {
            Picker("playlist_import_mode_header", selection: $sourceMode) {
                ForEach(ImportSourceMode.allCases) { mode in
                    Text(mode.titleKey).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isParsing)
            .padding(.horizontal, 22)
            .padding(.top, 18)

            switch sourceMode {
            case .file:
                macFileIntro
            case .link:
                macLinkIntro
            case .text:
                macTextIntro
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var macLinkIntro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("playlist_import_link_desc")
                .font(.system(size: 12.5))
                .foregroundStyle(PMColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("playlist_import_link_placeholder", text: $linkText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(3...6)
                .padding(10)
                .background(PMColor.card.opacity(0.78), in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                }
                .onSubmit { importFromLink() }
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in linkText = text }
                }
                Spacer()
                macPrimaryAction(
                    titleKey: "playlist_import_link_fetch",
                    systemImage: "link",
                    disabled: linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) { importFromLink() }
            }
            Spacer(minLength: 0)
        }
        .padding(22)
    }

    private var macTextIntro: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("playlist_import_text_desc")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Picker("playlist_import_text_order", selection: $listOrder) {
                    Text("playlist_import_text_order_title_first").tag(ExternalPlaylistTextParser.Order.titleFirst)
                    Text("playlist_import_text_order_artist_first").tag(ExternalPlaylistTextParser.Order.artistFirst)
                }
                .labelsHidden()
                .fixedSize()
            }
            TextEditor(text: $listText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(PMColor.card.opacity(0.78), in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                }
                .overlay(alignment: .topLeading) {
                    if listText.isEmpty {
                        Text("playlist_import_text_placeholder")
                            .font(.system(size: 13))
                            .foregroundStyle(PMColor.textFaint)
                            .padding(.top, 6)
                            .padding(.leading, 11)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Spacer()
                macPrimaryAction(
                    titleKey: "playlist_import_text_parse",
                    systemImage: "text.badge.checkmark",
                    disabled: listText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) { importFromText() }
            }
        }
        .padding(22)
    }

    @ViewBuilder
    private func macPrimaryAction(
        titleKey: LocalizedStringKey,
        systemImage: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if isParsing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("scanning")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
            }
            .frame(height: 34)
        } else {
            Button(action: action) {
                Label(titleKey, systemImage: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 34)
                    .background(disabled ? PMColor.textFaint.opacity(0.45) : PMColor.brand, in: .rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
        }
    }

    private var macFileIntro: some View {
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
                macFormatPill("JSON")
                macFormatPill("CSV")
                macFormatPill("TXT")
                macFormatPill("XML")
                macFormatPill("PLS")
                macFormatPill("XSPF")
                macFormatPill("WPL")
            }
            .padding(.top, 4)

            if isParsing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("scanning")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PMColor.textMuted)
                }
                .padding(.top, 6)
            } else {
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
            }

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

            if let partialImportNote {
                Label {
                    Text(verbatim: partialImportNote)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(PMColor.warn)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(PMColor.textMuted)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("playlist_import_destination_header")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PMColor.textMuted)
                Picker("playlist_import_destination_header", selection: $destination) {
                    Text("new_playlist")
                        .tag(PlaylistImportDestination.newPlaylist)
                    Text("playlist_liked_name")
                        .tag(PlaylistImportDestination.likedSongs)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if destination == .newPlaylist {
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
                    if p.missingCount > 0 {
                        Toggle("playlist_import_keep_missing", isOn: $keepMissing)
                            .font(.system(size: 12))
                            .toggleStyle(.checkbox)
                    }
                } else {
                    Text(verbatim: likedDestinationNote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(PMColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
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
                if p.probableCount > 0 {
                    Button(String(format: String(localized: "playlist_import_confirm_all_probable_format"), p.probableCount)) {
                        confirmAllProbable()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
                }
                if p.missingCount > 0 {
                    Text(unmatchedHintKey)
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
            } else if preview != nil, sourceMode == .file {
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
                    Text(verbatim: macConfirmTitle(matchedCount: preview.matchedCount))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(height: 28)
                        .padding(.horizontal, 14)
                        .background(canConfirmImport ? PMColor.brand : PMColor.textFaint.opacity(0.45), in: .rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!canConfirmImport)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func macConfirmTitle(matchedCount: Int) -> String {
        if keepsMissingEntries, let missing = preview?.missingCount, missing > 0 {
            return String(
                format: String(localized: "playlist_import_create_with_pending_format"),
                matchedCount,
                missing
            )
        }
        let format = destination == .likedSongs
            ? String(localized: "playlist_import_add_matched_only_format")
            : String(localized: "playlist_import_create_matched_only_format")
        return String(format: format, matchedCount)
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
                if entry.matchedSong == nil, let suggestion = entry.suggestedSong {
                    Text(verbatim: suggestionText(suggestion))
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.brand)
                        .lineLimit(1)
                }
            }

            Spacer()

            if entry.matchKind == nil, let suggestion = entry.suggestedSong {
                Button {
                    applyMatch(entry: entry, song: suggestion)
                } label: {
                    Text("playlist_pending_confirm")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 23)
                .background(PMColor.brand, in: .rect(cornerRadius: 6))
            }

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
        case .songID: return String(localized: "playlist_import_match_id")
        case .basename: return String(localized: "playlist_import_match_path")
        case .fuzzy: return String(localized: "playlist_import_match_fuzzy")
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
                if isParsing {
                    ProgressView { Text("scanning") }
                        .padding(.top, 8)
                } else {
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
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private var sourceModeSection: some View {
        Section {
            Picker("playlist_import_mode_header", selection: $sourceMode) {
                ForEach(ImportSourceMode.allCases) { mode in
                    Text(mode.titleKey).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isParsing)
        }
    }

    private var linkSection: some View {
        Section {
            TextField("playlist_import_link_placeholder", text: $linkText, axis: .vertical)
                .lineLimit(2...5)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in linkText = text }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                Spacer()
                if isParsing {
                    ProgressView()
                } else {
                    Button("playlist_import_link_fetch") { importFromLink() }
                        .fontWeight(.semibold)
                        .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } footer: {
            Text("playlist_import_link_desc")
        }
    }

    private var textSection: some View {
        Section {
            Picker("playlist_import_text_order", selection: $listOrder) {
                Text("playlist_import_text_order_title_first").tag(ExternalPlaylistTextParser.Order.titleFirst)
                Text("playlist_import_text_order_artist_first").tag(ExternalPlaylistTextParser.Order.artistFirst)
            }
            TextEditor(text: $listText)
                .font(.callout)
                .frame(minHeight: 180)
                .autocorrectionDisabled()
                .overlay(alignment: .topLeading) {
                    if listText.isEmpty {
                        Text("playlist_import_text_placeholder")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Spacer()
                if isParsing {
                    ProgressView()
                } else {
                    Button("playlist_import_text_parse") { importFromText() }
                        .fontWeight(.semibold)
                        .disabled(listText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } footer: {
            Text("playlist_import_text_desc")
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
            if p.probableCount > 0 {
                HStack {
                    Label("playlist_import_probable", systemImage: "questionmark.diamond")
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Button(String(format: String(localized: "playlist_import_confirm_all_probable_format"), p.probableCount)) {
                        confirmAllProbable()
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let partialImportNote {
                    Label {
                        Text(verbatim: partialImportNote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if p.missingCount > 0 {
                    Text(missingFooterKey)
                }
            }
        }
    }

    private var unmatchedHintKey: LocalizedStringKey {
        keepsMissingEntries ? "playlist_import_pending_kept_hint" : "playlist_import_unmatched_skip_hint"
    }

    private var missingFooterKey: LocalizedStringKey {
        keepsMissingEntries ? "playlist_import_keep_missing_footer" : "playlist_import_missing_footer"
    }

    private var destinationSection: some View {
        Section {
            Picker("playlist_import_destination_header", selection: $destination) {
                Text("new_playlist")
                    .tag(PlaylistImportDestination.newPlaylist)
                Text("playlist_liked_name")
                    .tag(PlaylistImportDestination.likedSongs)
            }
            .pickerStyle(.segmented)
            if destination == .newPlaylist {
                TextField("playlist_name", text: $playlistName)
                if (preview?.missingCount ?? 0) > 0 {
                    Toggle("playlist_import_keep_missing", isOn: $keepMissing)
                }
            }
        } header: {
            Text("playlist_import_destination_header")
        } footer: {
            if destination == .likedSongs {
                Text(verbatim: likedDestinationNote)
            }
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
                if entry.matchedSong == nil, let suggestion = entry.suggestedSong {
                    Text(verbatim: suggestionText(suggestion))
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
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
            } else if let suggestion = entry.suggestedSong {
                Button("playlist_pending_confirm") { applyMatch(entry: entry, song: suggestion) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func suggestionText(_ song: Song) -> String {
        String(
            format: String(localized: "playlist_pending_suggestion_format"),
            [song.title, library.artistDisplayName(for: song) ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " — ")
        )
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

    private func handleFile(_ result: Result<URL, Error>) async {
        switch result {
        case .success(let url):
            guard !isParsing else { return }
            let fileExtension = url.pathExtension.lowercased()
            if ExternalPlaylistFileParser.supportedExtensions.contains(fileExtension) {
                // 其他播放器导出的文件：和分享链接、文本清单走同一条匹配与预览。
                do {
                    let data = try readImportData(url)
                    let fileName = url.deletingPathExtension().lastPathComponent
                    let fallbackText = Self.legacyChineseText(data)
                    startExternalImport {
                        do {
                            return try ExternalPlaylistFileParser.parse(
                                data: data, fileExtension: fileExtension, fileName: fileName, fallbackText: fallbackText
                            )
                        } catch ExternalPlaylistError.empty {
                            throw OffMainImportError.empty
                        } catch {
                            throw OffMainImportError.unsupportedFormat
                        }
                    }
                } catch {
                    importError = error.localizedDescription
                }
                return
            }
            // 主线程只负责拍 songs 快照 + 读文件字节 (security-scoped 访问要
            // 在主线程短暂持有), 解析 + 库匹配 (O(条目数×库) 带 folding)
            // 全部丢到后台跑, 否则 1000 条对 5 万首库会冻结 UI 数秒。
            // 匹配池用 visibleSongs(排除停用源), 与歌单展示 / 手动匹配口径一致 ——
            // 命中停用源的歌写进歌单后 songs(forPlaylist:) 也看不到。
            let snapshot = library.visibleSongs
            let keyCache = library.playlistEntryMatchKeyCache
            isParsing = true
            defer { isParsing = false }
            do {
                let data = try readImportData(url)
                let ext = url.pathExtension.lowercased()
                let fileName = url.deletingPathExtension().lastPathComponent
                let raw = try await Task.detached(priority: .userInitiated) {
                    let parsed = try Self.parseAndMatchOffMain(data: data, ext: ext, fileName: fileName, songs: snapshot)
                    return Self.refineUnmatchedOffMain(parsed, songs: snapshot, keyCache: keyCache)
                }.value
                // @MainActor 隔离的 ImportEntry/ImportPreview 只能在主线程构造,
                // 但这一步是 O(条目数) 纯映射 (无 folding/全库扫描), 不卡 UI。
                let p = PlaylistImporter.ImportPreview(
                    suggestedName: raw.suggestedName,
                    entries: raw.matches.map { m in
                        PlaylistImporter.ImportEntry(
                            displayTitle: m.displayTitle,
                            displayArtist: m.displayArtist,
                            matchedSong: m.matchedSong,
                            matchKind: m.matchKindRaw.flatMap { PlaylistImporter.ImportEntry.MatchKind(rawValue: $0) },
                            suggestedSong: m.suggestedSong
                        )
                    }
                )
                preview = p
                playlistName = p.suggestedName
                destination = PlaylistImportDestinationPolicy.suggestedDestination(
                    kindMarker: raw.kindMarker,
                    playlistName: raw.suggestedName,
                    likedPlaylistNames: PlaylistImporter.likedPlaylistNamesInEveryLanguage()
                )
                importedFromName = fileName
                partialImportNote = nil
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    /// Excel 等在中文系统上存的 CSV 常是 GB18030，不是 UTF-8。
    nonisolated private static func legacyChineseText(_ data: Data) -> String? {
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: encoding))
    }

    /// 读取被沙箱保护的 import 文件字节。Files document picker 给的 URL 必须
    /// startAccessing 才能读 (否则 Data(contentsOf:) 报权限错)。
    private func readImportData(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw OffMainImportError.malformed(error.localizedDescription)
        }
    }

    /// 后台解析产出的中间结果 —— 全部 Sendable, 不碰 @MainActor 隔离的
    /// PlaylistImporter.ImportEntry/ImportPreview (那两个只能在主线程构造)。
    nonisolated private struct RawMatch: Sendable {
        let displayTitle: String
        let displayArtist: String?
        var matchedSong: Song?
        var matchKindRaw: String?  // PlaylistImporter.ImportEntry.MatchKind.rawValue
        var suggestedSong: Song? = nil
    }

    /// 文件里按路径/原样标题都没对上的条目, 再用导入外部歌单的那套规则(繁简、全半角、
    /// 括号附注、多歌手)对一遍: 把握大的直接算匹配, 只够「可能是」的给出候选。
    nonisolated private static func refineUnmatchedOffMain(
        _ result: RawImportResult,
        songs: [Song],
        keyCache: PlaylistEntryMatchKeyCache
    ) -> RawImportResult {
        guard result.matches.contains(where: { $0.matchedSong == nil }) else { return result }
        let matcher = PlaylistEntryMatcher(songs: songs, keyCache: keyCache)
        let refined = result.matches.map { raw -> RawMatch in
            guard raw.matchedSong == nil else { return raw }
            let artists = (raw.displayArtist ?? "")
                .components(separatedBy: " / ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let match = matcher.match(.init(title: raw.displayTitle, artists: artists, duration: nil))
            var updated = raw
            if let best = match.best {
                updated.matchedSong = best
                updated.matchKindRaw = "fuzzy"
            } else {
                updated.suggestedSong = match.probable.first
            }
            return updated
        }
        return RawImportResult(suggestedName: result.suggestedName, kindMarker: result.kindMarker, matches: refined)
    }

    nonisolated private struct RawImportResult: Sendable {
        let suggestedName: String
        /// 导出时写下的歌单类别(目前只有「我喜欢」), 旧文件和别的播放器的文件没有。
        let kindMarker: String?
        let matches: [RawMatch]
    }

    /// 后台可抛的错误 —— 复刻 PlaylistImporter.ImportError 的三种 case 与本地化
    /// 文案。PlaylistImporter.ImportError 自身被 @MainActor 隔离, 不能在后台抛。
    nonisolated private enum OffMainImportError: LocalizedError {
        case unsupportedFormat
        case malformed(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: return String(localized: "playlist_import_err_format")
            case .malformed(let why): return String(format: String(localized: "playlist_import_err_malformed_format"), why)
            case .empty: return String(localized: "playlist_import_err_empty")
            }
        }
    }

    /// 后台解析 + 库匹配。复刻 `PlaylistImporter.parseAndMatch` 的解析与匹配
    /// 优先级 (songID → basename → title+artist 模糊), 但:
    /// - 不在 @MainActor 上, 可丢到 Task.detached;
    /// - 匹配前预构建 basename → [Song] / normalized(title) → [Song] 字典,
    ///   把每条目匹配从 O(全库) 降为 O(1), 不再对每条目全量 filter + folding。
    nonisolated private static func parseAndMatchOffMain(
        data: Data,
        ext: String,
        fileName: String,
        songs: [Song]
    ) throws -> RawImportResult {
        let index = MatchIndex(songs: songs)
        switch ext {
        case "m3u", "m3u8":
            return try parseM3U8OffMain(data: data, fileName: fileName, index: index)
        case "json":
            return try parseJSONOffMain(data: data, fileName: fileName, index: index)
        default:
            throw OffMainImportError.unsupportedFormat
        }
    }

    /// 预建匹配索引: basename(小写) → [Song], normalized(title) → [Song]。
    /// 每条目匹配降为字典查找 + 同 normalized(artist) 过滤命中桶。
    nonisolated private struct MatchIndex {
        let byBasename: [String: [Song]]
        let byNormTitle: [String: [Song]]
        let byID: [String: Song]

        init(songs: [Song]) {
            var basename: [String: [Song]] = [:]
            var normTitle: [String: [Song]] = [:]
            var ids: [String: Song] = [:]
            basename.reserveCapacity(songs.count)
            normTitle.reserveCapacity(songs.count)
            ids.reserveCapacity(songs.count)
            for song in songs {
                ids[song.id] = song
                let base = (song.filePath as NSString).lastPathComponent.lowercased()
                basename[base, default: []].append(song)
                let nt = Self.normalize(song.title)
                if !nt.isEmpty {
                    normTitle[nt, default: []].append(song)
                }
            }
            byBasename = basename
            byNormTitle = normTitle
            byID = ids
        }

        func songByID(_ id: String) -> Song? { byID[id] }

        func matchByBasename(_ path: String) -> Song? {
            let needle = (path as NSString).lastPathComponent.lowercased()
            return Self.chooseBest(from: byBasename[needle] ?? [])
        }

        func matchByTitleArtist(title: String, artist: String?) -> Song? {
            let normTitle = Self.normalize(title)
            guard !normTitle.isEmpty, let bucket = byNormTitle[normTitle] else { return nil }
            let normArtist = artist.map { Self.normalize($0) }
            let hits = bucket.filter { song in
                if let normArtist {
                    return Self.normalize(song.artistName ?? "") == normArtist
                }
                return true
            }
            return Self.chooseBest(from: hits)
        }

        /// 多个命中挑最高音质 (跟 PlaylistImporter / DuplicateDetector 一致)。
        static func chooseBest(from songs: [Song]) -> Song? {
            songs.max { DuplicateDetector.qualityScore(of: $0) < DuplicateDetector.qualityScore(of: $1) }
        }

        static func normalize(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        }
    }

    nonisolated private static func parseJSONOffMain(
        data: Data,
        fileName: String,
        index: MatchIndex
    ) throws -> RawImportResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file: PlaylistExporter.PrimusePlaylistFile
        do {
            file = try decoder.decode(PlaylistExporter.PrimusePlaylistFile.self, from: data)
        } catch {
            throw OffMainImportError.malformed(error.localizedDescription)
        }
        guard !file.tracks.isEmpty else { throw OffMainImportError.empty }

        let matches = file.tracks.map { track -> RawMatch in
            if let s = index.songByID(track.songID) {
                return RawMatch(displayTitle: track.title, displayArtist: track.artistName, matchedSong: s, matchKindRaw: "songID")
            }
            if let s = index.matchByBasename(track.filePath) {
                return RawMatch(displayTitle: track.title, displayArtist: track.artistName, matchedSong: s, matchKindRaw: "basename")
            }
            if let s = index.matchByTitleArtist(title: track.title, artist: track.artistName) {
                return RawMatch(displayTitle: track.title, displayArtist: track.artistName, matchedSong: s, matchKindRaw: "fuzzy")
            }
            return RawMatch(displayTitle: track.title, displayArtist: track.artistName, matchedSong: nil, matchKindRaw: nil)
        }
        return RawImportResult(
            suggestedName: file.playlist.name,
            kindMarker: file.playlist.kind,
            matches: matches
        )
    }

    nonisolated private static func parseM3U8OffMain(
        data: Data,
        fileName: String,
        index: MatchIndex
    ) throws -> RawImportResult {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw OffMainImportError.malformed("encoding")
        }
        var playlistName = fileName
        var kindMarker: String?
        var pendingExtInf: String?
        var rawEntries: [(path: String, extInf: String?)] = []

        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTM3U") { continue }
            if line.hasPrefix("#PLAYLIST:") {
                playlistName = String(line.dropFirst("#PLAYLIST:".count)).trimmingCharacters(in: .whitespaces)
                if playlistName.isEmpty { playlistName = fileName }
                continue
            }
            if line.hasPrefix("#EXTINF:") {
                pendingExtInf = String(line.dropFirst("#EXTINF:".count))
                continue
            }
            if let marker = PlaylistImportDestinationPolicy.kindMarker(fromM3ULine: line) {
                kindMarker = marker
                continue
            }
            if line.hasPrefix("#") { continue }
            rawEntries.append((path: line, extInf: pendingExtInf))
            pendingExtInf = nil
        }
        guard !rawEntries.isEmpty else { throw OffMainImportError.empty }

        let matches = rawEntries.map { raw -> RawMatch in
            let (displayTitle, displayArtist) = Self.parseExtInf(raw.extInf, fallbackPath: raw.path)
            if let s = index.matchByBasename(raw.path) {
                return RawMatch(displayTitle: displayTitle, displayArtist: displayArtist, matchedSong: s, matchKindRaw: "basename")
            }
            if let s = index.matchByTitleArtist(title: displayTitle, artist: displayArtist) {
                return RawMatch(displayTitle: displayTitle, displayArtist: displayArtist, matchedSong: s, matchKindRaw: "fuzzy")
            }
            return RawMatch(displayTitle: displayTitle, displayArtist: displayArtist, matchedSong: nil, matchKindRaw: nil)
        }
        return RawImportResult(suggestedName: playlistName, kindMarker: kindMarker, matches: matches)
    }

    /// 解析 `#EXTINF:duration,Artist - Title`。Artist 段可能没有, 这种整段当
    /// title (跟 PlaylistImporter.parseExtInf 行为一致)。
    nonisolated private static func parseExtInf(_ extInf: String?, fallbackPath: String) -> (title: String, artist: String?) {
        guard let extInf else {
            let base = (fallbackPath as NSString).lastPathComponent
            let withoutExt = (base as NSString).deletingPathExtension
            return (withoutExt, nil)
        }
        guard let commaIdx = extInf.firstIndex(of: ",") else {
            return (extInf.trimmingCharacters(in: .whitespaces), nil)
        }
        let rest = String(extInf[extInf.index(after: commaIdx)...]).trimmingCharacters(in: .whitespaces)
        if let dashRange = rest.range(of: " - ") {
            let artist = String(rest[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(rest[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (title, artist.isEmpty ? nil : artist)
        }
        return (rest, nil)
    }

    private func confirm() {
        guard let preview, canConfirmImport else { return }
        switch destination {
        case .likedSongs:
            PlaylistImporter.addToLikedSongs(from: preview, library: library)
        case .newPlaylist:
            let name = playlistName.trimmingCharacters(in: .whitespaces)
            PlaylistImporter.createPlaylist(
                from: preview,
                named: name,
                keepingMissing: keepMissing,
                library: library
            )
        }
        dismiss()
    }

    /// 把「可能是」的候选确认成这一条的匹配。
    private func applyMatch(entry: PlaylistImporter.ImportEntry, song: Song) {
        guard let current = preview else { return }
        let entries = current.entries.map { item in
            item.id == entry.id
                ? PlaylistImporter.ImportEntry(
                    displayTitle: item.displayTitle,
                    displayArtist: item.displayArtist,
                    matchedSong: song,
                    matchKind: .fuzzy,
                    pendingTemplate: item.pendingTemplate
                )
                : item
        }
        preview = PlaylistImporter.ImportPreview(suggestedName: current.suggestedName, entries: entries)
    }

    private func confirmAllProbable() {
        guard let current = preview else { return }
        let entries = current.entries.map { item in
            guard item.matchedSong == nil, let suggestion = item.suggestedSong else { return item }
            return PlaylistImporter.ImportEntry(
                displayTitle: item.displayTitle,
                displayArtist: item.displayArtist,
                matchedSong: suggestion,
                matchKind: .fuzzy,
                pendingTemplate: item.pendingTemplate
            )
        }
        preview = PlaylistImporter.ImportPreview(suggestedName: current.suggestedName, entries: entries)
    }

    // MARK: - Links and text lists

    private func importFromLink() {
        let text = linkText
        startExternalImport { try await ExternalPlaylistFetcher.fetch(sharedText: text) }
    }

    private func importFromText() {
        let tracks = ExternalPlaylistTextParser.parse(listText, order: listOrder)
        guard !tracks.isEmpty else {
            importError = String(localized: "playlist_import_err_empty")
            return
        }
        let playlist = ExternalPlaylist(
            name: String(localized: "playlist_import_text_default_name"),
            platform: nil,
            tracks: tracks
        )
        startExternalImport { playlist }
    }

    /// 读取(可能要联网)→ 后台和曲库匹配 → 出预览。和文件导入共用预览与确认。
    private func startExternalImport(_ load: @escaping @Sendable () async throws -> ExternalPlaylist) {
        guard !isParsing else { return }
        let snapshot = library.visibleSongs
        let keyCache = library.playlistEntryMatchKeyCache
        isParsing = true
        loadTask = Task {
            defer {
                isParsing = false
                loadTask = nil
            }
            do {
                let playlist = try await load()
                let rows = await Task.detached(priority: .userInitiated) {
                    Self.matchExternalOffMain(playlist.tracks, songs: snapshot, keyCache: keyCache)
                }.value
                guard !Task.isCancelled else { return }
                let origin = playlist.platform?.rawValue ?? "text"
                let p = PlaylistImporter.ImportPreview(
                    suggestedName: playlist.name.isEmpty
                        ? String(localized: "playlist_import_text_default_name")
                        : playlist.name,
                    entries: rows.map { row in
                        PlaylistImporter.ImportEntry(
                            displayTitle: row.track.title,
                            displayArtist: row.track.artists.isEmpty ? nil : row.track.artistLine,
                            matchedSong: row.matched,
                            matchKind: row.matched == nil ? nil : .fuzzy,
                            suggestedSong: row.suggested,
                            pendingTemplate: PlaylistPendingEntry(
                                title: row.track.title,
                                artists: row.track.artists,
                                album: row.track.album,
                                duration: row.track.duration,
                                origin: origin,
                                externalID: row.track.externalID
                            )
                        )
                    }
                )
                preview = p
                playlistName = p.suggestedName
                destination = .newPlaylist
                importedFromName = playlist.platform.map(platformName) ?? p.suggestedName
                partialImportNote = playlist.isPartial
                    ? String(
                        format: String(localized: "playlist_import_partial_format"),
                        playlist.platform.map(platformName) ?? "",
                        playlist.tracks.count
                    )
                    : nil
            } catch is CancellationError {
                return
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func platformName(_ platform: ExternalPlaylistPlatform) -> String {
        switch platform {
        case .netease: String(localized: "playlist_import_platform_netease")
        case .qqMusic: String(localized: "playlist_import_platform_qqmusic")
        case .kuwo: String(localized: "playlist_import_platform_kuwo")
        case .bodian: String(localized: "playlist_import_platform_bodian")
        case .kugou: String(localized: "playlist_import_platform_kugou")
        case .migu: String(localized: "playlist_import_platform_migu")
        case .soda: String(localized: "playlist_import_platform_soda")
        case .appleMusic: String(localized: "playlist_import_platform_apple_music")
        case .spotify: String(localized: "playlist_import_platform_spotify")
        case .deezer: String(localized: "playlist_import_platform_deezer")
        case .bilibili: String(localized: "playlist_import_platform_bilibili")
        case .youtube: String(localized: "playlist_import_platform_youtube")
        }
    }

    nonisolated private struct RawExternalMatch: Sendable {
        let track: ExternalPlaylistTrack
        let matched: Song?
        let suggested: Song?
    }

    nonisolated private static func matchExternalOffMain(
        _ tracks: [ExternalPlaylistTrack],
        songs: [Song],
        keyCache: PlaylistEntryMatchKeyCache
    ) -> [RawExternalMatch] {
        let matcher = PlaylistEntryMatcher(songs: songs, keyCache: keyCache)
        // 播放器导出文件里带着文件路径时，先按文件名对（同一批文件多半就在曲库里）。
        let pathIndex = tracks.contains { $0.location != nil } ? MatchIndex(songs: songs) : nil
        return tracks.map { track in
            if let location = track.location, let song = pathIndex?.matchByBasename(location) {
                return RawExternalMatch(track: track, matched: song, suggested: nil)
            }
            let match = matcher.match(anyOf: track.matchSubjects)
            return RawExternalMatch(
                track: track,
                matched: match.best,
                suggested: match.best == nil ? match.probable.first : nil
            )
        }
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
                            Text(
                                [library.artistDisplayName(for: song), song.albumTitle]
                                    .compactMap { $0 }
                                    .joined(separator: " · ")
                            )
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
        guard !query.isEmpty else { return Array(library.visibleSongs.prefix(40)) }
        let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return library.visibleSongs
            .filter { song in
                [song.title, library.artistDisplayName(for: song), song.albumTitle]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(folded)
            }
            .prefix(40)
            .map { $0 }
    }

    private func applyManualMatch(entry: PlaylistImporter.ImportEntry, song: Song) {
        applyMatch(entry: entry, song: song)
        manualMatchEntry = nil
    }
    #endif

    // MARK: - Helpers

    private func importableTypes() -> [UTType] {
        var types: [UTType] = [.json, .commaSeparatedText, .tabSeparatedText, .plainText, .xml]
        for ext in ["pls", "xspf", "wpl"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
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

#if os(macOS)
/// macOS-only utility for converting standalone lyric files. It intentionally
/// follows the same full-sheet shell as playlist import, duplicate cleanup and
/// Scrobble: branded header, elevated work area, compact status strip, footer.
struct LyricsFormatConverterView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var sourceText = ""
    @State private var sourceFileName = ""
    @State private var targetFormat: LyricsFileFormat = .ttml
    @State private var conversion: LyricsFileConversionResult?
    @State private var conversionIssue: LyricsFileConversionError?
    @State private var isDropTargeted = false
    @State private var showFileImporter = false
    @State private var showFileExporter = false
    @State private var exportDocument = LyricsConverterDocument()
    @State private var actionMessage: String?
    @State private var alertMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            VStack(spacing: PMSpace.m14) {
                conversionOverview

                HStack(spacing: PMSpace.m) {
                    sourceEditor
                    conversionGlyph
                    outputPreview
                }
                .frame(maxHeight: .infinity)

                noticeBar
            }
            .padding(PMSpace.l)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)
            footer
        }
        .frame(width: 860, height: 660)
        .background(PMColor.bg)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: LyricsConverterDocument.readableContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                loadFile(url)
            case .failure(let error):
                let nsError = error as NSError
                guard nsError.code != NSUserCancelledError else { return }
                alertMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showFileExporter,
            document: exportDocument,
            contentType: targetFormat.contentType,
            defaultFilename: defaultExportFilename
        ) { result in
            switch result {
            case .success(let url):
                actionMessage = String(
                    format: String(localized: "lyrics_converter_exported_format"),
                    url.lastPathComponent
                )
            case .failure(let error):
                let nsError = error as NSError
                guard nsError.code != NSUserCancelledError else { return }
                alertMessage = error.localizedDescription
            }
        }
        .alert(
            String(localized: "lyrics_converter_error_title"),
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(verbatim: alertMessage ?? "")
        }
        .onChange(of: sourceText) { _, _ in refreshConversion() }
        .onChange(of: targetFormat) { _, _ in refreshConversion() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: PMSpace.m14) {
            ZStack {
                RoundedRectangle(cornerRadius: PMRadius.m10, style: .continuous)
                    .fill(PMColor.brand.opacity(0.16))
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text("lyrics_converter_title")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text("lyrics_converter_subtitle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
            }

            Spacer()

            HStack(spacing: PMSpace.s) {
                converterHeaderPill("LRC")
                converterHeaderPill("TTML")
                converterHeaderPill("TXT")
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
        .padding(.horizontal, PMSpace.l24)
        .padding(.vertical, PMSpace.l)
    }

    private func converterHeaderPill(_ label: String) -> some View {
        Text(verbatim: label)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(PMColor.textMuted)
            .padding(.horizontal, PMSpace.s8)
            .frame(height: 22)
            .background(PMColor.glassBtn, in: .capsule)
    }

    // MARK: Overview

    private var conversionOverview: some View {
        HStack(spacing: PMSpace.s10) {
            overviewNode(
                icon: "doc.text",
                eyebrow: String(localized: "lyrics_converter_input"),
                value: detectedSourceFormat.label,
                color: detectedSourceFormat.color
            )

            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PMColor.textFaint)

            overviewNode(
                icon: targetFormat.icon,
                eyebrow: String(localized: "lyrics_converter_output"),
                value: targetFormat.shortLabel,
                color: PMColor.brand
            )

            Spacer(minLength: PMSpace.m)

            if let conversion {
                Label(summaryText(for: conversion.lines), systemImage: "waveform.path")
                    .font(PMFont.caption)
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            } else {
                Text("lyrics_converter_overview_empty")
                    .font(PMFont.caption)
                    .foregroundStyle(PMColor.textFaint)
            }
        }
        .padding(.horizontal, PMSpace.m14)
        .frame(height: 54)
        .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.l))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func overviewNode(
        icon: String,
        eyebrow: String,
        value: String,
        color: Color
    ) -> some View {
        HStack(spacing: PMSpace.s8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .background(color.opacity(0.12), in: .rect(cornerRadius: PMRadius.s))

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: eyebrow.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PMColor.textFaint)
                Text(verbatim: value)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(PMColor.text)
            }
        }
    }

    // MARK: Editors

    private var sourceEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: PMSpace.s8) {
                Text("lyrics_converter_input")
                    .font(PMFont.cardTitleS)
                    .foregroundStyle(PMColor.text)

                sourceFormatBadge

                Spacer()

                Button {
                    showFileImporter = true
                } label: {
                    Label(
                        sourceFileName.isEmpty
                            ? String(localized: "lyrics_converter_choose_file")
                            : String(localized: "lyrics_converter_change_file"),
                        systemImage: "folder"
                    )
                    .font(PMFont.caption)
                    .foregroundStyle(PMColor.textMuted)
                    .padding(.horizontal, PMSpace.s8)
                    .frame(height: 24)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, PMSpace.m)
            .frame(height: 42)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ZStack {
                TextEditor(text: $sourceText)
                    .font(PMFont.mono)
                    .foregroundStyle(PMColor.text)
                    .scrollContentBackground(.hidden)
                    .padding(PMSpace.s8)

                if sourceText.isEmpty {
                    VStack(spacing: PMSpace.s8) {
                        Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                            .font(.system(size: 32, weight: .regular))
                            .foregroundStyle(isDropTargeted ? PMColor.brand : PMColor.textFaint)
                        Text("lyrics_converter_drop_title")
                            .font(PMFont.bodyM)
                            .foregroundStyle(PMColor.textMuted)
                        Text("lyrics_converter_drop_hint")
                            .font(PMFont.caption)
                            .foregroundStyle(PMColor.textFaint)
                            .multilineTextAlignment(.center)
                    }
                    .padding(PMSpace.l24)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.l))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? PMColor.brand : PMColor.cardBorder,
                    lineWidth: isDropTargeted ? 1.5 : 0.5
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            loadFile(url)
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
    }

    private var sourceFormatBadge: some View {
        Text(verbatim: detectedSourceFormat.label)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(detectedSourceFormat.color)
            .padding(.horizontal, PMSpace.s)
            .frame(height: 20)
            .background(detectedSourceFormat.color.opacity(0.11), in: .capsule)
    }

    private var conversionGlyph: some View {
        VStack(spacing: PMSpace.s) {
            Spacer()
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(conversion == nil ? PMColor.textFaint : PMColor.brand)
                .frame(width: 34, height: 34)
                .background(
                    conversion == nil
                        ? PMColor.glassBtn
                        : PMColor.brand.opacity(0.13),
                    in: .circle
                )
            Text("live_badge")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(PMColor.textFaint)
            Spacer()
        }
        .frame(width: 38)
        .accessibilityHidden(true)
    }

    private var outputPreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: PMSpace.s8) {
                Text("lyrics_converter_output")
                    .font(PMFont.cardTitleS)
                    .foregroundStyle(PMColor.text)

                Spacer()
                outputFormatPicker

                Button(action: copyOutput) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 24, height: 24)
                        .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
                }
                .buttonStyle(.plain)
                .disabled(conversion == nil)
                .opacity(conversion == nil ? 0.45 : 1)
                .help(Text("lyrics_converter_copy"))
            }
            .padding(.horizontal, PMSpace.m)
            .frame(height: 42)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ScrollView(.vertical, showsIndicators: true) {
                if let conversion {
                    Text(verbatim: conversion.output)
                        .font(PMFont.mono)
                        .foregroundStyle(PMColor.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(PMSpace.m16)
                } else {
                    VStack(spacing: PMSpace.s8) {
                        Image(systemName: conversionIssue == nil ? "text.document" : "exclamationmark.triangle")
                            .font(.system(size: 30, weight: .regular))
                            .foregroundStyle(conversionIssue == nil ? PMColor.textFaint : PMColor.bad)
                        Text(conversionIssue == nil
                             ? String(localized: "lyrics_converter_output_placeholder")
                             : String(localized: "lyrics_converter_invalid_notice"))
                            .font(PMFont.bodyM)
                            .foregroundStyle(PMColor.textMuted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .padding(PMSpace.l24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.l))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous))
    }

    private var outputFormatPicker: some View {
        HStack(spacing: 2) {
            ForEach(LyricsFileFormat.allCases, id: \.rawValue) { format in
                Button {
                    targetFormat = format
                } label: {
                    Text(verbatim: format.shortLabel)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(targetFormat == format ? .white : PMColor.textMuted)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(
                            targetFormat == format ? PMColor.brand : .clear,
                            in: .capsule
                        )
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: format.helpText))
            }
        }
        .padding(2)
        .background(PMColor.glassBtn, in: .capsule)
    }

    // MARK: Status + footer

    private var noticeBar: some View {
        let notice = currentNotice
        return HStack(spacing: PMSpace.s8) {
            Image(systemName: notice.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(notice.color)
                .frame(width: 18)
            Text(verbatim: notice.text)
                .font(PMFont.caption)
                .foregroundStyle(PMColor.textMuted)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, PMSpace.m)
        .frame(minHeight: 38)
        .background(notice.color.opacity(0.08), in: .rect(cornerRadius: PMRadius.m))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                .strokeBorder(notice.color.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var footer: some View {
        HStack(spacing: PMSpace.s10) {
            if let actionMessage {
                Label(actionMessage, systemImage: "checkmark.circle.fill")
                    .font(PMFont.caption)
                    .foregroundStyle(PMColor.ok)
                    .lineLimit(1)
            } else {
                Label("lyrics_converter_local_only", systemImage: "lock.shield")
                    .font(PMFont.caption)
                    .foregroundStyle(PMColor.textFaint)
            }

            Spacer()

            if !sourceText.isEmpty {
                Button("clear") { clearSource() }
                    .font(PMFont.bodyM)
                    .buttonStyle(.plain)
                    .foregroundStyle(PMColor.textMuted)
                    .padding(.horizontal, PMSpace.s10)
                    .frame(height: 28)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
            }

            Button("cancel") { dismiss() }
                .font(PMFont.bodyM)
                .buttonStyle(.plain)
                .foregroundStyle(PMColor.text)
                .padding(.horizontal, PMSpace.m)
                .frame(height: 28)
                .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))

            Button(action: exportOutput) {
                Label("export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, PMSpace.m14)
                    .frame(height: 28)
                    .background(
                        conversion == nil
                            ? PMColor.textFaint.opacity(0.45)
                            : PMColor.brand,
                        in: .rect(cornerRadius: PMRadius.s)
                    )
            }
            .buttonStyle(.plain)
            .disabled(conversion == nil)
        }
        .padding(.horizontal, PMSpace.l)
        .frame(height: 58)
    }

    // MARK: Conversion state

    private var detectedSourceFormat: MacLyricsDetectedFormat {
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        if LyricsContentParser.isTTML(sourceText) {
            return conversion == nil ? .invalid : .ttml
        }
        // A subtitle document parses into line- or word-timed lyrics, so the
        // conversion alone can no longer tell what the user pasted in.
        if let subtitle = SubtitleLyricsParser.detect(sourceText) {
            guard conversion != nil else { return .invalid }
            switch subtitle {
            case .webVTT: return .webVTT
            case .subRip: return .subRip
            }
        }
        guard let conversion else { return .invalid }
        switch conversion.sourceFormat {
        case .plain: return .plain
        case .lineLevel: return .lrc
        case .wordLevel: return .elrc
        }
    }

    private var currentNotice: LyricsConverterNotice {
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return LyricsConverterNotice(
                icon: "info.circle",
                color: PMColor.textFaint,
                text: String(localized: "lyrics_converter_empty_notice")
            )
        }
        guard let conversion else {
            return LyricsConverterNotice(
                icon: "exclamationmark.triangle.fill",
                color: PMColor.bad,
                text: String(localized: "lyrics_converter_invalid_notice")
            )
        }

        let lines = conversion.lines
        let hasTiming = lines.contains(where: \.isSynchronized)
        let hasVoices = lines.contains { line in
            line.voice == .secondary || !(line.background?.isEmpty ?? true)
        }
        if targetFormat == .plainText, hasTiming || hasVoices {
            return LyricsConverterNotice(
                icon: "exclamationmark.triangle.fill",
                color: PMColor.warn,
                text: String(localized: "lyrics_converter_plain_notice")
            )
        }
        if targetFormat == .lrc, hasVoices {
            return LyricsConverterNotice(
                icon: "person.2.wave.2",
                color: PMColor.warn,
                text: String(localized: "lyrics_converter_voice_notice")
            )
        }
        if targetFormat != .plainText, !hasTiming {
            return LyricsConverterNotice(
                icon: "clock.badge.exclamationmark",
                color: PMColor.warn,
                text: String(localized: "lyrics_converter_no_timing_notice")
            )
        }
        return LyricsConverterNotice(
            icon: "checkmark.seal.fill",
            color: PMColor.ok,
            text: String(localized: "lyrics_converter_preserve_notice")
        )
    }

    private func summaryText(for lines: [LyricLine]) -> String {
        String(
            format: String(localized: "lyrics_converter_summary_format"),
            lines.count,
            lines.filter(\.isSynchronized).count,
            lines.filter(\.isWordLevel).count
        )
    }

    private var defaultExportFilename: String {
        let base: String
        if sourceFileName.isEmpty {
            base = "lyrics"
        } else {
            base = (sourceFileName as NSString).deletingPathExtension
        }
        return "\(base)-converted.\(targetFormat.fileExtension)"
    }

    private func refreshConversion() {
        actionMessage = nil
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            conversion = nil
            conversionIssue = nil
            return
        }
        do {
            conversion = try LyricsFileConverter.convert(sourceText, to: targetFormat)
            conversionIssue = nil
        } catch let error as LyricsFileConversionError {
            conversion = nil
            conversionIssue = error
        } catch {
            conversion = nil
            conversionIssue = .invalidContent
        }
    }

    private func loadFile(_ url: URL) {
        do {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > 4 * 1_024 * 1_024 {
                throw LyricsConverterFileError.tooLarge
            }
            let data = try Data(contentsOf: url)
            guard var decoded = Self.decodeLyricsText(data) else {
                throw LyricsConverterFileError.cannotDecode
            }
            if decoded.first == "\u{FEFF}" { decoded.removeFirst() }

            sourceFileName = url.lastPathComponent
            sourceText = decoded
            targetFormat = LyricsContentParser.isTTML(decoded) ? .lrc : .ttml
            refreshConversion()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private static func decodeLyricsText(_ data: Data) -> String? {
        TextEncodingRepair.bestDecoding(
            of: data,
            encodings: [
                .utf8,
                .utf16,
                .utf16LittleEndian,
                .utf16BigEndian,
                TextEncodingRepair.gb18030,
                TextEncodingRepair.big5,
                .shiftJIS,
                TextEncodingRepair.eucKR,
                .windowsCP1252,
                .isoLatin1,
            ]
        )
    }

    private func copyOutput() {
        guard let conversion else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(conversion.output, forType: .string) else { return }
        actionMessage = String(localized: "lyrics_converter_copied")
    }

    private func exportOutput() {
        guard let conversion else { return }
        exportDocument = LyricsConverterDocument(text: conversion.output)
        showFileExporter = true
    }

    private func clearSource() {
        sourceText = ""
        sourceFileName = ""
        conversion = nil
        conversionIssue = nil
        actionMessage = nil
    }
}

private enum MacLyricsDetectedFormat {
    case empty
    case lrc
    case elrc
    case ttml
    case webVTT
    case subRip
    case plain
    case invalid

    var label: String {
        switch self {
        case .empty: "—"
        case .lrc: "LRC"
        case .elrc: "ELRC"
        case .ttml: "TTML"
        case .webVTT: "VTT"
        case .subRip: "SRT"
        case .plain: "TXT"
        case .invalid: String(localized: "lyrics_converter_format_invalid")
        }
    }

    @MainActor
    var color: Color {
        switch self {
        case .empty: PMColor.textFaint
        case .lrc: PMColor.ok
        case .elrc: PMColor.dsd
        case .ttml: PMColor.brand
        case .webVTT: PMColor.flac
        case .subRip: PMColor.warn
        case .plain: PMColor.textMuted
        case .invalid: PMColor.bad
        }
    }
}

private struct LyricsConverterNotice {
    let icon: String
    let color: Color
    let text: String
}

private enum LyricsConverterFileError: LocalizedError {
    case tooLarge
    case cannotDecode

    var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "lyrics_converter_file_too_large")
        case .cannotDecode: String(localized: "lyrics_converter_decode_failed")
        }
    }
}

private struct LyricsConverterDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        // Subtitle documents are readable input only; the converter still
        // writes LRC, TTML or plain text.
        [.primuseLRC, .primuseTTML, .primuseWebVTT, .primuseSubRip, .xml, .plainText]
    }

    static var writableContentTypes: [UTType] {
        [.primuseLRC, .primuseTTML, .plainText]
    }

    var text: String = ""

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let value = String(data: data, encoding: .utf8) else {
            throw LyricsConverterFileError.cannotDecode
        }
        text = value
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private extension UTType {
    static let primuseLRC = UTType(filenameExtension: "lrc", conformingTo: .plainText) ?? .plainText
    static let primuseTTML = UTType(filenameExtension: "ttml", conformingTo: .xml) ?? .xml
    static let primuseWebVTT = UTType(filenameExtension: "vtt", conformingTo: .plainText)
        ?? .plainText
    static let primuseSubRip = UTType(filenameExtension: "srt", conformingTo: .plainText)
        ?? .plainText
}

private extension LyricsFileFormat {
    var shortLabel: String {
        switch self {
        case .lrc: "LRC"
        case .ttml: "TTML"
        case .plainText: "TXT"
        }
    }

    var fileExtension: String {
        switch self {
        case .lrc: "lrc"
        case .ttml: "ttml"
        case .plainText: "txt"
        }
    }

    var contentType: UTType {
        switch self {
        case .lrc: .primuseLRC
        case .ttml: .primuseTTML
        case .plainText: .plainText
        }
    }

    var icon: String {
        switch self {
        case .lrc: "text.badge.checkmark"
        case .ttml: "chevron.left.forwardslash.chevron.right"
        case .plainText: "text.alignleft"
        }
    }

    var helpText: String {
        switch self {
        case .lrc: String(localized: "lyrics_converter_lrc_help")
        case .ttml: String(localized: "lyrics_converter_ttml_help")
        case .plainText: String(localized: "lyrics_converter_txt_help")
        }
    }
}
#endif
