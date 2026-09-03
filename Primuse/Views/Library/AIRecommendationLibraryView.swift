import SwiftUI
import PrimuseKit

private struct AIRecommendationIntentChoice: Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String
    var semanticIntent: String?

    static func all(
        customRawValue: String,
        hiddenPresetsRawValue: String
    ) -> [AIRecommendationIntentChoice] {
        let visiblePresets = [AIRecommendationIntentPreset.balanced]
            + AIRecommendationIntentPresetVisibilityPolicy.visiblePresets(
                hiddenPresetsRawValue
            )
        let presets = visiblePresets.map { preset in
            AIRecommendationIntentChoice(
                id: preset.selectionID,
                title: preset.localizedTitle,
                detail: preset.localizedDetail,
                semanticIntent: preset.semanticIntent
            )
        }
        let custom = AIRecommendationIntentStoragePolicy.decode(customRawValue).map { intent in
            AIRecommendationIntentChoice(
                id: intent.selectionID,
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
    private static let recommendationPoolSize = 36
    private static let recommendationPageSize = 12
    private static let minimumRecommendationPageSize = 10

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AIRecommendationIntentStoragePolicy.storageKey)
    private var customIntentsRawValue = ""
    @AppStorage(AIRecommendationIntentPresetVisibilityPolicy.storageKey)
    private var hiddenPresetsRawValue = ""
    @AppStorage(AIRecommendationIntentSelectionPolicy.storageKey)
    private var selectedIntentID = AIRecommendationIntentSelectionPolicy.defaultSelectionID
    @AppStorage("primuse.ai.recommendationScene.v1")
    private var recommendationSceneRawValue = AIRecommendationScene.automatic.rawValue

    @State private var localResults: [MusicDiscoveryResult] = []
    @State private var aiRecommendation = AIRecommendationViewModel()
    @State private var refreshGeneration: UInt64 = 0
    @State private var historyRevision = 0
    @State private var isLoadingMore = false
    @State private var loadMoreFailed = false
    @State private var preparedLocalContentRevision: String?
    @State private var streamedQueueSongIDs: [String]?

    private var intentChoices: [AIRecommendationIntentChoice] {
        AIRecommendationIntentChoice.all(
            customRawValue: customIntentsRawValue,
            hiddenPresetsRawValue: hiddenPresetsRawValue
        )
    }

    private var effectiveSelectedIntentID: String {
        AIRecommendationIntentSelectionPolicy.normalizedSelectionID(
            selectedIntentID,
            availableSelectionIDs: Set(intentChoices.map(\.id))
        )
    }

    private var selectedIntent: AIRecommendationIntentChoice {
        intentChoices.first { $0.id == effectiveSelectedIntentID }
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

    private var canLoadMore: Bool {
        !aiRecommendation.orderedSongIDs.isEmpty
            && aiRecommendation.orderedSongIDs.count < localResults.count
    }

    private var contentRevision: String {
        [
            recommendationSceneRawValue,
            selectedIntent.id,
            customIntentsRawValue,
            hiddenPresetsRawValue,
            String(library.visibleSongCollectionRevision),
            library.songReplacementToken.uuidString,
            String(intelligence.settingsStore.revision),
            String(intelligence.regionAvailability.revision),
            String(historyRevision),
        ].joined(separator: "#")
    }

    private var localContentRevision: String {
        [
            String(library.visibleSongCollectionRevision),
            library.songReplacementToken.uuidString,
            String(historyRevision),
        ].joined(separator: "#")
    }

    private var recommendationPresentationState: DeferredContentPresentationState {
        if aiRecommendation.isStreaming, displayedResults.isEmpty {
            return .loading
        }
        return DeferredContentPresentationPolicy.resolve(
            isPrepared: preparedLocalContentRevision == localContentRevision
                || !localResults.isEmpty,
            hasContent: !displayedResults.isEmpty
        )
    }

    private var refreshState: AIRecommendationRefreshState {
        AIRecommendationRefreshState(
            contentRevision: contentRevision,
            isSceneActive: scenePhase == .active
        )
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
        .onAppear(perform: normalizeIntentSelectionIfNeeded)
        .onChange(of: selectedIntentID) { _, _ in
            normalizeIntentSelectionIfNeeded()
        }
        .task(id: refreshState) {
            guard refreshState.shouldRefresh else { return }
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primusePlaybackHistoryDidChange)) { _ in
            historyRevision &+= 1
        }
        .onChange(of: customIntentsRawValue) { _, _ in
            normalizeIntentSelectionIfNeeded()
        }
        .onChange(of: hiddenPresetsRawValue) { _, _ in
            normalizeIntentSelectionIfNeeded()
        }
        .onChange(of: aiRecommendation.orderedSongIDs) { _, _ in
            appendNewStreamingRecommendationsToOwnedQueue()
        }
        .onDisappear {
            streamedQueueSongIDs = nil
        }
    }

    private var recommendationContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: platformSectionSpacing) {
                hero
                recommendationControls
                if showsActionableStatus {
                    statusPanel
                }
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
                        selectIntent(AIRecommendationIntentSelectionPolicy.defaultSelectionID)
                    } label: {
                        if effectiveSelectedIntentID
                            == AIRecommendationIntentSelectionPolicy.defaultSelectionID {
                            Label("library_recommendations_theme_none", systemImage: "checkmark")
                        } else {
                            Text("library_recommendations_theme_none")
                        }
                    }
                    let selectableChoices = intentChoices.filter {
                        $0.id != AIRecommendationIntentSelectionPolicy.defaultSelectionID
                    }
                    if !selectableChoices.isEmpty {
                        Divider()
                        ForEach(selectableChoices) { choice in
                            Button {
                                selectIntent(choice.id)
                            } label: {
                                if effectiveSelectedIntentID == choice.id {
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
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                        if effectiveSelectedIntentID
                            == AIRecommendationIntentSelectionPolicy.defaultSelectionID {
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

            if effectiveSelectedIntentID
                != AIRecommendationIntentSelectionPolicy.defaultSelectionID,
               let prompt = selectedIntent.semanticIntent {
                VStack(alignment: .leading, spacing: 5) {
                    if selectedIntent.detail != prompt {
                        Text(verbatim: selectedIntent.detail)
                            .font(.caption)
                            .foregroundStyle(platformSecondaryTextColor)
                    }
                    Text("ai_recommendation_intent_prompt_label")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(platformSecondaryTextColor)
                    Text(verbatim: prompt)
                        .font(.caption)
                        .foregroundStyle(platformPrimaryTextColor)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(platformChipBackground, in: RoundedRectangle(cornerRadius: 10))
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
            HStack(spacing: 6) {
                if intelligence.isPersonalizedRecommendationsConfigured {
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

                if intelligence.shouldExposeRemoteConfiguration {
                    #if os(macOS)
                    Button {
                        SettingsWindowController.shared.show(tab: .intelligence)
                    } label: {
                        intelligenceSettingsIcon
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(platformAccentColor)
                    .accessibilityLabel("ai_settings_title")
                    #else
                    NavigationLink {
                        AISettingsView()
                    } label: {
                        intelligenceSettingsIcon
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(platformAccentColor)
                    .accessibilityLabel("ai_settings_title")
                    #endif
                }
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

    private var intelligenceSettingsIcon: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 30, height: 30)
            .background(platformChipBackground, in: Circle())
    }

    private var recommendationGrid: some View {
        VStack(spacing: 14) {
            switch recommendationPresentationState {
            case .loading:
                recommendationLoadingGrid
            case .content:
                recommendationResultsGrid
            case .empty:
                recommendationResolvedEmptyState
            }

            if canLoadMore || isLoadingMore || loadMoreFailed {
                VStack(spacing: 8) {
                    if loadMoreFailed {
                        Text("library_recommendations_more_failed")
                            .font(.caption)
                            .foregroundStyle(platformSecondaryTextColor)
                            .multilineTextAlignment(.center)
                    }
                    if canLoadMore || isLoadingMore {
                        Button {
                            Task { await loadMoreRecommendations() }
                        } label: {
                            HStack(spacing: 7) {
                                if isLoadingMore {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text("library_recommendations_more")
                            }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18)
                            .frame(height: 38)
                            .foregroundStyle(platformPrimaryTextColor)
                            .background(platformChipBackground, in: Capsule())
                            .overlay {
                                Capsule().stroke(platformDividerColor, lineWidth: 0.5)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoadingMore)
                    }
                }
            }
        }
    }

    private var recommendationResultsGrid: some View {
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
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.snappy(duration: 0.28), value: aiRecommendation.orderedSongIDs)
    }

    private var recommendationLoadingGrid: some View {
        LoadingSkeletonGroup {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: platformCardMinimumWidth, maximum: 480),
                        spacing: 14
                    ),
                ],
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(0..<6, id: \.self) { index in
                    HStack(spacing: 13) {
                        recommendationSkeletonBlock(
                            width: platformArtworkSize,
                            height: platformArtworkSize,
                            cornerRadius: 12
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            recommendationSkeletonBlock(
                                width: 78 + CGFloat((index % 3) * 12),
                                height: 10
                            )
                            recommendationSkeletonBlock(
                                height: 18
                            )
                                .frame(
                                    maxWidth: 156 + CGFloat((index % 2) * 28),
                                    alignment: .leading
                                )
                            recommendationSkeletonBlock(width: 112, height: 13)
                            Spacer(minLength: 0)
                            recommendationSkeletonBlock(width: 64, height: 11)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: platformArtworkSize + 24,
                        alignment: .leading
                    )
                    .background(
                        platformCardBackground,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(platformDividerColor, lineWidth: 0.5)
                    }
                }
            }
        }
    }

    private var recommendationResolvedEmptyState: some View {
        ContentUnavailableView {
            Label("library_recommendations_empty_title", systemImage: "sparkles")
        } description: {
            Text("library_recommendations_empty_description")
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func recommendationSkeletonBlock(
        width: CGFloat? = nil,
        height: CGFloat,
        cornerRadius: CGFloat = 5
    ) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(platformSkeletonFill)
            .frame(width: width, height: height)
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
        let operationRefreshState = refreshState
        let operationLocalContentRevision = localContentRevision
        guard operationRefreshState.shouldRefresh else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        loadMoreFailed = false
        let input = MusicDiscoveryEngine.recommendationInput(in: library)
        let recommendationPoolSize = Self.recommendationPoolSize
        let results = await Task.detached(priority: .userInitiated) {
            MusicDiscoveryEngine.dailyRecommendations(
                from: input,
                limit: recommendationPoolSize
            )
        }.value
        guard generation == refreshGeneration,
              !Task.isCancelled,
              operationRefreshState == refreshState,
              refreshState.shouldRefresh else { return }
        localResults = results
        preparedLocalContentRevision = operationLocalContentRevision
        await aiRecommendation.refresh(
            scene: recommendationScene,
            intent: selectedIntent.semanticIntent,
            candidates: results.map(\.song),
            using: intelligence,
            forceRefresh: forceAIRefresh,
            maximumResults: Self.recommendationPageSize,
            minimumResults: Self.minimumRecommendationPageSize
        )
    }

    @MainActor
    private func loadMoreRecommendations() async {
        guard !isLoadingMore, refreshState.shouldRefresh else { return }
        let selectedIDs = Set(aiRecommendation.orderedSongIDs)
        let remaining = localResults.filter { !selectedIDs.contains($0.song.id) }
        guard !remaining.isEmpty else { return }

        let operationRefreshState = refreshState
        isLoadingMore = true
        loadMoreFailed = false
        defer { isLoadingMore = false }

        let appended = await aiRecommendation.refresh(
            scene: recommendationScene,
            intent: selectedIntent.semanticIntent,
            candidates: remaining.map(\.song),
            using: intelligence,
            maximumResults: Self.recommendationPageSize,
            minimumResults: min(Self.minimumRecommendationPageSize, remaining.count),
            appending: true
        )
        guard !Task.isCancelled,
              operationRefreshState == refreshState,
              refreshState.shouldRefresh else { return }
        loadMoreFailed = !appended
    }

    private func play(_ song: Song) {
        let visibleQueue = displayedResults.map(\.song).filteredPlayable()
        let fallbackQueue = aiRecommendation.isStreaming
            ? localResults.map(\.song).filteredPlayable()
            : []
        let songsByID = Dictionary(
            (visibleQueue + fallbackQueue).map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let orderedIDs = AIRecommendationPlaybackQueuePolicy.orderedSongIDs(
            visibleSongIDs: visibleQueue.map(\.id),
            fallbackSongIDs: fallbackQueue.map(\.id),
            selectedSongID: song.id
        )
        let queue = orderedIDs.compactMap { songsByID[$0] }
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: index)
        beginTrackingStreamingQueue(
            queue,
            hasFallbackTail: queue.count > visibleQueue.count
        )
        let selected = queue[index]
        SiriMediaInteractionDonor.donate(song: selected)
        Task { await player.play(song: selected) }
    }

    private func playAll() {
        let visibleQueue = displayedResults.map(\.song).filteredPlayable()
        guard let selected = visibleQueue.first else { return }
        let fallbackQueue = aiRecommendation.isStreaming
            ? localResults.map(\.song).filteredPlayable()
            : []
        let songsByID = Dictionary(
            (visibleQueue + fallbackQueue).map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let orderedIDs = AIRecommendationPlaybackQueuePolicy.orderedSongIDs(
            visibleSongIDs: visibleQueue.map(\.id),
            fallbackSongIDs: fallbackQueue.map(\.id),
            selectedSongID: selected.id
        )
        let queue = orderedIDs.compactMap { songsByID[$0] }
        guard let first = queue.first else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: 0)
        beginTrackingStreamingQueue(
            queue,
            hasFallbackTail: queue.count > visibleQueue.count
        )
        SiriMediaInteractionDonor.donate(song: first)
        Task { await player.play(song: first) }
    }

    private func beginTrackingStreamingQueue(
        _ queue: [Song],
        hasFallbackTail: Bool
    ) {
        streamedQueueSongIDs = aiRecommendation.isStreaming && !hasFallbackTail
            ? queue.map(\.id)
            : nil
    }

    private func appendNewStreamingRecommendationsToOwnedQueue() {
        guard let expectedQueueSongIDs = streamedQueueSongIDs else { return }
        let desiredQueue = displayedResults.map(\.song).filteredPlayable()
        let desiredQueueSongIDs = desiredQueue.map(\.id)
        let decision = AIRecommendationQueueSyncPolicy.decision(
            expectedQueueSongIDs: expectedQueueSongIDs,
            actualQueueSongIDs: player.queue.map(\.id),
            desiredQueueSongIDs: desiredQueueSongIDs
        )

        switch decision {
        case .unchanged:
            return
        case .relinquish:
            streamedQueueSongIDs = nil
        case let .append(songIDs):
            let songsByID = Dictionary(
                desiredQueue.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            let additions = songIDs.compactMap { songsByID[$0] }
            guard additions.map(\.id) == songIDs else {
                streamedQueueSongIDs = nil
                return
            }
            player.appendToQueue(additions)
            streamedQueueSongIDs = desiredQueueSongIDs
        }
    }

    private func selectIntent(_ id: String) {
        selectedIntentID = id
        CloudKVSSync.shared.markChanged(
            key: CloudKVSKey.aiRecommendationSelectedIntent
        )
    }

    private func normalizeIntentSelectionIfNeeded() {
        let normalizedID = effectiveSelectedIntentID
        guard normalizedID != selectedIntentID else { return }
        selectIntent(normalizedID)
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
        if case .localFallback = aiRecommendation.feedback {
            return true
        }
        return false
    }

    private var showsActionableStatus: Bool {
        switch aiRecommendation.feedback {
        case .needsConsent, .localFallback:
            return true
        case .idle, .loading, .success:
            return false
        }
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
    private var platformSkeletonFill: Color { PMColor.glassBtn }
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
    private var platformSkeletonFill: Color { Color.secondary.opacity(0.14) }
    #endif
}
