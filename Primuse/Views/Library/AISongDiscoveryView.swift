import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 「曲库以外的新歌」:按曲库的风格与常听艺人让 AI 推荐还没有的真实歌曲。
/// 不提供试听,每首都能拷贝歌名去别处找来听。
struct AISongDiscoveryView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicIntelligenceService.self) private var intelligence
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    @AppStorage("primuse.ai.songDiscovery.focusGenre") private var focusGenre = ""

    @State private var history = SongDiscoveryHistory()
    @State private var genreChoices: [String] = []
    @State private var isLoading = false
    @State private var failure: AILibraryContentFailure?
    @State private var retryAt: Date?
    @State private var emptyAfterFiltering = false
    @State private var copiedID: String?
    @State private var copiedAll = false
    @State private var requestTask: Task<Void, Never>?

    private static let ignoredArtistNames = [
        "Unknown Artist", "Various Artists", "Various", "VA", "群星", "未知艺术家", "未知歌手",
    ]

    private var focus: String? { focusGenre.isEmpty ? nil : focusGenre }
    private var batch: SongDiscoveryHistory.Batch? { history.batch(for: focus) }
    private var suggestions: [SongDiscoverySuggestion] { batch?.suggestions ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                genreChips
                actionRow
                statusPanel
                suggestionList
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        .background(PMColor.bg)
        #else
        .navigationTitle("ai_song_discovery_title")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            history = SongDiscoveryHistory.decode(
                UserDefaults.standard.data(forKey: SongDiscoveryHistory.storageKey)
            )
        }
        .task(id: library.visibleSongCollectionRevision) {
            await loadGenreChoices()
        }
        .task(id: retryAt) {
            guard let retryAt else { return }
            try? await Task.sleep(for: .seconds(max(0, retryAt.timeIntervalSinceNow)))
            if !Task.isCancelled { self.retryAt = nil }
        }
        .onChange(of: focusGenre) { _, _ in
            requestTask?.cancel()
            isLoading = false
            failure = nil
            emptyAfterFiltering = false
            copiedAll = false
        }
        // 离开页面不取消:请求做完照样记进历史,下次打开就能看到。
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("ai_song_discovery_eyebrow", systemImage: "sparkles")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(accentColor)
            #if os(macOS)
            HStack(alignment: .firstTextBaseline) {
                Text("ai_song_discovery_title")
                    .font(.title2.bold())
                Spacer()
                Button("done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            #endif
            Text("ai_song_discovery_subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var genreChips: some View {
        if !genreChoices.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(title: String(localized: "ai_song_discovery_all_genres"), value: "")
                    ForEach(genreChoices, id: \.self) { genre in
                        chip(title: genre, value: genre)
                    }
                }
            }
        }
    }

    private func chip(title: String, value: String) -> some View {
        let selected = SongDiscoveryMatching.key(focusGenre) == SongDiscoveryMatching.key(value)
        return Button {
            focusGenre = value
        } label: {
            Text(verbatim: title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .background(selected ? accentColor : chipBackground, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(action: requestBatch) {
                HStack(spacing: 7) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: suggestions.isEmpty ? "sparkles" : "arrow.clockwise")
                    }
                    Text(suggestions.isEmpty
                        ? LocalizedStringKey("ai_song_discovery_request")
                        : LocalizedStringKey("ai_song_discovery_request_more"))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(accentColor, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isLoading || retryAt != nil)
            .opacity(isLoading || retryAt != nil ? 0.6 : 1)

            Spacer(minLength: 0)

            if !suggestions.isEmpty {
                Button(action: copyAll) {
                    Label(
                        copiedAll
                            ? LocalizedStringKey("ai_song_discovery_copied_all")
                            : LocalizedStringKey("ai_song_discovery_copy_all"),
                        systemImage: copiedAll ? "checkmark" : "doc.on.doc"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(chipBackground, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var statusPanel: some View {
        if let failure {
            failurePanel(failure)
        } else if emptyAfterFiltering {
            statusText(String(localized: "ai_song_discovery_all_owned"), systemImage: "checkmark.circle")
        } else if let batch {
            statusText(
                String(
                    format: String(localized: "ai_song_discovery_provider_format"),
                    batch.providerName,
                    batch.generatedAt.formatted(.relative(presentation: .named))
                ),
                systemImage: "sparkles"
            )
        }
    }

    private func statusText(_ text: String, systemImage: String) -> some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func failurePanel(_ failure: AILibraryContentFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(verbatim: failureMessage(failure))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
            .font(.subheadline)

            if let retryAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(String(
                        format: String(localized: "ai_recommendation_retry_countdown_format"),
                        max(0, Int(ceil(retryAt.timeIntervalSince(context.date))))
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            switch failure {
            case .needsConsent:
                Button("ai_song_discovery_allow_and_request") {
                    do {
                        try intelligence.grantRemoteConsent()
                        requestBatch()
                    } catch {
                        self.failure = .failed(.unavailable)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .notConfigured, .builtInNotOffered:
                if intelligence.shouldExposeRemoteConfiguration {
                    intelligenceSettingsLink
                }
            case .failed, .noTasteProfile:
                EmptyView()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var intelligenceSettingsLink: some View {
        #if os(macOS)
        Button("ai_song_discovery_open_settings") {
            SettingsWindowController.shared.show(tab: .intelligence)
        }
        .controlSize(.small)
        #else
        NavigationLink {
            AISettingsView()
                .minimalNavigationDetail()
        } label: {
            Text("ai_song_discovery_open_settings")
                .font(.subheadline.weight(.semibold))
        }
        #endif
    }

    @ViewBuilder
    private var suggestionList: some View {
        if suggestions.isEmpty {
            if !isLoading, failure == nil, !emptyAfterFiltering {
                VStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("ai_song_discovery_empty_hint")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        } else {
            LazyVStack(spacing: 10) {
                ForEach(suggestions) { suggestion in
                    suggestionRow(suggestion)
                }
            }
            .opacity(isLoading ? 0.55 : 1)
            .pmAnimation(.control, value: isLoading)
        }
    }

    private func suggestionRow(_ suggestion: SongDiscoverySuggestion) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: suggestion.title)
                    .font(.body.weight(.semibold))
                    .discoveryTextSelection()
                Text(verbatim: subtitle(for: suggestion))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .discoveryTextSelection()
                if !suggestion.reason.isEmpty {
                    Label {
                        Text(verbatim: suggestion.reason)
                    } icon: {
                        Image(systemName: "sparkles")
                    }
                    .font(.caption)
                    .foregroundStyle(accentColor)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if suggestion.artistInLibrary {
                    Text("ai_song_discovery_artist_in_library")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(chipBackground, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                copy(suggestion.copyText, id: suggestion.id)
            } label: {
                Image(systemName: copiedID == suggestion.id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 34, height: 34)
                    .background(chipBackground, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("ai_song_discovery_copy_title_artist"))
        }
        .padding(12)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            Button {
                copy(suggestion.title, id: suggestion.id)
            } label: {
                Label("ai_song_discovery_copy_title", systemImage: "doc.on.doc")
            }
            Button {
                copy(suggestion.copyText, id: suggestion.id)
            } label: {
                Label("ai_song_discovery_copy_title_artist", systemImage: "doc.on.doc.fill")
            }
        }
    }

    private func subtitle(for suggestion: SongDiscoverySuggestion) -> String {
        var parts = [suggestion.artist]
        if let album = suggestion.album { parts.append(album) }
        if let year = suggestion.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func failureMessage(_ failure: AILibraryContentFailure) -> String {
        switch failure {
        case .notConfigured:
            return String(localized: "ai_song_discovery_not_configured")
        case .needsConsent:
            return String(localized: "ai_song_discovery_needs_consent")
        case .builtInNotOffered:
            return String(localized: "ai_song_discovery_builtin_not_offered")
        case .noTasteProfile:
            return String(localized: "ai_song_discovery_no_taste")
        case .failed(let reason):
            switch reason {
            case .busy: return String(localized: "ai_song_discovery_failed_busy")
            case .minuteLimit: return String(localized: "ai_song_discovery_failed_minute_limit")
            case .dailyLimit: return String(localized: "ai_song_discovery_failed_daily_limit")
            case .regionRestricted: return String(localized: "ai_song_discovery_failed_region")
            case .network: return String(localized: "ai_song_discovery_failed_network")
            case .empty: return String(localized: "ai_song_discovery_failed_empty")
            case .unavailable, .deviceRegistration, .authentication, .upstream:
                return String(localized: "ai_song_discovery_failed_generic")
            }
        }
    }

    private func requestBatch() {
        guard !isLoading else { return }
        requestTask?.cancel()
        isLoading = true
        failure = nil
        emptyAfterFiltering = false
        copiedAll = false
        let focus = self.focus
        let songs = library.musicSongs
        let likedIDs = Set(library.songIDs(forPlaylist: MusicLibrary.likedSongsPlaylistID))
        let ignored = Self.ignoredArtistNames + [String(localized: "unknown_artist")]
        let recentlyShown = history.recentlyShown
        let languageCode = Bundle.main.preferredLocalizations.first ?? "en"
        requestTask = Task {
            defer { if !Task.isCancelled { isLoading = false } }
            let profile = await Task.detached(priority: .userInitiated) {
                var accumulator = SongDiscoveryTasteAccumulator(focusGenre: focus, ignoredArtistNames: ignored)
                for song in songs {
                    accumulator.add(
                        title: song.title,
                        artist: song.artistName,
                        genre: song.genre,
                        year: song.year,
                        isLiked: likedIDs.contains(song.id)
                    )
                }
                return (accumulator.taste(), accumulator.ownedSamples(limit: 50))
            }.value
            guard !Task.isCancelled else { return }
            guard !profile.0.isEmpty else {
                failure = .noTasteProfile
                return
            }
            let request = SongDiscoveryAIExchange.request(
                languageCode: languageCode,
                focusGenre: focus,
                taste: profile.0,
                avoid: profile.1 + recentlyShown.prefix(30)
            )
            let outcome = await intelligence.discoverSongs(request)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .failed(let failure, let retryAt):
                self.failure = failure
                self.retryAt = retryAt
            case .success(let execution):
                let filtered = await Task.detached(priority: .userInitiated) {
                    var matcher = SongDiscoveryLibraryMatcher(suggestions: execution.suggestions)
                    if !matcher.isEmpty {
                        for song in songs {
                            matcher.consider(title: song.title, artist: song.artistName)
                        }
                    }
                    return matcher.filtered(execution.suggestions)
                }.value
                guard !Task.isCancelled else { return }
                if filtered.isEmpty {
                    emptyAfterFiltering = !execution.suggestions.isEmpty
                    if execution.suggestions.isEmpty { failure = .failed(.empty) }
                    return
                }
                history.record(SongDiscoveryHistory.Batch(
                    focusGenre: focus,
                    generatedAt: Date(),
                    providerName: execution.providerName,
                    suggestions: filtered
                ))
                UserDefaults.standard.set(history.encoded(), forKey: SongDiscoveryHistory.storageKey)
            }
        }
    }

    private func loadGenreChoices() async {
        let songs = library.musicSongs
        let genres = await Task.detached(priority: .utility) {
            var accumulator = SongDiscoveryTasteAccumulator()
            for song in songs {
                accumulator.add(title: "", artist: nil, genre: song.genre, year: nil, isLiked: false)
            }
            return accumulator.taste(maxGenres: 10).genres.map(\.name)
        }.value
        guard !Task.isCancelled else { return }
        genreChoices = genres
        // 选过的风格从曲库里消失了就回到「全部风格」。
        if !focusGenre.isEmpty,
           !genres.contains(where: { SongDiscoveryMatching.key($0) == SongDiscoveryMatching.key(focusGenre) }) {
            focusGenre = ""
        }
    }

    private func copy(_ text: String, id: String) {
        Self.copyToPasteboard(text)
        copiedID = id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedID == id { copiedID = nil }
        }
    }

    private func copyAll() {
        Self.copyToPasteboard(suggestions.map(\.copyText).joined(separator: "\n"))
        copiedAll = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedAll = false
        }
    }

    private static func copyToPasteboard(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }

    // MARK: - Style

    #if os(macOS)
    private var horizontalPadding: CGFloat { PMSpace.xxxl }
    private var accentColor: Color { PMColor.brand }
    private var cardBackground: Color { PMColor.bgElev }
    private var chipBackground: Color { PMColor.glassBtn }
    #else
    private var horizontalPadding: CGFloat { 20 }
    private var accentColor: Color { .accentColor }
    private var cardBackground: Color { Color.secondary.opacity(0.075) }
    private var chipBackground: Color { Color.secondary.opacity(0.09) }
    #endif
}

private extension View {
    /// Mac 上可以拖选文字;iPhone 上长按留给拷贝菜单,不再叠一层系统选择。
    @ViewBuilder
    func discoveryTextSelection() -> some View {
        #if os(macOS)
        textSelection(.enabled)
        #else
        self
        #endif
    }
}
