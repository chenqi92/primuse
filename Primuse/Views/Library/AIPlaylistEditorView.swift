import SwiftUI
import PrimuseKit

/// 给智能服务挑歌的候选(最多 100 首)。服务只在这里面挑,歌单好不好几乎全看这一步:
/// 搜索结果(提示词原文和扩展词)、提示词提到的风格和年代、常听艺人的歌、全库抽样,
/// 按 `AIPlaylistCandidatePoolPolicy` 配比。以前搜不到几首时直接按哈希在全库均匀抽,
/// 心情、场景类的提示词送去的几乎都是随机歌。
@MainActor
private enum AIPlaylistCandidateFinder {
    static func candidates(
        for prompt: String,
        songs: [Song],
        metadataRevisionKey: String,
        excluding excludedSongIDs: Set<String>,
        intelligence: MusicIntelligenceService,
        history: PlayHistoryStore = .shared,
        salt: UInt64,
        maximumCount: Int = AIPlaylistCandidatePoolPolicy.poolSize
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

        var rankedCandidates: [AISemanticLibraryMatchCandidate] = []
        for (queryOrder, query) in queries.enumerated() {
            guard !Task.isCancelled else { return [] }
            let matches = await search(
                query: query,
                songs: available,
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

        let request = PoolRequest(
            prompt: prompt,
            texts: queries,
            searchIDs: searchIDs,
            topArtists: history.topArtists(in: .year, limit: 8).map(\.title),
            topSongIDs: history.topSongs(in: .year, limit: 24).map(\.id),
            salt: salt,
            limit: maximumCount
        )
        let worker = Task.detached(priority: .userInitiated) {
            Self.pool(for: request, in: available)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private struct PoolRequest: Sendable {
        let prompt: String
        let texts: [String]
        let searchIDs: [String]
        let topArtists: [String]
        let topSongIDs: [String]
        let salt: UInt64
        let limit: Int
    }

    /// 风格、年代、常听艺人、全库抽样要扫整个曲库,不放在主线程上。
    private nonisolated static func pool(for request: PoolRequest, in songs: [Song]) -> [Song] {
        var songsByID: [String: Song] = [:]
        songsByID.reserveCapacity(songs.count)
        var playableIDs: [String] = []
        playableIDs.reserveCapacity(songs.count)
        var genreNamesByRaw: [String: [String]] = [:]
        var libraryGenres: [String] = []
        var seenGenres = Set<String>()
        for song in songs where song.isPlayable && songsByID[song.id] == nil {
            songsByID[song.id] = song
            playableIDs.append(song.id)
            guard let raw = song.genre, genreNamesByRaw[raw] == nil else { continue }
            let names = SongDiscoveryMatching.genreNames(raw)
            genreNamesByRaw[raw] = names
            for name in names where seenGenres.insert(SongDiscoveryMatching.key(name)).inserted {
                libraryGenres.append(name)
            }
        }
        guard !Task.isCancelled else { return [] }

        let wantedGenres = Set(AIPlaylistPromptHints.matchingGenres(
            texts: request.texts,
            libraryGenres: libraryGenres
        ).map(SongDiscoveryMatching.key))
        let decades = AIPlaylistPromptHints.decades(in: request.texts.joined(separator: " "))
        let topArtistKeys = Set(request.topArtists.compactMap { SongRadioGrouping.artistKey($0) })

        var genreIDs: [String] = []
        var decadeIDs: [String] = []
        var topArtistSongIDs: [String] = []
        var artistKeyByRaw: [String: String?] = [:]
        for id in playableIDs {
            guard let song = songsByID[id] else { continue }
            if !wantedGenres.isEmpty, let raw = song.genre,
               genreNamesByRaw[raw]?.contains(where: { wantedGenres.contains(SongDiscoveryMatching.key($0)) }) == true {
                genreIDs.append(song.id)
            }
            if let year = song.year, decades.contains(where: { $0.contains(year) }) {
                decadeIDs.append(song.id)
            }
            if !topArtistKeys.isEmpty, let raw = song.artistName {
                let key: String?
                if let cached = artistKeyByRaw[raw] {
                    key = cached
                } else {
                    key = SongRadioGrouping.artistKey(raw)
                    artistKeyByRaw[raw] = .some(key)
                }
                if let key, topArtistKeys.contains(key) { topArtistSongIDs.append(song.id) }
            }
        }
        guard !Task.isCancelled else { return [] }

        var artistKeys: [String: String?] = [:]
        func artist(_ id: String) -> String? {
            if let cached = artistKeys[id] { return cached }
            let key = SongRadioGrouping.artistKey(songsByID[id]?.artistName)
            artistKeys[id] = .some(key)
            return key
        }
        /// 按这次生成的随机数打乱后,每位艺人最多取 `perArtist` 首,取够 `count` 首为止。
        func sample(_ ids: [String], count: Int, perArtist: Int) -> [String] {
            var counts: [String: Int] = [:]
            var output: [String] = []
            for id in shuffled(ids, salt: request.salt, keeping: count * 6) {
                if let key = artist(id) {
                    guard counts[key, default: 0] < perArtist else { continue }
                    counts[key, default: 0] += 1
                }
                output.append(id)
                if output.count == count { break }
            }
            return output
        }

        let limit = request.limit
        let topSongIDs = request.topSongIDs.filter { songsByID[$0] != nil }
        let taste = interleave(
            shuffled(topSongIDs, salt: request.salt, keeping: topSongIDs.count),
            sample(topArtistSongIDs, count: limit, perArtist: AIPlaylistCandidatePoolPolicy.tastePerArtist)
        )
        let ids = AIPlaylistCandidatePoolPolicy.compose(
            matched: [
                request.searchIDs.filter { songsByID[$0] != nil },
                sample(genreIDs, count: limit, perArtist: 2),
                sample(decadeIDs, count: limit, perArtist: 2),
            ],
            taste: taste,
            spread: sample(playableIDs, count: limit * 4, perArtist: 1),
            limit: limit,
            artist: artist
        )
        return ids.compactMap { songsByID[$0] }
    }

    /// 按 (id, salt) 的哈希排序的前 `keeping` 个。整库几十万首时先按哈希阈值粗筛,只排一小部分。
    private nonisolated static func shuffled(_ ids: [String], salt: UInt64, keeping: Int) -> [String] {
        guard keeping > 0, !ids.isEmpty else { return [] }
        var hashed = ids.map { (hash: stableHash($0, salt: salt), id: $0) }
        if hashed.count > keeping * 4 {
            let threshold = UInt64.max / UInt64(hashed.count) * UInt64(keeping * 2)
            let narrowed = hashed.filter { $0.hash <= threshold }
            if narrowed.count >= keeping { hashed = narrowed }
        }
        hashed.sort { $0.hash < $1.hash }
        return hashed.prefix(keeping).map(\.id)
    }

    private nonisolated static func interleave(_ lhs: [String], _ rhs: [String]) -> [String] {
        var output: [String] = []
        output.reserveCapacity(lhs.count + rhs.count)
        for index in 0..<max(lhs.count, rhs.count) {
            if index < lhs.count { output.append(lhs[index]) }
            if index < rhs.count { output.append(rhs[index]) }
        }
        return output
    }

    private nonisolated static func stableHash(_ id: String, salt: UInt64) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037 ^ salt
        for byte in id.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return hash
    }

    /// 每个搜索词取多少首。候选池放到 100 首后,12 首会让搜索结果占不满池子。
    private nonisolated static let searchLimit = 24

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
            songLimit: searchLimit,
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

    /// 一次生成挑多少首(内置 AI 一次最多 30 首)。
    private static let songsPerGeneration = 25

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

                        ForEach(Array(generatedSongs.enumerated()), id: \.element.id) { index, song in
                            previewRow(song, ordinal: index + 1)
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
            .floatingInputPanelClearance()
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

            SongRowTrackNumber(number: ordinal, largestNumber: generatedSongs.count)
                .font(.subheadline).foregroundStyle(.secondary)
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

        // 只在音乐里挑:有声书章节、播客单集不进歌单候选。
        let songsSnapshot = library.musicSongs
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
            // 每次生成换一个随机数:「重新生成」送去的候选不同,挑出来的才会不同。
            let candidates = await AIPlaylistCandidateFinder.candidates(
                for: requestPrompt,
                songs: songsSnapshot,
                metadataRevisionKey: metadataRevisionKey,
                excluding: excludedIDs,
                intelligence: intelligence,
                salt: UInt64.random(in: .min ... .max)
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
                // 还没升级的服务只看前 36 首、最多回 12 首,8 首以上照样算成功。
                maximumResults: Self.songsPerGeneration,
                minimumResults: min(8, candidates.count),
                candidateLimit: AIRecommendationRequest.maximumCandidates,
                followsTimeOfDay: false
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
