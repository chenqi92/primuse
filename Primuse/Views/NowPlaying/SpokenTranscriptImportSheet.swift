import PrimuseKit
import SwiftUI
import UniformTypeIdentifiers

/// 「导入文字稿」给哪本书(#461),章节按阅读顺序。
struct SpokenTranscriptImportRequest: Identifiable {
    let id = UUID()
    let title: String
    let songs: [Song]

    /// 一本书的章节按书里的顺序排(书架给的歌曲不一定是这个顺序)。
    static func readingOrder(_ songs: [Song], of book: SpokenWordBook) -> [Song] {
        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = book.items.compactMap { byID[$0.id] }
        return ordered.count == songs.count ? ordered : songs
    }

    /// 正在听的这本书(本机下载的播客节目也算一本)。
    @MainActor
    static func currentBook(player: AudioPlayerService, library: MusicLibrary) -> SpokenTranscriptImportRequest? {
        guard let song = player.currentSong else { return nil }
        let book = player.currentSpokenWordBook
        let songs = (book?.items.map(\.id) ?? [song.id]).compactMap { library.song(id: $0) }
        guard !songs.isEmpty else { return nil }
        return SpokenTranscriptImportRequest(title: book?.title ?? song.albumTitle ?? song.title, songs: songs)
    }
}

/// 一次给一本书的各章导入一批文字稿文件(#461)。选好文件后按文件名对到章节
/// (`SpokenTranscriptImportMatcher`),先列出哪份对到哪一章、哪些对不上,确认后再写。
/// 导入的文字稿保留原来的句段与逐词时间,算作用户提供的:服务器稿、生成稿都不会自动换掉它。
struct SpokenTranscriptImportSheet: View {
    let request: SpokenTranscriptImportRequest

    @Environment(\.dismiss) private var dismiss
    @State private var phase: SpokenTranscriptImportPhase = .choosing
    @State private var showsImporter = false

    var body: some View {
        NavigationStack {
            Form {
                SpokenTranscriptImportContent(
                    title: request.title,
                    phase: phase,
                    onChoose: { showsImporter = true }
                )
            }
            #if os(macOS)
            .macFormSheet(title: Text("transcript_import_title"), systemImage: "square.and.arrow.down.on.square") {
                Button("cancel") { dismiss() }
                    .buttonStyle(.macSheet)
                    .keyboardShortcut(.cancelAction)
                confirmButton
                    .buttonStyle(.macSheetPrimary)
            }
            #else
            .navigationTitle(Text("transcript_import_title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton
                }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: Self.contentTypes,
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task { await prepare(urls) }
        }
    }

    /// 列出对上的几份之后才能导入;导入完换成「完成」。
    @ViewBuilder
    private var confirmButton: some View {
        switch phase {
        case .review(let plan):
            Button(String(format: String(localized: "transcript_import_confirm %lld"), Int64(plan.rows.count))) {
                Task { await commit(plan) }
            }
            .disabled(plan.rows.isEmpty)
        case .done:
            Button("done") { dismiss() }
        case .choosing, .reading, .importing:
            EmptyView()
        }
    }

    /// 能选的文件:各种能读的歌词 / 字幕格式和纯文本。
    static let contentTypes: [UTType] = {
        var types: [UTType] = [.plainText]
        for fileExtension in PrimuseConstants.readableLyricsExtensions {
            if let type = UTType(filenameExtension: fileExtension), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }()

    // MARK: - Reading and matching

    private func prepare(_ urls: [URL]) async {
        phase = .reading
        let files = await SpokenTranscriptImportReader.read(urls)
        let tracks = await SpokenTranscriptImportReader.tracks(for: request.songs)
        let result = SpokenTranscriptImportMatcher.match(
            files: files.map { SpokenTranscriptImportMatcher.File(name: $0.name, level: $0.level) },
            tracks: tracks
        )
        let segments = SpokenTranscriptTrackTimeline.segments(durations: request.songs.map(\.duration))
        var rows: [SpokenTranscriptImportPlan.Row] = []
        for match in result.matches {
            guard let index = request.songs.firstIndex(where: { $0.id == match.trackID }),
                  let lines = files[match.fileIndex].lines else { continue }
            let song = request.songs[index]
            let localized = SpokenTranscriptTrackTimeline.localized(lines, in: segments[index])
            let current = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)
            rows.append(SpokenTranscriptImportPlan.Row(
                song: song,
                fileName: files[match.fileIndex].name,
                lines: SpokenTranscriptImportPolicy.importedDocument(localized, fileName: files[match.fileIndex].name),
                replacesUserTranscript: current.flatMap(SpokenTranscriptOrigin.init(lines:)) == .userProvided
            ))
        }
        let skipped = result.skipped.map {
            SpokenTranscriptImportPlan.Skipped(fileIndex: $0.fileIndex, fileName: files[$0.fileIndex].name, reason: $0.reason)
        }
        phase = .review(SpokenTranscriptImportPlan(rows: rows, skipped: skipped))
    }

    private func commit(_ plan: SpokenTranscriptImportPlan) async {
        phase = .importing
        var imported = 0
        for row in plan.rows {
            guard await MetadataAssetStore.shared.cacheLyrics(row.lines, forSongID: row.song.id, force: true) else {
                continue
            }
            imported += 1
            NotificationCenter.default.post(name: .primuseLyricsDidChange, object: row.song.id)
        }
        plog("📜 imported \(imported) transcript(s) into '\(request.title)'")
        phase = .done(imported)
    }
}

enum SpokenTranscriptImportPhase {
    case choosing
    case reading
    case review(SpokenTranscriptImportPlan)
    case importing
    case done(Int)
}

struct SpokenTranscriptImportPlan {
    struct Row: Identifiable {
        let song: Song
        let fileName: String
        let lines: [LyricLine]
        let replacesUserTranscript: Bool

        var id: String { song.id }
    }

    struct Skipped: Identifiable {
        let fileIndex: Int
        let fileName: String
        let reason: SpokenTranscriptImportMatcher.SkipReason

        var id: Int { fileIndex }
    }

    let rows: [Row]
    let skipped: [Skipped]
}

/// 面板里的几段,按进行到哪一步换内容。
private struct SpokenTranscriptImportContent: View {
    let title: String
    let phase: SpokenTranscriptImportPhase
    let onChoose: () -> Void

    var body: some View {
        switch phase {
        case .choosing:
            introSection
        case .reading, .importing:
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("lyrics_sources_editor_loading")
                        .foregroundStyle(.secondary)
                }
            }
        case .review(let plan):
            SpokenTranscriptImportReview(plan: plan, onChoose: onChoose)
        case .done(let count):
            Section {
                Text(verbatim: String(format: String(localized: "transcript_import_done %lld"), Int64(count)))
            }
        }
    }

    private var introSection: some View {
        Section {
            Text(verbatim: title)
                .font(.headline)
            Text("transcript_import_intro")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("transcript_import_choose", action: onChoose)
        } footer: {
            Text("transcript_import_footer")
        }
    }
}

/// 对上的几份和对不上的几份。
private struct SpokenTranscriptImportReview: View {
    let plan: SpokenTranscriptImportPlan
    let onChoose: () -> Void

    var body: some View {
        if plan.rows.isEmpty {
            Section {
                Text("transcript_import_no_match")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                ForEach(plan.rows) { row in
                    SpokenTranscriptImportRowView(row: row)
                }
            } header: {
                Text(verbatim: String(format: String(localized: "transcript_import_matched_header %lld"), Int64(plan.rows.count)))
            } footer: {
                Text("transcript_import_footer")
            }
        }
        if !plan.skipped.isEmpty {
            Section {
                ForEach(plan.skipped) { skipped in
                    SpokenTranscriptImportSkippedRow(skipped: skipped)
                }
            } header: {
                Text("transcript_import_skipped_header")
            }
        }
        Section {
            Button("transcript_import_choose_again", action: onChoose)
        }
    }
}

private struct SpokenTranscriptImportRowView: View {
    let row: SpokenTranscriptImportPlan.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: row.song.title)
                .lineLimit(2)
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if row.replacesUserTranscript {
                Text("transcript_import_replaces_edit")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        let summary = LyricsDocumentSummary(lines: row.lines)
        let key: String.LocalizationValue = summary.isWordLevel
            ? "lyrics_sources_summary_word %lld"
            : (summary.isSynchronized
                ? "lyrics_sources_summary_line %lld"
                : "lyrics_sources_summary_plain %lld")
        return row.fileName + " · " + String(format: String(localized: key), Int64(summary.lineCount))
    }
}

private struct SpokenTranscriptImportSkippedRow: View {
    let skipped: SpokenTranscriptImportPlan.Skipped

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: skipped.fileName)
                .lineLimit(2)
            Text(reasonKey)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var reasonKey: LocalizedStringKey {
        switch skipped.reason {
        case .unreadable: "transcript_import_reason_unreadable"
        case .noTrack: "transcript_import_reason_no_track"
        case .duplicate: "transcript_import_reason_duplicate"
        }
    }
}

/// 读选中的文件、取各章的音频文件名。
enum SpokenTranscriptImportReader {
    struct LoadedFile: Sendable {
        let name: String
        /// 读不出能用的文字稿时为 nil。
        let lines: [LyricLine]?

        var level: LyricsTimingLevel? { lines.map(LyricsTimingLevel.init(lines:)) }
    }

    /// 解码和解析放到后台:一章的逐词稿上万行。和别处读有声内容的文字稿一样,单个文件最大 32 MB。
    static func read(_ urls: [URL]) async -> [LoadedFile] {
        let limit = LyricsSidecarTargetPolicy.maximumSpokenWordReadByteCount
        return await Task.detached(priority: .userInitiated) {
            urls.map { url -> LoadedFile in
                let name = url.lastPathComponent
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), data.count <= limit,
                      let text = TextEncodingRepair.decodeTextFile(data)?.text else {
                    return LoadedFile(name: name, lines: nil)
                }
                let lines = LyricsContentParser.parseText(TextEncodingRepair.repairedLyricsDocument(text) ?? text)
                return LoadedFile(name: name, lines: lines.isEmpty ? nil : lines)
            }
        }.value
    }

    /// 各章按什么名字对:音频文件名(服务端的歌曲路径是合成的,问音乐源要真名)和标题。
    @MainActor
    static func tracks(for songs: [Song]) async -> [SpokenTranscriptImportMatcher.Track] {
        let sourceManager = AppServices.shared.sourceManager
        var connectors: [String: (any ServerTranscriptFileConnector)?] = [:]
        var tracks: [SpokenTranscriptImportMatcher.Track] = []
        for song in songs {
            if connectors[song.sourceID] == nil {
                let connector = try? await sourceManager.auxiliaryConnector(for: song)
                connectors[song.sourceID] = .some(connector as? any ServerTranscriptFileConnector)
            }
            var fileName: String?
            if let files = connectors[song.sourceID] ?? nil {
                fileName = await files.serverAudioFileName(for: song.filePath)
            } else if !song.isCueTrack, !song.isStreamDescriptor {
                fileName = (song.filePath as NSString).lastPathComponent
            }
            tracks.append(SpokenTranscriptImportMatcher.Track(
                id: song.id,
                fileName: fileName,
                title: song.title,
                trackNumber: song.trackNumber
            ))
        }
        return tracks
    }
}
