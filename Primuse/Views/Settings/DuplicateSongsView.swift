import SwiftUI
import PrimuseKit

/// 重复歌曲管理 — 找 library 里 title+artist+duration 一致的多版本歌曲,
/// 让用户保留一个 (推荐: 最高音质), 其他从 library 移除。
///
/// **NAS 上的源文件不会被删**, 仅从 primuse 的 library 数据库中移除 +
/// 写 tombstone 防止下次 scan 重新加入。如果用户想恢复, 在 source
/// 设置里手动 delete tombstone 即可。
struct DuplicateSongsView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore

    @State private var groups: [DuplicateGroup] = []
    @State private var isScanning = false
    @State private var expandedGroupID: String?
    @State private var showCleanAllConfirm = false
    @State private var cleanedCount: Int = 0
    @State private var lastActionMessage: String?

    var body: some View {
        Form {
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

                    ForEach(groups) { group in
                        groupSection(group)
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
                deleteSingle(song: song, in: group)
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
        // detect 是 CPU bound 的 in-memory 算, 几千首歌 < 100ms
        // 直接同步算 + 让出一帧给 SwiftUI 显示 ProgressView
        try? await Task.sleep(for: .milliseconds(50))
        groups = DuplicateDetector.detect(in: library.songs)
        expandedGroupID = nil
    }

    private func keepBest(of group: DuplicateGroup) {
        let removed = group.redundantSongs.count
        for song in group.redundantSongs {
            library.deleteSong(song)
        }
        flashAction(String(format: String(localized: "dup_action_done_format"), removed))
        Task { await rescan() }
    }

    private func deleteSingle(song: Song, in group: DuplicateGroup) {
        library.deleteSong(song)
        flashAction(String(format: String(localized: "dup_action_done_format"), 1))
        Task { await rescan() }
    }

    private func cleanAll() {
        var removed = 0
        for group in groups {
            for song in group.redundantSongs {
                library.deleteSong(song)
                removed += 1
            }
        }
        cleanedCount = removed
        flashAction(String(format: String(localized: "dup_clean_all_done_format"), removed))
        Task { await rescan() }
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
