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
            .onChange(of: coverPickerItem) { _, newItem in
                Task { await loadPickedCover(newItem) }
            }
        }
    }

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
                filePath: song.filePath
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

        // 新封面 → 写到 MetadataAssetStore,文件名作为新 coverArtFileName。
        // storeCover 内部 dedupe by content hash,同一张图重复存只占一份空间。
        if let coverData = pickedCoverData {
            let oldRef = song.coverArtFileName
            if let newFileName = MetadataAssetStore.shared.storeCover(coverData, for: song.id) {
                updated.coverArtFileName = newFileName
                // 失效原 coverArtFileName 的渲染缓存,让 CachedArtworkView 在
                // 下一次 read 时拿到新数据 (新文件名不会跟旧名同 hash,但保险)
                if let oldRef { CachedArtworkView.invalidateCache(for: oldRef) }
                CachedArtworkView.invalidateCache(for: song.id)
            }
        }

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
        pickedCoverData = nil
        coverPickerItem = nil
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
