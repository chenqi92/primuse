import SwiftUI
import PhotosUI
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 用户手动编辑歌曲元数据 ── 标题 / 艺术家 / 专辑 / 年份 / 流派 / 曲号 / 碟号
/// 以及封面。不改文件本身的 tag (NAS / 云盘文件不可直接写),只更新 Primuse
/// 内部的 MusicLibrary 记录 + MetadataAssetStore 封面缓存,通过 CloudKit
/// 同步,全 fleet 都能看到一致的编辑结果。
///
/// 自动刮削回写 tag 走 ScrapeOptionsView; 这里是给"刮削抓不到 / 抓错了 /
/// 想自定义命名 / 自己用一张图当封面"场景兜底,完全手工。
struct TagEditorView: View {
    let song: Song
    /// 批量整理时的上下文：调用方给一串待整理的歌，编辑器底部就能直接翻页。
    /// 只传单首(默认)时底部翻页条自动隐藏。
    var queue: [Song] = []
    /// 注意参数顺序：onSave 必须排在 onNavigate 前面 —— 既有调用点都用尾随闭包
    /// 传 onSave，Swift 的前向扫描会把尾随闭包绑给第一个函数型参数。
    var onSave: ((Song) -> Void)? = nil
    var onNavigate: ((Song) -> Void)? = nil

    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var genre: String
    @State private var yearText: String
    @State private var trackText: String
    @State private var discText: String
    @State private var lyricsText = ""
    @State private var originalLyricsText = ""
    @State private var lyricsLoading = true
    @State private var lyricsWritebackMode: LyricsWriteback.Mode = .checking
    @State private var lyricsErrorMessage: String?
    @State private var isSaving = false
    @State private var showLyricsDeleteConfirm = false
    @State private var showLyricsEditor = false

    @State private var showResetConfirm = false
    @State private var showEncodingFixes = false
    /// 选中但还没保存的新封面。nil 表示"维持原 song.coverArtFileName"。
    @State private var pickedCoverData: Data?
    /// PhotosPicker 的 selection token。change 时把它解码成 Data 存到
    /// pickedCoverData。
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var didApplySplit = false
    /// 候选 chip 的数据源。同目录文件名 / 艺术家 / 流派候选都要扫库，
    /// 放进 body 每敲一个字就全库扫一遍；进入时算一次缓存住。
    @State private var cachedSiblingNames: [String] = []
    @State private var cachedArtistChips: [String] = []
    @State private var cachedGenreChips: [String] = []

    init(
        song: Song,
        queue: [Song] = [],
        onSave: ((Song) -> Void)? = nil,
        onNavigate: ((Song) -> Void)? = nil
    ) {
        self.song = song
        self.queue = queue
        self.onSave = onSave
        self.onNavigate = onNavigate
        _title = State(initialValue: song.title)
        _artist = State(initialValue: song.artistName ?? "")
        _album = State(initialValue: song.albumTitle ?? "")
        _genre = State(initialValue: song.genre ?? "")
        _yearText = State(initialValue: song.year.map { String($0) } ?? "")
        _trackText = State(initialValue: song.trackNumber.map { String($0) } ?? "")
        _discText = State(initialValue: song.discNumber.map { String($0) } ?? "")
    }

    var body: some View {
        Group {
            #if os(macOS)
            macBody
            #else
            legacyBody
            #endif
        }
        .task(id: song.id) {
            computeCandidates()
            await loadLyricsEditor()
        }
        .alert(
            String(localized: "tag_editor_lyrics_error_title"),
            isPresented: Binding(
                get: { lyricsErrorMessage != nil },
                set: { if !$0 { lyricsErrorMessage = nil } }
            )
        ) {
            Button(String(localized: "done"), role: .cancel) {}
        } message: {
            Text(lyricsErrorMessage ?? "")
        }
        .confirmationDialog(
            String(localized: "tag_editor_lyrics_delete_confirm_title"),
            isPresented: $showLyricsDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "tag_editor_lyrics_delete"), role: .destructive) {
                Task { await save(allowLyricsRemoval: true) }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "tag_editor_lyrics_delete_confirm_message"))
        }
        .sheet(isPresented: $showLyricsEditor) {
            LyricsEditorView(song: song, text: $lyricsText)
        }
        .sheet(isPresented: $showEncodingFixes) {
            EncodingFixPicker(
                fixes: encodingFixes,
                originalFields: encodingFixableFields,
                onPick: { fix in
                    applyEncodingFix(fix)
                    showEncodingFixes = false
                }
            )
        }
    }

    /// 编码修正入口。乱码是"看得见就能判断"的问题, 所以入口常驻 —— 启发式
    /// 漏检时用户仍能自己进来试。
    @ViewBuilder
    private var encodingFixButton: some View {
        Button {
            showEncodingFixes = true
        } label: {
            Label(
                String(localized: "tag_editor_encoding_fix"),
                systemImage: encodingLooksSuspicious
                    ? "exclamationmark.triangle"
                    : "character.cursor.ibeam"
            )
            .font(.subheadline)
            .foregroundStyle(encodingLooksSuspicious ? .orange : .secondary)
        }
        .disabled(isSaving || encodingFixes.isEmpty)
    }

    private var legacyBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        filenameHeader
                        titleField
                        artistField
                        albumAndYearFields
                        genreField
                        moreFieldsSection
                        lyricsCard
                        resetRow
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !navigationQueue.isEmpty { queueNavigationBar }
            }
            .navigationTitle(String(localized: "tag_editor_title_navigation"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { requestSave() } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(String(localized: "save"))
                        }
                    }
                    .disabled(!canSubmitChanges)
                }
            }
            .confirmationDialog(
                String(localized: "tag_editor_reset_confirm"),
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "tag_editor_reset"), role: .destructive) { resetFromOriginal() }
                Button(String(localized: "cancel"), role: .cancel) {}
            }
            .onChange(of: coverPickerItem) { _, newItem in
                Task { await loadPickedCover(newItem) }
            }
        }
    }

    // MARK: - 文件名 + 一键拆分

    /// 文件名摆最上面。大多数需要手工整理的歌，答案本来就写在文件名里 ——
    /// 点一下拆好填进去，比逐字段打字快得多。
    private var filenameHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                coverPreview
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                PhotosPicker(
                    selection: $coverPickerItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 26, height: 26)
                        .background(.background, in: Circle())
                        .overlay { Circle().stroke(.primary.opacity(0.12), lineWidth: 0.5) }
                }
                .offset(x: 5, y: 5)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("tag_editor_filename_label")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(fileNameDisplay)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Button {
                    applyFilenameSplit()
                } label: {
                    Label("tag_editor_split_filename", systemImage: "wand.and.stars")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background {
                            Capsule().fill(
                                didApplySplit ? Color.secondary.opacity(0.14) : Color.accentColor.opacity(0.14)
                            )
                        }
                        .foregroundStyle(didApplySplit ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(splitPreview == nil)

                if let preview = splitPreview {
                    Text(String(
                        format: String(localized: "tag_editor_split_preview %@ %@"),
                        preview.artist ?? String(localized: "unknown_artist"),
                        preview.title
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var fileNameDisplay: String {
        (song.filePath as NSString).lastPathComponent
    }

    /// 当前规则下的拆分结果。空标题的结果不算数 —— 那说明规则不适用。
    private var splitPreview: FilenameTagParser.ParsedTags? {
        let parsed = FilenameTagParser.parse(fileNameDisplay, pattern: suggestedPattern)
        guard !parsed.title.isEmpty else { return nil }
        return parsed
    }

    /// 用同目录的邻居一起猜规则。单看一个文件名分不清 `A - B` 里谁是艺术家，
    /// 一整个文件夹放在一起看就分得清了。
    private var suggestedPattern: FilenameTagParser.Pattern {
        FilenameTagParser.suggestedPattern(for: cachedSiblingNames)
    }

    /// 扫库拿候选。只在进入编辑器 / 翻页换歌时跑一次。
    private func computeCandidates() {
        let directory = (song.filePath as NSString).deletingLastPathComponent
        let siblings: [String]
        if directory.isEmpty {
            siblings = [fileNameDisplay]
        } else {
            let names = library.visibleSongs.lazy
                .filter {
                    $0.sourceID == song.sourceID
                        && ($0.filePath as NSString).deletingLastPathComponent == directory
                }
                .prefix(60)
                .map { ($0.filePath as NSString).lastPathComponent }
            siblings = names.isEmpty ? [fileNameDisplay] : Array(names)
        }
        cachedSiblingNames = siblings

        // 艺术家候选按可信度排：文件名拆出来的 → 同目录里反复出现的 →
        // 同专辑已填好的。用已有写法兜底能避免同一个人被写成好几种。
        var artists: [String] = []
        var seenArtists = Set<String>()
        func appendArtist(_ value: String?) {
            guard let value, !value.isEmpty,
                  seenArtists.insert(value.lowercased()).inserted else { return }
            artists.append(value)
        }
        for candidate in FilenameTagParser.candidates(for: fileNameDisplay) {
            appendArtist(candidate.tags.artist)
        }
        for neighbour in FilenameTagParser.neighbouringArtists(from: siblings) {
            appendArtist(neighbour)
        }
        if let albumID = song.albumID, !albumID.isEmpty {
            let albumArtist = library.visibleSongs.first {
                $0.albumID == albumID && $0.artistName?.isEmpty == false
            }?.artistName
            appendArtist(albumArtist)
        }
        cachedArtistChips = Array(artists.prefix(5))

        // 流派候选取库里已用过的，按使用频次排。
        var counts: [String: Int] = [:]
        var displayByKey: [String: String] = [:]
        for entry in library.visibleSongs {
            guard let value = entry.genre?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            let key = value.lowercased()
            counts[key, default: 0] += 1
            if displayByKey[key] == nil { displayByKey[key] = value }
        }
        cachedGenreChips = counts
            .sorted { $0.value > $1.value }
            .prefix(6)
            .compactMap { displayByKey[$0.key] }
    }

    private func applyFilenameSplit() {
        guard let parsed = splitPreview else { return }
        title = parsed.title
        if let parsedArtist = parsed.artist, !parsedArtist.isEmpty {
            artist = parsedArtist
        }
        if let track = parsed.trackNumber, trackText.isEmpty {
            trackText = String(track)
        }
        didApplySplit = true
    }

    // MARK: - 字段 + 候选

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 7) {
            fieldLabel("tag_editor_title")
            editableField(text: $title, placeholder: "tag_editor_title")

            chipRow(titleCandidates) { candidate in
                title = candidate
            }
        }
    }

    /// 歌名候选：各条拆分规则给出的不同解释。用户不用猜规则叫什么，
    /// 直接看结果选。
    private var titleCandidates: [String] {
        var seen = Set<String>()
        return FilenameTagParser.candidates(for: fileNameDisplay)
            .map(\.tags.title)
            .filter { $0 != title && !$0.isEmpty && seen.insert($0).inserted }
    }

    private var artistField: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                fieldLabel("tag_editor_artist")
                Spacer()
                if !artistCandidates.isEmpty {
                    Text("tag_editor_tap_candidate_hint")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            editableField(text: $artist, placeholder: "tag_editor_artist")

            chipRow(artistCandidates) { candidate in
                artist = candidate
            }
        }
    }

    /// 艺术家候选。已经填成候选值的那一项就不再重复列出来。
    private var artistCandidates: [String] {
        cachedArtistChips.filter { $0.lowercased() != artist.lowercased() }
    }

    private var albumAndYearFields: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                fieldLabel("tag_editor_album")
                editableField(text: $album, placeholder: "tag_editor_album")
            }

            VStack(alignment: .leading, spacing: 7) {
                fieldLabel("tag_editor_year")
                editableField(text: $yearText, placeholder: "tag_editor_year", keyboard: .numberPad)
            }
            .frame(width: 108)
        }
    }

    private var genreField: some View {
        VStack(alignment: .leading, spacing: 7) {
            fieldLabel("tag_editor_genre")
            editableField(text: $genre, placeholder: "tag_editor_genre")

            chipRow(genreCandidates) { candidate in
                genre = candidate == genre ? "" : candidate
            }
        }
    }

    /// 流派候选取库里已用过的，按使用频次排。让用户复用既有写法，
    /// 而不是每次自己想一个近义词。
    private var genreCandidates: [String] {
        cachedGenreChips
    }

    private var moreFieldsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("tag_editor_track")
                    editableField(text: $trackText, placeholder: "tag_editor_track", keyboard: .numberPad)
                }
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("tag_editor_disc")
                    editableField(text: $discText, placeholder: "tag_editor_disc", keyboard: .numberPad)
                }
            }

            encodingFixButton
                .padding(.top, 2)
        }
    }

    private var lyricsCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            fieldLabel("tag_editor_lyrics_section")

            Button {
                showLyricsEditor = true
            } label: {
                HStack(spacing: 12) {
                    if lyricsLoading {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "tag_editor_lyrics_writeback_checking"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(lyricsSummaryTitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(lyricsSummaryDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    hasLyricsChanges ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.14),
                                    lineWidth: hasLyricsChanges ? 1 : 0.5
                                )
                        }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(lyricsLoading || isSaving)

            lyricsWritebackStatus
                .font(.caption2)
        }
    }

    private var resetRow: some View {
        HStack {
            Text("tag_editor_footer")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Label("tag_editor_reset", systemImage: "arrow.uturn.backward")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .disabled(!hasChanges || isSaving)
        }
        .padding(.top, 4)
    }

    private func fieldLabel(_ key: String.LocalizationValue) -> some View {
        Text(String(localized: key))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func editableField(
        text: Binding<String>,
        placeholder: String.LocalizationValue,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        HStack(spacing: 8) {
            TextField(String(localized: placeholder), text: text)
                .font(.system(size: 15))
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .default ? .words : .never)

            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            text.wrappedValue.isEmpty
                                ? Color.secondary.opacity(0.14)
                                : Color.accentColor.opacity(0.35),
                            lineWidth: 0.8
                        )
                }
        }
    }

    @ViewBuilder
    private func chipRow(_ candidates: [String], onPick: @escaping (String) -> Void) -> some View {
        if !candidates.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(candidates, id: \.self) { candidate in
                        Button {
                            onPick(candidate)
                        } label: {
                            Text(candidate)
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(Color.secondary.opacity(0.14), in: Capsule())
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: - 批量翻页

    /// 翻页队列排除当前这首，用它判断底部条要不要出现。
    private var navigationQueue: [Song] {
        queue.count > 1 ? queue : []
    }

    private var currentQueueIndex: Int? {
        navigationQueue.firstIndex { $0.id == song.id }
    }

    private var queueNavigationBar: some View {
        let index = currentQueueIndex
        let previous = index.flatMap { $0 > 0 ? navigationQueue[$0 - 1] : nil }
        let next = index.flatMap { $0 + 1 < navigationQueue.count ? navigationQueue[$0 + 1] : nil }

        return HStack(spacing: 12) {
            Button {
                if let previous { navigate(to: previous) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(Color.secondary.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(previous == nil || isSaving)
            .opacity(previous == nil ? 0.35 : 1)

            VStack(spacing: 3) {
                Text(next.map {
                    String(format: String(localized: "tag_editor_next_song %@"), $0.title)
                } ?? String(localized: "tag_editor_queue_last"))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let index {
                    Text(String(
                        format: String(localized: "tag_editor_queue_position %lld %lld"),
                        index + 1,
                        navigationQueue.count
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                if let next { navigate(to: next) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.16), in: Circle())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(next == nil || isSaving)
            .opacity(next == nil ? 0.35 : 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// 翻页前先把当前这首存掉 —— 用户在这一屏做的修改不该因为翻页而丢失。
    private func navigate(to target: Song) {
        guard let onNavigate else { return }
        if canSubmitChanges {
            Task {
                await save()
                onNavigate(target)
            }
        } else {
            onNavigate(target)
        }
    }


    #if os(macOS)
    private var macBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                macCoverPreview(size: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "tag_editor_mac_title"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(String(localized: "tag_editor_mac_subtitle"))
                        .font(PMFont.caption)
                        .foregroundStyle(PMColor.textMuted)
                }

                Spacer()

                PhotosPicker(
                    selection: $coverPickerItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label(String(localized: "tag_editor_mac_change_cover"), systemImage: "photo.on.rectangle")
                        .font(PMFont.bodyM)
                        .foregroundStyle(PMColor.text)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(PMColor.glassBtn, in: .rect(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                        }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ScrollView {
                VStack(spacing: 6) {
                    macField(String(localized: "tag_editor_title"), text: $title, original: song.title)
                    macField(String(localized: "tag_editor_artist"), text: $artist, original: song.artistName ?? "")
                    macField(String(localized: "tag_editor_album"), text: $album, original: song.albumTitle ?? "")
                    macEncodingFixRow
                    macReadOnlyField(String(localized: "tag_editor_field_format"), value: song.fileFormat.displayName)
                    macReadOnlyField(String(localized: "tag_editor_field_audio_spec"), value: macAudioSpec)
                    macField(String(localized: "tag_editor_genre"), text: $genre, original: song.genre ?? "")
                    macField(String(localized: "tag_editor_year"), text: $yearText, original: song.year.map(String.init) ?? "")

                    HStack(spacing: 10) {
                        macField(String(localized: "tag_editor_track"), text: $trackText, original: song.trackNumber.map(String.init) ?? "")
                        macField(String(localized: "tag_editor_disc"), text: $discText, original: song.discNumber.map(String.init) ?? "")
                    }

                    macLyricsEditor

                    macReadOnlyField(String(localized: "tag_editor_field_file_size"), value: macFileSizeText)
                    macReadOnlyField(String(localized: "tag_editor_field_duration"), value: macDurationText)
                    macReadOnlyField(String(localized: "tag_editor_field_location"), value: song.filePath, monospace: true)

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(PMColor.textFaint)
                            .padding(.top, 1)
                        Text(String(localized: "tag_editor_mac_note"))
                            .font(PMFont.caption)
                            .foregroundStyle(PMColor.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(PMColor.rowHover, in: .rect(cornerRadius: 6))
                    .padding(.top, 6)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack(spacing: 10) {
                Text(hasChanges
                     ? String(format: String(localized: "tag_editor_mac_changed_format"), macChangedCount)
                     : String(localized: "tag_editor_mac_unchanged"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hasChanges ? PMColor.brand : PMColor.textFaint)

                Spacer()

                Button {
                    showResetConfirm = true
                } label: {
                    Text(String(localized: "tag_editor_reset"))
                        .font(PMFont.bodyM)
                        .foregroundStyle(hasChanges ? PMColor.text : PMColor.textFaint)
                        .frame(height: 26)
                        .padding(.horizontal, 12)
                        .background(PMColor.glassBtn, in: .rect(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(!hasChanges || lyricsLoading || isSaving)

                Button {
                    dismiss()
                } label: {
                    Text(String(localized: "cancel"))
                        .font(PMFont.bodyM)
                        .foregroundStyle(PMColor.text)
                        .frame(height: 26)
                        .padding(.horizontal, 14)
                }
                .buttonStyle(.plain)
                .disabled(isSaving)

                Button {
                    requestSave()
                } label: {
                    Group {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(String(localized: "tag_editor_mac_save"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(height: 26)
                    .padding(.horizontal, 14)
                    .background(hasChanges ? PMColor.brand : PMColor.textFaint.opacity(0.45),
                                in: .rect(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitChanges)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 620)
        .background(PMColor.bg)
        .foregroundStyle(PMColor.text)
        .confirmationDialog(
            String(localized: "tag_editor_reset_confirm"),
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "tag_editor_reset"), role: .destructive) { resetFromOriginal() }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
        .onChange(of: coverPickerItem) { _, newItem in
            Task { await loadPickedCover(newItem) }
        }
    }

    @ViewBuilder
    private func macCoverPreview(size: CGFloat) -> some View {
        if let data = pickedCoverData, let img = PlatformImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
        } else {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: size,
                cornerRadius: 6,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
        }
    }

    private func macField(_ label: String, text: Binding<String>, original: String) -> some View {
        let changed = fieldChanged(text.wrappedValue, original)

        return HStack(spacing: 10) {
            Text(label)
                .font(PMFont.bodyS)
                .foregroundStyle(PMColor.textMuted)
                .frame(width: 110, alignment: .leading)

            TextField(label, text: text, prompt: Text(verbatim: "—"))
                .textFieldStyle(.plain)
                .font(PMFont.bodyS)
                .foregroundStyle(PMColor.text)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(PMColor.bgElev, in: .rect(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(changed ? PMColor.brand.opacity(0.55) : PMColor.dividerStrong, lineWidth: 0.5)
                }

            Circle()
                .fill(changed ? PMColor.brand : .clear)
                .frame(width: 8, height: 8)
                .help(changed ? Text(String(localized: "tag_editor_mac_field_changed")) : Text(verbatim: ""))
        }
    }

    /// 与 macField 对齐的编码修正行 —— 左侧留出同宽标签列, 按钮落在输入框位置。
    private var macEncodingFixRow: some View {
        HStack(spacing: 10) {
            Text(verbatim: "")
                .frame(width: 110, alignment: .leading)

            Button {
                showEncodingFixes = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: encodingLooksSuspicious
                          ? "exclamationmark.triangle"
                          : "character.cursor.ibeam")
                        .font(.system(size: 10, weight: .semibold))
                    Text(String(localized: "tag_editor_encoding_fix"))
                        .font(PMFont.caption)
                }
                .foregroundStyle(encodingLooksSuspicious ? PMColor.brand : PMColor.textMuted)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(PMColor.glassBtn, in: .rect(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(
                            encodingLooksSuspicious
                                ? PMColor.brand.opacity(0.5)
                                : PMColor.dividerStrong,
                            lineWidth: 0.5
                        )
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isSaving || encodingFixes.isEmpty)

            Spacer(minLength: 0)

            Circle().fill(.clear).frame(width: 8, height: 8)
        }
    }

    private func macReadOnlyField(_ label: String, value: String, monospace: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(PMFont.bodyS)
                .foregroundStyle(PMColor.textMuted)
                .frame(width: 110, alignment: .leading)

            Text(value.isEmpty ? "—" : value)
                .font(monospace ? .system(size: 11.5, design: .monospaced) : PMFont.bodyS)
                .foregroundStyle(value.isEmpty ? PMColor.textFaint : PMColor.text)
                .lineLimit(monospace ? 2 : 1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: monospace ? 34 : 26, alignment: .center)
                .background(PMColor.bgElev.opacity(0.72), in: .rect(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
                }

            Circle()
                .fill(.clear)
                .frame(width: 8, height: 8)
        }
    }

    private var macChangedCount: Int {
        var count = 0
        if pickedCoverData != nil { count += 1 }
        if fieldChanged(title, song.title) { count += 1 }
        if fieldChanged(artist, song.artistName ?? "") { count += 1 }
        if fieldChanged(album, song.albumTitle ?? "") { count += 1 }
        if fieldChanged(genre, song.genre ?? "") { count += 1 }
        if fieldChanged(yearText, song.year.map(String.init) ?? "") { count += 1 }
        if fieldChanged(trackText, song.trackNumber.map(String.init) ?? "") { count += 1 }
        if fieldChanged(discText, song.discNumber.map(String.init) ?? "") { count += 1 }
        if hasLyricsChanges { count += 1 }
        return count
    }

    private var macLyricsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "tag_editor_lyrics_section"))
                    .font(PMFont.bodyS)
                    .foregroundStyle(PMColor.textMuted)
                Spacer()
                lyricsWritebackStatus
            }

            Button {
                showLyricsEditor = true
            } label: {
                HStack(spacing: 10) {
                    if lyricsLoading {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "tag_editor_lyrics_writeback_checking"))
                            .font(PMFont.caption)
                            .foregroundStyle(PMColor.textMuted)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(lyricsSummaryTitle)
                                .font(PMFont.bodyS)
                                .foregroundStyle(PMColor.text)
                            Text(lyricsSummaryDetail)
                                .font(PMFont.caption)
                                .foregroundStyle(PMColor.textMuted)
                        }
                    }
                    Spacer()
                    if !lyricsLoading {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(lyricsLoading || isSaving)
            .background(PMColor.bgElev, in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(hasLyricsChanges ? PMColor.brand.opacity(0.55) : PMColor.dividerStrong, lineWidth: 0.5)
            }

            if !lyricsLoading, !lyricsPreviewLines.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lyricsPreviewLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(PMColor.textFaint)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 2)
            }

            lyricsEditorControls

            Text(String(localized: "tag_editor_lyrics_format_hint"))
                .font(PMFont.caption)
                .foregroundStyle(PMColor.textFaint)
        }
        .padding(.top, 6)
    }

    private var macAudioSpec: String {
        var parts: [String] = []
        if let sr = song.sampleRate, sr > 0 { parts.append("\(sr / 1000) kHz") }
        if let depth = song.bitDepth, depth > 0 { parts.append("\(depth)-bit") }
        if let bitrate = song.bitRate, bitrate > 0 { parts.append("\(bitrate / 1000) kbps") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var macFileSizeText: String {
        guard song.fileSize > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: song.fileSize, countStyle: .file)
    }

    private var macDurationText: String {
        guard song.duration > 0 else { return "—" }
        let total = song.duration.rounded().finiteInt()
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func fieldChanged(_ current: String, _ original: String) -> Bool {
        current.trimmingCharacters(in: .whitespacesAndNewlines)
            != original.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif

    /// 摘要区展示前几行,让用户不进编辑器也能确认这首歌到底有没有歌词。
    private var lyricsPreviewLines: [String] {
        let nonEmpty = LyricsWriteback.normalized(lyricsText)
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Array(nonEmpty.prefix(3))
    }

    private var lyricsSummaryTitle: String {
        LyricsWriteback.normalized(lyricsText).isEmpty
            ? String(localized: "tag_editor_lyrics_add")
            : String(localized: "tag_editor_lyrics_edit")
    }

    private var lyricsSummaryDetail: String {
        let content = LyricsWriteback.normalized(lyricsText)
        guard !content.isEmpty else {
            return String(localized: "tag_editor_lyrics_summary_empty")
        }
        let document = LyricsEditorDocument(parsing: content)
        if document.unstampedCount > 0, document.stampedCount > 0 {
            return String(
                format: String(localized: "tag_editor_lyrics_summary_partial"),
                document.stampedCount,
                document.lines.count
            )
        }
        return String(
            format: String(localized: "tag_editor_lyrics_summary_format"),
            document.lines.count,
            lyricsFormatLabel(LyricsFormat.detect(content))
        )
    }

    @ViewBuilder
    private var lyricsWritebackStatus: some View {
        switch lyricsWritebackMode {
        case .checking:
            Label(String(localized: "tag_editor_lyrics_writeback_checking"), systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .sidecar(let fileName, let replacesExistingFile):
            let template = replacesExistingFile
                ? String(localized: "tag_editor_lyrics_writeback_sidecar_replace")
                : String(localized: "tag_editor_lyrics_writeback_sidecar_new")
            Label(
                String(format: template, fileName),
                systemImage: "externaldrive.badge.checkmark"
            )
                .foregroundStyle(.secondary)
        case .mediaServer:
            Label(String(localized: "tag_editor_lyrics_writeback_server"), systemImage: "server.rack")
                .foregroundStyle(.secondary)
        case .localOnly:
            Label(String(localized: "tag_editor_lyrics_writeback_read_only"), systemImage: "lock")
                .foregroundStyle(.orange)
        case .unavailable(let reason):
            Label(
                String(
                    format: String(localized: "tag_editor_lyrics_writeback_unavailable"),
                    reason
                ),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var lyricsEditorControls: some View {
        let validation = currentLyricsValidation
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label(lyricsFormatLabel(validation?.format), systemImage: lyricsFormatIcon(validation?.format))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(validation?.issues.isEmpty == false ? .red : .secondary)
                Spacer()
                if !LyricsWriteback.normalized(lyricsText).isEmpty {
                    Button(role: .destructive) {
                        lyricsText = ""
                    } label: {
                        Label(String(localized: "tag_editor_lyrics_clear"), systemImage: "trash")
                            .font(.caption)
                    }
                    #if os(macOS)
                    .buttonStyle(.plain)
                    #endif
                    .disabled(isSaving)
                }
            }

            if let validation, !validation.issues.isEmpty {
                let lineNumbers = validation.issues.map(\.lineNumber)
                Text(
                    String(
                        format: String(localized: "tag_editor_lyrics_invalid_lines_format"),
                        lineNumbers.map(String.init).joined(separator: ", ")
                    )
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var coverPreview: some View {
        if let data = pickedCoverData, let img = PlatformImage(data: data) {
            #if os(iOS)
            Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            #else
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            #endif
        } else {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 84,
                cornerRadius: 8,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
        }
    }

    /// PhotosPicker 给的是 PhotosPickerItem,需要 await 拿原始 data。
    /// HEIC / RAW 之类的也允许,因为 storeCover 写的是 content-addressed
    /// 文件,后续 UIImage(data:) 解能不能成由读时决定; 大多数 iPhone 拍
    /// 的图都是 HEIC, UIImage 能正常解。
    private func loadPickedCover(_ item: PhotosPickerItem?) async {
        guard let item else { pickedCoverData = nil; return }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            pickedCoverData = nil
            return
        }
        // 太大的原图(几 MB+)会让 storeCover 落盘膨胀; 缩到 ~1024 长边
        // 后再 JPEG 压。1024px JPEG 在 NowPlayingView 全屏渲染足够清晰。
        pickedCoverData = downscale(data: data, maxLongSide: 1024) ?? data
    }

    private func downscale(data: Data, maxLongSide: CGFloat) -> Data? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        let longSide = max(image.size.width, image.size.height)
        guard longSide > maxLongSide else { return image.jpegData(compressionQuality: 0.86) }
        let scale = maxLongSide / longSide
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.86)
        #else
        // macOS 没有 UIGraphicsImageRenderer, 用 CGContext 走通用的 bitmap
        // 渲染 → JPEG 编码路径。Apple 推荐的 NSImage 缩放 (lockFocus / draw)
        // 会引入坐标系 + DPI 麻烦, 直接 CGImage + CGContext 最干净。
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let longSide = max(width, height)
        let resized: CGImage
        if longSide > maxLongSide {
            let scale = maxLongSide / longSide
            let target = CGSize(width: width * scale, height: height * scale)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: Int(target.width),
                height: Int(target.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(origin: .zero, size: target))
            guard let scaled = ctx.makeImage() else { return nil }
            resized = scaled
        } else {
            resized = cgImage
        }
        let rep = NSBitmapImageRep(cgImage: resized)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86])
        #endif
    }

    /// 跟原始 Song 比对 ── 全部 trim 后比较,没差就 disable 保存按钮,
    /// 避免用户改了一下又改回去也触发 CloudKit 同步。封面有改时也算 change。
    private var hasChanges: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let al = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        let y = Int(yearText.trimmingCharacters(in: .whitespacesAndNewlines))
        let tn = Int(trackText.trimmingCharacters(in: .whitespacesAndNewlines))
        let dn = Int(discText.trimmingCharacters(in: .whitespacesAndNewlines))
        return pickedCoverData != nil
            || t != song.title
            || a != (song.artistName ?? "")
            || al != (song.albumTitle ?? "")
            || g != (song.genre ?? "")
            || y != song.year
            || tn != song.trackNumber
            || dn != song.discNumber
            || hasLyricsChanges
    }

    private var hasLyricsChanges: Bool {
        guard !lyricsLoading else { return false }
        return LyricsWriteback.normalized(lyricsText) != LyricsWriteback.normalized(originalLyricsText)
    }

    private var currentLyricsValidation: LyricsEditableValidation? {
        let content = LyricsWriteback.normalized(lyricsText)
        return content.isEmpty ? nil : LyricsContentParser.validateEditableText(content)
    }

    private var canSubmitChanges: Bool {
        guard hasChanges, !lyricsLoading, !isSaving else { return false }
        guard hasLyricsChanges else { return true }
        let content = LyricsWriteback.normalized(lyricsText)
        if content.isEmpty {
            return !LyricsWriteback.normalized(originalLyricsText).isEmpty
        }
        return currentLyricsValidation?.isValid == true
    }

    private func lyricsFormatLabel(_ format: LyricsFormat?) -> String {
        switch format {
        case .plain: return "Plain"
        case .lineLevel: return "LRC"
        case .wordLevel: return "ELRC"
        case nil: return String(localized: "tag_editor_lyrics_format_empty")
        }
    }

    private func lyricsFormatIcon(_ format: LyricsFormat?) -> String {
        switch format {
        case .plain: return "text.alignleft"
        case .lineLevel: return "clock"
        case .wordLevel: return "waveform"
        case nil: return "text.badge.minus"
        }
    }

    @MainActor
    private func requestSave() {
        if hasLyricsChanges,
           LyricsWriteback.normalized(lyricsText).isEmpty,
           !LyricsWriteback.normalized(originalLyricsText).isEmpty {
            showLyricsDeleteConfirm = true
            return
        }
        Task { await save() }
    }

    @MainActor
    private func save(allowLyricsRemoval: Bool = false) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        var updated = song
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.title.isEmpty {
            // 不允许空标题,fallback 回 filename(最后一段)
            updated.title = (song.filePath as NSString).lastPathComponent
        }
        updated.artistName = trimmedOrNil(artist)
        updated.albumTitle = trimmedOrNil(album)
        updated.genre = trimmedOrNil(genre)
        updated.year = Int(yearText.trimmingCharacters(in: .whitespacesAndNewlines))
        updated.trackNumber = Int(trackText.trimmingCharacters(in: .whitespacesAndNewlines))
        updated.discNumber = Int(discText.trimmingCharacters(in: .whitespacesAndNewlines))

        let lyricsChanged = hasLyricsChanges
        var needsLibraryReplace = true
        if lyricsChanged {
            let mode = await resolveLyricsWritebackMode()
            let outcome = await LyricsWriteback.save(
                text: lyricsText,
                for: updated,
                mode: mode,
                allowRemoval: allowLyricsRemoval,
                sourceManager: sourceManager,
                library: library
            )
            guard outcome.succeeded else {
                lyricsErrorMessage = outcome.errorMessage
                return
            }
            updated = outcome.updatedSong
            // LyricsWriteback 已经把标签与歌词一起写回 MusicLibrary；只有后面
            // 封面又发生变化时，才需要再 replace 一次。
            needsLibraryReplace = false
        }

        // 新封面 → 写到 MetadataAssetStore,文件名作为新 coverArtFileName。
        // storeCover 内部 dedupe by content hash,同一张图重复存只占一份空间。
        if let coverData = pickedCoverData {
            let oldRef = song.coverArtFileName
            if let newFileName = await MetadataAssetStore.shared.storeCover(coverData, for: song.id) {
                updated.coverArtFileName = newFileName
                // 失效原 coverArtFileName 的渲染缓存,让 CachedArtworkView 在
                // 下一次 read 时拿到新数据 (新文件名不会跟旧名同 hash,但保险)
                if let oldRef { CachedArtworkView.invalidateCache(for: oldRef) }
                CachedArtworkView.invalidateCache(for: song.id)
                needsLibraryReplace = true
            }
        }

        if needsLibraryReplace {
            library.replaceSong(updated)
        }
        onSave?(updated)
        dismiss()
    }

    @MainActor
    private func loadLyricsEditor() async {
        lyricsLoading = true
        let text = await LyricsWriteback.loadEditableText(
            for: song,
            sourceManager: sourceManager
        )
        _ = await resolveLyricsWritebackMode()
        lyricsText = text
        originalLyricsText = text
        lyricsLoading = false
    }

    @MainActor
    private func resolveLyricsWritebackMode() async -> LyricsWriteback.Mode {
        let mode = await LyricsWriteback.resolveMode(
            for: song,
            sourceManager: sourceManager,
            sourcesStore: sourcesStore
        )
        lyricsWritebackMode = mode
        return mode
    }

    private func resetFromOriginal() {
        title = song.title
        artist = song.artistName ?? ""
        album = song.albumTitle ?? ""
        genre = song.genre ?? ""
        yearText = song.year.map { String($0) } ?? ""
        trackText = song.trackNumber.map { String($0) } ?? ""
        discText = song.discNumber.map { String($0) } ?? ""
        lyricsText = originalLyricsText
        pickedCoverData = nil
        coverPickerItem = nil
    }

    private func trimmedOrNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: - 文字编码修正

    /// 表单里受编码影响的文本字段, 顺序与 `applyEncodingFix` 一一对应。
    /// 曲号/碟号/年份是数字, 不会有乱码问题。
    private var encodingFixableFields: [String] {
        [title, artist, album, genre]
    }

    /// 整批重解的候选方案。自动修复必须保守, 猜错会把好数据改坏; 这里让用户
    /// 看着预览选, 所以列得比自动模式宽。
    private var encodingFixes: [TextEncodingRepair.EncodingFix] {
        TextEncodingRepair.availableFixes(for: encodingFixableFields)
    }

    /// 只在文本看着像乱码时才把入口显亮 —— 启发式会漏, 所以入口始终可点。
    private var encodingLooksSuspicious: Bool {
        encodingFixableFields.contains { field in
            !field.isEmpty
                && (TextEncodingRepair.looksCorrupted(field)
                    || TextEncodingRepair.hasUnrecoverableReplacement(in: field))
        }
    }

    private func applyEncodingFix(_ fix: TextEncodingRepair.EncodingFix) {
        guard fix.fields.count == 4 else { return }
        title = fix.fields[0]
        artist = fix.fields[1]
        album = fix.fields[2]
        genre = fix.fields[3]
    }

}
