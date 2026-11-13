import ImageIO
import PhotosUI
import PrimuseKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The songs a batch sheet works on. Identifiable so a page can present the
/// sheet with `.sheet(item:)` and the list is fixed for its lifetime.
struct BatchSongSelection: Identifiable {
    let id = UUID()
    let songs: [Song]
}

extension BatchSongSelection {
    /// Every song a library-wide tidy-up can write to; Apple Music's own
    /// library entries are not the listener's files.
    @MainActor
    static func wholeLibraryForTidy(_ library: MusicLibrary) -> BatchSongSelection {
        BatchSongSelection(songs: library.songs.filter {
            $0.sourceID != AppleMusicLibraryService.systemSourceID
        })
    }
}

// MARK: - Batch edit

/// Sets the same values on many songs: an album, an artist, a genre, a
/// year, a disc number, one cover for all of them, or track numbers in the
/// order the songs were selected. Only fields switched on are touched.
/// Nothing is written from here — "Review" lists every resulting change
/// first, and only what is left ticked there is applied.
struct BatchTagEditorView: View {
    let songs: [Song]
    var onFinished: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    private enum EditableField: String, CaseIterable, Identifiable {
        case title, artist, album, genre, year, disc
        var id: String { rawValue }

        var cleanupField: TagCleanupField {
            switch self {
            case .title: .title
            case .artist: .artist
            case .album: .album
            case .genre: .genre
            case .year: .year
            case .disc: .discNumber
            }
        }

        var titleKey: LocalizedStringKey {
            switch self {
            case .title: "tag_editor_title"
            case .artist: "tag_editor_artist"
            case .album: "tag_editor_album"
            case .genre: "tag_editor_genre"
            case .year: "tag_editor_year"
            case .disc: "tag_editor_disc"
            }
        }

        var isNumeric: Bool { self == .year || self == .disc }
    }

    @State private var enabled: Set<EditableField> = []
    @State private var values: [EditableField: String] = [:]
    @State private var renumberTracks = false
    @State private var firstTrackNumber = 1
    @State private var coverItem: PhotosPickerItem?
    @State private var coverData: Data?
    @State private var coverLoadFailed = false
    @State private var isLoadingCover = false
    @State private var review: TagChangeReviewInput?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(EditableField.allCases) { field in
                        fieldRow(field)
                    }
                } header: {
                    Text(String(format: String(localized: "batch_edit_songs_count_format"), songs.count))
                } footer: {
                    Text("batch_edit_fields_footer")
                }

                Section {
                    Toggle("batch_edit_renumber_tracks", isOn: $renumberTracks)
                    if renumberTracks {
                        Stepper(value: $firstTrackNumber, in: 1...999) {
                            Text(String(format: String(localized: "batch_edit_first_track_format"), firstTrackNumber))
                        }
                    }
                } footer: {
                    Text("batch_edit_renumber_footer")
                }

                Section {
                    // The picker's label closure is not main-actor isolated;
                    // hand it a value rather than reading view state inside.
                    let currentCover = coverData
                    PhotosPicker(selection: $coverItem, matching: .images, preferredItemEncoding: .current) {
                        BatchCoverPickerLabel(coverData: currentCover)
                    }
                    .buttonStyle(.plain)
                    if coverData != nil {
                        Button("batch_edit_remove_cover_choice", role: .destructive) {
                            coverItem = nil
                            coverData = nil
                        }
                    }
                } header: {
                    Text("batch_edit_cover_section")
                } footer: {
                    Text("batch_edit_cover_footer")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("batch_edit_title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("batch_edit_review") { review = makeReview() }
                        .disabled(!hasAnyChange || isLoadingCover)
                }
            }
            .navigationDestination(item: $review) { input in
                TagChangeReviewView(input: input) {
                    onFinished()
                    dismiss()
                }
            }
            .task(id: coverItem) {
                guard let coverItem else { isLoadingCover = false; return }
                isLoadingCover = true
                let loaded = await BatchCoverImage.load(coverItem)
                guard !Task.isCancelled else { return }
                isLoadingCover = false
                if let loaded { coverData = loaded }
                else { coverLoadFailed = true }
            }
            .alert(String(localized: "artwork_invalid_image"), isPresented: $coverLoadFailed) {
                Button(String(localized: "ok"), role: .cancel) {}
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    @ViewBuilder
    private func fieldRow(_ field: EditableField) -> some View {
        let isOn = Binding(
            get: { enabled.contains(field) },
            set: { on in
                if on {
                    enabled.insert(field)
                    if values[field] == nil { values[field] = commonValue(field) ?? "" }
                } else {
                    enabled.remove(field)
                }
            }
        )
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.titleKey)
                    if !enabled.contains(field) {
                        Text(currentSummary(field))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if enabled.contains(field) {
                SwiftUI.TextField(
                    field == .title ? String(localized: "tag_editor_title") : String(localized: "batch_edit_empty_clears"),
                    text: Binding(get: { values[field] ?? "" }, set: { values[field] = $0 })
                )
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .keyboardType(field.isNumeric ? .numberPad : .default)
                #endif
            }
        }
    }

    private var hasAnyChange: Bool {
        if renumberTracks || coverData != nil || !enabled.subtracting([.title]).isEmpty { return true }
        let title = (values[.title] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return enabled.contains(.title) && !title.isEmpty && songs.contains { $0.title != title }
    }

    private func currentValues(_ field: EditableField) -> [String] {
        songs.map { BatchTagEditService.cleanupSong($0).value(of: field.cleanupField) ?? "" }
    }

    private func commonValue(_ field: EditableField) -> String? {
        let all = Set(currentValues(field))
        return all.count == 1 ? all.first : nil
    }

    private func currentSummary(_ field: EditableField) -> String {
        let distinct = Set(currentValues(field))
        if distinct.count > 1 {
            return String(format: String(localized: "batch_edit_mixed_values_format"), distinct.count)
        }
        let only = distinct.first ?? ""
        return only.isEmpty ? String(localized: "batch_edit_value_empty") : only
    }

    private func makeReview() -> TagChangeReviewInput {
        var proposals: [TagCleanupProposal] = []
        for (index, song) in songs.enumerated() {
            let current = BatchTagEditService.cleanupSong(song)
            for field in enabled {
                let raw = (values[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if field == .title, raw.isEmpty { continue }
                var newValue: String? = raw.isEmpty ? nil : raw
                if field.isNumeric, let text = newValue {
                    guard let number = Int(text), number > 0 else { continue }
                    newValue = String(number)
                }
                let old = current.value(of: field.cleanupField)
                guard old != newValue else { continue }
                proposals.append(TagCleanupProposal(
                    songID: song.id, field: field.cleanupField,
                    oldValue: old, newValue: newValue, reason: .assistant
                ))
            }
            if renumberTracks {
                let number = String(firstTrackNumber + index)
                let old = current.value(of: .trackNumber)
                if old != number {
                    proposals.append(TagCleanupProposal(
                        songID: song.id, field: .trackNumber,
                        oldValue: old, newValue: number, reason: .assistant
                    ))
                }
            }
        }
        return TagChangeReviewInput(
            songs: songs,
            proposals: proposals,
            coverData: coverData,
            showsReasons: false
        )
    }
}

private struct BatchCoverPickerLabel: View {
    let coverData: Data?

    var body: some View {
        HStack(spacing: 12) {
            if let coverData, let image = BatchCoverImage.image(from: coverData) {
                UploadedArtworkAnimation(previewData: coverData, presentationRole: .animatedHero) {
                    image.resizable().aspectRatio(contentMode: .fill)
                }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 48, height: 48)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
            if coverData == nil {
                Text("batch_edit_pick_cover")
            } else {
                Text("batch_edit_replace_cover")
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Tidy up

/// Finds what could be tidied in the selected songs' tags — junk around
/// names, track numbers stuck in titles, one album spelled three ways — and,
/// when an AI service is set up and the listener asks for it, what that
/// service suggests on top. Every suggestion is shown for review before
/// anything is written; the listener's own naming is never changed without
/// being seen first.
struct TagTidyView: View {
    let songs: [Song]
    /// Opened from settings over the whole library rather than a selection:
    /// the counts say how much was checked, and the AI service only sees the
    /// songs the rules flagged.
    var isLibraryWide = false
    var onFinished: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(MusicIntelligenceService.self) private var intelligence

    @State private var localProposals: [TagCleanupProposal] = []
    @State private var builtInConsent: BuiltInAIConsentRequest?
    @State private var aiProposals: [TagCleanupProposal] = []
    @State private var aiProgress: (done: Int, total: Int)?
    @State private var aiStatus: String?
    @State private var aiTask: Task<Void, Never>?
    @State private var review: TagChangeReviewInput?
    @State private var isCheckingLocally = true

    /// What goes to the AI service. A selection goes whole; the library goes
    /// as the songs the rules changed or could not settle, so the request
    /// budget is spent where the tags look wrong. Filled once the local
    /// check has finished.
    @State private var aiCandidates: [Song] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isLibraryWide {
                        LabeledContent("tag_tidy_library_checked") {
                            Text("\(songs.count)").monospacedDigit()
                        }
                    }
                    LabeledContent("tag_tidy_local_found") {
                        if isCheckingLocally {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("\(localProposals.count)")
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    Text("tag_tidy_local_footer")
                }

                Section {
                    NavigationLink("artist_merge_suggestions") { ArtistMergeSuggestionsView() }
                }

                Section {
                    if intelligence.isTagCleanupAvailable {
                        if let aiProgress {
                            HStack(spacing: 10) {
                                ProgressView(value: Double(aiProgress.done), total: Double(max(1, aiProgress.total)))
                                Text("\(aiProgress.done)/\(aiProgress.total)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if aiTask != nil {
                                Button("cancel", role: .cancel) {
                                    aiTask?.cancel()
                                    aiTask = nil
                                }
                            }
                        } else {
                            Button {
                                startAI()
                            } label: {
                                Label(String(localized: "tag_tidy_ask_ai"), systemImage: "sparkles")
                            }
                            .disabled(isCheckingLocally || aiCandidates.isEmpty)
                        }
                        if !aiProposals.isEmpty || aiStatus != nil {
                            LabeledContent("tag_tidy_ai_found") {
                                Text("\(aiProposals.count)").monospacedDigit()
                            }
                        }
                        if let aiStatus {
                            Text(aiStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if intelligence.tagCleanupNeedsRemoteConsent {
                        // A service is ready; only the permission to send is
                        // off. Say so here and turn it on in one tap.
                        Text("tag_tidy_ai_consent_needed")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button {
                            allowRemoteConsentAndStartAI()
                        } label: {
                            Label(String(localized: "tag_tidy_ai_allow_consent"), systemImage: "checkmark.shield")
                        }
                        .disabled(isCheckingLocally || aiCandidates.isEmpty)
                        if let aiStatus {
                            Text(aiStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("tag_tidy_ai_unavailable")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("tag_tidy_ai_section")
                } footer: {
                    if intelligence.isTagCleanupAvailable || intelligence.tagCleanupNeedsRemoteConsent,
                       !isCheckingLocally {
                        Text(String(
                            format: String(localized: "tag_tidy_ai_footer_format"),
                            min(aiCandidates.count, TagCleanupAIExchange.maximumSongs)
                        ))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("tag_tidy_title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") {
                        aiTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("batch_edit_review") {
                        // An exact decoding of garbled text beats a guess;
                        // otherwise the AI service, which saw the whole
                        // list, wins and the rules fill in what it left.
                        let proposals = TagCleanupPolicy.reviewProposals(ai: aiProposals, local: localProposals)
                        let changedIDs = Set(proposals.map(\.songID))
                        review = TagChangeReviewInput(
                            // Only the songs with something to review: the
                            // review list is grouped per song it is given.
                            songs: songs.filter { changedIDs.contains($0.id) },
                            proposals: proposals,
                            coverData: nil,
                            showsReasons: true
                        )
                    }
                    .disabled(localProposals.isEmpty && aiProposals.isEmpty || aiTask != nil)
                }
            }
            .navigationDestination(item: $review) { input in
                TagChangeReviewView(input: input) {
                    onFinished()
                    dismiss()
                }
            }
            .task {
                let year = Calendar.current.component(.year, from: Date())
                let cleanupSongs = songs.map(BatchTagEditService.cleanupSong)
                // A whole library is tens of thousands of rows; keep the
                // string work off the main thread.
                let (proposals, attention) = await Task.detached(priority: .userInitiated) {
                    (
                        TagCleanupPolicy.proposals(for: cleanupSongs, currentYear: year),
                        Set(cleanupSongs.lazy.filter(TagCleanupPolicy.needsAttention).map(\.id))
                    )
                }.value
                guard !Task.isCancelled else { return }
                localProposals = proposals
                if isLibraryWide || songs.count > TagCleanupAIExchange.maximumSongs {
                    let flagged = attention.union(proposals.map(\.songID))
                    aiCandidates = songs.filter { flagged.contains($0.id) }
                } else {
                    aiCandidates = songs
                }
                isCheckingLocally = false
            }
            .onDisappear { aiTask?.cancel() }
            .builtInAIConsentSheet($builtInConsent)
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    private func allowRemoteConsentAndStartAI() {
        // 要交给内置 AI 而还没同意:先弹同意页,同意页会一并打开发送内容的授权。
        if intelligence.needsBuiltInConsent(for: .tagCleanup) {
            builtInConsent = BuiltInAIConsentRequest {
                guard intelligence.isTagCleanupAvailable else { return }
                startAI()
            }
            return
        }
        do {
            try intelligence.grantRemoteConsent()
        } catch {
            aiStatus = String(localized: "tag_tidy_ai_consent_failed")
            return
        }
        guard intelligence.isTagCleanupAvailable else { return }
        startAI()
    }

    private func startAI() {
        aiStatus = nil
        aiProposals = []
        // Songs of one album travel together so the service sees the
        // spellings it is asked to unify side by side.
        let ordered = aiCandidates.sorted {
            ($0.albumTitle ?? "", $0.discNumber ?? 0, $0.trackNumber ?? 0)
                < ($1.albumTitle ?? "", $1.discNumber ?? 0, $1.trackNumber ?? 0)
        }.map(BatchTagEditService.cleanupSong)
        aiTask = Task {
            let result = await intelligence.tagCleanupProposals(for: ordered) { done, total in
                aiProgress = (done, total)
            }
            guard !Task.isCancelled else {
                aiProgress = nil
                return
            }
            aiProposals = result.proposals
            if result.primuseRelayStopped, result.failedBatches > 0 {
                aiStatus = String(
                    format: String(localized: "tag_tidy_ai_relay_stopped_format"),
                    result.failedBatches
                )
            } else if result.failedBatches > 0 {
                aiStatus = String(
                    format: String(localized: "tag_tidy_ai_partial_format"),
                    result.failedBatches
                )
            } else if let provider = result.providerName {
                aiStatus = String(format: String(localized: "tag_tidy_ai_done_format"), provider)
            }
            aiProgress = nil
            aiTask = nil
        }
    }
}

// MARK: - Review

struct TagChangeReviewInput: Identifiable, Hashable {
    let id = UUID()
    let songs: [Song]
    let proposals: [TagCleanupProposal]
    let coverData: Data?
    /// Tidy-up shows why each change is suggested; a plain batch edit does
    /// not need to explain the listener's own input back to them.
    let showsReasons: Bool

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The confirmation step: every proposed change, grouped by song, each with
/// its own switch. Applying writes only the switched-on changes, then offers
/// to undo them.
struct TagChangeReviewView: View {
    let input: TagChangeReviewInput
    let onFinished: () -> Void

    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(AudioPlayerService.self) private var player

    @State private var excluded: Set<String> = []
    @State private var appliesCover = true
    @State private var progress: (done: Int, total: Int)?
    @State private var outcome: BatchTagEditService.Outcome?
    @State private var isUndoing = false
    @State private var didUndo = false
    @State private var isRetrying = false
    /// Songs the retries on this screen have written to their files.
    @State private var rewrittenCount = 0

    private struct SongGroup: Identifiable {
        let song: Song
        let proposals: [TagCleanupProposal]
        var id: String { song.id }
    }

    private var groups: [SongGroup] {
        let byID = Dictionary(grouping: input.proposals, by: \.songID)
        return input.songs.compactMap { song in
            guard let proposals = byID[song.id], !proposals.isEmpty else { return nil }
            return SongGroup(
                song: song,
                proposals: proposals.sorted { $0.field.sortOrder < $1.field.sortOrder }
            )
        }
    }

    private var selectedProposals: [TagCleanupProposal] {
        input.proposals.filter { !excluded.contains($0.id) }
    }

    private var selectedCount: Int {
        selectedProposals.count + (input.coverData != nil && appliesCover ? input.songs.count : 0)
    }

    var body: some View {
        Group {
            if let outcome {
                resultView(outcome)
            } else {
                reviewList
            }
        }
        .navigationTitle(outcome == nil
            ? String(localized: "tag_review_title")
            : String(localized: "tag_review_done_title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationBarBackButtonHidden(progress != nil || outcome != nil)
        .interactiveDismissDisabled(progress != nil)
    }

    private var reviewList: some View {
        List {
            Section {
                HStack {
                    Text(String(format: String(localized: "tag_review_selected_format"), selectedCount))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !input.proposals.isEmpty {
                        Button {
                            excluded = excluded.isEmpty ? Set(input.proposals.map(\.id)) : []
                        } label: {
                            if excluded.isEmpty {
                                Text("tag_review_select_none")
                            } else {
                                Text("tag_review_select_all")
                            }
                        }
                        .font(.subheadline)
                    }
                }
                // One row, so an empty note leaves no blank row behind.
                VStack(alignment: .leading, spacing: 6) {
                    Text("tag_review_footer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TagWritebackPreflightNote(songIDs: input.songs.map(\.id))
                }
            }

            if let coverData = input.coverData {
                Section("batch_edit_cover_section") {
                    Toggle(isOn: $appliesCover) {
                        HStack(spacing: 12) {
                            if let image = BatchCoverImage.image(from: coverData) {
                                UploadedArtworkAnimation(previewData: coverData, presentationRole: .animatedHero) {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                }
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            Text(String(
                                format: String(localized: "tag_review_cover_format"),
                                input.songs.count
                            ))
                        }
                    }
                }
            }

            if groups.isEmpty, input.coverData == nil {
                Text("tag_review_nothing")
                    .foregroundStyle(.secondary)
            }

            ForEach(groups) { group in
                Section {
                    ForEach(group.proposals) { proposal in
                        proposalRow(proposal)
                    }
                } header: {
                    Text(group.song.title)
                        .lineLimit(1)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            applyBar
        }
    }

    private var applyBar: some View {
        VStack(spacing: 8) {
            if let progress {
                ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                Text(String(
                    format: String(localized: "tag_review_progress_format"),
                    progress.done,
                    progress.total
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await apply() }
                } label: {
                    Text(String(format: String(localized: "tag_review_apply_format"), selectedCount))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .prominentLabelOnAccent()
                .disabled(selectedCount == 0)
            }
        }
        .padding()
        .background(.bar)
    }

    private func proposalRow(_ proposal: TagCleanupProposal) -> some View {
        let isOn = Binding(
            get: { !excluded.contains(proposal.id) },
            set: { on in
                if on { excluded.remove(proposal.id) } else { excluded.insert(proposal.id) }
            }
        )
        return Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(proposal.field.titleKey)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(proposal.oldValue ?? String(localized: "batch_edit_value_empty"))
                        .strikethrough(proposal.oldValue != nil)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(proposal.newValue ?? String(localized: "batch_edit_value_cleared"))
                        .foregroundStyle(proposal.newValue == nil ? .secondary : .primary)
                        .lineLimit(2)
                }
                .font(.body)
                if input.showsReasons, let reason = proposal.reasonText {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private func resultView(_ outcome: BatchTagEditService.Outcome) -> some View {
        List {
            Section {
                Label(
                    String(format: String(localized: "tag_review_applied_format"), outcome.applied.count),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                if didUndo {
                    Label(String(localized: "tag_review_undone"), systemImage: "arrow.uturn.backward.circle")
                }
            }
            if !outcome.failures.isEmpty {
                Section("tag_review_failures_section") {
                    ForEach(outcome.failures) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.title).lineLimit(1)
                            Text(failure.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            // After an undo the library and the files agree on the old
            // values again; there is nothing left to write.
            if !didUndo {
                BatchWritebackIssuesSection(
                    entries: outcome.localOnlyWrites,
                    rewrittenCount: rewrittenCount,
                    isRetrying: isRetrying,
                    isDisabled: isUndoing || progress != nil
                ) {
                    Task { await retryWrites() }
                }
            }
            // Notes for songs listed above are shown there as the reason.
            let otherNotices = outcome.noticesOutsideLocalOnly
            if !otherNotices.isEmpty {
                Section("tag_editor_writeback_notice_title") {
                    ForEach(Array(otherNotices.enumerated()), id: \.offset) { _, notice in
                        Text(notice).font(.caption)
                    }
                }
            }
            if !outcome.coverChanged, !outcome.applied.isEmpty, !didUndo {
                Section {
                    Button {
                        Task { await undo(outcome) }
                    } label: {
                        Label(String(localized: "tag_review_undo"), systemImage: "arrow.uturn.backward")
                    }
                    .disabled(isUndoing || isRetrying || progress != nil)
                } footer: {
                    Text("tag_review_undo_footer")
                }
            }
            if let progress {
                Section {
                    ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("done") { onFinished() }
                    .disabled(progress != nil)
            }
        }
    }

    private func apply() async {
        let chosen = selectedProposals
        let changes = input.songs.compactMap { song -> (original: Song, updated: Song)? in
            let current = library.song(id: song.id) ?? song
            let updated = BatchTagEditService.song(current, applying: chosen)
            let coverApplies = input.coverData != nil && appliesCover
            guard coverApplies || SongUserMetadataPolicy.editableFieldsChanged(from: current, to: updated) else {
                return nil
            }
            return (current, updated)
        }
        progress = (0, changes.count)
        let result = await BatchTagEditService.apply(
            changes,
            coverData: appliesCover ? input.coverData : nil,
            sourceManager: sourceManager,
            library: library,
            player: player
        ) { done, total in
            progress = (done, total)
        }
        progress = nil
        outcome = result
    }

    /// Writes the values the songs had before, through the same path.
    private func undo(_ outcome: BatchTagEditService.Outcome) async {
        isUndoing = true
        defer { isUndoing = false }
        let changes = zip(outcome.applied, outcome.originals).map { applied, original in
            var restored = library.storedSong(id: applied.id) ?? applied
            restored.title = original.title
            restored.artistName = original.artistName
            restored.sourceArtistNames = original.sourceArtistNames
            restored.albumTitle = original.albumTitle
            restored.albumArtistName = original.albumArtistName
            restored.genre = original.genre
            restored.year = original.year
            restored.trackNumber = original.trackNumber
            restored.discNumber = original.discNumber
            return (original: library.song(id: applied.id) ?? applied, updated: restored)
        }
        progress = (0, changes.count)
        let result = await BatchTagEditService.apply(
            changes,
            coverData: nil,
            sourceManager: sourceManager,
            library: library,
            player: player
        ) { done, total in
            progress = (done, total)
        }
        progress = nil
        didUndo = true
        var merged = outcome
        merged.failures += result.failures
        self.outcome = merged
    }

    /// Writes the songs kept only in Primuse to their files again. Undo
    /// still restores what this batch changed: the retry adds no undo
    /// targets and does not count the songs a second time.
    private func retryWrites() async {
        guard !isRetrying, !isUndoing, progress == nil,
              let entries = outcome?.localOnlyWrites.filter(\.canRetry), !entries.isEmpty else { return }
        isRetrying = true
        defer { isRetrying = false }
        progress = (0, entries.count)
        let result = await BatchTagEditService.retryLocalOnlyWrites(
            entries,
            sourceManager: sourceManager,
            library: library,
            player: player
        ) { done, total in
            progress = (done, total)
        }
        progress = nil
        guard var merged = outcome else { return }
        rewrittenCount += merged.mergeRetry(result)
        outcome = merged
    }
}

// MARK: - Write-back issues

/// The songs of a batch whose change was kept only in Primuse because the
/// file could not be written: which song, which source and file, and why.
/// Shared by the batch editor's result and the artist merge result; place
/// it inside a Form or List.
struct BatchWritebackIssuesSection: View {
    let entries: [BatchTagEditService.LocalOnlyWrite]
    /// Songs written to their files by retries on this screen so far.
    var rewrittenCount = 0
    var isRetrying = false
    /// Something else is writing the same songs (undo, the batch itself).
    var isDisabled = false
    var footer: LocalizedStringKey = "batch_writeback_local_only_footer"
    let onRetry: () -> Void

    @Environment(SourcesStore.self) private var sourcesStore: SourcesStore?
    @State private var copied = false
    @State private var copiedResetTask: Task<Void, Never>?

    var body: some View {
        if !entries.isEmpty {
            Section {
                if rewrittenCount > 0 { rewrittenRow }
                ForEach(entries) { entry in
                    row(entry)
                }
                if entries.contains(where: \.canRetry) {
                    Button(action: onRetry) {
                        if isRetrying {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("batch_writeback_retrying")
                            }
                        } else {
                            Label(String(localized: "batch_writeback_retry"), systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isRetrying || isDisabled)
                }
                Button(action: copyList) {
                    if copied {
                        Label(String(localized: "batch_writeback_copied"), systemImage: "checkmark")
                    } else {
                        Label(String(localized: "batch_writeback_copy_list"), systemImage: "doc.on.doc")
                    }
                }
            } header: {
                Text(String(format: String(localized: "batch_writeback_local_only_header_format"), entries.count))
            } footer: {
                Text(footer)
            }
        } else if rewrittenCount > 0 {
            // Every song went through on a retry; say so rather than let
            // the list vanish without a word.
            Section { rewrittenRow }
        }
    }

    private var rewrittenRow: some View {
        Label(
            String(format: String(localized: "batch_writeback_retry_written_format"), rewrittenCount),
            systemImage: "checkmark.circle.fill"
        )
        .foregroundStyle(.green)
    }

    private func row(_ entry: BatchTagEditService.LocalOnlyWrite) -> some View {
        let place = location(of: entry)
        return VStack(alignment: .leading, spacing: 3) {
            Text(entry.title)
                .lineLimit(1)
            Text(place)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .writebackIssueTextSelection()
                .help(place)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(reason(of: entry))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .font(.caption)
        }
        .accessibilityElement(children: .combine)
    }

    private func sourceName(of entry: BatchTagEditService.LocalOnlyWrite) -> String? {
        guard let name = sourcesStore?.source(id: entry.sourceID)?.name, !name.isEmpty else { return nil }
        return name
    }

    private func location(of entry: BatchTagEditService.LocalOnlyWrite) -> String {
        [sourceName(of: entry), entry.filePath.isEmpty ? nil : entry.filePath]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func reason(of entry: BatchTagEditService.LocalOnlyWrite) -> String {
        if let reason = entry.reason, !reason.isEmpty { return reason }
        return String(localized: "metadata_writeback_error_unsupported")
    }

    /// One line per song, tab-separated: title, source, path, reason.
    private func copyList() {
        let text = entries.map { entry -> String in
            let columns: [String] = [entry.title, sourceName(of: entry) ?? "", entry.filePath, reason(of: entry)]
            return columns
                .map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t")
        }
        .joined(separator: "\n")
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
        copiedResetTask?.cancel()
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

private extension View {
    /// On the Mac the path can be selected and copied. On iPhone a long press
    /// would fight the row; the Copy List button covers it there.
    @ViewBuilder
    func writebackIssueTextSelection() -> some View {
        #if os(macOS)
        textSelection(.enabled)
        #else
        self
        #endif
    }
}

// MARK: - Helpers

extension TagCleanupField {
    var titleKey: LocalizedStringKey {
        switch self {
        case .title: "tag_editor_title"
        case .artist: "tag_editor_artist"
        case .albumArtist: "album_metadata_album_artist"
        case .album: "tag_editor_album"
        case .genre: "tag_editor_genre"
        case .year: "tag_editor_year"
        case .trackNumber: "tag_editor_track"
        case .discNumber: "tag_editor_disc"
        }
    }

    var sortOrder: Int {
        switch self {
        case .title: 0
        case .artist: 1
        case .albumArtist: 7
        case .album: 2
        case .genre: 3
        case .year: 4
        case .trackNumber: 5
        case .discNumber: 6
        }
    }
}

extension TagCleanupProposal {
    /// The explanation shown under a tidy-up suggestion.
    var reasonText: String? {
        if let note, !note.isEmpty { return note }
        switch reason {
        case .whitespace: return String(localized: "tag_reason_whitespace")
        case .advertisement: return String(localized: "tag_reason_advertisement")
        case .placeholder: return String(localized: "tag_reason_placeholder")
        case .trackPrefix: return String(localized: "tag_reason_track_prefix")
        case .artistInTitle: return String(localized: "tag_reason_artist_in_title")
        case .unifiedSpelling: return String(localized: "tag_reason_unified_spelling")
        case .invalidYear: return String(localized: "tag_reason_invalid_year")
        case .trackFromFileName: return String(localized: "tag_reason_track_from_file")
        case .titleFromFileName: return String(localized: "tag_reason_title_from_file")
        case .copyCounter: return String(localized: "tag_reason_copy_counter")
        case .encodingRepair: return String(localized: "tag_reason_encoding_repair")
        case .assistant: return nil
        }
    }
}

/// Uses the same bounded static image or original animation as the single-song editor.
enum BatchCoverImage {
    static func load(_ item: PhotosPickerItem?) async -> Data? {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            LibraryArtworkImageProcessor.processUpload(data)
        }.value
    }

    static func scaled(_ data: Data, maxPixelSize: Int = 1024) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func image(from data: Data) -> Image? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 160,
              ] as CFDictionary) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}


// MARK: - Pending write-back list

/// Every tag edit still kept only in Primuse that could reach its file:
/// from batch edits, artist merges and refused single edits, across
/// launches. Written again on its own once the source is reachable; here the
/// listener can see which files, retry now, or stop writing them.
struct PendingTagWritebackView: View {
    /// Shown in a sheet (Mac settings), which needs its own Done button.
    var showsDoneButton = false

    @Environment(\.dismiss) private var dismiss
    @Environment(MusicLibrary.self) private var library
    @State private var showsClearConfirmation = false
    private var store: PendingTagWritebackStore { .shared }

    var body: some View {
        let writes = store.localOnlyWrites(in: library)
        List {
            BatchWritebackIssuesSection(
                entries: writes,
                rewrittenCount: store.rewrittenCount,
                isRetrying: store.isRetrying,
                isDisabled: ArtistMergeService.shared.isRunning,
                footer: "pending_writeback_footer"
            ) {
                Task { await store.retry() }
            }
            if writes.isEmpty {
                Section {
                    Text("pending_writeback_empty")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Button(role: .destructive) {
                        showsClearConfirmation = true
                    } label: {
                        Label(String(localized: "pending_writeback_clear"), systemImage: "trash")
                    }
                    .disabled(store.isRetrying)
                    .confirmationDialog(
                        "pending_writeback_clear",
                        isPresented: $showsClearConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("pending_writeback_clear", role: .destructive) { store.removeAll() }
                        Button("cancel", role: .cancel) {}
                    } message: {
                        Text("pending_writeback_clear_message")
                    }
                }
            }
        }
        .navigationTitle("pending_writeback_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
        }
        // Drops what no longer needs writing (an undo, a song removed).
        .task { store.dropFinished() }
    }
}

/// Says before a batch edit starts which of its songs will keep the change
/// only in Primuse: songs whose source or format takes no tags in the file,
/// and sources that refused to write last time. Shows nothing otherwise.
struct TagWritebackPreflightNote: View {
    let songIDs: [String]

    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore: SourcesStore?
    @State private var unsupportedCount = 0
    @State private var refusedSourceNames: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if unsupportedCount > 0 {
                line(String(format: String(localized: "writeback_preflight_unsupported_format"), unsupportedCount))
            }
            if !refusedSourceNames.isEmpty {
                line(String(
                    format: String(localized: "writeback_preflight_refused_format"),
                    ListFormatter.localizedString(byJoining: refusedSourceNames)
                ))
            }
        }
        .task(id: songIDs) { evaluate() }
    }

    private func line(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }

    private func evaluate() {
        guard let sourcesStore else { return }
        var unsupported = 0
        var sourceIDs: Set<String> = []
        for id in songIDs {
            guard let song = library.storedSong(id: id) ?? library.song(id: id),
                  let source = sourcesStore.source(id: song.sourceID) else { continue }
            if AudioMetadataWritebackPolicy.textTagsLeaveLibrary(
                sourceType: source.type,
                format: song.fileFormat,
                isCueTrack: song.isCueTrack,
                isStreamDescriptor: song.isStreamDescriptor
            ) {
                sourceIDs.insert(song.sourceID)
            } else {
                unsupported += 1
            }
        }
        unsupportedCount = unsupported
        refusedSourceNames = SourceWriteRefusalMemory.recentlyRefused(among: sourceIDs)
            .compactMap { sourcesStore.source(id: $0)?.name }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
