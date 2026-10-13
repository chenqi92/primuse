import SwiftUI

/// Mac 歌词页上的离线翻译包按钮:写明大小,点了先确认再下;失败时把原因放在悬停提示里。
/// 只在当前歌词需要时出现。
struct LocalTranslationModelBadge: View {
    var onTap: () -> Void = {}
    private var service: LocalLyricsTranslationService { .shared }
    @State private var pendingDownload: LocalLyricsTranslationModel.Pack?

    var body: some View {
        switch service.modelState {
        case .notDownloaded, .failed:
            let failed = service.modelState == .failed
            Button {
                onTap()
                pendingDownload = service.requestedPack
            } label: {
                Label(
                    failed
                        ? String(localized: "lyrics_translation_local_retry")
                        : String(localized: "lyrics_translation_local_download")
                            + " · " + service.requestedPack.formattedDownloadSize,
                    systemImage: failed ? "arrow.clockwise" : "arrow.down.circle"
                )
            }
            .buttonStyle(.plain)
            .help(failed ? (service.modelFailureReason ?? "") : "")
            .modifier(LocalTranslationModelDownloadConfirmation(pack: $pendingDownload))
        case .downloading(let fraction):
            Label(
                String(
                    format: String(localized: "lyrics_translation_local_downloading_format"),
                    fraction.formatted(.percent.precision(.fractionLength(0)))
                ),
                systemImage: "arrow.down.circle.dotted"
            )
            .monospacedDigit()
        case .ready, .unsupportedSystem:
            EmptyView()
        }
    }
}

extension LocalLyricsTranslationModel.Pack {
    var formattedDownloadSize: String {
        ByteCountFormatter.string(fromByteCount: approximateDownloadBytes, countStyle: .file)
    }
}

/// 歌词页上点「下载翻译模型」时先确认:哪个包、多大,用蜂窝网络或低数据模式时提醒流量,
/// 上次没下成时附上原因。设置页的下载按钮旁边本来就写着大小,不再多问一次。
struct LocalTranslationModelDownloadConfirmation: ViewModifier {
    @Binding var pack: LocalLyricsTranslationModel.Pack?
    private var service: LocalLyricsTranslationService { .shared }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            String(
                format: String(localized: "lyrics_translation_local_download_confirm_title_format"),
                pack.map { String(localized: String.LocalizationValue($0.pairsKey)) } ?? ""
            ),
            isPresented: Binding(
                get: { pack != nil },
                set: { if !$0 { pack = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pack {
                Button(String(
                    format: String(localized: "lyrics_translation_local_download_size_format"),
                    pack.formattedDownloadSize
                )) {
                    service.downloadModel(pack)
                    self.pack = nil
                }
            }
            Button("cancel", role: .cancel) { pack = nil }
        } message: {
            Text(verbatim: message)
        }
    }

    private var message: String {
        guard let pack else { return "" }
        var lines = [String(localized: "lyrics_translation_local_download_confirm_message")]
        let network = NetworkMonitor.shared
        if network.isExpensive || network.isConstrained {
            lines.append(String(
                format: String(localized: "lyrics_translation_local_download_cellular_format"),
                pack.formattedDownloadSize
            ))
        }
        // 失败原因本身就是「下载失败：…」那一句,原样附上。
        if service.modelState(for: pack) == .failed, let reason = service.modelFailureReason(for: pack) {
            lines.append(reason)
        }
        return lines.joined(separator: "\n\n")
    }
}

/// Settings rows for the offline translation model: download with its size,
/// progress, retry with the failure reason, and removal.
struct LocalTranslationModelSection: View {
    private var service: LocalLyricsTranslationService { .shared }
    @State private var pendingRemovalPack: LocalLyricsTranslationModel.Pack?

    var body: some View {
        ForEach(LocalLyricsTranslationModel.Pack.allCases) { pack in
            if pack.isListedBesideSystemTranslation(service.modelState(for: pack)) {
                Section {
                    LabeledContent(LocalizedStringKey(pack.pairsKey)) {
                        status(for: pack)
                    }
                    actions(for: pack)
                } header: {
                    Text(LocalizedStringKey(pack.besideSystemHeaderKey))
                } footer: {
                    Text(LocalizedStringKey(pack.besideSystemFooterKey))
                }
            }
        }
        .task { service.refreshAvailability() }
    }

    @ViewBuilder
    private func status(for pack: LocalLyricsTranslationModel.Pack) -> some View {
        switch service.modelState(for: pack) {
        case .ready:
            Text("lyrics_translation_local_ready")
                .foregroundStyle(.secondary)
        case .downloading(let fraction):
            ProgressView(value: fraction)
                .frame(maxWidth: 120)
        case .notDownloaded, .failed, .unsupportedSystem:
            Text(pack.formattedDownloadSize)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actions(for pack: LocalLyricsTranslationModel.Pack) -> some View {
        switch service.modelState(for: pack) {
        case .notDownloaded:
            Button("lyrics_translation_local_download") { service.downloadModel(pack) }
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Button("lyrics_translation_local_retry") { service.downloadModel(pack) }
                if let reason = service.modelFailureReason(for: pack) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .ready:
            Button("lyrics_translation_local_remove", role: .destructive) {
                pendingRemovalPack = pack
            }
            // 挂在各自的移除按钮上，弹框从按钮长出来。
            .confirmationDialog(
                "lyrics_translation_local_remove_confirm",
                isPresented: Binding(
                    get: { pendingRemovalPack == pack },
                    set: { if !$0 { pendingRemovalPack = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("lyrics_translation_local_remove", role: .destructive) {
                    Task { await service.removeModel(pack) }
                }
            }
        case .downloading, .unsupportedSystem:
            EmptyView()
        }
    }
}
