import SwiftUI
import PrimuseKit

/// 用户手动编辑歌曲元数据 ── 标题 / 艺术家 / 专辑 / 年份 / 流派 / 曲号 / 碟号。
/// 不改文件本身的 tag (NAS / 云盘文件不可直接写),只更新 Primuse 内部的
/// MusicLibrary 记录 + CloudKit 同步,所以全 fleet 都能看到一致的编辑结果。
///
/// 自动刮削回写 tag 走 ScrapeOptionsView; 这里是给"刮削抓不到 / 抓错了 /
/// 想自定义命名"场景兜底,完全手工。
struct TagEditorView: View {
    let song: Song
    var onSave: ((Song) -> Void)? = nil

    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var genre: String
    @State private var yearText: String
    @State private var trackText: String
    @State private var discText: String

    @State private var showResetConfirm = false

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
        NavigationStack {
            Form {
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
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "save")) { save() }
                        .disabled(!hasChanges)
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
        }
    }

    /// 跟原始 Song 比对 ── 全部 trim 后比较,没差就 disable 保存按钮,
    /// 避免用户改了一下又改回去也触发 CloudKit 同步。
    private var hasChanges: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let al = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        let y = Int(yearText.trimmingCharacters(in: .whitespacesAndNewlines))
        let tn = Int(trackText.trimmingCharacters(in: .whitespacesAndNewlines))
        let dn = Int(discText.trimmingCharacters(in: .whitespacesAndNewlines))
        return t != song.title
            || a != (song.artistName ?? "")
            || al != (song.albumTitle ?? "")
            || g != (song.genre ?? "")
            || y != song.year
            || tn != song.trackNumber
            || dn != song.discNumber
    }

    private func save() {
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
        library.replaceSong(updated)
        onSave?(updated)
        dismiss()
    }

    private func resetFromOriginal() {
        title = song.title
        artist = song.artistName ?? ""
        album = song.albumTitle ?? ""
        genre = song.genre ?? ""
        yearText = song.year.map { String($0) } ?? ""
        trackText = song.trackNumber.map { String($0) } ?? ""
        discText = song.discNumber.map { String($0) } ?? ""
    }

    private func trimmedOrNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
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
