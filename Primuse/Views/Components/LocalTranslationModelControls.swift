import SwiftUI

/// Lyric-page badge that downloads the offline translation model on tap.
/// Only shown when the current lyrics need it.
struct LocalTranslationModelBadge: View {
    var onTap: () -> Void = {}
    private var service: LocalLyricsTranslationService { .shared }

    var body: some View {
        switch service.modelState {
        case .notDownloaded, .failed:
            Button {
                onTap()
                service.downloadModel()
            } label: {
                Label(
                    service.modelState == .failed
                        ? LocalizedStringKey("lyrics_translation_local_retry")
                        : LocalizedStringKey("lyrics_translation_local_download"),
                    systemImage: service.modelState == .failed ? "arrow.clockwise" : "arrow.down.circle"
                )
            }
            .buttonStyle(.plain)
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

/// Settings rows for the offline translation model: download with its size,
/// progress, retry with the failure reason, and removal.
struct LocalTranslationModelSection: View {
    private var service: LocalLyricsTranslationService { .shared }
    @State private var showRemoveConfirm = false
    @State private var removalPack: LocalLyricsTranslationModel.Pack = .persian

    var body: some View {
        ForEach(LocalLyricsTranslationModel.Pack.allCases) { pack in
            if service.modelState(for: pack) != .unsupportedSystem {
                Section {
                    LabeledContent(LocalizedStringKey(pack.pairsKey)) {
                        status(for: pack)
                    }
                    actions(for: pack)
                } header: {
                    Text("lyrics_translation_local_section")
                } footer: {
                    Text(LocalizedStringKey(pack.footerKey))
                }
            }
        }
        .confirmationDialog(
            "lyrics_translation_local_remove_confirm",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("lyrics_translation_local_remove", role: .destructive) {
                Task { await service.removeModel(removalPack) }
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
            Text(ByteCountFormatter.string(fromByteCount: pack.approximateDownloadBytes, countStyle: .file))
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
                removalPack = pack
                showRemoveConfirm = true
            }
        case .downloading, .unsupportedSystem:
            EmptyView()
        }
    }
}
