import Foundation
import SwiftUI

// MARK: - 通用目录浏览器外壳
//
// ConnectorDirectoryBrowserView / NFSBrowserView / UPnPBrowserView /
// MediaServerBrowserView 共用的 sheet chrome——breadcrumb、底部 bar、
// list 样式、frame 限制、toolbar 快捷键。各自的业务差异(path 解析、
// connector 类型)留在原 view 里;这里只统一视觉。

extension View {
    /// 目录浏览器统一的 list 样式:macOS inset(交替行背景),iOS plain。
    func directoryBrowserListStyle() -> some View {
        #if os(macOS)
        self.listStyle(.inset(alternatesRowBackgrounds: true))
        #else
        self.listStyle(.plain)
        #endif
    }

    /// macOS 上给目录浏览器 sheet 加合理最小尺寸 + Done/Cancel 键盘快捷键。
    /// iOS 不需要 frame,toolbar 已由 caller 定义,这里就只在 macOS 加一层。
    func directoryBrowserSheetFrame() -> some View {
        #if os(macOS)
        self.frame(minWidth: 760, idealWidth: 820, minHeight: 480, idealHeight: 600)
        #else
        self
        #endif
    }
}

// MARK: - Breadcrumb

struct DirectoryBreadcrumb: View {
    struct Segment {
        let path: String
        let title: String
    }

    let segments: [Segment]
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }

                        let isCurrent = index == segments.count - 1
                        Button { onSelect(index) } label: {
                            Text(segment.title)
                                #if os(macOS)
                                .font(.system(size: 12))
                                .fontWeight(isCurrent ? .semibold : .regular)
                                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                                #else
                                .font(.caption)
                                .fontWeight(isCurrent ? .semibold : .regular)
                                .foregroundStyle(isCurrent ? Color.primary : Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                #endif
                        }
                        .buttonStyle(.plain)
                        .disabled(isCurrent)
                        .id(index)
                    }
                    Spacer(minLength: 0)
                }
                #if os(macOS)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                #else
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                #endif
            }
            .onChange(of: segments.count) { _, _ in
                withAnimation { proxy.scrollTo(segments.count - 1, anchor: .trailing) }
            }
        }
        #if os(macOS)
        .background {
            ZStack {
                PMColor.bg
                PMColor.card.opacity(0.72)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
        #else
        .background(.bar)
        #endif
    }
}

// MARK: - Bottom bar

struct BrowserBottomBar: View {
    let selectedCount: Int
    let idleIcon: String
    let onClearAll: () -> Void

    init(
        selectedCount: Int,
        idleIcon: String = "folder.badge.questionmark",
        onClearAll: @escaping () -> Void
    ) {
        self.selectedCount = selectedCount
        self.idleIcon = idleIcon
        self.onClearAll = onClearAll
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if selectedCount == 0 {
                    #if os(macOS)
                    Image(systemName: idleIcon).foregroundStyle(.secondary)
                    Text("no_dirs_selected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    #else
                    Label("no_dirs_selected", systemImage: idleIcon)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    #endif
                } else {
                    #if os(macOS)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("\(selectedCount) \(String(localized: "directories_selected"))")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("clear_all", action: onClearAll)
                        .controlSize(.small)
                    #else
                    Label(
                        "\(selectedCount) \(String(localized: "directories_selected"))",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentColor)
                    Spacer()
                    Button("clear_all", action: onClearAll)
                        .font(.caption)
                    #endif
                }
                Spacer()
            }
            #if os(macOS)
            .padding(.horizontal, 16).padding(.vertical, 8)
            #else
            .padding(.horizontal, 16).padding(.vertical, 10)
            #endif
        }
        #if os(macOS)
        .background(PMColor.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
        #else
        .background(.bar)
        #endif
    }
}

// MARK: - Preview pane

#if os(macOS)
struct DirectoryPreviewPane: View {
    let title: String
    let path: String
    let items: [RemoteFileItem]
    let selectedCount: Int

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "alac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma", "dsf", "dff"
    ]
    private static let coverNames: Set<String> = [
        "cover", "folder", "front", "album", "artwork"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "已选择")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(PMColor.textFaint)
                    .textCase(.uppercase)

                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(coverGradient)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                    VStack(spacing: 9) {
                        Image(systemName: coverFileCount > 0 ? "photo.stack.fill" : "music.note")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                        Text(verbatim: coverFileCount > 0 ? "\(coverFileCount) 张封面" : "暂无封面")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.86))
                    }
                }
                .frame(width: 120, height: 120)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(2)
                Text(verbatim: pathDisplay)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(2)
            }

            VStack(spacing: 0) {
                DirectoryPreviewStatRow(
                    icon: "music.note.list",
                    title: "文件统计",
                    value: "\(audioFileCount) 个文件 · \(totalSizeText)"
                )
                DirectoryPreviewStatRow(
                    icon: "waveform",
                    title: "格式",
                    value: formatSummary
                )
                DirectoryPreviewStatRow(
                    icon: hasLyrics ? "text.quote" : "text.badge.xmark",
                    title: "歌词",
                    value: hasLyrics ? "包含 .lrc 文件" : "无 .lrc 文件 (将刮削)",
                    divider: true
                )
            }
            .background(PMColor.bgElev.opacity(0.76), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }

            HStack(spacing: 8) {
                Image(systemName: selectedCount > 0 ? "checkmark.circle.fill" : "folder.badge.questionmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selectedCount > 0 ? PMColor.ok : PMColor.textFaint)
                Text(verbatim: selectedCount > 0 ? "\(selectedCount) 个目录已勾选" : "勾选左侧目录后导入")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(width: 240)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                PMColor.bg
                PMColor.card.opacity(0.52)
            }
        }
    }

    private var files: [RemoteFileItem] {
        items.filter { !$0.isDirectory }
    }

    private var audioFiles: [RemoteFileItem] {
        files.filter { Self.audioExtensions.contains(fileExtension($0.name)) }
    }

    private var audioFileCount: Int {
        audioFiles.isEmpty ? files.count : audioFiles.count
    }

    private var totalSizeText: String {
        let bytes = (audioFiles.isEmpty ? files : audioFiles).reduce(Int64(0)) { $0 + max(0, $1.size) }
        guard bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var formatSummary: String {
        let extensions = audioFiles
            .map { fileExtension($0.name).uppercased() }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = extensions.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return "—" }
        if unique.count <= 3 {
            return unique.joined(separator: " · ")
        }
        return unique.prefix(3).joined(separator: " · ") + " +\(unique.count - 3)"
    }

    private var hasLyrics: Bool {
        files.contains { fileExtension($0.name) == "lrc" }
            || audioFiles.contains { $0.sidecarHints?.lyricsPath != nil }
    }

    private var coverFileCount: Int {
        let sidecarCount = audioFiles.filter { $0.sidecarHints?.coverPath != nil }.count
        let siblingCount = files.filter { item in
            let ext = fileExtension(item.name)
            guard ["jpg", "jpeg", "png", "webp", "heic"].contains(ext) else { return false }
            let base = ((item.name as NSString).deletingPathExtension).lowercased()
            return Self.coverNames.contains(base) || base.hasSuffix("-cover")
        }.count
        return max(sidecarCount, siblingCount)
    }

    private var pathDisplay: String {
        path == "/" ? String(localized: "shared_folders") : path
    }

    private var coverGradient: LinearGradient {
        LinearGradient(
            colors: [
                PMColor.brand.opacity(0.92),
                Color(red: 0.10, green: 0.48, blue: 0.54),
                Color(red: 0.88, green: 0.58, blue: 0.20)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func fileExtension(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }
}

private struct DirectoryPreviewStatRow: View {
    let icon: String
    let title: String
    let value: String
    var divider = false

    var body: some View {
        VStack(spacing: 0) {
            if divider {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
            }
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
                    .frame(width: 16, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(PMColor.textFaint)
                    Text(verbatim: value)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
    }
}

// MARK: - macOS 树形目录浏览器 (设计稿)

/// 扁平化的树形目录行 (id = 远端路径)。展开时把子目录懒加载插到该行之后,
/// 收起时移除其子树 —— 比递归 DisclosureGroup 更好控制选中态与远端按需加载。
struct MacDirTreeRow: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let depth: Int
    var isExpanded: Bool
    var isLoading: Bool
}

/// 设计稿的 macOS 目录浏览器外壳: traffic-light 自定义窗头 + 懒加载树形目录
/// (多选勾选) + 「已选择」预览面板 + 返回/完成 底栏。SMB / WebDAV / FTP /
/// SFTP / NFS / UPnP / 云盘 / Synology 共用 —— 各自只提供一个 `load(path)`
/// 闭包返回该目录下的条目 (子目录 + 文件)。SSL 信任弹窗由本组件统一处理。
struct MacDirTreeBrowser: View {
    let title: String
    let subtitle: String
    var rootTitle: String = ""
    @Binding var selectedDirectories: [String]
    let load: (String) async throws -> [RemoteFileItem]
    var rootPath: String = "/"

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [MacDirTreeRow] = []
    @State private var focusedPath: String?
    @State private var focusedItems: [RemoteFileItem] = []
    @State private var cache: [String: [RemoteFileItem]] = [:]
    @State private var rootLoaded = false
    @State private var rootLoading = false
    @State private var errorMessage: String?
    @State private var sslTrustDomain: String?
    @State private var sslTrustContinuation: CheckedContinuation<Bool, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            if let errorMessage {
                errorState(errorMessage)
            } else {
                HStack(spacing: 0) {
                    treeColumn
                    Rectangle().fill(PMColor.divider).frame(width: 0.5)
                    DirectoryPreviewPane(
                        title: focusedTitle,
                        path: focusedPath ?? rootPath,
                        items: focusedItems,
                        selectedCount: selectedDirectories.count
                    )
                }
            }

            Rectangle().fill(PMColor.divider).frame(height: 0.5)
            footer
        }
        .frame(minWidth: 860, idealWidth: 940, minHeight: 560, idealHeight: 660)
        .background(PMColor.bg)
        .onAppear {
            guard !rootLoaded else { return }
            rootLoaded = true
            Task { await loadRoot() }
        }
        .alert(
            String(localized: "ssl_trust_title"),
            isPresented: Binding(
                get: { sslTrustDomain != nil },
                set: { if !$0 { resolveSSLTrust(approved: false) } }
            )
        ) {
            Button(String(localized: "trust_domain"), role: .destructive) { resolveSSLTrust(approved: true) }
            Button(String(localized: "dont_trust"), role: .cancel) { resolveSSLTrust(approved: false) }
        } message: {
            if let domain = sslTrustDomain { Text("ssl_trust_message \(domain)") }
        }
    }

    // MARK: 顶栏 / 底栏

    private var header: some View {
        HStack(spacing: 12) {
            PMWindowTrafficLights(closeOnly: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if selectedDirectories.isEmpty {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textFaint)
                Text(verbatim: "勾选要导入的目录")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textFaint)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.ok)
                Text(verbatim: "已选 \(selectedDirectories.count) 个目录")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(PMColor.textMuted)
                Button {
                    withAnimation { selectedDirectories.removeAll() }
                } label: {
                    Text(verbatim: "清除")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PMColor.brand)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button { dismiss() } label: {
                Text(verbatim: "返回")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 7))
            }
            .buttonStyle(.plain)

            Button { dismiss() } label: {
                Text(verbatim: selectedDirectories.isEmpty ? "完成" : "完成 (\(selectedDirectories.count))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(PMColor.brand, in: .rect(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    // MARK: 树形列

    private var treeColumn: some View {
        ScrollView(.vertical, showsIndicators: true) {
            if rootLoading {
                status(icon: nil, text: String(localized: "loading_directories"))
            } else if rows.isEmpty {
                status(icon: "folder", text: String(localized: "no_subdirectories"))
            } else {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func status(icon: String?, text: String) -> some View {
        VStack(spacing: 10) {
            if let icon {
                Image(systemName: icon).font(.system(size: 30)).foregroundStyle(PMColor.textFaint)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(verbatim: text).font(.system(size: 12.5)).foregroundStyle(PMColor.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func rowView(_ row: MacDirTreeRow) -> some View {
        let focused = focusedPath == row.path
        let checked = selectedDirectories.contains(row.path)
        return HStack(spacing: 6) {
            Button { Task { await toggleExpand(row) } } label: {
                Group {
                    if row.isLoading {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(PMColor.textFaint)
                            .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    }
                }
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { toggleChecked(row.path) } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(checked ? PMColor.brand : PMColor.textFaint)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Image(systemName: row.isExpanded ? "folder.fill" : "folder")
                .font(.system(size: 13))
                .foregroundStyle(checked ? PMColor.brand : PMColor.textMuted)
                .frame(width: 18)

            Text(verbatim: row.name)
                .font(.system(size: 13, weight: (focused || checked) ? .medium : .regular))
                .foregroundStyle(focused ? PMColor.text : PMColor.text.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)
        }
        .padding(.leading, 8 + CGFloat(row.depth) * 16)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(focused ? PMColor.brand.opacity(0.16) : Color.clear)
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await focus(row) } }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(PMColor.warn)
            Text(verbatim: message)
                .font(.system(size: 12))
                .foregroundStyle(PMColor.textMuted)
                .multilineTextAlignment(.center)
            Button("retry") { Task { await loadRoot() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: 计算属性

    private var focusedTitle: String {
        if let path = focusedPath, let row = rows.first(where: { $0.path == path }) {
            return row.name
        }
        return rootTitle
    }

    // MARK: 加载 / 展开 / 选择

    private func toggleChecked(_ path: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if let idx = selectedDirectories.firstIndex(of: path) {
                selectedDirectories.remove(at: idx)
            } else {
                selectedDirectories.append(path)
            }
        }
    }

    private func loadRoot() async {
        rootLoading = true
        errorMessage = nil
        do {
            let items = try await listing(rootPath)
            rows = dirRows(from: items, depth: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
        rootLoading = false
    }

    private func dirRows(from items: [RemoteFileItem], depth: Int) -> [MacDirTreeRow] {
        items.filter(\.isDirectory)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { MacDirTreeRow(id: $0.path, name: $0.name, path: $0.path,
                                 depth: depth, isExpanded: false, isLoading: false) }
    }

    private func toggleExpand(_ row: MacDirTreeRow) async {
        guard let idx = rows.firstIndex(where: { $0.id == row.id }) else { return }
        if rows[idx].isExpanded {
            let baseDepth = rows[idx].depth
            var end = idx + 1
            while end < rows.count, rows[end].depth > baseDepth { end += 1 }
            rows.removeSubrange((idx + 1)..<end)
            rows[idx].isExpanded = false
            return
        }
        rows[idx].isLoading = true
        do {
            let items = try await listing(row.path)
            guard let i = rows.firstIndex(where: { $0.id == row.id }) else { return }
            let children = dirRows(from: items, depth: rows[i].depth + 1)
            rows.insert(contentsOf: children, at: i + 1)
            rows[i].isExpanded = true
            rows[i].isLoading = false
        } catch {
            if let i = rows.firstIndex(where: { $0.id == row.id }) { rows[i].isLoading = false }
            errorMessage = error.localizedDescription
        }
    }

    private func focus(_ row: MacDirTreeRow) async {
        focusedPath = row.path
        do {
            focusedItems = try await listing(row.path)
        } catch {
            focusedItems = []
        }
    }

    /// 拉取某个远端目录的列表 (带 cache 与 SSL 信任重试)。
    private func listing(_ path: String) async throws -> [RemoteFileItem] {
        if let cached = cache[path] { return cached }
        do {
            let items = try await load(path)
            cache[path] = items
            return items
        } catch {
            let trusted = await promptSSLTrust(for: error)
            guard trusted else { throw error }
            let items = try await load(path)
            cache[path] = items
            return items
        }
    }

    // MARK: SSL 信任

    private func resolveSSLTrust(approved: Bool) {
        if approved, let domain = sslTrustDomain { SSLTrustStore.shared.trust(domain: domain) }
        let cont = sslTrustContinuation
        sslTrustDomain = nil; sslTrustContinuation = nil
        cont?.resume(returning: approved)
    }

    private func promptSSLTrust(for error: Error) async -> Bool {
        guard let domain = SSLTrustStore.sslErrorDomain(from: error) else { return false }
        if SSLTrustStore.shared.isTrusted(domain: domain) { return true }
        return await withCheckedContinuation { continuation in
            sslTrustDomain = domain; sslTrustContinuation = continuation
        }
    }
}
#endif

// MARK: - Toolbar

/// 目录浏览器顶端 cancel/done toolbar item。macOS 上自动绑 Esc/Return。
struct DirectoryBrowserToolbar: ToolbarContent {
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("done", action: onConfirm)
                .fontWeight(.semibold)
                .keyboardShortcut(.defaultAction)
        }
    }
}
