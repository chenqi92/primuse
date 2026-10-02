import SwiftUI
import PrimuseKit

/// 原生播放页背景上的那张图（封面模糊 / 专辑封底 / 自选图片），叠在封面取色的色场之上。
/// 选的是封面取色、或者图还没准备好时什么也不画，色场照旧露出来。
///
/// 只放在原生播放页：全屏效果打开时整页换成全屏舞台，背景图不参与。
struct PlayerBackdropImageHost: View {
    let song: Song?
    let isLight: Bool
    let strength: Double
    let usesIncreasedContrast: Bool
    /// 播放页是当前正在看的那一面（定时轮播只在这时走）。
    let isSurfaceVisible: Bool
    /// 入场动画结束前不开始读盘解码。
    let allowsLoading: Bool

    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(\.displayScale) private var displayScale
    @State private var store = PlayerBackdropSettingsStore.shared
    @State private var resolver = PlayerBackdropResolver.shared

    private struct TimerKey: Equatable {
        let isActive: Bool
        let interval: Int
    }

    var body: some View {
        let settings = store.settings
        let source = store.effectiveSource

        GeometryReader { geometry in
            let longSide = Double(max(geometry.size.width, geometry.size.height) * displayScale)
            let request = PlayerBackdropResolver.Request(
                source: source,
                rotation: settings.rotation,
                step: resolver.rotation.step,
                song: song,
                customImageIDs: store.customImageIDs,
                maxPixel: PlayerBackdropPixelPolicy.storagePixel(forDisplayLongSide: longSide),
                allowsLoading: allowsLoading
            )
            imageLayer(size: geometry.size, source: source)
                .onChange(of: request, initial: true) { _, request in
                    resolver.update(request, sourceManager: sourceManager, sourcesStore: sourcesStore)
                }
        }
        .onChange(of: song?.id, initial: true) { _, songID in
            resolver.observeSong(songID, rotation: settings.rotation)
        }
        .task(id: TimerKey(
            isActive: isSurfaceVisible && settings.rotation == .timed && source.supportsRotation,
            interval: settings.intervalSeconds
        )) {
            guard isSurfaceVisible, settings.rotation == .timed, source.supportsRotation else { return }
            let interval = max(PlayerBackdropSettings.intervalChoices.first ?? 15, settings.intervalSeconds)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                resolver.advanceTimer(rotation: .timed)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 外层 ZStack 一直在（没有图时是空的），挂在它上面的 onChange 才始终有效。
    private func imageLayer(size: CGSize, source: PlayerBackdropSource) -> some View {
        ZStack {
            if let frame = resolver.frame, frame.source == source {
                // 上一张垫在下面，新图淡入时不先闪出底色。
                if let previous = resolver.previousFrame, previous.source == source {
                    backdropImage(previous.image, size: size)
                }
                backdropImage(frame.image, size: size)
                    .id(frame.id)
                    .pmAppearFade(.ambient)
                scrim
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func backdropImage(_ image: CGImage, size: CGSize) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    private var scrim: some View {
        let value = PlayerBackdropScrimPolicy.scrim(
            isLight: isLight,
            strength: strength,
            usesIncreasedContrast: usesIncreasedContrast
        )
        let base: Color = isLight ? .white : .black
        return LinearGradient(
            stops: [
                .init(color: base.opacity(value.topOpacity), location: 0),
                .init(color: base.opacity(value.middleOpacity), location: 0.5),
                .init(color: base.opacity(value.bottomOpacity), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
