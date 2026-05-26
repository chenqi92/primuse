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

    var body: some View {
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
    private var macBody: some View {
        ZStack {
            PMColor.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    macPanel
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 36)
                .padding(.vertical, 34)
                .padding(.bottom, 110)
            }
        }
    }

    private var macPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            macHeader

            Divider().overlay(PMColor.divider)

            if let preview {
                macPreview(preview)
            } else {
                macIntro
            }

            Divider().overlay(PMColor.divider)
            macFooter
        }
        .frame(width: 620)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PMColor.bgElev.opacity(0.88))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.20), radius: 28, y: 14)
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
                Text("导入歌单")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text(preview == nil ? "M3U8 / JSON · 选择文件后自动匹配本地资料库" : importedFromName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            Text(preview == nil ? "PL-08" : "READY")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(PMColor.textFaint)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var macIntro: some View {
        VStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PMColor.card.opacity(0.72))
                .frame(height: 188)
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(PMColor.brand)
                        Text("选择一个歌单文件开始")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(PMColor.text)
                        Text("支持 .m3u / .m3u8 / .json，导入前会先展示匹配与缺失条目。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(PMColor.textMuted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 48)
                }

            HStack(spacing: 8) {
                macFormatPill("M3U8")
                macFormatPill("M3U")
                macFormatPill("JSON")
                Spacer()
                Button {
                    showFileImporter = true
                } label: {
                    Label("选择文件", systemImage: "folder")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(PMColor.brand, in: .rect(cornerRadius: 7))
            }
        }
        .padding(22)
    }

    private func macPreview(_ p: PlaylistImporter.ImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                macMetric(title: "匹配成功", value: "\(p.matchedCount)", color: PMColor.ok)
                macMetric(title: "待确认", value: "\(p.missingCount)", color: p.missingCount > 0 ? PMColor.warn : PMColor.textFaint)
                macMetric(title: "总条目", value: "\(p.entries.count)", color: PMColor.brand)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("歌单名称")
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

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("条目预览")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PMColor.textMuted)
                    Spacer()
                    if p.missingCount > 0 {
                        Text("缺失条目不会写入新歌单")
                            .font(.system(size: 11))
                            .foregroundStyle(PMColor.textFaint)
                    }
                }

                VStack(spacing: 0) {
                    ForEach(Array(p.entries.prefix(12))) { entry in
                        macEntryRow(entry)
                        if entry.id != p.entries.prefix(12).last?.id {
                            Divider().overlay(PMColor.divider).padding(.leading, 28)
                        }
                    }
                    if p.entries.count > 12 {
                        Text("还有 \(p.entries.count - 12) 个条目会在创建时一并处理")
                            .font(.system(size: 11.5))
                            .foregroundStyle(PMColor.textFaint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }
                .background(PMColor.card.opacity(0.62), in: .rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                }
            }
        }
        .padding(22)
    }

    private var macFooter: some View {
        HStack(spacing: 10) {
            Button {
                preview = nil
                playlistName = ""
                importedFromName = ""
            } label: {
                Text(preview == nil ? "清空" : "重新选择")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(PMColor.textMuted)
            .frame(height: 28)
            .padding(.horizontal, 12)
            .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
            .disabled(preview == nil)

            Spacer()

            Button {
                showFileImporter = true
            } label: {
                Label(preview == nil ? "选择文件" : "更换文件", systemImage: "folder")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(PMColor.text)
            .frame(height: 28)
            .padding(.horizontal, 12)
            .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))

            Button {
                confirm()
            } label: {
                Label("创建歌单", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .frame(height: 28)
            .padding(.horizontal, 14)
            .background(canCreatePlaylist ? PMColor.brand : PMColor.textFaint.opacity(0.45), in: .rect(cornerRadius: 6))
            .disabled(!canCreatePlaylist)
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

    private func macEntryRow(_ entry: PlaylistImporter.ImportEntry) -> some View {
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
