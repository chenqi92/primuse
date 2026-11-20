import SwiftUI

/// Inline settings row for downloading or removing the Apple-hosted
/// `LyricsAlignmentModel` Background Assets pack (26.4+).
struct WordAlignmentModelSettingsRow: View {
    let isSimulationEnabled: Bool
    private var service: WordLyricsAlignmentService { .shared }
    @State private var showsRemovalConfirmation = false

    private var shouldShow: Bool {
        guard LyricsAlignmentModel.isSystemSupported else { return false }
        return isSimulationEnabled || service.modelState != .notDownloaded
    }

    var body: some View {
        if shouldShow {
            LabeledContent("word_alignment_model_title") {
                control
            }
            .accessibilityIdentifier("wordAlignmentModelRow")
            .task { await service.refreshAvailability() }
            .confirmationDialog(
                "word_alignment_model_remove_confirm",
                isPresented: $showsRemovalConfirmation,
                titleVisibility: .visible
            ) {
                Button("lyrics_translation_local_remove", role: .destructive) {
                    Task { await service.removeModel() }
                }
                Button("cancel", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch service.modelState {
        case .notDownloaded:
            Button {
                service.downloadModel()
            } label: {
                Text(String(
                    format: String(localized: "lyrics_translation_local_download_size_format"),
                    LyricsAlignmentModel.formattedDownloadSize
                ))
            }
            .buttonStyle(.borderless)
        case .downloading(let fraction):
            ProgressView(value: fraction)
                .frame(maxWidth: 110)
        case .failed:
            Button("lyrics_translation_local_retry") {
                service.downloadModel()
            }
            .buttonStyle(.borderless)
        case .ready:
            HStack(spacing: 10) {
                Text("lyrics_translation_local_ready")
                    .foregroundStyle(.secondary)
                Button("lyrics_translation_local_remove", role: .destructive) {
                    showsRemovalConfirmation = true
                }
                .buttonStyle(.borderless)
            }
        case .unsupportedSystem:
            EmptyView()
        }
    }
}
