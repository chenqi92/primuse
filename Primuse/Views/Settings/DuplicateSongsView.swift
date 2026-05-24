import SwiftUI
import PrimuseKit

/// 重复歌曲管理 — 找 library 里 title+artist+duration 一致的多版本歌曲,
/// 让用户保留一个 (推荐: 最高音质), 其他从 library 移除。
///
/// 支持删除的源会同步删源端音频；同名歌词/封面 sidecar 只有在没有保留歌曲
/// 继续使用时才删除。本地库记录、tombstone 和缓存统一由 SourceManager/MusicLibrary 链路处理。
struct DuplicateSongsView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(SourceManager.self) private var sourceManager
    @Environment(DuplicateCleanupService.self) private var cleaner

    @State private var groups: [DuplicateGroup] = []
    @State private var isScanning = false
    @State private var expandedGroupID: String?
    @State private var showCleanAllConfirm = false
    @State private var cleanedCount: Int = 0
    @State private var lastActionMessage: String?
    @State private var showAllGroups = false

    /// 一次性最多渲染多少个 Section, 超过后下面给个「显示全部」按钮。
    /// SwiftUI Form 大量 Section + DisclosureGroup 会让 macOS 渲染掉帧,
    /// 100 是经验值: 用户该清的早就用「一键清理」按钮处理了, 看完整列表
    /// 是相对边缘的需求, 显式展开避免默认 paint 卡。
    private static let initialGroupRenderCap = 100

    var body: some View {
        Form {
            // 内嵌进度条 (而不是 overlay), 这样切到其他菜单再回来仍能看到,
            // 因为状态在 DuplicateCleanupService 里, 不绑 view 生命周期。
            if let p = cleaner.progress {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(String(format: String(localized: "dup_cleaning_progress_format"),
                                        p.done, p.total))
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                            Spacer()
                        }
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                            .progressViewStyle(.linear)
                    }
                    .padding(.vertical, 4)
                }
            }

            if !isScanning && groups.isEmpty {
                emptyStateSection
            } else {
                if isScanning {
                    Section {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("dup_scanning").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    summarySection
                    cleanAllSection

                    ForEach(visibleGroups) { group in
                        groupSection(group)
                    }

                    if !showAllGroups, groups.count > Self.initialGroupRenderCap {
                        Section {
                            Button {
                                showAllGroups = true
                            } label: {
                                HStack {
                                    Image(systemName: "list.bullet.indent")
                                    Text(String(format: String(localized: "dup_show_all_format"),
                                                groups.count - Self.initialGroupRenderCap))
                                }
                            }
                        } footer: {
                            Text("dup_show_all_hint")
                        }
                    }
                }
            }
        }
        .navigationTitle("dup_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await rescan() }
        .refreshable { await rescan() }
        // 用 alert 而非 confirmationDialog: iOS 26 在 Form 内的
        // confirmationDialog 会按 popover 锚到触发按钮, 看起来像悬浮
        // 气泡且位置不固定; alert 居中显示更明显, destructive button
        // 也清楚。
        .alert(
            "dup_clean_all_confirm",
            isPresented: $showCleanAllConfirm
        ) {
            Button("dup_keep_best_action_short", role: .destructive) {
                cleanAll()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text(String(format: String(localized: "dup_clean_all_message_format"), totalRedundantCount))
        }
        .overlay(alignment: .bottom) {
            if let msg = lastActionMessage {
                Text(msg)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // 清理期间禁交互, 避免用户中途点其他按钮触发状态错乱。状态来自
        // service, 跨 view 销毁/重建也保持一致。
        .disabled(cleaner.progress != nil)
        .onChange(of: cleaner.progress?.isFinished) { _, finished in
            // 后台完成后顺便 rescan + 给个总结提示, 即便用户切走又回来也成。
            guard finished == true else { return }
            let n = cleaner.lastCompletedCount
            if n > 0 {
                flashAction(String(format: String(localized: "dup_clean_all_done_format"), n))
            }
            Task { await rescan() }
        }
        #if os(macOS)
        .macReadablePane(maxWidth: 980)
        #endif
    }

    // MARK: - Sections

    private var emptyStateSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("dup_none_title").font(.headline)
                Text("dup_none_desc")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }

    private var summarySection: some View {
        Section {
            HStack {
                Label("dup_groups_count", systemImage: "square.stack.3d.up")
                Spacer()
                Text("\(groups.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Label("dup_redundant_count", systemImage: "trash")
                Spacer()
                Text("\(totalRedundantCount)").foregroundStyle(.secondary).monospacedDigit()
            }
        } footer: {
            Text("dup_summary_footer")
        }
    }

    private var cleanAllSection: some View {
        Section {
            Button(role: .destructive) {
                showCleanAllConfirm = true
            } label: {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text("dup_clean_all_action")
                }
            }
        }
    }

    @ViewBuilder
    private func groupSection(_ group: DuplicateGroup) -> some View {
        Section {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedGroupID == group.id },
                    set: { isExpanded in expandedGroupID = isExpanded ? group.id : nil }
                )
            ) {
                ForEach(group.songs, id: \.id) { song in
                    songRow(song: song, isBest: song.id == group.bestSong.id, group: group)
                }

                Button {
                    keepBest(of: group)
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                        Text(String(format: String(localized: "dup_keep_best_action_format"), group.songs.count - 1))
                    }
                    .font(.subheadline.weight(.medium))
                }
                .padding(.vertical, 4)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(group.artist.isEmpty ? "—" : group.artist)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text("\(group.count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func songRow(song: Song, isBest: Bool, group: DuplicateGroup) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(song.fileFormat.displayName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(formatBadgeColor(song).opacity(0.18)))
                        .foregroundStyle(formatBadgeColor(song))
                    if isBest {
                        Text("dup_best_badge")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
                            .foregroundStyle(.green)
                    }
                }
                Text(qualityDescription(song))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(sourceDescription(song))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }

            Spacer()

            Button(role: .destructive) {
                deleteSingle(song: song)
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .disabled(group.songs.count <= 1)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func rescan() async {
        isScanning = true
        defer { isScanning = false }
        // 主线程只负责拍 snapshot, 实际 Dictionary(grouping:) + folding
        // + sort 全部到后台跑。10k+ 库主线程跑要 1-3s 直接卡 UI。
        let snapshot = library.songs
        let detected = await Task.detached(priority: .userInitiated) {
            DuplicateDetector.detect(in: snapshot)
        }.value
        groups = detected
        expandedGroupID = nil
        showAllGroups = false
    }

    private func keepBest(of group: DuplicateGroup) {
        let toRemove = group.redundantSongs
        guard !toRemove.isEmpty else { return }
        cleaner.cleanup(toRemove)
    }

    private func deleteSingle(song: Song) {
        cleaner.cleanup([song])
    }

    private func cleanAll() {
        let toRemove = groups.flatMap(\.redundantSongs)
        cleaner.cleanup(toRemove)
    }

    private func flashAction(_ msg: String) {
        withAnimation { lastActionMessage = msg }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { lastActionMessage = nil }
        }
    }

    // MARK: - Display helpers

    private var totalRedundantCount: Int {
        groups.reduce(0) { $0 + $1.songs.count - 1 }
    }

    private var visibleGroups: [DuplicateGroup] {
        if showAllGroups || groups.count <= Self.initialGroupRenderCap {
            return groups
        }
        return Array(groups.prefix(Self.initialGroupRenderCap))
    }

    private func qualityDescription(_ song: Song) -> String {
        var parts: [String] = []
        if let br = song.bitRate, br > 0 { parts.append("\(br / 1000) kbps") }
        if let sr = song.sampleRate, sr > 0 {
            let kHz = Double(sr) / 1000
            parts.append(String(format: "%.1f kHz", kHz))
        }
        if let bd = song.bitDepth, bd > 0 { parts.append("\(bd)-bit") }
        if song.fileSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: song.fileSize, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private func sourceDescription(_ song: Song) -> String {
        let src = sourcesStore.allSources.first(where: { $0.id == song.sourceID })
        let sourceName = src?.name ?? "?"
        return "\(sourceName)  \(song.filePath)"
    }

    private func formatBadgeColor(_ song: Song) -> Color {
        switch song.fileFormat {
        case .flac, .alac, .wav, .aiff, .aif, .ape, .wv: return .purple
        case .dsf, .dff: return .pink
        default: return .blue
        }
    }
}
