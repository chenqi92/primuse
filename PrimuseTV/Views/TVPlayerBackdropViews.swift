#if os(tvOS)
import SwiftUI
import PrimuseKit

/// 播放页背景：封面色场之上按设置铺图（模糊封面 / 专辑封底 / 我的图片）。
/// 只用在原生播放页；全屏效果播放时整页换成全屏舞台。
struct TVPlayerBackdrop: View {
    let tint: Color
    let tint2: Color

    @Environment(TVStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsStore = PlayerBackdropSettingsStore.shared
    @State private var resolver = TVPlayerBackdropResolver.shared

    private struct TimerKey: Equatable {
        let isActive: Bool
        let interval: Int
        /// 换上新图就从头计时：上一张取得慢时，新图照样停够一个间隔。
        let frameID: String?
    }

    var body: some View {
        let settings = settingsStore.settings
        let source = settingsStore.effectiveSource
        let songID = store.isLiveRadio ? nil : store.currentSongID
        let request = TVPlayerBackdropResolver.Request(
            source: source,
            rotation: settings.rotation,
            step: resolver.rotation.step,
            songID: songID,
            cover: source == .coverBlur ? TVPlayerCoverArtwork.input(songID: songID, store: store) : nil,
            customImageIDs: settingsStore.customImageIDs
        )
        let frame = resolver.frame.flatMap { $0.source == source ? $0 : nil }

        TVAmbientBackdrop(
            tint: tint, tint2: tint2, strength: 1, image: frame?.image, imageID: frame?.id,
            meshPalette: source == .coverAmbient && settings.ambientStyle == .mesh
                ? songID.map { store.artworkAmbientPalette(forSongID: $0) } ?? []
                : nil,
            liquidPalette: source == .liquid
                ? songID.map { store.artworkAmbientPalette(forSongID: $0) } ?? []
                : nil,
            isPlaying: store.isPlaying
        )
            .onChange(of: request, initial: true) { _, request in
                resolver.update(request, store: store)
            }
            .onChange(of: songID, initial: true) { _, songID in
                resolver.observeSong(songID, rotation: settings.rotation)
            }
            .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidCache)) { note in
                resolver.artworkDidCache(note, request: request, store: store)
            }
            .task(id: TimerKey(
                isActive: scenePhase == .active && settings.rotation == .timed && source.supportsRotation,
                interval: settings.intervalSeconds,
                frameID: frame?.id
            )) {
                guard scenePhase == .active, settings.rotation == .timed, source.supportsRotation else { return }
                let interval = max(PlayerBackdropSettings.intervalChoices.first ?? 15, settings.intervalSeconds)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { return }
                    resolver.advanceTimer(rotation: .timed)
                }
            }
    }
}

/// 设置 › 外观 › 播放页背景。电视没有相册：「我的图片」来自 iPhone / Mac 的扫码直传。
struct TVPlayerBackdropSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = PlayerBackdropSettingsStore.shared
    @State private var choosingInterval = false

    static let sourceRows: [[PlayerBackdropSource]] = [
        [.coverAmbient, .liquid],
        [.coverBlur, .albumBack],
        [.customImages],
    ]

    var body: some View {
        let settings = store.settings
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text("player_backdrop_title").tvFont(.pageTitle)
                    // 列宽跟着本列最长的一项走，长文案的语言也不会挤成省略号。
                    Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 22) {
                        ForEach(Self.sourceRows, id: \.self) { row in
                            GridRow {
                                ForEach(row, id: \.self) { source in
                                    choice(
                                        title: Self.title(source),
                                        isSelected: settings.source == source,
                                        identifier: "tv.playerBackdrop.source.\(source.rawValue)"
                                    ) {
                                        store.update { $0.source = source }
                                    }
                                }
                            }
                        }
                    }
                    Text(verbatim: hint(for: settings.source))
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textMuted)

                    if #available(tvOS 18.0, *), settings.source == .coverAmbient {
                        Text("player_backdrop_ambient_style").tvFont(.rowTitle).padding(.top, 12)
                        HStack(spacing: 22) {
                            ForEach(PlayerAmbientStyle.allCases, id: \.self) { style in
                                choice(
                                    title: style == .mesh
                                        ? String(localized: "player_backdrop_ambient_mesh")
                                        : String(localized: "player_backdrop_ambient_classic"),
                                    isSelected: settings.ambientStyle == style,
                                    identifier: "tv.playerBackdrop.ambientStyle.\(style.rawValue)"
                                ) {
                                    store.update { $0.ambientStyle = style }
                                }
                            }
                        }
                    }

                    if settings.source.supportsRotation {
                        Text("player_backdrop_rotation").tvFont(.rowTitle).padding(.top, 12)
                        HStack(spacing: 22) {
                            ForEach(PlayerBackdropRotation.allCases, id: \.self) { rotation in
                                choice(
                                    title: Self.title(rotation),
                                    isSelected: settings.rotation == rotation,
                                    identifier: "tv.playerBackdrop.rotation.\(rotation.rawValue)"
                                ) {
                                    store.update { $0.rotation = rotation }
                                }
                            }
                        }
                        if settings.rotation == .timed {
                            // 档位多，横排放不下：一颗按钮显示当前间隔，按下弹出列表选。
                            Text("player_backdrop_interval").tvFont(.rowTitle).padding(.top, 12)
                            TVPillButton(
                                title: Self.intervalTitle(settings.intervalSeconds),
                                systemImage: "timer",
                                style: .glass,
                                action: { choosingInterval = true }
                            )
                            .accessibilityIdentifier("tv.playerBackdrop.interval")
                        }
                    }

                    Text("player_backdrop_footer")
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textMuted)
                        .padding(.top, 12)
                }
                .foregroundStyle(TVColor.text)
                .frame(maxWidth: 1400, alignment: .leading)
                .padding(70)
            }
        }
        .onAppear { store.pruneMissingCustomImages() }
        .onExitCommand { dismiss() }
        .tvFullScreenCover(isPresented: $choosingInterval) { TVPlayerBackdropIntervalPicker() }
    }

    static func intervalTitle(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }

    static func title(_ source: PlayerBackdropSource) -> String {
        switch source {
        case .coverAmbient: String(localized: "player_backdrop_cover_ambient")
        case .liquid: String(localized: "player_backdrop_liquid")
        case .coverBlur: String(localized: "player_backdrop_cover_blur")
        case .albumBack: String(localized: "player_backdrop_album_back")
        case .customImages: String(localized: "player_backdrop_custom_images")
        case .visualizer: String(localized: "player_backdrop_visualizer")
        }
    }

    static func title(_ rotation: PlayerBackdropRotation) -> String {
        switch rotation {
        case .fixed: String(localized: "player_backdrop_rotation_fixed")
        case .perSong: String(localized: "player_backdrop_rotation_per_song")
        case .timed: String(localized: "player_backdrop_rotation_timed")
        }
    }

    private func hint(for source: PlayerBackdropSource) -> String {
        switch source {
        case .coverAmbient: String(localized: "player_backdrop_cover_ambient_hint")
        case .liquid: String(localized: "player_backdrop_liquid_hint")
        case .visualizer: String(localized: "player_backdrop_liquid_tv_hint")
        case .coverBlur: String(localized: "player_backdrop_cover_blur_hint")
        case .albumBack: String(localized: "player_backdrop_album_back_hint")
        case .customImages:
            store.hasCustomImages
                ? String(format: String(localized: "player_backdrop_tv_images_count"), store.customImageIDs.count)
                : String(localized: "player_backdrop_tv_images_empty")
        }
    }

    private func choice(
        title: String,
        isSelected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        TVPillButton(
            title: title,
            systemImage: isSelected ? "checkmark.circle.fill" : "circle",
            style: isSelected ? .solid : .glass,
            isSelected: isSelected,
            action: action
        )
        .accessibilityIdentifier(identifier)
    }
}

/// 轮播间隔的选单：居中面板竖排全部档位，焦点先落在当前那一档，选了就关。
struct TVPlayerBackdropIntervalPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = PlayerBackdropSettingsStore.shared
    @FocusState private var focusedID: String?

    var body: some View {
        let selected = store.settings.intervalSeconds
        ZStack {
            TVAmbientBackdrop(strength: 0.5)
            TVColor.bg.opacity(0.52).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                Text("player_backdrop_interval").tvFont(.sectionTitle).foregroundStyle(TVColor.text)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(PlayerBackdropSettings.intervalChoices, id: \.self) { seconds in
                        row(seconds: seconds, isSelected: seconds == selected)
                    }
                }
                .focusSection()
            }
            .padding(40)
            .frame(width: 720, alignment: .leading)
            .tvPanel(radius: 24)
        }
        .defaultFocus($focusedID, Self.focusID(selected))
        .onExitCommand { dismiss() }
    }

    private static func focusID(_ seconds: Int) -> String { "interval.\(seconds)" }

    private func row(seconds: Int, isSelected: Bool) -> some View {
        TVFocusButton(
            radius: 14, scale: 1.03, lift: 0, ring: false,
            action: {
                store.update { $0.intervalSeconds = seconds }
                dismiss()
            },
            focusBinding: $focusedID,
            focusID: Self.focusID(seconds)
        ) { focused in
            HStack {
                Text(TVPlayerBackdropSettingsView.intervalTitle(seconds)).tvFont(.rowTitle)
                Spacer()
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .opacity(isSelected ? 1 : 0)
            }
            .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
            .padding(.horizontal, 26)
            .frame(height: 72)
            .background(focused ? AnyShapeStyle(TVColor.brand) : AnyShapeStyle(TVColor.surfaceStrong),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityIdentifier("tv.playerBackdrop.interval.\(seconds)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
#endif
