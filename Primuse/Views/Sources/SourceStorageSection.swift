import SwiftUI
import PrimuseKit

/// 一个源在这台设备上占了多少。详情页头上那个大小、下面「本机占用」一段共用这一份,
/// 只量一次;清理完、从离线下载页回来时再量。
@MainActor
@Observable
final class SourceStorageUsageModel {
    let sourceID: String
    private(set) var usage: SourceManager.SourceStorageUsage?
    private(set) var clearing: SourceStorageCategory?
    var showsOfflineDownloads = false

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    func reload(sourceManager: SourceManager, library: MusicLibrary) async {
        let measured = await sourceManager.sourceStorageUsage(
            sourceID: sourceID,
            songs: library.visibleSongs(forSourceID: sourceID)
        )
        if measured != usage { usage = measured }
    }

    /// 清掉一类,量一遍新的,交回要给人看的那句话。
    func clear(
        _ category: SourceStorageCategory,
        sourceManager: SourceManager,
        library: MusicLibrary
    ) async -> PMToastItem? {
        guard clearing == nil else { return nil }
        clearing = category
        let result: (freedBytes: Int64, failedCount: Int)
        switch category {
        case .playback: result = await sourceManager.clearPlaybackCache(sourceID: sourceID)
        case .sourceFiles: result = await sourceManager.clearSourceFileCache(sourceID: sourceID)
        case .musicVideo: result = await sourceManager.clearMusicVideoCache(sourceID: sourceID)
        case .offline, .imported: result = (0, 0)
        }
        clearing = nil
        await reload(sourceManager: sourceManager, library: library)
        let freed = SourceByteText.string(result.freedBytes)
        if result.failedCount > 0 {
            return PMToastItem(
                key: "source-storage-clear",
                message: String(format: String(localized: "source_storage_cleared_partial_format"), freed, result.failedCount),
                systemImage: "exclamationmark.circle",
                tint: .orange
            )
        }
        return PMToastItem(
            key: "source-storage-clear",
            message: String(format: String(localized: "source_storage_cleared_format"), freed),
            systemImage: "checkmark.circle.fill",
            tint: .green
        )
    }
}

enum SourceStorageCategory: String, Identifiable, CaseIterable {
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

/// 详情页里单独一段「本机占用」:一条按类分色的条,下面各类各自清理。只清本机的数据,
/// 不动音乐源上的文件。离线下载是用户自己要留的,只给「管理」。原来要点右上角的大小弹出来看,
/// 现在直接摆在页面里。
struct SourceStorageSection: View {
    let model: SourceStorageUsageModel
    let onMessage: (PMToastItem) -> Void

    @Environment(SourceManager.self) private var sourceManager
    @Environment(MusicLibrary.self) private var library

    var body: some View {
        Section {
            if let usage = model.usage {
                if usage.totalBytes == 0 {
                    Text("source_storage_empty")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    SourceStorageBar(segments: segments(usage))
                        .listRowSeparator(.hidden, edges: .bottom)
                    rows(usage)
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 6)
            }
        } header: {
            Text("source_storage_title")
        } footer: {
            Text("source_storage_footer")
        }
    }

    @ViewBuilder
    private func rows(_ usage: SourceManager.SourceStorageUsage) -> some View {
        if usage.importedFileBytes > 0 {
            SourceStorageRow(
                color: SourceStorageCategory.imported.color,
                title: String(localized: "source_storage_imported"),
                detail: String(localized: "source_storage_imported_detail"),
                bytes: usage.importedFileBytes,
                actionTitle: nil,
                isWorking: false
            ) {}
        }
        if usage.offlineDownloadBytes > 0 {
            SourceStorageRow(
                color: SourceStorageCategory.offline.color,
                title: String(localized: "offline_downloads"),
                detail: String(format: String(localized: "source_storage_offline_detail_format"), usage.offlineDownloadSongCount),
                bytes: usage.offlineDownloadBytes,
                actionTitle: String(localized: "source_storage_manage"),
                isWorking: false
            ) { model.showsOfflineDownloads = true }
        }
        if usage.playbackCacheBytes > 0 || usage.inUseBytes > 0 {
            SourceStorageRow(
                color: SourceStorageCategory.playback.color,
                title: String(localized: "source_storage_playback"),
                detail: playbackDetail(usage),
                bytes: usage.playbackCacheBytes + usage.inUseBytes,
                actionTitle: usage.playbackCacheBytes > 0 ? String(localized: "source_storage_clear") : nil,
                isWorking: model.clearing == .playback
            ) { clear(.playback) }
        }
        if usage.sourceFileBytes > 0 {
            SourceStorageRow(
                color: SourceStorageCategory.sourceFiles.color,
                title: String(localized: "source_storage_source_files"),
                detail: String(localized: "source_storage_source_files_detail"),
                bytes: usage.sourceFileBytes,
                actionTitle: String(localized: "source_storage_clear"),
                isWorking: model.clearing == .sourceFiles
            ) { clear(.sourceFiles) }
        }
        if usage.musicVideoBytes > 0 {
            SourceStorageRow(
                color: SourceStorageCategory.musicVideo.color,
                title: String(localized: "source_storage_music_video"),
                detail: nil,
                bytes: usage.musicVideoBytes,
                actionTitle: String(localized: "source_storage_clear"),
                isWorking: model.clearing == .musicVideo
            ) { clear(.musicVideo) }
        }
    }

    private func segments(_ usage: SourceManager.SourceStorageUsage) -> [SourceStorageBar.Segment] {
        [
            .init(id: SourceStorageCategory.imported.id, color: SourceStorageCategory.imported.color, bytes: usage.importedFileBytes),
            .init(id: SourceStorageCategory.offline.id, color: SourceStorageCategory.offline.color, bytes: usage.offlineDownloadBytes),
            .init(id: SourceStorageCategory.playback.id, color: SourceStorageCategory.playback.color,
                  bytes: usage.playbackCacheBytes + usage.inUseBytes),
            .init(id: SourceStorageCategory.sourceFiles.id, color: SourceStorageCategory.sourceFiles.color, bytes: usage.sourceFileBytes),
            .init(id: SourceStorageCategory.musicVideo.id, color: SourceStorageCategory.musicVideo.color, bytes: usage.musicVideoBytes),
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

    private func clear(_ category: SourceStorageCategory) {
        Task { @MainActor in
            if let message = await model.clear(category, sourceManager: sourceManager, library: library) {
                onMessage(message)
            }
        }
    }
}

extension View {
    /// 详情页挂上「本机占用」要用的几件事:进页面量一次、扫完一次再量,离线下载页的入口。
    func sourceStorageUsage(_ model: SourceStorageUsageModel, songCount: Int) -> some View {
        modifier(SourceStorageUsageHost(model: model, songCount: songCount))
    }
}

private struct SourceStorageUsageHost: ViewModifier {
    let model: SourceStorageUsageModel
    let songCount: Int

    @Environment(SourceManager.self) private var sourceManager
    @Environment(MusicLibrary.self) private var library

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .task(id: songCount) {
                await model.reload(sourceManager: sourceManager, library: library)
            }
            .navigationDestination(isPresented: $model.showsOfflineDownloads) {
                OfflineDownloadsView(sourceID: model.sourceID)
            }
            .onChange(of: model.showsOfflineDownloads) { _, isShowing in
                guard !isShowing else { return }
                Task { await model.reload(sourceManager: sourceManager, library: library) }
            }
    }
}

/// 详情页头上右边那个「本机占用」:量出来之前是一道横线。
struct SourceStorageHeaderValue: View {
    let model: SourceStorageUsageModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: model.usage.map { SourceByteText.string($0.totalBytes) } ?? "—")
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
            Text("source_card_metric_storage")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .pmAnimation(.control, value: model.usage?.totalBytes)
        .accessibilityElement(children: .combine)
    }
}

/// 一条按类分色的条。
private struct SourceStorageBar: View {
    struct Segment: Identifiable {
        let id: String
        let color: Color
        let bytes: Int64
    }

    let segments: [Segment]

    var body: some View {
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
        .padding(.vertical, 6)
        .accessibilityHidden(true)
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
