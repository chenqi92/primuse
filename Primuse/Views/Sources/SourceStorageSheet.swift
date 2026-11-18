import SwiftUI
import PrimuseKit

/// 「音乐源 › 本机占用」:一个源在这台设备上占了多少,分几类各自清理。
/// 只清本机的数据,不动音乐源上的文件。离线下载是用户自己要留的,只给「管理」。
struct SourceStorageSheet: View {
    let source: MusicSource

    @Environment(\.dismiss) private var dismiss
    @Environment(SourceManager.self) private var sourceManager
    @Environment(MusicLibrary.self) private var library

    @State private var usage: SourceManager.SourceStorageUsage?
    @State private var clearing: Category?
    @State private var showsOfflineDownloads = false
    @State private var toasts = PMToastPresenter()

    private enum Category: String, Identifiable, CaseIterable {
        case imported
        case offline
        case playback
        case sourceFiles
        case musicVideo

        var id: String { rawValue }

        var color: Color {
            switch self {
            case .imported: .green
            case .offline: .accentColor
            case .playback: .blue
            case .sourceFiles: .orange
            case .musicVideo: .purple
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SourceStorageSummary(source: source, segments: segments, totalBytes: usage?.totalBytes)
                }
                .listRowSeparator(.hidden)

                if let usage {
                    if usage.totalBytes == 0 {
                        Section {
                            Text("source_storage_empty")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        rows(usage)
                    }
                } else {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 12)
                    }
                }

                Section {
                } footer: {
                    Text("source_storage_footer")
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("source_storage_title")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showsOfflineDownloads) {
                OfflineDownloadsView(sourceID: source.id)
            }
            .onChange(of: showsOfflineDownloads) { _, isShowing in
                if !isShowing { Task { await reload() } }
            }
        }
        .task { await reload() }
        .pmToastHost(toasts)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    @ViewBuilder
    private func rows(_ usage: SourceManager.SourceStorageUsage) -> some View {
        Section {
            if usage.importedFileBytes > 0 {
                SourceStorageRow(
                    color: Category.imported.color,
                    title: String(localized: "source_storage_imported"),
                    detail: String(localized: "source_storage_imported_detail"),
                    bytes: usage.importedFileBytes,
                    actionTitle: nil,
                    isWorking: false
                ) {}
            }
            if usage.offlineDownloadBytes > 0 {
                SourceStorageRow(
                    color: Category.offline.color,
                    title: String(localized: "offline_downloads"),
                    detail: String(format: String(localized: "source_storage_offline_detail_format"), usage.offlineDownloadSongCount),
                    bytes: usage.offlineDownloadBytes,
                    actionTitle: String(localized: "source_storage_manage"),
                    isWorking: false
                ) { showsOfflineDownloads = true }
            }
            if usage.playbackCacheBytes > 0 || usage.inUseBytes > 0 {
                SourceStorageRow(
                    color: Category.playback.color,
                    title: String(localized: "source_storage_playback"),
                    detail: playbackDetail(usage),
                    bytes: usage.playbackCacheBytes + usage.inUseBytes,
                    actionTitle: usage.playbackCacheBytes > 0 ? String(localized: "source_storage_clear") : nil,
                    isWorking: clearing == .playback
                ) { clear(.playback) }
            }
            if usage.sourceFileBytes > 0 {
                SourceStorageRow(
                    color: Category.sourceFiles.color,
                    title: String(localized: "source_storage_source_files"),
                    detail: String(localized: "source_storage_source_files_detail"),
                    bytes: usage.sourceFileBytes,
                    actionTitle: String(localized: "source_storage_clear"),
                    isWorking: clearing == .sourceFiles
                ) { clear(.sourceFiles) }
            }
            if usage.musicVideoBytes > 0 {
                SourceStorageRow(
                    color: Category.musicVideo.color,
                    title: String(localized: "source_storage_music_video"),
                    detail: nil,
                    bytes: usage.musicVideoBytes,
                    actionTitle: String(localized: "source_storage_clear"),
                    isWorking: clearing == .musicVideo
                ) { clear(.musicVideo) }
            }
        }
    }

    private var segments: [SourceStorageSummary.Segment] {
        guard let usage else { return [] }
        return [
            .init(id: Category.imported.id, color: Category.imported.color, bytes: usage.importedFileBytes),
            .init(id: Category.offline.id, color: Category.offline.color, bytes: usage.offlineDownloadBytes),
            .init(id: Category.playback.id, color: Category.playback.color,
                  bytes: usage.playbackCacheBytes + usage.inUseBytes),
            .init(id: Category.sourceFiles.id, color: Category.sourceFiles.color, bytes: usage.sourceFileBytes),
            .init(id: Category.musicVideo.id, color: Category.musicVideo.color, bytes: usage.musicVideoBytes),
        ].filter { $0.bytes > 0 }
    }

    private func playbackDetail(_ usage: SourceManager.SourceStorageUsage) -> String {
        var lines = [String(localized: "source_storage_playback_detail")]
        if usage.partialBytes > 0 {
            lines.append(String(
                format: String(localized: "source_storage_partial_format"),
                SourceByteText.string(usage.partialBytes)
            ))
        }
        if usage.inUseBytes > 0 {
            lines.append(String(
                format: String(localized: "source_storage_in_use_format"),
                SourceByteText.string(usage.inUseBytes)
            ))
        }
        return lines.joined(separator: "\n")
    }

    private func reload() async {
        usage = await sourceManager.sourceStorageUsage(
            sourceID: source.id,
            songs: library.visibleSongs(forSourceID: source.id)
        )
    }

    private func clear(_ category: Category) {
        guard clearing == nil else { return }
        clearing = category
        Task { @MainActor in
            let result: (freedBytes: Int64, failedCount: Int)
            switch category {
            case .playback: result = await sourceManager.clearPlaybackCache(sourceID: source.id)
            case .sourceFiles: result = await sourceManager.clearSourceFileCache(sourceID: source.id)
            case .musicVideo: result = await sourceManager.clearMusicVideoCache(sourceID: source.id)
            case .offline, .imported: result = (0, 0)
            }
            clearing = nil
            await reload()
            let freed = SourceByteText.string(result.freedBytes)
            if result.failedCount > 0 {
                toasts.show(PMToastItem(
                    key: "source-storage-clear",
                    message: String(format: String(localized: "source_storage_cleared_partial_format"), freed, result.failedCount),
                    systemImage: "exclamationmark.circle",
                    tint: .orange
                ))
            } else {
                toasts.show(PMToastItem(
                    key: "source-storage-clear",
                    message: String(format: String(localized: "source_storage_cleared_format"), freed),
                    systemImage: "checkmark.circle.fill",
                    tint: .green
                ))
            }
        }
    }
}

/// 顶上的总数和一条按类分色的条。
private struct SourceStorageSummary: View {
    struct Segment: Identifiable {
        let id: String
        let color: Color
        let bytes: Int64
    }

    let source: MusicSource
    let segments: [Segment]
    let totalBytes: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(totalBytes.map(SourceByteText.string) ?? "…")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                Text(String(format: String(localized: "source_storage_subtitle_format"), source.name))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let total = max(1, segments.reduce(0) { $0 + $1.bytes })
                let spacing: CGFloat = 2
                let available = max(0, proxy.size.width - spacing * CGFloat(max(0, segments.count - 1)))
                HStack(spacing: spacing) {
                    if segments.isEmpty {
                        Capsule().fill(Color.secondary.opacity(0.15))
                    } else {
                        ForEach(segments) { segment in
                            Rectangle()
                                .fill(segment.color)
                                .frame(width: max(3, available * CGFloat(segment.bytes) / CGFloat(total)))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
    }
}

private struct SourceStorageRow: View {
    let color: Color
    let title: String
    let detail: String?
    let bytes: Int64
    let actionTitle: String?
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                    Spacer(minLength: 8)
                    Text(SourceByteText.string(bytes))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let actionTitle {
                Button(action: action) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(actionTitle)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isWorking)
            }
        }
        .padding(.vertical, 2)
    }
}
