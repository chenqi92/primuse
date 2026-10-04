import SwiftUI
import UniformTypeIdentifiers
import PrimuseKit
#if os(iOS)
import PhotosUI
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 播放页背景设置里各项的文字与图标，iPhone 与 Mac 共用。
enum PlayerBackdropSettingsText {
    static func title(_ source: PlayerBackdropSource) -> String {
        switch source {
        case .coverAmbient: String(localized: "player_backdrop_cover_ambient")
        case .coverBlur: String(localized: "player_backdrop_cover_blur")
        case .albumBack: String(localized: "player_backdrop_album_back")
        case .customImages: String(localized: "player_backdrop_custom_images")
        }
    }

    static func hint(_ source: PlayerBackdropSource) -> String {
        switch source {
        case .coverAmbient: String(localized: "player_backdrop_cover_ambient_hint")
        case .coverBlur: String(localized: "player_backdrop_cover_blur_hint")
        case .albumBack: String(localized: "player_backdrop_album_back_hint")
        case .customImages: String(localized: "player_backdrop_custom_images_hint")
        }
    }

    static func symbol(_ source: PlayerBackdropSource) -> String {
        switch source {
        case .coverAmbient: "sun.haze.fill"
        case .coverBlur: "drop.circle.fill"
        case .albumBack: "rectangle.on.rectangle.angled"
        case .customImages: "photo.on.rectangle"
        }
    }

    static func title(_ rotation: PlayerBackdropRotation) -> String {
        switch rotation {
        case .fixed: String(localized: "player_backdrop_rotation_fixed")
        case .perSong: String(localized: "player_backdrop_rotation_per_song")
        case .timed: String(localized: "player_backdrop_rotation_timed")
        }
    }

    static func interval(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }
}

/// 把用户挑的原图缩到这台设备屏幕的尺寸存起来。都在后台做，12MP 照片也不卡界面。
enum PlayerBackdropImageImporter {
    @MainActor
    static var storagePixel: Int {
        PlayerBackdropPixelPolicy.storagePixel(forDisplayLongSide: displayLongSidePixels)
    }

    /// 导入一批原图，返回成功的 id 和失败的张数。
    static func importImages(_ items: [Data], maxPixel: Int) async -> (ids: [String], failures: Int) {
        await Task.detached(priority: .userInitiated) {
            var ids: [String] = []
            var failures = 0
            for data in items {
                if Task.isCancelled { break }
                if let id = PlayerBackdropImageStore.importImage(data, maxPixel: maxPixel) {
                    ids.append(id)
                } else {
                    failures += 1
                }
            }
            return (ids, failures)
        }.value
    }

    @MainActor
    private static var displayLongSidePixels: Double {
        #if os(iOS)
        let screens = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }
        return screens.map { Double(max($0.nativeBounds.width, $0.nativeBounds.height)) }.max() ?? 0
        #elseif os(macOS)
        return NSScreen.screens.map {
            Double(max($0.frame.width, $0.frame.height) * $0.backingScaleFactor)
        }.max() ?? 0
        #else
        return 0
        #endif
    }
}

/// 一张已选图片的缩略图，读盘解码在后台。
struct PlayerBackdropThumbnail: View {
    let id: String
    var width: CGFloat = 64
    var height: CGFloat = 96

    @State private var image: CGImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .pmAppearFade(.contentAppear)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .task(id: id) {
                let id = id
                let pixel = Int(max(width, height) * 3)
                image = await Task.detached(priority: .utility) { () -> CGImage? in
                    guard let url = PlayerBackdropImageStore.fileURL(id: id) else { return nil }
                    return PlayerBackdropImaging.decodedImage(url: url, maxPixel: pixel)
                }.value
            }
    }
}

/// 已选图片一排：每张右上角可以移除，最后是「添加」入口（由各端放 PhotosPicker 或文件选择）。
struct PlayerBackdropImageStrip<AddButton: View>: View {
    let ids: [String]
    let isImporting: Bool
    let onRemove: (String) -> Void
    @ViewBuilder let addButton: () -> AddButton

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ids, id: \.self) { id in
                    PlayerBackdropThumbnail(id: id)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                onRemove(id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.55))
                                    .font(.system(size: 18))
                                    .padding(3)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("player_backdrop_remove_image"))
                        }
                        .transition(.opacity)
                }
                if isImporting {
                    ProgressView()
                        .frame(width: 64, height: 96)
                } else if ids.count < PlayerBackdropSettings.maximumCustomImages {
                    addButton()
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// 「添加图片」那一格的样子。
struct PlayerBackdropAddTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(width: 64, height: 96)
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .accessibilityLabel(Text("player_backdrop_add_images"))
    }
}

#if os(iOS)
/// iPhone / iPad 设置里的「播放页背景」，和封面取色放在同一页。
struct PlayerBackdropSettingsSections: View {
    @State private var store = PlayerBackdropSettingsStore.shared
    @Environment(ThemeService.self) private var themeService
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var importFailed = false

    var body: some View {
        let settings = store.settings

        Section {
            ForEach(PlayerBackdropSource.allCases, id: \.self) { source in
                sourceRow(source, isSelected: settings.source == source)
            }

            if settings.source == .customImages {
                VStack(alignment: .leading, spacing: 6) {
                    PlayerBackdropImageStrip(
                        ids: store.customImageIDs,
                        isImporting: isImporting,
                        onRemove: { id in
                            withAnimation(PMMotion.list.animation) { store.removeCustomImage(id) }
                        }
                    ) {
                        PhotosPicker(
                            selection: $pickerItems,
                            maxSelectionCount: max(1, PlayerBackdropSettings.maximumCustomImages - store.customImageIDs.count),
                            matching: .images,
                            preferredItemEncoding: .compatible
                        ) {
                            PlayerBackdropAddTile()
                        }
                        .buttonStyle(.plain)
                    }
                    if !store.hasCustomImages && !isImporting {
                        Text("player_backdrop_no_images")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if importFailed {
                        Text("player_backdrop_import_failed")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .pmAppearFade(.contentAppear)
            }

            if settings.source.supportsRotation {
                Picker(selection: rotationBinding) {
                    ForEach(PlayerBackdropRotation.allCases, id: \.self) { rotation in
                        Text(verbatim: PlayerBackdropSettingsText.title(rotation)).tag(rotation)
                    }
                } label: {
                    Label("player_backdrop_rotation", systemImage: "arrow.triangle.2.circlepath")
                }
                .pmAppearFade(.contentAppear)

                if settings.rotation == .timed {
                    Picker(selection: intervalBinding) {
                        ForEach(PlayerBackdropSettings.intervalChoices, id: \.self) { seconds in
                            Text(verbatim: PlayerBackdropSettingsText.interval(seconds)).tag(seconds)
                        }
                    } label: {
                        Label("player_backdrop_interval", systemImage: "timer")
                    }
                    .pmAppearFade(.contentAppear)
                }
            }
        } header: {
            SettingsInfoHeader("player_backdrop_title") {
                Text("player_backdrop_footer")
            }
        }
        .settingsAnchor("appearance.playerBackdrop")
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            importPicked(items)
        }
        .onAppear { store.pruneMissingCustomImages() }
    }

    private func sourceRow(_ source: PlayerBackdropSource, isSelected: Bool) -> some View {
        Button {
            store.update { $0.source = source }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: PlayerBackdropSettingsText.symbol(source))
                    .font(.body)
                    .foregroundStyle(themeService.uiAccentColor)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: PlayerBackdropSettingsText.title(source))
                        .foregroundStyle(.primary)
                    Text(verbatim: PlayerBackdropSettingsText.hint(source))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(themeService.uiAccentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var rotationBinding: Binding<PlayerBackdropRotation> {
        Binding(
            get: { store.settings.rotation },
            set: { value in store.update { $0.rotation = value } }
        )
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { store.settings.intervalSeconds },
            set: { value in store.update { $0.intervalSeconds = value } }
        )
    }

    private func importPicked(_ items: [PhotosPickerItem]) {
        isImporting = true
        importFailed = false
        let maxPixel = PlayerBackdropImageImporter.storagePixel
        Task {
            // 一张一张来：原图读进来、缩好存盘就放掉，不同时攥着十几张原图。
            var failures = 0
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    failures += 1
                    continue
                }
                let result = await PlayerBackdropImageImporter.importImages([data], maxPixel: maxPixel)
                failures += result.failures
                withAnimation(PMMotion.list.animation) {
                    store.appendCustomImages(result.ids)
                }
            }
            importFailed = failures > 0
            isImporting = false
        }
    }
}
#endif
