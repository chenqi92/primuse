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
            coverRef: songID.flatMap { store.library.song(id: $0)?.coverArtFileName },
            customImageIDs: settingsStore.customImageIDs
        )
        let frame = resolver.frame.flatMap { $0.source == source ? $0 : nil }

        TVAmbientBackdrop(tint: tint, tint2: tint2, strength: 1, image: frame?.image, imageID: frame?.id)
            .onChange(of: request, initial: true) { _, request in
                resolver.update(request, store: store)
            }
            .onChange(of: songID, initial: true) { _, songID in
                resolver.observeSong(songID, rotation: settings.rotation)
            }
            .task(id: TimerKey(
                isActive: scenePhase == .active && settings.rotation == .timed && source.supportsRotation,
                interval: settings.intervalSeconds
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

    private static let sourceRows: [[PlayerBackdropSource]] = [
        [.coverAmbient, .coverBlur],
        [.albumBack, .customImages],
    ]

    var body: some View {
        let settings = store.settings
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text("player_backdrop_title").tvFont(.pageTitle)
                    // 两行两列，列宽跟着本列最长的一项走，长文案的语言也不会挤成省略号。
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
                            Text("player_backdrop_interval").tvFont(.rowTitle).padding(.top, 12)
                            HStack(spacing: 22) {
                                ForEach(PlayerBackdropSettings.intervalChoices, id: \.self) { seconds in
                                    choice(
                                        title: Duration.seconds(seconds)
                                            .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)),
                                        isSelected: settings.intervalSeconds == seconds,
                                        identifier: "tv.playerBackdrop.interval.\(seconds)"
                                    ) {
                                        store.update { $0.intervalSeconds = seconds }
                                    }
                                }
                            }
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
    }

    static func title(_ source: PlayerBackdropSource) -> String {
        switch source {
        case .coverAmbient: String(localized: "player_backdrop_cover_ambient")
        case .liquid: String(localized: "player_backdrop_liquid")
        case .coverBlur: String(localized: "player_backdrop_cover_blur")
        case .albumBack: String(localized: "player_backdrop_album_back")
        case .customImages: String(localized: "player_backdrop_custom_images")
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
        case .liquid: String(localized: "player_backdrop_liquid_tv_hint")
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
#endif
