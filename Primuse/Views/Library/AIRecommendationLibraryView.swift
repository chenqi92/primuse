import SwiftUI
import PrimuseKit

private struct AIRecommendationIntentChoice: Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String
    var semanticIntent: String?

    static func all(customRawValue: String) -> [AIRecommendationIntentChoice] {
        let presets = AIRecommendationIntentPreset.allCases.map { preset in
            AIRecommendationIntentChoice(
                id: "preset:\(preset.rawValue)",
                title: preset.localizedTitle,
                detail: preset.localizedDetail,
                semanticIntent: preset.semanticIntent
            )
        }
        let custom = AIRecommendationIntentStoragePolicy.decode(customRawValue).map { intent in
            AIRecommendationIntentChoice(
                id: "custom:\(intent.id.uuidString)",
                title: intent.title,
                detail: intent.prompt,
                semanticIntent: intent.prompt
            )
        }
        return presets + custom
    }
}

extension AIRecommendationIntentPreset {
    var localizedTitle: String {
        String(localized: String.LocalizationValue("ai_recommendation_intent_\(rawValue)"))
    }

    var localizedDetail: String {
        String(localized: String.LocalizationValue("ai_recommendation_intent_\(rawValue)_detail"))
    }
}

/// A library-sized recommendation destination. The local discovery engine is
/// always the source of playable candidates; a configured remote provider may
/// only reorder those candidates and explain the result.
struct AIRecommendationLibraryView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicIntelligenceService.self) private var intelligence
    @AppStorage(AIRecommendationIntentStoragePolicy.storageKey)
    private var customIntentsRawValue = ""
    @AppStorage("primuse.ai.recommendationIntent.selected.v1")
    private var selectedIntentID = "preset:rightNow"

    @State private var localResults: [MusicDiscoveryResult] = []
    @State private var aiRecommendation = AIRecommendationViewModel()
    @State private var refreshGeneration: UInt64 = 0
    @State private var historyRevision = 0

    private var intentChoices: [AIRecommendationIntentChoice] {
        AIRecommendationIntentChoice.all(customRawValue: customIntentsRawValue)
    }

    private var selectedIntent: AIRecommendationIntentChoice {
        intentChoices.first { $0.id == selectedIntentID }
            ?? intentChoices[0]
    }

    private var displayedResults: [MusicDiscoveryResult] {
        let byID = Dictionary(
            localResults.map { ($0.song.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let ordered = aiRecommendation.orderedSongs(from: localResults.map(\.song))
        return ordered.compactMap { byID[$0.id] }
    }

    private var refreshKey: String {
        [
            selectedIntent.id,
            customIntentsRawValue,
            String(library.visibleSongCollectionRevision),
            library.songReplacementToken.uuidString,
            String(intelligence.settingsStore.revision),
            String(intelligence.regionAvailability.revision),
            String(historyRevision),
        ].joined(separator: "#")
    }

    var body: some View {
        Group {
            if library.visibleSongs.filteredPlayable().isEmpty {
                ContentUnavailableView {
                    Label("library_recommendations_empty_title", systemImage: "sparkles")
                } description: {
                    Text("library_recommendations_empty_description")
                }
            } else {
                recommendationContent
            }
        }
        #if os(macOS)
        .background(PMColor.bg.ignoresSafeArea())
        #endif
        .task(id: refreshKey) {
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primusePlaybackHistoryDidChange)) { _ in
            historyRevision &+= 1
        }
        .onChange(of: customIntentsRawValue) { _, _ in
            if !intentChoices.contains(where: { $0.id == selectedIntentID }) {
                selectedIntentID = "preset:rightNow"
                CloudKVSSync.shared.markChanged(
                    key: CloudKVSKey.aiRecommendationSelectedIntent
                )
            }
        }
    }

    private var recommendationContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: platformSectionSpacing) {
                hero
                intentRibbon
                statusPanel
                recommendationGrid
            }
            .padding(.horizontal, platformHorizontalPadding)
            .padding(.top, platformTopPadding)
            .padding(.bottom, 96)
        }
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Label("library_recommendations_eyebrow", systemImage: "sparkles")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(platformAccentColor)

                Text("library_recommendations_title")
                    .font(platformTitleFont)
                    .foregroundStyle(platformPrimaryTextColor)

                Text("library_recommendations_description")
                    .font(.subheadline)
                    .foregroundStyle(platformSecondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 42, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(platformAccentColor)
                .accessibilityHidden(true)
        }
    }

    private var intentRibbon: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("library_recommendations_intent_title")
                    .font(.headline)
                    .foregroundStyle(platformPrimaryTextColor)
                Spacer()
                Text("library_recommendations_intent_settings_hint")
                    .font(.caption)
                    .foregroundStyle(platformSecondaryTextColor)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(intentChoices) { choice in
                        Button {
                            selectedIntentID = choice.id
                            CloudKVSSync.shared.markChanged(
                                key: CloudKVSKey.aiRecommendationSelectedIntent
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: choice.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(verbatim: choice.detail)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .opacity(0.76)
                            }
                            .foregroundStyle(
                                selectedIntentID == choice.id
                                    ? Color.white
                                    : platformPrimaryTextColor
                            )
                            .padding(.horizontal, 15)
                            .frame(height: 54, alignment: .leading)
                            .background(
                                selectedIntentID == choice.id
                                    ? platformAccentColor
                                    : platformChipBackground,
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                            )
                            .overlay {
                                if selectedIntentID != choice.id {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .stroke(platformDividerColor, lineWidth: 0.5)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            selectedIntentID == choice.id ? .isSelected : []
                        )
                    }
                }
            }
        }
    }

    private var statusPanel: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: statusIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 24, height: 24)
                .background(statusColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(aiRecommendation.statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(platformPrimaryTextColor)
                if let summary = aiRecommendation.summaryText {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(platformSecondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                } else if showsLocalFallbackDetail {
                    Text("library_recommendations_local_fallback_detail")
                        .font(.caption)
                        .foregroundStyle(platformSecondaryTextColor)
                }
            }
            Spacer(minLength: 8)
            if case .loading = aiRecommendation.feedback {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(13)
        .background(platformCardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(platformDividerColor, lineWidth: 0.5)
        }
    }

    private var recommendationGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: platformCardMinimumWidth, maximum: 480), spacing: 14),
            ],
            alignment: .leading,
            spacing: 14
        ) {
            ForEach(displayedResults) { result in
                Button {
                    play(result.song)
                } label: {
                    recommendationCard(result)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func recommendationCard(_ result: MusicDiscoveryResult) -> some View {
        let song = result.song
        return HStack(spacing: 13) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: platformArtworkSize,
                cornerRadius: 12,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 5) {
                if let reason = aiRecommendation.reason(for: song.id) {
                    Label(reason, systemImage: "sparkles")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(platformAccentColor)
                        .lineLimit(2)
                } else {
                    Text(String(localized: String.LocalizationValue(result.primaryReason.localizationKey)))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(platformSecondaryTextColor)
                        .lineLimit(1)
                }
                Text(verbatim: song.title)
                    .font(.headline)
                    .foregroundStyle(platformPrimaryTextColor)
                    .lineLimit(2)
                Text(verbatim: song.artistName ?? String(localized: "unknown_artist"))
                    .font(.subheadline)
                    .foregroundStyle(platformSecondaryTextColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Label("play", systemImage: "play.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(platformPrimaryTextColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: platformArtworkSize + 24, alignment: .leading)
        .background(platformCardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) {
            if aiRecommendation.reason(for: song.id) != nil {
                RoundedRectangle(cornerRadius: 2)
                    .fill(platformAccentColor)
                    .frame(width: 3)
                    .padding(.vertical, 12)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(platformDividerColor, lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @MainActor
    private func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let input = MusicDiscoveryEngine.recommendationInput(in: library)
        let results = await Task.detached(priority: .userInitiated) {
            MusicDiscoveryEngine.dailyRecommendations(from: input, limit: 24)
        }.value
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        localResults = results
        await aiRecommendation.refresh(
            scene: .automatic,
            intent: selectedIntent.semanticIntent,
            candidates: results.map(\.song),
            using: intelligence
        )
    }

    private func play(_ song: Song) {
        let queue = displayedResults.map(\.song).filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: index)
        SiriMediaInteractionDonor.donate(song: queue[index])
        Task { await player.play(song: queue[index]) }
    }

    private var statusIcon: String {
        switch aiRecommendation.feedback {
        case .idle: return "iphone.and.arrow.forward"
        case .loading: return "sparkles"
        case .needsConsent: return "hand.raised.fill"
        case .success: return "checkmark.circle.fill"
        case .localFallback: return "arrow.uturn.backward.circle.fill"
        }
    }

    private var statusColor: Color {
        switch aiRecommendation.feedback {
        case .success: return .green
        case .needsConsent: return .orange
        case .localFallback: return .orange
        case .idle, .loading: return platformAccentColor
        }
    }

    private var showsLocalFallbackDetail: Bool {
        if case .success = aiRecommendation.feedback {
            return false
        }
        return true
    }

    #if os(macOS)
    private var platformHorizontalPadding: CGFloat { PMSpace.xxxl }
    private var platformTopPadding: CGFloat { PMSpace.l24 }
    private var platformSectionSpacing: CGFloat { PMSpace.xl }
    private var platformCardMinimumWidth: CGFloat { 330 }
    private var platformArtworkSize: CGFloat { 88 }
    private var platformTitleFont: Font { PMFont.pageTitle(32) }
    private var platformAccentColor: Color { PMColor.brand }
    private var platformPrimaryTextColor: Color { PMColor.text }
    private var platformSecondaryTextColor: Color { PMColor.textMuted }
    private var platformCardBackground: Color { PMColor.bgElev }
    private var platformChipBackground: Color { PMColor.glassBtn }
    private var platformDividerColor: Color { PMColor.dividerStrong }
    #else
    private var platformHorizontalPadding: CGFloat { 20 }
    private var platformTopPadding: CGFloat { 16 }
    private var platformSectionSpacing: CGFloat { 24 }
    private var platformCardMinimumWidth: CGFloat { 300 }
    private var platformArtworkSize: CGFloat { 96 }
    private var platformTitleFont: Font { .largeTitle.bold() }
    private var platformAccentColor: Color { .accentColor }
    private var platformPrimaryTextColor: Color { .primary }
    private var platformSecondaryTextColor: Color { .secondary }
    private var platformCardBackground: Color { Color.secondary.opacity(0.075) }
    private var platformChipBackground: Color { Color.secondary.opacity(0.09) }
    private var platformDividerColor: Color { Color.secondary.opacity(0.18) }
    #endif
}
