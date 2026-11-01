import PrimuseKit
import SwiftUI

struct SpokenChapterGenerationSheet: View {
    let song: Song
    var bookSongs: [Song] = []
    let library: MusicLibrary
    let loadTranscript: @MainActor (Song) async -> [LyricLine]
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.dismiss) private var dismiss
    @State private var wholeBook = false
    @State private var confirmsUpload = false
    @State private var confirmsDelete = false
    @State private var consent: BuiltInAIConsentRequest?
    @State private var error: String?
    @State private var editingIndex: Int?
    @State private var editingSongID = ""
    @State private var editingTitle = ""
    @State private var editingPreview = false
    @State private var resumingJobID: String?
    @State private var discardingJobID: String?

    var generator: SpokenChapterGenerator = .shared
    private var record: SpokenChapterRecord? {
        library.generatedChapterRecord(id: song.id).flatMap { $0.isDeleted ? nil : $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(song.title).font(.headline)
                    if bookSongs.count > 1 {
                        Toggle("chapter_generation_whole_book", isOn: $wholeBook).disabled(generator.isRunning)
                    }
                    if generator.isRunning {
                        Text(generator.currentTitle).lineLimit(2)
                        ProgressView(value: (Double(generator.completedItems) + generator.progress) / Double(max(1, generator.totalItems)))
                        Button("chapter_generation_pause") { generator.cancel() }
                    } else {
                        Button("chapter_generation_start") { requestStart() }
                            .disabled(generator.isApplying)
                    }
                    if let failure = error ?? generator.failure { Text(failure).foregroundStyle(.secondary) }
                }
                if !generator.isRunning, !generator.jobs(for: song.id).isEmpty {
                    Section("chapter_generation_saved_jobs") {
                        ForEach(generator.jobs(for: song.id)) { job in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(job.title)
                                ProgressView(value: job.progress)
                                if let date = job.retryAt, date > Date() {
                                    Text(date, style: .relative).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button("chapter_generation_resume") { requestStart(resuming: job.id) }
                                        .disabled(generator.isApplying)
                                    Spacer()
                                    Button("delete", role: .destructive) { discardingJobID = job.id }
                                        .disabled(generator.isApplying)
                                }
                            }
                        }
                    }
                }
                if !generator.previews.isEmpty {
                    ForEach(generator.previews) { preview in
                        Section(preview.song.title) {
                            chapterRows(preview.record.chapters, songID: preview.id, isPreview: true)
                        }
                    }
                    if !generator.isRunning, generator.completedItems == generator.totalItems {
                        Button("chapter_generation_apply") {
                            Task {
                                do { try await generator.apply(to: library); error = nil }
                                catch let failure as SpokenChapterGeneration.Failure { error = SpokenChapterGenerator.message(failure) }
                                catch { self.error = String(localized: "chapter_generation_failed") }
                            }
                        }
                        .disabled(generator.isApplying)
                    }
                }
                if let record {
                    Section {
                        Toggle("chapter_generation_use", isOn: Binding(get: { record.isEnabled }, set: { enabled in
                            updateRecord { $0.isEnabled = enabled }
                        }))
                        chapterRows(record.chapters, songID: song.id, isPreview: false)
                        Button("delete", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            #if os(tvOS)
            .safeAreaInset(edge: .top) {
                HStack {
                    Text("chapter_generation_title").font(.title).foregroundStyle(.white)
                    Spacer()
                    Button("done") { dismiss() }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 24)
                .background(.black)
            }
            #else
            .navigationTitle(Text("chapter_generation_title"))
            #endif
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if !os(tvOS)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("done") { dismiss() } } }
            #endif
            .alert(Text("chapter_generation_title"), isPresented: $confirmsUpload) {
                Button("cancel", role: .cancel) {}
                Button("chapter_generation_start") {
                    do {
                        try intelligence.grantRemoteConsent()
                        if intelligence.needsBuiltInConsent(for: .spokenChapters) {
                            consent = BuiltInAIConsentRequest(onAgree: start)
                        } else { start() }
                    } catch { self.error = String(localized: "chapter_generation_failed") }
                }
            } message: { Text("chapter_generation_upload") }
            .alert(Text("chapter_generation_discard_job"), isPresented: Binding(
                get: { discardingJobID != nil }, set: { if !$0 { discardingJobID = nil } }
            )) {
                Button("cancel", role: .cancel) { discardingJobID = nil }
                Button("delete", role: .destructive) {
                    if let id = discardingJobID {
                        do { try generator.discard(id) }
                        catch { self.error = String(localized: "chapter_generation_save_failed") }
                    }
                    discardingJobID = nil
                }
            }
            .alert(Text("delete"), isPresented: $confirmsDelete) {
                Button("cancel", role: .cancel) {}
                Button("delete", role: .destructive) { updateRecord { $0.isDeleted = true; $0.chapters = [] } }
            }
            .alert(Text("chapter_generation_rename"), isPresented: Binding(get: { editingIndex != nil }, set: { if !$0 { editingIndex = nil } })) {
                TextField("chapter_generation_name", text: $editingTitle)
                Button("cancel", role: .cancel) { editingIndex = nil }
                Button("done") {
                    if let index = editingIndex {
                        if editingPreview { generator.rename(songID: editingSongID, index: index, title: editingTitle) }
                        else {
                            let title = String(editingTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
                            if !title.isEmpty { updateRecord { if $0.chapters.indices.contains(index) { $0.chapters[index].title = title } } }
                        }
                    }
                    editingIndex = nil
                }
            }
        }
        .builtInAIConsentSheet($consent)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 540)
        #elseif os(tvOS)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .background(Color.black.ignoresSafeArea())
        #endif
    }

    private func requestStart(resuming id: String? = nil) {
        resumingJobID = id
        if intelligence.spokenChaptersNeedsRemoteConsent {
            confirmsUpload = true
        } else if intelligence.needsBuiltInConsent(for: .spokenChapters) {
            consent = BuiltInAIConsentRequest(onAgree: start)
        } else { start() }
    }

    private func start() {
        error = nil
        let songs: [Song]
        if let id = resumingJobID, let job = generator.savedJobs.first(where: { $0.id == id }) {
            let available = Dictionary(([song] + bookSongs).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            songs = job.songIDs.compactMap { available[$0] ?? library.song(id: $0) }
            guard songs.count == job.songIDs.count else {
                error = String(localized: "chapter_generation_missing_items")
                return
            }
        } else { songs = wholeBook ? bookSongs : [song] }
        generator.start(songs: songs, library: library, intelligence: intelligence,
                        loadTranscript: loadTranscript, resuming: resumingJobID)
    }

    private func updateRecord(_ change: (inout SpokenChapterRecord) -> Void) {
        guard var value = record else { return }
        change(&value)
        value.updatedAt = Date(); value.revision = UUID().uuidString
        library.saveGeneratedChapterRecord(value)
    }

    private func chapterRows(_ chapters: [MediaChapter], songID: String, isPreview: Bool) -> some View {
        ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
            Button {
                editingSongID = songID; editingPreview = isPreview
                editingTitle = chapter.title; editingIndex = index
            } label: {
                HStack {
                    Text(ChapterTimeFormatter.string(from: chapter.startTime)).monospacedDigit().foregroundStyle(.secondary)
                    Text(chapter.title).foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            #if !os(tvOS)
            .buttonStyle(.plain)
            #endif
            .contextMenu {
                Button("chapter_generation_rename") {
                    editingSongID = songID; editingPreview = isPreview
                    editingTitle = chapter.title; editingIndex = index
                }
                if chapters.count > 1 {
                    Button("delete", role: .destructive) {
                        if isPreview { generator.remove(songID: songID, index: index) }
                        else { updateRecord { if $0.chapters.indices.contains(index) { $0.chapters.remove(at: index) } } }
                    }
                }
            }
        }
    }
}
