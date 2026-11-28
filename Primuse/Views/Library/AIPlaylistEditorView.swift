import SwiftUI
import PrimuseKit

/// 每批结合提示词、收听历史与全库抽样，排除已入选歌曲及其跨来源副本。
@MainActor
final class AIPlaylistCandidateFinder {
    private let queries: [String]
    private let library: MusicLibrary
    private let existingIDs: Set<String>
    private var pathsByAccount: [String: Set<String>] = [:]
    private var recordedCount = 0

    init(queries: [String], library: MusicLibrary, existing: [SongIdentity]) {
        self.queries = queries
        self.library = library
        existingIDs = Set(existing.map(\.songID)).union(library.visibleSongs(matching: existing).map(\.id))
        for identity in existing { rememberCloudPath(identity) }
    }

    private func rememberCloudPath(_ identity: SongIdentity) {
        if let account = identity.cloudAccountID, !identity.filePath.isEmpty {
            pathsByAccount[account, default: []].insert(identity.filePath)
        }
    }

    func next(excluding: Set<String>, selectedIDs: [String]) async -> [Song] {
        for id in selectedIDs.dropFirst(recordedCount) {
            if let song = library.visibleSong(id: id) {
                rememberCloudPath(library.portableSongIdentity(for: song))
            }
        }
        recordedCount = selectedIDs.count
        var pathsBySource: [String: Set<String>] = [:]
        for source in library.sourceIDsWithPlayableSongs {
            if let account = library.sourceIdentityResolver?(source) { pathsBySource[source] = pathsByAccount[account] }
        }
        let blocked = existingIDs.union(library.dislikedSongIDs).union(excluding)
        let page = await Self.candidates(for: queries, library: library, excluding: blocked,
                                         excludedPathsBySource: pathsBySource, salt: UInt64.random(in: .min ... .max))
        var pageKeys = Set<String>()
        return page.filter {
            pageKeys.insert(AISmartPlaylistConfiguration.identityKey(library.portableSongIdentity(for: $0))).inserted
        }
    }

    static func queries(
        for prompt: String,
        intelligence: MusicIntelligenceService
    ) async -> [String] {
        var queries = [prompt]
        if intelligence.isSemanticSearchConfigured,
           case .success(let execution) = await intelligence.semanticSearchOutcome(for: prompt) {
            queries.append(contentsOf: AISemanticLibraryAggregationPolicy.concepts(
                from: execution.plan
            ))
        }
        return uniqueQueries(queries)
    }

    private static func candidates(
        for queries: [String],
        library: MusicLibrary,
        excluding excludedSongIDs: Set<String>,
        excludedPathsBySource: [String: Set<String>],
        history: PlayHistoryStore = .shared,
        salt: UInt64
    ) async -> [Song] {
        guard !Task.isCancelled, !library.musicSongs.isEmpty else { return [] }
        let maximumCount = AIPlaylistCandidatePoolPolicy.poolSize
        let snapshot = library.searchSongSnapshot()
        let metadataRevisionKey = "\(library.visibleSongCollectionRevision):\(library.searchRevision)"
        let topArtists = history.topArtists(in: .year, limit: 8).map(\.title)
        let topSongs = history.topSongs(in: .year, limit: 24).map(\.id)
        let useIndexes = snapshot.lookup != nil && snapshot.songs.count > AIPlaylistCandidatePoolPolicy.poolSize * 48
        let genreGroups = useIndexes ? library.recommendationGenreGroups() : nil
        let artistGroups = useIndexes ? topArtists.map { library.trackSongIDs(forArtistNamed: $0) } : []
        var rankedCandidates: [AISemanticLibraryMatchCandidate] = []
        for (queryOrder, query) in queries.enumerated() {
            guard !Task.isCancelled else { return [] }
            let matches = await search(
                query: query,
                snapshot: snapshot, excluding: excludedSongIDs,
                metadataRevisionKey: metadataRevisionKey
            )
            for match in matches {
                rankedCandidates.append(AISemanticLibraryMatchCandidate(
                    songID: match.song.id,
                    title: match.song.title,
                    score: match.score,
                    relatedConcept: query,
                    conceptOrder: queryOrder
                ))
            }
        }
        let searchIDs = AISemanticLibraryAggregationPolicy.rankedMatches(
            rankedCandidates,
            limit: maximumCount
        ).map(\.songID)
        guard !Task.isCancelled else { return [] }

        let worker = Task.detached(priority: .userInitiated) { [queries] in
            if let genreGroups, let lookup = snapshot.lookup {
                return AIPlaylistCandidatePoolPolicy.indexedCandidates(
                    in: snapshot.songs, texts: queries, searchIDs: searchIDs, topArtists: topArtists,
                    topSongIDs: topSongs, genreGroups: genreGroups(queries), artistGroups: artistGroups,
                    lookup: lookup, excluding: excludedSongIDs, salt: salt, limit: maximumCount,
                    excludedPathsBySource: excludedPathsBySource,
                    isCancelled: { Task.isCancelled }
                )
            }
            return AIPlaylistCandidatePoolPolicy.songs(
                in: snapshot.songs, texts: queries, searchIDs: searchIDs, topArtists: topArtists,
                topSongIDs: topSongs, salt: salt, limit: maximumCount, excluding: excludedSongIDs,
                excludedPathsBySource: excludedPathsBySource,
                isCancelled: { Task.isCancelled }
            )
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// 每个搜索词取多少首。候选池放到 100 首后,12 首会让搜索结果占不满池子。
    private nonisolated static let searchLimit = 24

    private static func search(
        query: String,
        snapshot: LibrarySearchSongSnapshot, excluding: Set<String>,
        metadataRevisionKey: String
    ) async -> [LibrarySearchResult] {
        if let indexed = await LibrarySearchIndex.shared.search(
            query: query,
            snapshot: snapshot,
            albums: [],
            metadataRevisionKey: metadataRevisionKey,
            excluding: excluding,
            songLimit: searchLimit,
            albumLimit: 0
        ) {
            return indexed.output.songResults
        }

        let worker = Task.detached(priority: .utility) {
            LibrarySearchWorker.compute(
                query: query,
                songs: snapshot.songs,
                albums: [],
                cache: LibrarySearchCache(),
                sourceTypes: snapshot.sourceTypes,
                includeMetadata: true,
                includeLyrics: false,
                excluding: excluding,
                songLimit: searchLimit,
                albumLimit: 0
            ).songResults
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func uniqueQueries(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard !trimmed.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

}

struct AIPlaylistEditorView: View {
    let existing: SmartPlaylist?
    var createsListeningScene = false
    var initialName = ""
    var initialPrompt = ""

    @Environment(MusicLibrary.self) private var library
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var name = ""
    @State private var prompt = ""
    @State private var songCountText = String(AISmartPlaylistConfiguration.defaultGenerationSongCount)
    @State private var generatedPrompt = ""
    @State private var generatedSongCount: Int?
    @State private var recommendation = AIRecommendationViewModel()
    @State private var isGenerating = false
    @State private var generationMessage: String?
    @State private var generationTask: Task<Void, Never>?
    @State private var generationID = UUID()
    @State private var didLoadInitialState = false
    @State private var existingSongCount = 0

    private var isEditing: Bool { existing != nil }
    private var isListeningScene: Bool {
        createsListeningScene || existing?.aiConfiguration?.isListeningScene == true
    }

    private var normalizedPrompt: String {
        AISmartPlaylistPrompt(text: prompt).text
    }

    private var requestedSongCount: Int? {
        AISmartPlaylistConfiguration.generationSongCount(from: songCountText, locale: locale)
    }

    private var remainingSelectionCapacity: Int {
        let previousCount = isListeningScene ? 0 : (existing?.aiConfiguration?.selections.count ?? 0)
        return AISmartPlaylistConfiguration.maximumSelectionCount - previousCount
    }

    private var generatedSongs: [Song] {
        recommendation.orderedSongIDs.compactMap { library.visibleSong(id: $0) }
    }

    private var canResumeGeneration: Bool {
        recommendation.isPartial && !recommendation.orderedSongIDs.isEmpty
            && normalizedPrompt == generatedPrompt && requestedSongCount == generatedSongCount
    }

    private var generationButtonTitle: LocalizedStringKey {
        if isGenerating { return "transcript_generation_stop" }
        if canResumeGeneration { return "chapter_generation_resume" }
        return recommendation.orderedSongIDs.isEmpty ? "ai_playlist_generate" : "ai_playlist_regenerate"
    }

    private var canGenerate: Bool {
        !isGenerating
            && !normalizedPrompt.isEmpty
            && requestedSongCount != nil
            && remainingSelectionCapacity > 0
            && PlaybackSurfaceCountsModel.visibleSongCount(in: library) != 0
            && intelligence.isPersonalizedRecommendationsConfigured
    }

    private var canSave: Bool {
        guard !isGenerating, let requestedSongCount else { return false }
        if !recommendation.orderedSongIDs.isEmpty {
            return normalizedPrompt == generatedPrompt && requestedSongCount == generatedSongCount
                && recommendation.orderedSongIDs.contains { library.visibleSong(id: $0) != nil }
        }
        return isListeningScene && isEditing && !normalizedPrompt.isEmpty
            && normalizedPrompt == existing?.aiConfiguration?.lastPrompt
            && requestedSongCount == existing?.aiConfiguration?.effectiveGenerationSongCount
    }

    private var commitTitle: String {
        if isListeningScene { return String(localized: "save") }
        if isEditing {
            return String(
                format: String(localized: "ai_playlist_add_count_format"),
                isGenerating ? recommendation.orderedSongIDs.count : generatedSongs.count
            )
        }
        return String(localized: "ai_playlist_create")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("ai_playlist_name_section") {
                    TextField("ai_playlist_name_placeholder", text: $name)
                        .accessibilityIdentifier("aiPlaylistNameField")
                }

                if isEditing && !isListeningScene {
                    Section("ai_playlist_current_section") {
                        LabeledContent(
                            "songs_count",
                            value: existingSongCount.formatted()
                        )
                        .onChange(of: library.visibleSongsVersion, initial: true) { _, _ in
                            if let existing {
                                existingSongCount = SmartPlaylistEngine.match(existing, in: library, history: .shared).count
                            }
                        }
                    }
                }

                Section {
                    ZStack(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text("ai_playlist_prompt_placeholder")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $prompt)
                            .frame(minHeight: 104)
                            .accessibilityIdentifier("aiPlaylistPromptEditor")
                            .onChange(of: prompt) { _, value in
                                // 内置 AI 160 字，用自己的 AI 服务时放开。
                                let limit = intelligence.promptCharacterLimit(for: .recommendations)
                                if value.count > limit { prompt = String(value.prefix(limit)) }
                            }
                    }

                    songCountField

                    Button {
                        if isGenerating { generationTask?.cancel() } else { generate() }
                    } label: {
                        HStack {
                            if isGenerating {
                                Image(systemName: "stop.fill")
                            } else {
                                Image(systemName: recommendation.orderedSongIDs.isEmpty
                                      ? "sparkles"
                                      : "arrow.clockwise")
                            }
                            Text(generationButtonTitle)
                            Spacer()
                        }
                    }
                    .disabled(!isGenerating && !canGenerate)
                    .accessibilityIdentifier("aiPlaylistGenerateButton")
                } header: {
                    Text("ai_playlist_prompt_section")
                } footer: {
                    Text(promptFooterKey)
                }

                if isGenerating || generationMessage != nil || !recommendation.orderedSongIDs.isEmpty {
                    Section {
                        if isGenerating {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(LocalizedStringKey(
                                    recommendation.feedback == .idle
                                        ? "ai_playlist_finding_candidates"
                                        : (recommendation.isStreaming
                                           ? "ai_playlist_streaming_results"
                                           : "ai_recommendation_status_loading")
                                ))
                                    .foregroundStyle(.secondary)
                                if let generatedSongCount {
                                    Spacer()
                                    Text(verbatim: "\(recommendation.orderedSongIDs.count.formatted()) / \(min(generatedSongCount, remainingSelectionCapacity).formatted())")
                                        .monospacedDigit()
                                }
                            }
                        }

                        ForEach(Array(recommendation.orderedSongIDs.enumerated()), id: \.element) { index, id in
                            if let song = library.visibleSong(id: id) {
                                previewRow(song, ordinal: index + 1)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }

                        if let generationMessage {
                            Text(generationMessage)
                                .font(.footnote)
                                .foregroundStyle(recommendation.orderedSongIDs.isEmpty ? .secondary : .tertiary)
                        }
                    } header: {
                        Text("ai_playlist_preview_section")
                    }
                    .animation(
                        .snappy(duration: 0.28),
                        value: recommendation.orderedSongIDs
                    )
                }
            }
            .floatingInputPanelClearance()
            #if os(macOS)
            .macFormSheet(title: Text(LocalizedStringKey(titleKey)), systemImage: "sparkles") {
                Button("cancel") { dismiss() }
                    .buttonStyle(.macSheet)
                    .keyboardShortcut(.cancelAction)
                Button(action: save) {
                    Text(commitTitle)
                }
                .buttonStyle(.macSheetPrimary)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("aiPlaylistCommitButton")
            }
            #else
            .navigationTitle(LocalizedStringKey(titleKey))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        Text(commitTitle)
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("aiPlaylistCommitButton")
                }
            }
            #endif
            .onAppear(perform: loadInitialState)
            .onDisappear {
                generationTask?.cancel()
            }
            #if os(macOS)
            .frame(minWidth: 620, minHeight: 600)
            #endif
        }
    }

    private var titleKey: String {
        isListeningScene
            ? (isEditing ? "listening_scene_edit" : "listening_scene_new")
            : (isEditing ? "ai_playlist_add_songs" : "ai_playlist_new")
    }

    private var promptFooterKey: LocalizedStringKey {
        if PlaybackSurfaceCountsModel.visibleSongCount(in: library) == 0 {
            return "ai_playlist_empty_library"
        }
        if !intelligence.isPersonalizedRecommendationsConfigured {
            return "ai_playlist_configuration_required"
        }
        return "ai_playlist_prompt_footer"
    }

    private var songCountField: some View {
        let range = AISmartPlaylistConfiguration.generationSongCountRange
        let numberFormat = IntegerFormatStyle<Int>(locale: locale)
        let rangeText = "\(range.lowerBound.formatted(numberFormat))–\(range.upperBound.formatted(numberFormat))"
        return LabeledContent("playlist_sort_song_count") {
            HStack(spacing: 8) {
                if requestedSongCount == nil && !songCountText.isEmpty {
                    Text(verbatim: rangeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("playlist_sort_song_count", text: $songCountText, prompt: Text(verbatim: rangeText))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .accessibilityIdentifier("aiPlaylistSongCountField")
            }
        }
        .disabled(isGenerating)
    }

    private func previewRow(_ song: Song, ordinal: Int) -> some View {
        HStack(spacing: 10) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 38,
                cornerRadius: 6,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    SongRowTrackNumber(number: ordinal, largestNumber: recommendation.orderedSongIDs.count)
                    Text(song.title)
                        .lineLimit(1)
                }
                Text(library.artistDisplayName(for: song) ?? String(localized: "unknown_artist"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let reason = recommendation.reason(for: song.id) {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func loadInitialState() {
        guard !didLoadInitialState else { return }
        didLoadInitialState = true
        name = existing?.name ?? initialName
        let count = existing?.aiConfiguration?.effectiveGenerationSongCount
            ?? AISmartPlaylistConfiguration.defaultGenerationSongCount
        songCountText = count.formatted(.number.grouping(.never).locale(locale))
        if isListeningScene {
            prompt = existing?.aiConfiguration?.lastPrompt ?? initialPrompt
        }
    }

    private func generate() {
        let requestPrompt = normalizedPrompt
        guard canGenerate, let requestedSongCount else { return }
        let targetSongCount = min(requestedSongCount, remainingSelectionCapacity)

        generationTask?.cancel()
        let operationID = UUID()
        generationID = operationID
        let nextRecommendation = canResumeGeneration ? recommendation : AIRecommendationViewModel()
        recommendation = nextRecommendation
        generatedPrompt = requestPrompt
        generatedSongCount = requestedSongCount
        generationMessage = nil
        isGenerating = true

        let existingIdentities = isListeningScene ? [] : (existing?.aiConfiguration?.selections.map(\.identity) ?? [])

        generationTask = Task { @MainActor in
            // 候选从整库里挑:整个生成占着歌曲模型(放掉了先装回来),做到一半在后台也不会被放掉;装不回来就不生成。
            let hold = await SongModelArrayRead.hold(library)
            defer {
                hold?.end()
                if generationID == operationID {
                    isGenerating = false
                }
            }
            guard hold != nil else { return }
            let queries = await AIPlaylistCandidateFinder.queries(for: requestPrompt, intelligence: intelligence)
            let finder = AIPlaylistCandidateFinder(queries: queries, library: library, existing: existingIdentities)
            let didGenerate = await nextRecommendation.refreshPlaylist(
                intent: requestPrompt, using: intelligence, songCount: targetSongCount
            ) { excluded in
                await finder.next(excluding: excluded, selectedIDs: nextRecommendation.orderedSongIDs)
            }
            guard generationID == operationID else { return }
            guard didGenerate, !nextRecommendation.orderedSongIDs.isEmpty else {
                if !Task.isCancelled {
                    generationMessage = nextRecommendation.feedback == .idle
                        ? String(localized: "ai_playlist_no_suggestions") : nextRecommendation.playlistFailureText
                }
                return
            }

            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = defaultName(from: requestPrompt)
            }
            let resultCount = nextRecommendation.orderedSongIDs.count
            if !nextRecommendation.isPartial,
               resultCount == requestedSongCount,
               requestedSongCount <= AIRecommendationRequest.maximumSongSelections,
               case .success(let summary, _, _, _, _) = nextRecommendation.feedback,
               !summary.isEmpty {
                generationMessage = summary
            } else {
                let countMessage = String(
                    format: String(localized: "ai_playlist_generated_count_format"),
                    resultCount
                )
                if !Task.isCancelled, case .localFallback = nextRecommendation.feedback {
                    generationMessage = countMessage + "\n" + nextRecommendation.playlistFailureText
                } else {
                    generationMessage = countMessage
                }
            }
        }
    }

    private func save() {
        guard canSave, let requestedSongCount else { return }
        let additions = generatedSongs.map { song in
            AISmartPlaylistSelection(
                identity: library.portableSongIdentity(for: song),
                reason: recommendation.reason(for: song.id)
            )
        }
        guard recommendation.orderedSongIDs.isEmpty || !additions.isEmpty else { return }
        var configuration = existing?.aiConfiguration ?? AISmartPlaylistConfiguration()
        if isListeningScene {
            configuration.isListeningScene = true
            if !additions.isEmpty {
                configuration = configuration.replacingScene(prompt: generatedPrompt, selections: additions)
            }
        } else {
            configuration = configuration.appending(prompt: generatedPrompt, selections: additions)
        }
        configuration.generationSongCount = requestedSongCount

        var smart = existing ?? SmartPlaylist(name: "")
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        smart.name = trimmedName.isEmpty ? defaultName(from: normalizedPrompt) : trimmedName
        smart.kind = .ai
        smart.aiConfiguration = configuration
        // Older app versions ignore the AI payload and interpret an empty rule
        // set as "all songs". Keep one impossible source rule so a synced AI
        // playlist stays empty there instead of exposing the whole library.
        smart.rules = [
            SmartPlaylistRule(
                id: "ai-legacy-safety-filter",
                field: .sourceID,
                op: .equals,
                value: "primuse://ai-smart-playlist/\(smart.id)"
            )
        ]
        smart.combinator = .and
        smart.ruleGroups = nil
        smart.groupCombinator = nil
        smart.limit = nil
        library.saveSmartPlaylist(smart)
        if isListeningScene {
            ListeningIntentService.shared.refresh(library: library)
            ListeningIntentService.shared.setSmartPlaylistPinned(true, playlistID: smart.id)
        }
        dismiss()
    }

    private func defaultName(from prompt: String) -> String {
        String(prompt.prefix(32))
    }
}
