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
        #if os(macOS)
        macBody
        #else
        legacyBody
        #endif
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
                    Text("编辑标签")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text("1 首选中 · 改动会写入资料库记录")
                        .font(PMFont.caption)
                        .foregroundStyle(PMColor.textMuted)
                }

                Spacer()

                PhotosPicker(
                    selection: $coverPickerItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label("更换封面", systemImage: "photo.on.rectangle")
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
                    macField("标题", text: $title, original: song.title)
                    macField("艺术家", text: $artist, original: song.artistName ?? "")
                    macField("专辑", text: $album, original: song.albumTitle ?? "")
                    macReadOnlyField("格式", value: song.fileFormat.displayName)
                    macReadOnlyField("音频规格", value: macAudioSpec)
                    macField("流派", text: $genre, original: song.genre ?? "")
                    macField("发行年", text: $yearText, original: song.year.map(String.init) ?? "")

                    HStack(spacing: 10) {
                        macField("曲目号", text: $trackText, original: song.trackNumber.map(String.init) ?? "")
                        macField("碟号", text: $discText, original: song.discNumber.map(String.init) ?? "")
                    }

                    macReadOnlyField("文件大小", value: macFileSizeText)
                    macReadOnlyField("时长", value: macDurationText)
                    macReadOnlyField("文件位置", value: song.filePath, monospace: true)

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(PMColor.textFaint)
                            .padding(.top, 1)
                        Text("改动会保存到 Primuse 资料库记录；封面会写入本地缓存并同步显示。")
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
                Text(hasChanges ? "● \(macChangedCount) 处改动" : "未改动")
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
                .disabled(!hasChanges)

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

                Button {
                    save()
                } label: {
                    Text("保存并写回")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(height: 26)
                        .padding(.horizontal, 14)
                        .background(hasChanges ? PMColor.brand : PMColor.textFaint.opacity(0.45),
                                    in: .rect(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(!hasChanges)
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
                filePath: song.filePath
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
                .help(changed ? Text("已改动") : Text(verbatim: ""))
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
        return count
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
        let total = Int(song.duration.rounded())
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
