import ImageIO
import PhotosUI
import PrimuseKit
import SwiftUI
import UniformTypeIdentifiers

/// The songs a batch sheet works on. Identifiable so a page can present the
/// sheet with `.sheet(item:)` and the list is fixed for its lifetime.
struct BatchSongSelection: Identifiable {
    let id = UUID()
    let songs: [Song]
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
        case artist, album, genre, year, disc
        var id: String { rawValue }

        var cleanupField: TagCleanupField {
            switch self {
            case .artist: .artist
            case .album: .album
            case .genre: .genre
            case .year: .year
            case .disc: .discNumber
            }
        }

        var titleKey: LocalizedStringKey {
            switch self {
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
                    PhotosPicker(selection: $coverItem, matching: .images) {
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
                        .disabled(!hasAnyChange)
                }
            }
            .navigationDestination(item: $review) { input in
                TagChangeReviewView(input: input) {
                    onFinished()
                    dismiss()
                }
            }
            .onChange(of: coverItem) { _, item in
                Task { coverData = await BatchCoverImage.load(item) }
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
                    String(localized: "batch_edit_empty_clears"),
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
        !enabled.isEmpty || renumberTracks || coverData != nil
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
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
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
                    } else {
                        Text("tag_tidy_ai_unavailable")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("tag_tidy_ai_section")
                } footer: {
                    if intelligence.isTagCleanupAvailable, !isCheckingLocally {
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
                        let proposals = TagCleanupPolicy.merging(aiProposals, localProposals)
                        let changedIDs = Set(proposals.map(\.songID))
                        review = TagChangeReviewInput(
                            // Only the songs with something to review: the
                            // review list is grouped per song it is given.
                            songs: songs.filter { changedIDs.contains($0.id) },
                            // What the AI service suggested wins over the
                            // mechanical rule for the same field: it saw the
                            // whole list. The rules fill in what it left.
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
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
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
            if result.failedBatches > 0 {
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
                Text("tag_review_footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let coverData = input.coverData {
                Section("batch_edit_cover_section") {
                    Toggle(isOn: $appliesCover) {
                        HStack(spacing: 12) {
                            if let image = BatchCoverImage.image(from: coverData) {
                                image.resizable().aspectRatio(contentMode: .fill)
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
            if !outcome.notices.isEmpty {
                Section("tag_editor_writeback_notice_title") {
                    ForEach(Array(outcome.notices.enumerated()), id: \.offset) { _, notice in
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
                    .disabled(isUndoing || progress != nil)
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
            var restored = library.song(id: applied.id) ?? applied
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
}

// MARK: - Helpers

extension TagCleanupField {
    var titleKey: LocalizedStringKey {
        switch self {
        case .title: "tag_editor_title"
        case .artist: "tag_editor_artist"
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
        case .assistant: return nil
        }
    }
}

/// Loads a picked picture and scales it to a cover: 1024 px on the long side
/// as JPEG, which is what the single-song editor stores too.
enum BatchCoverImage {
    static func load(_ item: PhotosPickerItem?) async -> Data? {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return scaled(data) ?? data
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
