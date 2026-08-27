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
    @AppStorage("primuse.ai.recommendationScene.v1")
    private var recommendationSceneRawValue = AIRecommendationScene.automatic.rawValue

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

    private var recommendationScene: AIRecommendationScene {
        AIRecommendationScene(rawValue: recommendationSceneRawValue) ?? .automatic
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
            recommendationSceneRawValue,
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
                recommendationControls
                statusPanel
                recommendationGrid
            }
            .padding(.horizontal, platformHorizontalPadding)
            .padding(.top, platformTopPadding)
            .padding(.bottom, 96)
        }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 16) {
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
            Spacer(minLength: 12)
            Button(action: playAll) {
                Label("play_all", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .foregroundStyle(Color.white)
                    .background(platformAccentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(displayedResults.map(\.song).filteredPlayable().isEmpty)
        }
    }

    private var recommendationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("library_recommendations_intent_title")
                    .font(.headline)
                    .foregroundStyle(platformPrimaryTextColor)
                Spacer()
                Menu {
                    Button {
                        selectIntent("preset:rightNow")
                    } label: {
                        if selectedIntentID == "preset:rightNow" {
                            Label("library_recommendations_theme_none", systemImage: "checkmark")
                        } else {
                            Text("library_recommendations_theme_none")
                        }
                    }
                    Divider()
                    ForEach(intentChoices.filter { $0.id != "preset:rightNow" }) { choice in
                        Button {
                            selectIntent(choice.id)
                        } label: {
                            if selectedIntentID == choice.id {
                                Label {
                                    Text(verbatim: choice.title)
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                            } else {
                                Text(verbatim: choice.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                        if selectedIntentID == "preset:rightNow" {
                            Text("library_recommendations_theme")
                                .lineLimit(1)
                        } else {
                            Text(verbatim: selectedIntent.title)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(platformAccentColor)
                }
                .menuStyle(.borderlessButton)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(AIRecommendationScene.allCases, id: \.self) { scene in
                        Button {
                            recommendationSceneRawValue = scene.rawValue
                        } label: {
                            Text(scene.localizedName)
                                .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                recommendationScene == scene
                                    ? Color.white
                                    : platformPrimaryTextColor
                            )
                            .padding(.horizontal, 13)
                            .frame(height: 32)
                            .background(
                                recommendationScene == scene
                                    ? platformAccentColor
                                    : platformChipBackground,
                                in: Capsule()
                            )
                            .overlay {
                                if recommendationScene != scene {
                                    Capsule().stroke(platformDividerColor, lineWidth: 0.5)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            recommendationScene == scene ? .isSelected : []
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
            } else if intelligence.isPersonalizedRecommendationsConfigured {
                Button {
                    Task { await refresh(forceAIRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(platformChipBackground, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(platformAccentColor)
                .accessibilityLabel("ai_recommendation_refresh")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
                Text(
                    verbatim: library.artistDisplayName(for: song)
                        ?? String(localized: "unknown_artist")
                )
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
    private func refresh(forceAIRefresh: Bool = false) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let input = MusicDiscoveryEngine.recommendationInput(in: library)
        let results = await Task.detached(priority: .userInitiated) {
            MusicDiscoveryEngine.dailyRecommendations(from: input, limit: 24)
        }.value
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        localResults = results
        await aiRecommendation.refresh(
            scene: recommendationScene,
            intent: selectedIntent.semanticIntent,
            candidates: results.map(\.song),
            using: intelligence,
            forceRefresh: forceAIRefresh
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

    private func playAll() {
        let queue = displayedResults.map(\.song).filteredPlayable()
        guard let first = queue.first else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: 0)
        SiriMediaInteractionDonor.donate(song: first)
        Task { await player.play(song: first) }
    }

    private func selectIntent(_ id: String) {
        selectedIntentID = id
        CloudKVSSync.shared.markChanged(
            key: CloudKVSKey.aiRecommendationSelectedIntent
        )
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
    private var platformSectionSpacing: CGFloat { PMSpace.l }
    private var platformCardMinimumWidth: CGFloat { 330 }
    private var platformArtworkSize: CGFloat { 88 }
    private var platformTitleFont: Font { PMFont.pageTitle(28) }
    private var platformAccentColor: Color { PMColor.brand }
    private var platformPrimaryTextColor: Color { PMColor.text }
    private var platformSecondaryTextColor: Color { PMColor.textMuted }
    private var platformCardBackground: Color { PMColor.bgElev }
    private var platformChipBackground: Color { PMColor.glassBtn }
    private var platformDividerColor: Color { PMColor.dividerStrong }
    #else
    private var platformHorizontalPadding: CGFloat { 20 }
    private var platformTopPadding: CGFloat { 16 }
    private var platformSectionSpacing: CGFloat { 16 }
    private var platformCardMinimumWidth: CGFloat { 300 }
    private var platformArtworkSize: CGFloat { 96 }
    private var platformTitleFont: Font { .title.bold() }
    private var platformAccentColor: Color { .accentColor }
    private var platformPrimaryTextColor: Color { .primary }
    private var platformSecondaryTextColor: Color { .secondary }
    private var platformCardBackground: Color { Color.secondary.opacity(0.075) }
    private var platformChipBackground: Color { Color.secondary.opacity(0.09) }
    private var platformDividerColor: Color { Color.secondary.opacity(0.18) }
    #endif
}
