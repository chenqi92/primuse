import Foundation
import PrimuseKit
import SwiftUI

// MARK: - 通用目录浏览器外壳
//
// ConnectorDirectoryBrowserView / NFSBrowserView / UPnPBrowserView
// 共用的 sheet chrome——breadcrumb、底部 bar、
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

@MainActor
enum DirectoryBrowserNetworkRetry {
    /// The first real TCP/SMB/WebDAV connection can be the moment macOS/iOS/tvOS
    /// shows the Local Network permission alert. Some lower-level libraries
    /// surface that in-flight authorization as an immediate connection failure
    /// before the user has clicked Allow. Keep the browser in loading state
    /// briefly and retry so the successful permission decision is picked up
    /// without a manual Retry click.
    private static let localNetworkAuthorizationRetryDelays: [UInt64] = [
        700_000_000,
        1_300_000_000,
        2_500_000_000,
        4_000_000_000
    ]

    static func loadWithLocalNetworkAuthorizationGrace<Value>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch {
            guard shouldRetryAfterLocalNetworkAuthorization(error) else {
                throw error
            }

            var lastError = error
            for delay in localNetworkAuthorizationRetryDelays {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: delay)
                do {
                    return try await operation()
                } catch {
                    lastError = error
                    if shouldRetryAfterLocalNetworkAuthorization(error) == false {
                        throw error
                    }
                }
            }
            throw lastError
        }
    }

    static func shouldRetryAfterLocalNetworkAuthorization(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if SSLTrustStore.sslErrorDomain(from: error) != nil { return false }

        switch error {
        case SourceError.connectionFailed, SourceError.timeout:
            return true
        case SourceError.pathNotFound, SourceError.fileNotFound,
             SourceError.credentialUnavailable, SourceError.authenticationFailed:
            return false
        default:
            break
        }

        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return [
                NSURLErrorNotConnectedToInternet,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorDataNotAllowed,
                NSURLErrorTimedOut
            ].contains(ns.code)
        }

        if ns.domain == NSPOSIXErrorDomain {
            return [
                Int(EACCES), Int(EPERM),
                Int(ECONNREFUSED), Int(EHOSTUNREACH), Int(ENETUNREACH),
                Int(ENOTCONN), Int(ECONNRESET), Int(ENETRESET),
                Int(ETIMEDOUT)
            ].contains(ns.code)
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("network")
            || message.contains("connection")
            || message.contains("timed out")
            || message.contains("timeout")
            || message.contains("not permitted")
            || message.contains("operation not permitted")
            || message.contains("unreachable")
            || message.contains("refused")
            || message.contains("网络")
            || message.contains("联网")
            || message.contains("连接")
            || message.contains("权限")
            || message.contains("不可达")
            || message.contains("超时")
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
            // 路径条固定在目录列表上方:iPhone Duo 竖栏时停在竖栏前。
            .pmPinnedRowStopsAtVerticalBar()
            .onChange(of: segments.count) { _, _ in
                pmWithAnimation(.list) { proxy.scrollTo(segments.count - 1, anchor: .trailing) }
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

// MARK: - 已包含在上级里的目录

/// 被已勾选的上级目录覆盖的那一行下面的说明:这一行会跟着上级一起扫描
/// (源上以后新建的目录也一样),要单独勾它得先取消上级。
enum DirectorySelectionInclusionText {
    static func caption(ancestor: String, title: String?) -> String {
        if SourceDirectorySelectionPolicy.isRootPath(ancestor) {
            return String(localized: "folder_pick_included_whole_source")
        }
        guard let title, !title.isEmpty else {
            return String(localized: "folder_pick_included_generic")
        }
        return String(format: String(localized: "folder_pick_included_in_format"), title)
    }
}

// MARK: - 立即扫描「已包含」的目录

/// 选目录页「已包含」行上的「立即扫描此目录」：只把这一棵子树重新列一遍（走资料库文件夹页
/// 「重新扫描此文件夹」同一条路径），不改勾选。宿主（音乐源页）只给已保存、支持单独重扫
/// 文件夹的源；这次打开后改过勾选就不再提供——扫描索引对应的是旧范围，关掉页面时会整源重扫。
struct DirectoryRescanAction {
    /// 这一行（连同浏览经过的上级，外层在前）是否被已扫描的范围覆盖。
    let covers: @MainActor (_ path: String, _ ancestors: [String]) -> Bool
    /// 这个源正在扫描。只在按钮自己的 body 里调用（读的是只在开扫、扫完时才变的那一份）。
    let isScanning: @MainActor () -> Bool
    /// 目录本身在前、再依次往上的各级；开始了返回 true。
    let rescan: @MainActor (_ candidates: [String]) -> Bool

    @MainActor
    static func forSavedSource(
        _ source: MusicSource,
        directoriesWhenOpened: @escaping @MainActor () -> [String]?,
        scanService: ScanService,
        sourceManager: SourceManager,
        library: MusicLibrary,
        sourceStore: SourcesStore,
        scraperService: MusicScraperService
    ) -> DirectoryRescanAction? {
        guard let saved = sourceStore.source(id: source.id),
              saved.isEnabled, !saved.isDeleted,
              ScanService.supportsFolderRescan(saved) else { return nil }
        let sourceID = saved.id
        return DirectoryRescanAction(
            covers: { path, ancestors in
                guard let current = sourceStore.source(id: sourceID) else { return false }
                let directories = current.scannedDirectories
                if let opened = directoriesWhenOpened(), Set(opened) != Set(directories) {
                    return false
                }
                guard case .included = SourceDirectorySelectionPolicy.selectionState(
                    of: path,
                    in: directories,
                    ancestors: ancestors,
                    for: current.type
                ) else { return false }
                return true
            },
            isScanning: { scanService.scanningSourceIDs.contains(sourceID) },
            rescan: { candidates in
                guard let current = sourceStore.source(id: sourceID) else { return false }
                return scanService.rescanFolder(
                    of: current,
                    request: SourceFolderRescanRequest(directoryCandidates: candidates),
                    sourceManager: sourceManager,
                    library: library,
                    sourceStore: sourceStore,
                    scraperService: scraperService
                )
            }
        )
    }
}

private struct DirectoryRescanActionKey: EnvironmentKey {
    static var defaultValue: DirectoryRescanAction? { nil }
}

extension EnvironmentValues {
    var directoryRescanAction: DirectoryRescanAction? {
        get { self[DirectoryRescanActionKey.self] }
        set { self[DirectoryRescanActionKey.self] = newValue }
    }
}

/// 「已包含」行行尾的次级按钮。点下去这个源开始扫描时转圈，扫完复原；源正在扫（别处发起的）时不可点。
struct DirectoryRescanButton: View {
    let action: DirectoryRescanAction
    let candidates: [String]
    @State private var isRequested = false

    var body: some View {
        let isScanning = action.isScanning()
        Button {
            isRequested = action.rescan(candidates)
        } label: {
            ZStack {
                if isRequested && isScanning {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(Color.secondary.opacity(0.12), in: Circle())
            #if os(iOS)
            .frame(width: 34, height: 44)
            #endif
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isScanning)
        .help(Text("directory_rescan_now"))
        .accessibilityLabel(Text("directory_rescan_now"))
        .accessibilityIdentifier("directoryPicker.rescan")
        .onChange(of: isScanning) { _, scanning in
            if !scanning { isRequested = false }
        }
    }
}

// MARK: - Folder tags

extension ListeningContentKind {
    var directorySpace: ListeningSpace {
        switch self {
        case .music: .music
        case .spokenWord: .spokenWord
        case .podcast: .podcast
        }
    }
}

/// A selected scan folder's content tag; music keeps the usual file inference.
struct DirectoryFolderTag {
    let kind: ListeningContentKind
    let set: (ListeningContentKind) -> Void

    var space: ListeningSpace { kind.directorySpace }

    /// The tag for `path` of `source`, or nil for sources that offer no
    /// folders to choose (media servers and other whole-catalogue servers).
    @MainActor
    static func forFolder(
        path: String, of source: MusicSource, store: SpokenWordStore = .shared
    ) -> DirectoryFolderTag? {
        guard SpokenWordFolderTag.supportsFolderTags(for: source.type) else { return nil }
        let sourceID = source.id
        return DirectoryFolderTag(
            kind: store.folderKind(sourceID: sourceID, path: path),
            set: { store.setFolderKind($0, sourceID: sourceID, path: path) }
        )
    }
}

/// The capsule on a selected folder row; tapping it picks what is inside.
struct DirectoryFolderTagMenu: View {
    let tag: DirectoryFolderTag

    private var space: ListeningSpace { tag.space }

    var body: some View {
        Menu {
            Section("directory_tag_menu_title") {
                ForEach(ListeningContentKind.allCases, id: \.rawValue) { kind in
                    option(kind.directorySpace, kind: kind)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: space.systemImage)
                    .font(.caption2.weight(.semibold))
                Text(space.title)
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(space.tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(space.tint.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(Text("directory_tag_menu_title"))
        .accessibilityValue(Text(space.title))
    }

    private func option(_ space: ListeningSpace, kind: ListeningContentKind) -> some View {
        Button {
            tag.set(kind)
        } label: {
            if tag.kind == kind {
                Label(space.title, systemImage: "checkmark")
            } else {
                Label(space.title, systemImage: space.systemImage)
            }
        }
    }
}

/// The rounded tile a folder row leads with.
struct DirectoryFolderTile: View {
    let icon: String
    let tint: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// One selected folder in the bottom bar, so choices made in other folders
/// stay in view and can be taken back from here.
struct BrowserSelectionChip: Identifiable, Equatable {
    let id: String
    let title: String
    let kind: ListeningContentKind
}

// MARK: - Bottom bar

struct BrowserBottomBar: View {
    let selectedCount: Int
    let idleIcon: String
    let chips: [BrowserSelectionChip]
    let onRemove: ((String) -> Void)?
    let onClearAll: () -> Void

    init(
        selectedCount: Int,
        idleIcon: String = "folder.badge.questionmark",
        chips: [BrowserSelectionChip] = [],
        onRemove: ((String) -> Void)? = nil,
        onClearAll: @escaping () -> Void
    ) {
        self.selectedCount = selectedCount
        self.idleIcon = idleIcon
        self.chips = chips
        self.onRemove = onRemove
        self.onClearAll = onClearAll
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            #if os(iOS)
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips) { chip in
                            chipView(chip)
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }
                // 底栏固定不动:已选目录的胶囊停在竖栏前。
                .pmPinnedRowStopsAtVerticalBar()
                .pmAnimation(.list, value: chips)
            }
            #endif
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

    #if os(iOS)
    private func chipView(_ chip: BrowserSelectionChip) -> some View {
        let space = chip.kind.directorySpace
        return HStack(spacing: 6) {
            Image(systemName: chip.kind == .music ? "folder.fill" : space.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(space.tint)
            Text(verbatim: chip.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
            if let onRemove {
                Button { onRemove(chip.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("remove"))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, onRemove == nil ? 10 : 4)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
    #endif
}

// MARK: - Preview pane

#if os(macOS)
struct DirectoryPreviewPane: View {
    let title: String
    let path: String
    let items: [RemoteFileItem]
    let selectedCount: Int

    private static let audioExtensions = PrimuseConstants.supportedAudioExtensions
    private static let coverNames: Set<String> = [
        "cover", "folder", "front", "album", "artwork"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("library_quick_access_selected")
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
                        Text(verbatim: coverFileCount > 0
                            ? String(format: String(localized: "directory_cover_count_format"), coverFileCount)
                            : String(localized: "directory_no_cover"))
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
                    title: String(localized: "directory_file_stats"),
                    value: String(format: String(localized: "directory_audio_files_format"), audioFileCount, totalSizeText)
                )
                DirectoryPreviewStatRow(
                    icon: "waveform",
                    title: String(localized: "format_label"),
                    value: formatSummary
                )
                DirectoryPreviewStatRow(
                    icon: hasLyrics ? "text.quote" : "text.badge.xmark",
                    title: String(localized: "lyrics_word"),
                    value: hasLyrics ? String(localized: "directory_has_lrc") : String(localized: "directory_no_lrc"),
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
                Text(verbatim: selectedCount > 0
                    ? String(format: String(localized: "directory_checked_count_format"), selectedCount)
                    : String(localized: "directory_select_to_import"))
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
        files.contains { PrimuseConstants.readableLyricsExtensions.contains(fileExtension($0.name)) }
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

/// 设计稿的 macOS 目录浏览器外壳: 自定义标题区 + 懒加载树形目录
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
    var sourceType: MusicSourceType? = nil
    var selectableRootPath: String? = nil
    var onConfirm: ((Bool) -> Void)? = nil
    /// 失败态要说明「这次连的是哪个地址」时才给。没有服务器地址这个概念的源
    /// (云盘、本机)不传,失败态就还是只有一句错误。
    var failureSource: MusicSource? = nil
    /// 失败态「修改地址」的出口,由宿主负责关 sheet 再开编辑表单。
    var onEditAddress: (() -> Void)? = nil
    /// 给勾选的目录标「音乐 / 有声」。只有歌曲路径就是真实目录的源才传。
    var tagSource: MusicSource? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.directoryRescanAction) private var rescanAction
    @State private var rows: [MacDirTreeRow] = []
    @State private var focusedPath: String?
    @State private var focusedItems: [RemoteFileItem] = []
    @State private var cache: [String: [RemoteFileItem]] = [:]
    @State private var rootLoaded = false
    @State private var rootLoading = false
    @State private var errorMessage: String?
    @State private var rootConnectionValidated = false
    @State private var failureReport = SourceConnectionFailureReport()

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
        .transportTrustAlerts()
    }

    // MARK: 顶栏 / 底栏

    private var header: some View {
        HStack(spacing: 12) {
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
                Text("directory_select_to_import")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textFaint)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.ok)
                Text(verbatim: String(
                    format: String(localized: "directory_selected_count_format"),
                    selectedDirectories.count
                ))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(PMColor.textMuted)
                Button {
                    pmWithAnimation(.list) { selectedDirectories.removeAll() }
                } label: {
                    Text("clear")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PMColor.brand)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button { dismiss() } label: {
                Text("back")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 7))
            }
            .buttonStyle(.plain)

            Button { confirmSelection() } label: {
                Text(verbatim: selectedDirectories.isEmpty
                    ? String(localized: "done")
                    : String(format: String(localized: "done_count_format"), selectedDirectories.count))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(PMColor.brand, in: .rect(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(deferredConfirmationDisabled)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    // MARK: 树形列

    private var treeColumn: some View {
        ScrollView(.vertical, showsIndicators: true) {
            if rootLoading {
                status(icon: nil, text: String(localized: "loading_directories"))
                    .pmAppearFade(.contentAppear)
            } else if rows.isEmpty, effectiveRootSelectionPath == nil {
                status(icon: "folder", text: String(localized: "no_subdirectories"))
                    .pmAppearFade(.contentAppear)
            } else {
                let selections = rowSelections()
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let effectiveRootSelectionPath {
                        rootSelectionRow(effectiveRootSelectionPath)
                    }
                    ForEach(rows) { row in
                        rowView(
                            row,
                            state: selections[row.path]?.state ?? .unselected,
                            ancestors: selections[row.path]?.ancestors ?? []
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                // 只在「整份内容替换」这一层淡入, 目录行自己的增删不挂动画 ——
                // 连点面包屑时逐行 diff 的动画会排队。
                .pmAppearFade(.contentAppear)
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

    private func rowView(
        _ row: MacDirTreeRow,
        state: SourceDirectorySelectionPolicy.SelectionState,
        ancestors: [String]
    ) -> some View {
        let focused = focusedPath == row.path
        let checked = state == .selected
        let includedCaption = inclusionCaption(for: state)
        let included = includedCaption != nil
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
                Image(systemName: checked || included ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(checked ? PMColor.brand : PMColor.textFaint)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 上级已勾选:这一行本来就会被扫描,不能再单独勾。展开、聚焦照常。
            .disabled(included)
            .help(includedCaption ?? "")
            .accessibilityLabel(Text(verbatim: row.name))
            .accessibilityValue(includedCaption ?? "")
            .accessibilityAddTraits(checked || included ? .isSelected : [])

            Image(systemName: row.isExpanded ? "folder.fill" : "folder")
                .font(.system(size: 13))
                .foregroundStyle(checked ? PMColor.brand : PMColor.textMuted)
                .frame(width: 18)

            Text(verbatim: row.name)
                .font(.system(size: 13, weight: (focused || checked) ? .medium : .regular))
                .foregroundStyle(focused ? PMColor.text : PMColor.text.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)

            if let includedCaption {
                Text(verbatim: includedCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            // 「已包含」的子目录也能单独标成有声:标签按目录匹配歌曲,不要求它自己是扫描根。
            if checked || included, let tag = folderTag(for: row.path) {
                DirectoryFolderTagMenu(tag: tag)
            }

            if included, let rescanAction, rescanAction.covers(row.path, ancestors) {
                DirectoryRescanButton(action: rescanAction, candidates: [row.path] + ancestors.reversed())
            }
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

    private func folderTag(for path: String) -> DirectoryFolderTag? {
        guard let tagSource else { return nil }
        return DirectoryFolderTag.forFolder(path: path, of: tagSource)
    }

    private func rootSelectionRow(_ path: String) -> some View {
        let checked = SourceDirectorySelectionPolicy.selectionState(
            of: path,
            in: selectedDirectories,
            for: sourceType
        ) == .selected
        return HStack(spacing: 0) {
            rootSelectionButton(path, checked: checked)
            if checked, let tag = folderTag(for: path) {
                DirectoryFolderTagMenu(tag: tag)
                    .padding(.trailing, 8)
            }
        }
    }

    private func rootSelectionButton(_ path: String, checked: Bool) -> some View {
        Button {
            toggleChecked(path)
        } label: {
            HStack(spacing: 6) {
                Color.clear.frame(width: 16, height: 16)
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(checked ? PMColor.brand : PMColor.textFaint)
                    .frame(width: 18, height: 18)
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(checked ? PMColor.brand : PMColor.textMuted)
                    .frame(width: 18)
                Text(verbatim: rootTitle)
                    .font(.system(size: 13, weight: checked ? .medium : .regular))
                    .foregroundStyle(PMColor.text.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(PMColor.warn)
            // 这次连的是哪个地址 / 针对性提示,都按这一屏的设计语言写,
            // 取值来自与 iOS 同一份 SourceConnectionFailureReport。
            if let address = failureReport.address {
                Text(verbatim: String(
                    format: String(localized: "connection_failed_address %@"),
                    address
                ))
                .font(.system(size: 12))
                .foregroundStyle(PMColor.textMuted)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            }
            Text(verbatim: message)
                .font(.system(size: 12))
                .foregroundStyle(PMColor.textMuted)
                .multilineTextAlignment(.center)
            if let hint = failureReport.hint {
                Label(hint, systemImage: "lightbulb")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textFaint)
                    .multilineTextAlignment(.leading)
            }
            HStack(spacing: 10) {
                Button("retry") { Task { await loadRoot() } }
                    .buttonStyle(.bordered)
                SourceConnectionEditAddressButton(
                    report: failureReport,
                    onEditAddress: onEditAddress
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// 失败态那两行说明的取值。没传 `failureSource` 的调用点拿到空报告,
    /// 显示结果与以前一模一样。
    private func resolvedFailureReport(for error: Error) async -> SourceConnectionFailureReport {
        guard let failureSource else { return SourceConnectionFailureReport() }
        return await SourceConnectionFailureReport.resolve(
            for: failureSource,
            suggestsAddressEdit: SourceConnectionFailureReport.errorSuggestsAddressEdit(error)
        )
    }

    // MARK: 计算属性

    /// 可勾选的整源行。本来不提供根目录勾选的源,如果已存的选择里有根
    /// (比如电视端存的「整个音乐源」),也把它显示出来,这样才能取消。
    private var effectiveRootSelectionPath: String? {
        selectableRootPath
            ?? SourceDirectorySelectionPolicy.storedRootSelection(in: selectedDirectories)
    }

    /// 每一行的勾选状态与它的祖先链(外层在前)。树是按深度拍平的前序列表,沿途维护
    /// 一条祖先链,一趟算完;按 ID 寻址的源只能靠这条链认出上下级。
    private func rowSelections() -> [String: (
        state: SourceDirectorySelectionPolicy.SelectionState,
        ancestors: [String]
    )] {
        let rootAncestors = [rootPath] + (effectiveRootSelectionPath.map { [$0] } ?? [])
        var chain: [String] = []
        var selections: [String: (
            state: SourceDirectorySelectionPolicy.SelectionState,
            ancestors: [String]
        )] = [:]
        selections.reserveCapacity(rows.count)
        for row in rows {
            if chain.count > row.depth {
                chain.removeLast(chain.count - row.depth)
            }
            let ancestors = rootAncestors + chain
            selections[row.path] = (
                SourceDirectorySelectionPolicy.selectionState(
                    of: row.path,
                    in: selectedDirectories,
                    ancestors: ancestors,
                    for: sourceType
                ),
                ancestors
            )
            chain.append(row.path)
        }
        return selections
    }

    private func inclusionCaption(
        for state: SourceDirectorySelectionPolicy.SelectionState
    ) -> String? {
        guard case .included(let ancestor) = state else { return nil }
        let title: String?
        if SourceDirectorySelectionPolicy.isSamePath(ancestor, rootPath) {
            title = rootTitle
        } else {
            // 覆盖这一行的上级一定是树里它上方已展开的某一行。
            title = rows.first(where: {
                SourceDirectorySelectionPolicy.isSamePath($0.path, ancestor)
            })?.name
        }
        return DirectorySelectionInclusionText.caption(ancestor: ancestor, title: title)
    }

    private var focusedTitle: String {
        if let path = focusedPath, let row = rows.first(where: { $0.path == path }) {
            return row.name
        }
        return rootTitle
    }

    // MARK: 加载 / 展开 / 选择

    private func toggleChecked(_ path: String) {
        pmWithAnimation(.list) {
            selectedDirectories = SourceDirectorySelectionPolicy.toggledSelection(
                selectedDirectories,
                path: path
            )
        }
    }

    private func loadRoot() async {
        rootLoading = true
        errorMessage = nil
        failureReport = SourceConnectionFailureReport()
        rootConnectionValidated = false
        do {
            let items = try await listing(rootPath)
            rows = dirRows(from: items, depth: 0)
            rootConnectionValidated = true
            if selectableRootPath != nil {
                focusedItems = items
            }
        } catch {
            failureReport = await resolvedFailureReport(for: error)
            errorMessage = error.localizedDescription
        }
        rootLoading = false
    }

    private var deferredConfirmationDisabled: Bool {
        guard onConfirm != nil, let sourceType else { return false }
        return !SourceCreationPersistencePolicy.canCommitDeferredCreation(
            for: sourceType,
            connectionValidated: rootConnectionValidated,
            selectedDirectories: selectedDirectories
        )
    }

    private func confirmSelection() {
        guard let onConfirm else {
            dismiss()
            return
        }
        guard !deferredConfirmationDisabled else { return }
        onConfirm(rootConnectionValidated)
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
            failureReport = await resolvedFailureReport(for: error)
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
            let items = try await DirectoryBrowserNetworkRetry.loadWithLocalNetworkAuthorizationGrace {
                try await load(path)
            }
            cache[path] = items
            return items
        } catch {
            let trusted = await promptSSLTrust(for: error)
            guard trusted else { throw error }
            let items = try await DirectoryBrowserNetworkRetry.loadWithLocalNetworkAuthorizationGrace {
                try await load(path)
            }
            cache[path] = items
            return items
        }
    }

    // MARK: SSL 信任

    private func promptSSLTrust(for error: Error) async -> Bool {
        guard let domain = SSLTrustStore.sslErrorDomain(from: error) else { return false }
        return await SSLTrustStore.shared.requestTrust(domain: domain)
    }
}
#endif

// MARK: - Toolbar

/// 目录浏览器顶端 cancel/done toolbar item。macOS 上自动绑 Esc/Return。
struct DirectoryBrowserToolbar: ToolbarContent {
    let onCancel: () -> Void
    let onConfirm: () -> Void
    var confirmationDisabled = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("done", action: onConfirm)
                .fontWeight(.semibold)
                .keyboardShortcut(.defaultAction)
                .disabled(confirmationDisabled)
        }
    }
}
