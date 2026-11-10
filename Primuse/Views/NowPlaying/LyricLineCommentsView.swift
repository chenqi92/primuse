import SwiftUI
import PrimuseKit
import UniformTypeIdentifiers

struct LyricCommentPresentation: Identifiable {
    let songID: String
    var anchor: LyricLineCommentAnchor?
    let id = UUID()
}

struct LyricLineCommentModifier: ViewModifier {
    let songID: String?
    let anchor: LyricLineCommentAnchor?
    var alignment: HorizontalAlignment = .leading
    var foreground: Color = .secondary
    var share: (() -> Void)? = nil
    let present: (LyricCommentPresentation) -> Void
    var store: LyricLineCommentStore = .shared

    func body(content: Content) -> some View {
        if let songID, let anchor {
            let comment = try? store.comment(songID: songID, anchor: anchor)
            let action: LocalizedStringKey = comment == nil ? "library_review_add_comment" : "library_review_edit_comment"
            VStack(alignment: alignment, spacing: 5) {
                content
                if let comment {
                    Button { present(.init(songID: songID, anchor: anchor)) } label: {
                        Label {
                            Text(verbatim: comment.text).lineLimit(2)
                        } icon: {
                            Image(systemName: "text.bubble.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(foreground)
                        .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("library_review_edit_comment"))
                    .accessibilityValue(Text(verbatim: comment.text))
                }
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button(action, systemImage: "text.bubble") {
                    present(.init(songID: songID, anchor: anchor))
                }
                Button("lyrics_comments_all", systemImage: "text.bubble.fill") {
                    present(.init(songID: songID))
                }
                if let share {
                    Button("lyric_poster_menu", systemImage: "square.and.arrow.up", action: share)
                }
            }
        } else {
            content
        }
    }
}

struct LyricCommentsListButton: View {
    let songID: String?
    let present: (LyricCommentPresentation) -> Void
    var store: LyricLineCommentStore = .shared

    var body: some View {
        if let songID, (try? store.comments(songID: songID).isEmpty) == false {
            Button { present(.init(songID: songID)) } label: {
                Image(systemName: "text.bubble.fill")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("lyrics_comments_title"))
            .help(Text("lyrics_comments_title"))
        }
    }
}

struct LyricLineCommentsSheet: View {
    let presentation: LyricCommentPresentation
    var store: LyricLineCommentStore = .shared
    var song: Song? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAnchor: LyricLineCommentAnchor?
    @State private var draft = ""
    @State private var loadFailed = false
    @State private var showsError = false
    @State private var didLoad = false
    @State private var exportTitle = ""
    @State private var exportArtist: String?
    @State private var exportDocument: LyricCommentsDocument?
    @State private var exportFileName = ""
    @State private var exporting = false
    @State private var exportFailed = false

    private var title: LocalizedStringKey {
        selectedAnchor == nil ? "lyrics_comments_title" : "library_review_comment_title"
    }

    var body: some View {
        platformBody
            .fileExporter(isPresented: $exporting, document: exportDocument,
                          contentType: LyricCommentsDocument.contentType, defaultFilename: exportFileName) { result in
                if case .failure(let error) = result {
                    let error = error as NSError
                    if error.domain != NSCocoaErrorDomain || error.code != CocoaError.userCancelled.rawValue {
                        exportFailed = true
                    }
                }
            }
            .alert("songs_export_failed", isPresented: $exportFailed) { Button("ok") {} }
    }

    @ViewBuilder private var platformBody: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2.bold())
            content
            HStack {
                Button("cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if selectedAnchor != nil {
                    Button("save", action: save).keyboardShortcut(.defaultAction).disabled(loadFailed)
                } else {
                    exportButton
                }
            }
        }
        .padding(24)
        .frame(width: 480, height: 420)
        .background(.regularMaterial)
        .onAppear(perform: load)
        .alert("lyrics_comment_save_failed", isPresented: $showsError) { Button("ok") {} }
        #else
        NavigationStack {
            content.padding()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if selectedAnchor != nil { Button("save", action: save).disabled(loadFailed) }
                        else { exportButton }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .onAppear(perform: load)
        .alert("lyrics_comment_save_failed", isPresented: $showsError) { Button("ok") {} }
        #endif
    }

    @ViewBuilder private var content: some View {
        if let anchor = selectedAnchor {
            VStack(alignment: .leading, spacing: 16) {
                ScrollView {
                    Text(verbatim: anchor.text).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 85)
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.12)))
                    .accessibilityLabel(Text("library_review_comment_title"))
                    .disabled(loadFailed)
                    .onChange(of: draft) { _, value in
                        if value.count > LyricLineCommentStore.maximumLength {
                            draft = String(value.prefix(LyricLineCommentStore.maximumLength))
                        }
                    }
            }
        } else {
            let comments = (try? store.comments(songID: presentation.songID)) ?? []
            if comments.isEmpty {
                ContentUnavailableView("lyrics_comments_empty", systemImage: "text.bubble")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(comments) { comment in
                            Button {
                                selectedAnchor = comment.anchor
                                draft = comment.text
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(verbatim: comment.anchor.text).font(.headline)
                                    Text(verbatim: comment.text).font(.body).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        selectedAnchor = presentation.anchor
        let matchingSong = song?.id == presentation.songID ? song : nil
        exportTitle = matchingSong?.title ?? String(localized: "lyrics_comments_title")
        exportArtist = matchingSong?.artistName
        do {
            if let anchor = selectedAnchor {
                draft = try store.comment(songID: presentation.songID, anchor: anchor)?.text ?? ""
            } else {
                _ = try store.comments(songID: presentation.songID)
            }
        } catch {
            loadFailed = true
            showsError = true
        }
    }

    private var exportButton: some View {
        Button("export", systemImage: "square.and.arrow.up", action: exportComments)
            .disabled(loadFailed || (try? store.comments(songID: presentation.songID).isEmpty) != false)
    }

    private func exportComments() {
        do {
            let comments = try store.comments(songID: presentation.songID)
            guard !comments.isEmpty else { return }
            let voices: [LyricVoice: String] = comments.contains { $0.anchor.voice == .secondary }
                ? [.primary: String(localized: "karaoke_part_primary"), .secondary: String(localized: "karaoke_part_secondary")] : [:]
            exportDocument = LyricCommentsDocument(markdown: LyricLineCommentsExport.markdown(
                title: exportTitle, artist: exportArtist, comments: comments, voiceNames: voices
            ))
            exportFileName = LyricLineCommentsExport.fileName(title: exportTitle)
            exporting = true
        } catch {
            exportFailed = true
        }
    }

    private func save() {
        guard let anchor = selectedAnchor, !loadFailed else { return }
        do {
            try store.save(songID: presentation.songID, anchor: anchor, text: draft)
            dismiss()
        } catch {
            showsError = true
        }
    }
}

struct LyricCommentsDocument: FileDocument {
    static var contentType: UTType { UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText }
    static var readableContentTypes: [UTType] { [contentType] }
    var data: Data

    init(markdown: String) { data = Data(markdown.utf8) }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
