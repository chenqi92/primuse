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
    private enum LyricsWritebackMode: Equatable {
        case checking
        case sidecar(fileName: String, replacesExistingFile: Bool)
        case mediaServer
        case localOnly
        case unavailable(String)
    }

    let song: Song
    var onSave: ((Song) -> Void)? = nil

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
    @State private var lyricsWritebackMode: LyricsWritebackMode = .checking
    @State private var lyricsErrorMessage: String?
    @State private var isSaving = false
    @State private var showLyricsDeleteConfirm = false
    @State private var showLyricsEditor = false

    @State private var showResetConfirm = false
    /// 选中但还没保存的新封面。nil 表示"维持原 song.coverArtFileName"。
    @State private var pickedCoverData: Data?
    /// PhotosPicker 的 selection token。change 时把它解码成 Data 存到
    /// pickedCoverData。
    @State private var coverPickerItem: PhotosPickerItem?

    init(song: Song, onSave: ((Song) -> Void)? = nil) {
        self.song = song
        self.onSave = onSave
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
    }

    private var legacyBody: some View {
        NavigationStack {
            Form {
                coverSection

                Section(String(localized: "tag_editor_basic_section")) {
                    LabeledField(label: String(localized: "tag_editor_title"), text: $title)
                    LabeledField(label: String(localized: "tag_editor_artist"), text: $artist)
                    LabeledField(label: String(localized: "tag_editor_album"), text: $album)
                }

                Section(String(localized: "tag_editor_extra_section")) {
                    LabeledField(label: String(localized: "tag_editor_genre"), text: $genre)
                    LabeledField(label: String(localized: "tag_editor_year"), text: $yearText, keyboard: .numberPad)
                    HStack {
                        LabeledField(label: String(localized: "tag_editor_track"), text: $trackText, keyboard: .numberPad)
                        LabeledField(label: String(localized: "tag_editor_disc"), text: $discText, keyboard: .numberPad)
                    }
                }

                lyricsEditorSection

                Section {
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label(String(localized: "tag_editor_reset"), systemImage: "arrow.uturn.backward")
                    }
                } footer: {
                    Text(String(localized: "tag_editor_footer"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    @ViewBuilder
    private var coverSection: some View {
        Section {
            HStack(spacing: 14) {
                coverPreview
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 8) {
                    PhotosPicker(
                        selection: $coverPickerItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label(String(localized: "tag_editor_pick_cover"), systemImage: "photo.on.rectangle")
                            .font(.subheadline)
                    }
                    if pickedCoverData != nil {
                        Button(role: .destructive) {
                            pickedCoverData = nil
                            coverPickerItem = nil
                        } label: {
                            Label(String(localized: "tag_editor_cover_revert"),
                                  systemImage: "arrow.uturn.backward")
                                .font(.caption)
                        }
                    }
                }
                Spacer()
            }
        } header: {
            Text(String(localized: "tag_editor_cover_section"))
        }
    }

    private var lyricsEditorSection: some View {
        Section {
            if lyricsLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "tag_editor_lyrics_writeback_checking"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    showLyricsEditor = true
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lyricsSummaryTitle)
                                .foregroundStyle(.primary)
                            Text(lyricsSummaryDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(isSaving)

                if !lyricsPreviewLines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lyricsPreviewLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            lyricsEditorControls
            lyricsWritebackStatus
        } header: {
            Text(String(localized: "tag_editor_lyrics_section"))
        } footer: {
            Text(String(localized: "tag_editor_lyrics_format_hint"))
        }
    }

    /// 摘要区展示前几行,让用户不进编辑器也能确认这首歌到底有没有歌词。
    private var lyricsPreviewLines: [String] {
        let nonEmpty = normalizedLyricsText(lyricsText)
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Array(nonEmpty.prefix(3))
    }

    private var lyricsSummaryTitle: String {
        normalizedLyricsText(lyricsText).isEmpty
            ? String(localized: "tag_editor_lyrics_add")
            : String(localized: "tag_editor_lyrics_edit")
    }

    private var lyricsSummaryDetail: String {
        let content = normalizedLyricsText(lyricsText)
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
                if !normalizedLyricsText(lyricsText).isEmpty {
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
        return normalizedLyricsText(lyricsText) != normalizedLyricsText(originalLyricsText)
    }

    private var currentLyricsValidation: LyricsEditableValidation? {
        let content = normalizedLyricsText(lyricsText)
        return content.isEmpty ? nil : LyricsContentParser.validateEditableText(content)
    }

    private var canSubmitChanges: Bool {
        guard hasChanges, !lyricsLoading, !isSaving else { return false }
        guard hasLyricsChanges else { return true }
        let content = normalizedLyricsText(lyricsText)
        if content.isEmpty {
            return !normalizedLyricsText(originalLyricsText).isEmpty
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
           normalizedLyricsText(lyricsText).isEmpty,
           !normalizedLyricsText(originalLyricsText).isEmpty {
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

        if hasLyricsChanges {
            let content = normalizedLyricsText(lyricsText)
            let mode = await resolveLyricsWritebackMode()
            if content.isEmpty {
                guard allowLyricsRemoval else {
                    lyricsErrorMessage = String(localized: "tag_editor_lyrics_empty_error")
                    return
                }
                if let error = await removeLyricsBack(for: updated, mode: mode) {
                    lyricsErrorMessage = String(
                        format: String(localized: "tag_editor_lyrics_write_failed"),
                        error
                    )
                    return
                }
                await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: song.id)
                updated.lyricsFileName = nil
                updated.lyricsText = nil
            } else {
                let validation = LyricsContentParser.validateEditableText(content)
                guard validation.isValid else {
                    lyricsErrorMessage = String(localized: "tag_editor_lyrics_invalid_error")
                    return
                }
                if let error = await writeLyricsBack(
                    validation.lines,
                    content: validation.normalizedContent,
                    for: updated,
                    mode: mode
                ) {
                    lyricsErrorMessage = String(
                        format: String(localized: "tag_editor_lyrics_write_failed"),
                        error
                    )
                    return
                }

                _ = await MetadataAssetStore.shared.cacheLyrics(
                    validation.lines,
                    forSongID: song.id,
                    force: true
                )
                updated.lyricsFileName = MetadataAssetStore.shared.expectedLyricsFileName(for: song.id)
                updated.lyricsText = validation.lines.map(\.text).joined(separator: "\n")
            }
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
            }
        }

        library.replaceSong(updated)
        if hasLyricsChanges {
            NotificationCenter.default.post(name: .primuseLyricsDidChange, object: updated.id)
        }
        onSave?(updated)
        dismiss()
    }

    @MainActor
    private func loadLyricsEditor() async {
        lyricsLoading = true
        let text = await LyricsLoader.loadEditableText(for: song, sourceManager: sourceManager)
        _ = await resolveLyricsWritebackMode()
        lyricsText = text
        originalLyricsText = text
        lyricsLoading = false
    }

    @MainActor
    private func resolveLyricsWritebackMode() async -> LyricsWritebackMode {
        let mode: LyricsWritebackMode
        if await sourceManager.supportsSidecarWriting(for: song) {
            do {
                let preflight = try await MusicScraperService.preflightLyricsWriteWithTimeout(
                    seconds: 10,
                    sourceManager: sourceManager,
                    for: song
                )
                mode = .sidecar(
                    fileName: preflight.fileName,
                    replacesExistingFile: preflight.replacesExistingFile
                )
            } catch {
                mode = .unavailable(error.localizedDescription)
            }
        } else if sourcesStore.source(id: song.sourceID)?.type == .jellyfin {
            do {
                let connector = try await sourceManager.connectorForSong(song)
                mode = connector is any MediaServerWritebackConnector
                    ? .mediaServer
                    : .unavailable(String(localized: "tag_editor_lyrics_server_unsupported"))
            } catch {
                mode = .unavailable(error.localizedDescription)
            }
        } else {
            mode = .localOnly
        }
        lyricsWritebackMode = mode
        return mode
    }

    private func writeLyricsBack(
        _ lines: [LyricLine],
        content: String,
        for updated: Song,
        mode: LyricsWritebackMode
    ) async -> String? {
        switch mode {
        case .localOnly:
            return nil
        case .checking:
            return String(localized: "tag_editor_lyrics_writeback_checking")
        case .unavailable(let reason):
            return reason
        case .sidecar:
            do {
                let result = try await MusicScraperService.writeSidecarWithTimeout(
                    seconds: 30,
                    sourceManager: sourceManager,
                    for: updated,
                    coverData: nil,
                    lyricsLines: lines,
                    lyricsContent: content
                )
                guard result.lyricsWritten else {
                    return result.errors.joined(separator: "\n")
                }
                guard await verifySidecarWriteback(content: content, song: updated) else {
                    return String(localized: "tag_editor_lyrics_verify_failed")
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        case .mediaServer:
            let result = await sourceManager.writeScrapedMetadataToMediaServer(
                original: updated,
                updated: updated,
                coverData: nil,
                lyricsLines: lines,
                lyricsContent: content
            )
            guard result.lyricsWritten else {
                return (result.errors + result.unsupported).joined(separator: "\n")
            }
            guard await verifyMediaServerWriteback(expectedLines: lines, song: updated) else {
                return String(localized: "tag_editor_lyrics_verify_failed")
            }
            return nil
        }
    }

    private func removeLyricsBack(
        for updated: Song,
        mode: LyricsWritebackMode
    ) async -> String? {
        switch mode {
        case .localOnly:
            return nil
        case .checking:
            return String(localized: "tag_editor_lyrics_writeback_checking")
        case .unavailable(let reason):
            return reason
        case .sidecar:
            do {
                let result = try await MusicScraperService.removeLyricsSidecarWithTimeout(
                    seconds: 30,
                    sourceManager: sourceManager,
                    for: updated
                )
                guard result.lyricsRemoved else {
                    return result.errors.joined(separator: "\n")
                }
                guard await verifySidecarRemoval(song: updated) else {
                    return String(localized: "tag_editor_lyrics_verify_failed")
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        case .mediaServer:
            let result = await sourceManager.removeLyricsFromMediaServer(for: updated)
            guard result.lyricsRemoved else {
                return (result.errors + result.unsupported).joined(separator: "\n")
            }
            guard await verifyMediaServerRemoval(song: updated) else {
                return String(localized: "tag_editor_lyrics_verify_failed")
            }
            return nil
        }
    }

    private func verifySidecarWriteback(
        content: String,
        song: Song
    ) async -> Bool {
        guard let readback = await LyricsLoader.loadSourceText(for: song, sourceManager: sourceManager) else {
            return false
        }
        return normalizedLyricsText(readback) == normalizedLyricsText(content)
    }

    private func verifyMediaServerWriteback(
        expectedLines: [LyricLine],
        song: Song
    ) async -> Bool {
        guard let connector = try? await sourceManager.connectorForSong(song),
              let server = connector as? any ServerLyricsConnector,
              let readback = await server.fetchServerLyrics(for: song.filePath) else {
            return false
        }
        return LyricsContentParser.areSemanticallyEquivalent(
            expectedLines,
            LyricsContentParser.parseText(readback)
        )
    }

    private func verifySidecarRemoval(song: Song) async -> Bool {
        guard let preflight = try? await MusicScraperService.preflightLyricsWriteWithTimeout(
            seconds: 10,
            sourceManager: sourceManager,
            for: song
        ) else {
            return false
        }
        return !preflight.replacesExistingFile
    }

    private func verifyMediaServerRemoval(song: Song) async -> Bool {
        guard let connector = try? await sourceManager.connectorForSong(song),
              let server = connector as? any ServerLyricsConnector else {
            return false
        }
        return await server.fetchServerLyrics(for: song.filePath) == nil
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

    private func normalizedLyricsText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct LabeledField: View {
    let label: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(label, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .default ? .words : .never)
        }
        .padding(.vertical, 2)
    }
}
