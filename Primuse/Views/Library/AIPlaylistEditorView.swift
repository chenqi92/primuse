import SwiftUI
import PrimuseKit

@MainActor
private enum AIPlaylistCandidateFinder {
    static func candidates(
        for prompt: String,
        songs: [Song],
        metadataRevisionKey: String,
        excluding excludedSongIDs: Set<String>,
        intelligence: MusicIntelligenceService,
        maximumCount: Int = 36
    ) async -> [Song] {
        let available = songs.filter {
            !$0.id.isEmpty && !excludedSongIDs.contains($0.id)
        }
        guard !available.isEmpty, maximumCount > 0 else { return [] }

        var queries = [prompt]
        if intelligence.isSemanticSearchConfigured,
           case .success(let execution) = await intelligence.semanticSearchOutcome(for: prompt) {
            queries.append(contentsOf: AISemanticLibraryAggregationPolicy.concepts(
                from: execution.plan
            ))
        }
        queries = uniqueQueries(queries)

        var songsByID: [String: Song] = [:]
        var rankedCandidates: [AISemanticLibraryMatchCandidate] = []
        for (queryOrder, query) in queries.enumerated() {
            guard !Task.isCancelled else { return [] }
            let matches = await search(
                query: query,
                songs: available,
                metadataRevisionKey: metadataRevisionKey
            )
            for match in matches {
                songsByID[match.song.id] = match.song
                rankedCandidates.append(AISemanticLibraryMatchCandidate(
                    songID: match.song.id,
                    title: match.song.title,
                    score: match.score,
                    relatedConcept: query,
                    conceptOrder: queryOrder
                ))
            }
        }

        var result = AISemanticLibraryAggregationPolicy.rankedMatches(
            rankedCandidates,
            limit: maximumCount
        ).compactMap { songsByID[$0.songID] }
        var seen = Set(result.map(\.id))

        // Semantic/literal search can legitimately return only a few songs for
        // a mood-like request. Give the recommendation model a library-wide,
        // evenly distributed remainder instead of repeatedly sending the first
        // alphabetic rows from a large collection.
        let remaining = maximumCount - result.count
        if remaining > 0 {
            let start = stableOffset(for: prompt, count: available.count)
            let step = max(1, available.count / max(maximumCount, 1))
            for offset in 0..<available.count {
                let index = (start + offset * step) % available.count
                let song = available[index]
                guard seen.insert(song.id).inserted else { continue }
                result.append(song)
                if result.count == maximumCount { break }
            }
            if result.count < maximumCount {
                for song in available where seen.insert(song.id).inserted {
                    result.append(song)
                    if result.count == maximumCount { break }
                }
            }
        }
        return result
    }

    private static func search(
        query: String,
        songs: [Song],
        metadataRevisionKey: String
    ) async -> [LibrarySearchResult] {
        if let indexed = await LibrarySearchIndex.shared.search(
            query: query,
            songs: songs,
            albums: [],
            metadataRevisionKey: metadataRevisionKey,
            songLimit: 12,
            albumLimit: 0
        ) {
            return indexed.output.songResults
        }

        let worker = Task.detached(priority: .utility) {
            LibrarySearchWorker.compute(
                query: query,
                songs: songs,
                albums: [],
                cache: LibrarySearchCache(),
                includeMetadata: true,
                includeLyrics: false,
                songLimit: 12,
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

    private static func stableOffset(for value: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let hash = value.unicodeScalars.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1.value)) &* 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }
}

struct AIPlaylistEditorView: View {
    let existing: SmartPlaylist?

    @Environment(MusicLibrary.self) private var library
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var prompt = ""
    @State private var generatedPrompt = ""
    @State private var candidateSongs: [Song] = []
    @State private var recommendation = AIRecommendationViewModel()
    @State private var isGenerating = false
    @State private var generationMessage: String?
    @State private var generationTask: Task<Void, Never>?
    @State private var generationID = UUID()
    @State private var didLoadInitialState = false

    private var isEditing: Bool { existing != nil }

    private var normalizedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var generatedSongs: [Song] {
        let songsByID = Dictionary(
            candidateSongs.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        return recommendation.orderedSongIDs.compactMap { songsByID[$0] }
    }

    private var canGenerate: Bool {
        !isGenerating
            && !normalizedPrompt.isEmpty
            && !library.visibleSongs.isEmpty
            && intelligence.isPersonalizedRecommendationsConfigured
    }

    private var canSave: Bool {
        !isGenerating
            && !generatedSongs.isEmpty
            && normalizedPrompt == generatedPrompt
    }

    private var commitTitle: String {
        if isEditing {
            return String(
                format: String(localized: "ai_playlist_add_count_format"),
                generatedSongs.count
            )
        }
        return String(localized: "ai_playlist_create")
    }

    private var existingSongCount: Int {
        guard let existing else { return 0 }
        return SmartPlaylistEngine.match(existing, in: library, history: .shared).count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("ai_playlist_name_section") {
                    TextField("ai_playlist_name_placeholder", text: $name)
                        .accessibilityIdentifier("aiPlaylistNameField")
                }

                if isEditing {
                    Section("ai_playlist_current_section") {
                        LabeledContent(
                            "songs_count",
                            value: existingSongCount.formatted()
                        )
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
                    }

                    Button(action: generate) {
                        HStack {
                            if isGenerating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: generatedSongs.isEmpty
                                      ? "sparkles"
                                      : "arrow.clockwise")
                            }
                            Text(LocalizedStringKey(
                                generatedSongs.isEmpty
                                    ? "ai_playlist_generate"
                                    : "ai_playlist_regenerate"
                            ))
                            Spacer()
                        }
                    }
                    .disabled(!canGenerate)
                    .accessibilityIdentifier("aiPlaylistGenerateButton")
                } header: {
                    Text("ai_playlist_prompt_section")
                } footer: {
                    Text(promptFooterKey)
                }

                if isGenerating || generationMessage != nil || !generatedSongs.isEmpty {
                    Section {
                        if isGenerating {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(LocalizedStringKey(
                                    candidateSongs.isEmpty
                                        ? "ai_playlist_finding_candidates"
                                        : (recommendation.isStreaming
                                           ? "ai_playlist_streaming_results"
                                           : "ai_recommendation_status_loading")
                                ))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ForEach(generatedSongs) { song in
                            previewRow(song)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        if let generationMessage {
                            Text(generationMessage)
                                .font(.footnote)
                                .foregroundStyle(generatedSongs.isEmpty ? .secondary : .tertiary)
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
            .navigationTitle(isEditing ? "ai_playlist_add_songs" : "ai_playlist_new")
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
            .onAppear(perform: loadInitialState)
            .onDisappear {
                generationTask?.cancel()
            }
            #if os(macOS)
            .frame(minWidth: 620, minHeight: 600)
            #endif
        }
    }

    private var promptFooterKey: LocalizedStringKey {
        if library.visibleSongs.isEmpty {
            return "ai_playlist_empty_library"
        }
        if !intelligence.isPersonalizedRecommendationsConfigured {
            return "ai_playlist_configuration_required"
        }
        return "ai_playlist_prompt_footer"
    }

    private func previewRow(_ song: Song) -> some View {
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
                Text(song.title)
                    .lineLimit(1)
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
        name = existing?.name ?? ""
    }

    private func generate() {
        let requestPrompt = normalizedPrompt
        guard !requestPrompt.isEmpty else { return }

        generationTask?.cancel()
        let operationID = UUID()
        generationID = operationID
        let nextRecommendation = AIRecommendationViewModel()
        recommendation = nextRecommendation
        candidateSongs = []
        generatedPrompt = ""
        generationMessage = nil
        isGenerating = true

        let songsSnapshot = library.visibleSongs
        let metadataRevisionKey = "\(library.visibleSongCollectionRevision):\(library.searchRevision)"
        let excludedIDs: Set<String>
        if let selections = existing?.aiConfiguration?.selections {
            excludedIDs = Set(
                library.visibleSongs(matching: selections.map(\.identity)).map(\.id)
            )
        } else {
            excludedIDs = []
        }

        generationTask = Task { @MainActor in
            defer {
                if generationID == operationID {
                    isGenerating = false
                }
            }
            let candidates = await AIPlaylistCandidateFinder.candidates(
                for: requestPrompt,
                songs: songsSnapshot,
                metadataRevisionKey: metadataRevisionKey,
                excluding: excludedIDs,
                intelligence: intelligence
            )
            guard !Task.isCancelled, generationID == operationID else { return }
            guard !candidates.isEmpty else {
                generationMessage = String(localized: "ai_playlist_no_suggestions")
                return
            }
            candidateSongs = candidates
            let didGenerate = await nextRecommendation.refresh(
                scene: .automatic,
                intent: requestPrompt,
                candidates: candidates,
                using: intelligence,
                forceRefresh: true,
                maximumResults: 12,
                minimumResults: min(8, candidates.count)
            )
            guard !Task.isCancelled, generationID == operationID else { return }
            guard didGenerate, !nextRecommendation.orderedSongIDs.isEmpty else {
                generationMessage = nextRecommendation.statusText
                return
            }

            generatedPrompt = requestPrompt
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = defaultName(from: requestPrompt)
            }
            if case .success(let summary, _, _, _, _) = nextRecommendation.feedback,
               !summary.isEmpty {
                generationMessage = summary
            } else {
                generationMessage = String(
                    format: String(localized: "ai_playlist_generated_count_format"),
                    nextRecommendation.orderedSongIDs.count
                )
            }
        }
    }

    private func save() {
        guard canSave else { return }
        let additions = generatedSongs.map { song in
            AISmartPlaylistSelection(
                identity: library.portableSongIdentity(for: song),
                reason: recommendation.reason(for: song.id)
            )
        }
        var configuration = existing?.aiConfiguration ?? AISmartPlaylistConfiguration()
        configuration = configuration.appending(
            prompt: generatedPrompt,
            selections: additions
        )

        var smart = existing ?? SmartPlaylist(name: "")
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        smart.name = trimmedName.isEmpty ? defaultName(from: generatedPrompt) : trimmedName
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
        dismiss()
    }

    private func defaultName(from prompt: String) -> String {
        String(prompt.prefix(32))
    }
}
