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
                        Button("cancel", role: .cancel) { generator.cancel() }
                    } else {
                        Button("chapter_generation_start") { confirmsUpload = true }
                            .disabled(generator.isApplying)
                    }
                    if let failure = error ?? generator.failure { Text(failure).foregroundStyle(.secondary) }
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

    private func start() {
        error = nil
        generator.start(songs: wholeBook ? bookSongs : [song], library: library,
                        intelligence: intelligence, loadTranscript: loadTranscript)
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
