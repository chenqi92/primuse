#if os(iOS)
import PhotosUI
import PrimuseKit
import SwiftUI

enum HomeHeroCoverStyle: String, Codable, CaseIterable {
    case automatic, collage, photo, hidden

    var title: LocalizedStringKey {
        switch self {
        case .automatic: "artwork_mode_automatic"
        case .collage: "home_hero_cover_collage"
        case .photo: "player_backdrop_custom_images"
        case .hidden: "home_hero_cover_hidden"
        }
    }
}

enum HomeHeroBackdropStyle: String, Codable, CaseIterable {
    case automatic, gradient, flow, glow

    var title: LocalizedStringKey {
        switch self {
        case .automatic: "artwork_mode_automatic"
        case .gradient: "home_hero_static_gradient"
        case .flow: "player_backdrop_motion_flowing"
        case .glow: "home_hero_soft_glow"
        }
    }

    func resolved(medium: Bool, album: Bool) -> Self {
        self == .automatic ? (medium || album ? .gradient : .flow) : self
    }
}

final class HomeHeroCardPhoto: Codable, Equatable, Sendable {
    let jpeg: Data
    let image: UIImage
    let palette: ImmersiveArtworkPalette

    nonisolated init(jpeg: Data) throws {
        guard let decoded = PlayerBackdropImaging.decodedImage(data: jpeg, maxPixel: 768) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.jpeg = jpeg
        image = UIImage(cgImage: decoded)
        if let colors = ThemeService.extractDominantColor(from: image) {
            palette = .init(primary: colors.accent, secondary: colors.secondaryDark)
        } else {
            palette = .homeMonochrome
        }
    }

    nonisolated static func == (lhs: HomeHeroCardPhoto, rhs: HomeHeroCardPhoto) -> Bool {
        lhs === rhs || lhs.jpeg == rhs.jpeg
    }

    nonisolated required convenience init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        try self.init(jpeg: data)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jpeg)
    }
}

extension ImmersiveArtworkPalette {
    static let homeMonochrome = Self(primary: Color(white: 0.64), secondary: Color(white: 0.18))

    static func homePreset(_ theme: HomeHeroRecommendationTheme?) -> Self {
        switch theme {
        case .catalogRewind: .init(primary: Color(hex: "D39066"), secondary: Color(hex: "683D50"))
        case .recentCatalog: .init(primary: Color(hex: "84BBB8"), secondary: Color(hex: "295966"))
        case .daily: .init(primary: Color(hex: "AC99D4"), secondary: Color(hex: "504572"))
        case nil: .fallback
        }
    }
}

struct HomeHeroCardAppearance: Codable, Equatable {
    var cover: HomeHeroCoverStyle = .automatic
    var backdrop: HomeHeroBackdropStyle = .automatic
    var customColors = false
    var primaryHex = "A698DD"
    var secondaryHex = "3C4C71"
    var photo: HomeHeroCardPhoto?

    func palette(artwork: ImmersiveArtworkPalette?, theme: HomeHeroRecommendationTheme?) -> ImmersiveArtworkPalette {
        if customColors { return .init(primary: Color(hex: primaryHex), secondary: Color(hex: secondaryHex)) }
        if cover == .photo, let photo { return photo.palette }
        if cover != .hidden, let artwork { return artwork }
        return .homePreset(theme)
    }
}

struct HomeHeroCardAppearances: Codable, Equatable {
    var large = HomeHeroCardAppearance()
    var medium = HomeHeroCardAppearance()
}

// 两种尺寸及其压缩后的照片一起原子保存，取消编辑不会替换正在显示的图片。
@MainActor @Observable
final class HomeHeroCardAppearanceStore {
    static let shared = HomeHeroCardAppearanceStore(url: MetadataAssetStore.shared.customArtworkDirectoryURL
        .appendingPathComponent("HomeHeroAppearance.plist"))
    private let url: URL
    private(set) var values = HomeHeroCardAppearances()
    @ObservationIgnored private var loading: Task<HomeHeroCardAppearances, Never>?
    private(set) var isLoaded = false

    init(url: URL) { self.url = url }

    func load() async {
        guard !isLoaded else { return }
        let task = loading ?? Task.detached(priority: .utility) { [url] in
            guard let data = try? Data(contentsOf: url),
                  let saved = try? PropertyListDecoder().decode(HomeHeroCardAppearances.self, from: data)
            else { return HomeHeroCardAppearances() }
            return saved
        }
        loading = task
        let saved = await task.value
        if !isLoaded { values = saved; isLoaded = true }
        loading = nil
    }

    func save(_ draft: HomeHeroCardAppearances, original: HomeHeroCardAppearances) throws {
        var next = values
        if draft.large != original.large { next.large = draft.large }
        if draft.medium != original.medium { next.medium = draft.medium }
        guard next != values else { return }
        let data = try PropertyListEncoder().encode(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        values = next
    }
}

struct HomeHeroCardAppearanceFields: View {
    @Binding var appearance: HomeHeroCardAppearance
    @Binding var importing: Bool
    @State private var item: PhotosPickerItem?
    @State private var importFailed = false

    var body: some View {
        Picker("cover", selection: $appearance.cover) {
            ForEach(HomeHeroCoverStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier("home.hero.appearance.cover")
        if appearance.cover == .photo {
            let busy = importing
            let photo = appearance.photo
            PhotosPicker(selection: $item, matching: .images) {
                HStack {
                    Text("artwork_choose_photo")
                    Spacer()
                    if busy {
                        ProgressView()
                    } else if let photo {
                        Image(uiImage: photo.image).resizable().scaledToFill()
                            .frame(width: 38, height: 38).clipShape(.rect(cornerRadius: 7))
                    }
                }
            }
            .onChange(of: item) { _, selected in importing = selected != nil }
            .task(id: item) {
                guard let item else { return }
                do {
                    let source = try await item.loadTransferable(type: Data.self)
                    let photo = await Task.detached(priority: .userInitiated) {
                        source.flatMap { PlayerBackdropImaging.downscaledJPEG(from: $0, maxPixel: 768) }
                            .flatMap { try? HomeHeroCardPhoto(jpeg: $0) }
                    }.value
                    try Task.checkCancellation()
                    if let photo { appearance.photo = photo } else { importFailed = true }
                } catch {
                    guard !Task.isCancelled else { return }
                    importFailed = true
                }
                self.item = nil
                importing = false
            }
            .onDisappear { importing = false; item = nil }
            .alert("player_backdrop_import_failed", isPresented: $importFailed) { Button("ok") {} }
        }
        Picker("player_backdrop_motion", selection: $appearance.backdrop) {
            ForEach(HomeHeroBackdropStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .accessibilityValue(Text(appearance.backdrop.title))
        .accessibilityIdentifier("home.hero.appearance.effect")
        Picker("listening_space_tint_source", selection: $appearance.customColors) {
            Text("backdrop_color_source_artwork").tag(false)
            Text("backdrop_color_source_custom").tag(true)
        }
        if appearance.customColors {
            ColorPicker("home_hero_primary_color", selection: colorBinding($appearance.primaryHex), supportsOpacity: false)
            ColorPicker("home_hero_secondary_color", selection: colorBinding($appearance.secondaryHex), supportsOpacity: false)
        }
    }

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(hex: hex.wrappedValue) }, set: { hex.wrappedValue = ThemeColorSettings.hex(from: $0) })
    }
}

struct HomeHeroCardBackdrop: View {
    let style: HomeHeroBackdropStyle
    let palette: ImmersiveArtworkPalette
    let focused: Bool
    let reduceMotion: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var elapsed: TimeInterval = 0
    @State private var started: TimeInterval?

    var body: some View {
        let moving = focused && !reduceMotion && scenePhase == .active && (style == .flow || style == .glow)
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moving)) { _ in
            let time = elapsed + (started.map { CACurrentMediaTime() - $0 } ?? 0)
            switch style {
            case .flow:
                MeshGradient(width: 3, height: 3, points: MeshBackdropPalettePolicy.liquidPoints(at: time), colors: [
                    palette.secondary, palette.primary, palette.secondary,
                    palette.secondary, palette.secondary, palette.primary,
                    palette.primary, palette.secondary, palette.secondary
                ])
            case .glow:
                ZStack {
                    palette.secondary
                    EllipticalGradient(colors: [palette.primary, palette.primary.opacity(0)],
                                       center: UnitPoint(x: 0.66, y: 0.34), endRadiusFraction: 0.84)
                        .opacity(0.79 + 0.16 * sin(time * 0.32))
                }
            case .automatic, .gradient:
                LinearGradient(colors: [palette.primary, palette.secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .onChange(of: moving, initial: true) { _, active in
            if active {
                started = CACurrentMediaTime()
            } else if let started {
                elapsed += CACurrentMediaTime() - started
                self.started = nil
            }
        }
        .accessibilityHidden(true)
    }
}
#endif
