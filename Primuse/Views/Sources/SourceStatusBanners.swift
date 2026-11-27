import SwiftUI
import PrimuseKit

// MARK: - 状态横幅

/// 详情页顶上那几条:连不上、扫描出错、要确认的移除、扫描进度、读取标签。
/// 只订阅这个源自己的扫描状态,不让整页跟着进度重画。
struct SourceStatusBanners: View {
    let source: MusicSource
    let onDiagnose: () -> Void
    let onScan: () -> Void
    let onOpenMetadata: () -> Void

    @Environment(SourceManager.self) private var sourceManager

    /// 每条各占列表里的一行;没有要说的就一行都不占。
    var body: some View {
        if sourceManager.isSourceManuallyOffline(source) {
            SourceOfflineModeNotice(source: source)
        } else if sourceManager.unreachablePlaybackSourceIDs.contains(source.id) {
            SourceUnreachableNotice(source: source)
        }
        if source.type == .googleDrive,
           GoogleDrivePickerPolicy.showsLegacyAccessReminder(
               storedMode: source.googleDriveAccessMode,
               configuredRoots: source.scannedDirectories
           ) {
            GoogleDriveAccessChangeNotice()
        }
        SourceScanStateReader(sourceID: source.id) { scanning in
            SourceScanBanner(
                scanning: scanning,
                sourceID: source.id,
                onDiagnose: onDiagnose,
                onScan: onScan,
                onOpenMetadata: onOpenMetadata
            )
        }
    }
}

/// Google Drive 已选文件:有歌不在所选文件里时的「从资料库移除」与「保留」。移除要再完整扫一遍,
/// 只移除仍然不在列表里的那些;保留后不再提示。
struct PickedFilesRemovalActions: View {
    let sourceID: String

    @Environment(ScanService.self) private var scanService
    @Environment(SourceManager.self) private var sourceManager
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MusicScraperService.self) private var scraperService

    var body: some View {
        HStack(spacing: 16) {
            Button("batch_remove_from_library", role: .destructive) {
                Task {
                    await scanService.confirmPickedFilesRemoval(
                        sourceID: sourceID,
                        sourceManager: sourceManager,
                        library: library,
                        sourceStore: sourcesStore,
                        scraperService: scraperService
                    )
                }
            }
            Button("gdrive_removal_keep") {
                Task { await scanService.keepPickedFilesRemoval(sourceID: sourceID) }
            }
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.borderless)
    }
}

private struct SourceScanBanner: View {
    let scanning: ScanService.ScanState?
    let sourceID: String
    let onDiagnose: () -> Void
    let onScan: () -> Void
    let onOpenMetadata: () -> Void

    var body: some View {
        if let failure = scanning?.failureMessage, !failure.isEmpty {
            SourceBannerBox(tint: .red) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("notify_scan_failed_title", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    Spacer(minLength: 8)
                    Button("source_diagnostics", action: onDiagnose)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                }
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let message = scanning?.reconciliationMessage, !message.isEmpty {
            SourceBannerBox(tint: .orange) {
                Label(message, systemImage: "checkmark.shield.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if scanning?.pickedFilesRemovalCount != nil {
                    PickedFilesRemovalActions(sourceID: sourceID)
                } else {
                    Button("source_incremental_scan", action: onScan)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }
        } else if let scan = scanning, scan.isScanning {
            SourceBannerBox(tint: .accentColor) {
                if scan.totalCount > 0 {
                    ProgressView(value: min(scan.progress, 1.0))
                }
                HStack(spacing: 8) {
                    if scan.totalCount == 0 {
                        ProgressView().controlSize(.small)
                    }
                    Text(scan.currentFile)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Group {
                        if scan.totalCount > 0 {
                            Text(verbatim: "\(scan.scannedCount)/\(scan.totalCount)")
                        } else {
                            Text(String(format: String(localized: "new_songs_added"), scan.addedCount))
                        }
                    }
                    .monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } else {
            SourceMetadataStatusCard(sourceID: sourceID, openDetails: onOpenMetadata) {
                EmptyView()
            }
        }
    }
}

struct SourceBannerBox<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
