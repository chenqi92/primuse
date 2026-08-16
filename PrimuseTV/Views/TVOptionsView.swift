#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 正在播放选项覆层 — 底部动作网格(对应 TVOptionsArtboard)。
/// Apple TV 无右键,长按 select / 菜单键升起此层。
struct TVOptionsView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private struct Action: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        var on: Bool = false
        let run: () -> Void
    }

    // 仅保留已真实接通的动作(其余如「加入歌单/相似歌曲/AirPlay 输出」需额外基建,
    // 暂不放占位假按钮)。
    private var actions: [Action] {
        let liked = store.currentSongID.map(store.isLiked) ?? false
        let sleepOn = store.sleepTimerMinutes > 0
        return [
            .init(icon: liked ? "heart.fill" : "heart",
                  label: liked ? PMString("ext.tv.options.loved") : PMString("ext.tv.options.love"), on: liked,
                  run: { if let id = store.currentSongID { store.toggleLiked(id) } }),
            .init(icon: "moon.zzz.fill",
                  label: sleepOn ? PMString("ext.tv.options.sleepActive", store.sleepTimerMinutes) : PMString("ext.tv.options.sleepTimer"), on: sleepOn,
                  run: { store.cycleSleepTimer() }),
        ]
    }

    var body: some View {
        let np = store.nowPlaying
        ZStack {
            TVAmbientBackdrop(tint: np.tint, tint2: np.tint2, strength: 0.5)
            TVColor.bg.opacity(0.52).ignoresSafeArea()

            VStack {
                HStack(spacing: 28) {
                    TVArtworkView(coverKey: np.albumID, artist: np.artist, album: np.album,
                                  songID: np.songID, coverRef: np.coverRef,
                                  tint: np.tint, tint2: np.tint2, glyph: np.glyph, size: 140, radius: 14)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(np.title).font(.system(size: 36, weight: .bold)).foregroundStyle(TVColor.text)
                        Text(np.artist).font(.system(size: 22)).foregroundStyle(TVColor.textMuted)
                    }
                    Spacer()
                }
                .opacity(0.7)
                .padding(.horizontal, 100).padding(.top, 80)

                Spacer()

                VStack(alignment: .leading, spacing: 24) {
                    TVEyebrow(text: PMString("ext.tv.options.eyebrow"))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            ForEach(actions) { a in actionTile(a) }
                        }
                        .padding(.vertical, 14).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 100).padding(.bottom, 60)
                .background(
                    LinearGradient(colors: [.clear, TVColor.chrome],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
        }
        .onExitCommand { dismiss() }
        .onAppear { FullscreenPlayerEffectSync.shared.install() }
    }

    private func actionTile(_ a: Action) -> some View {
        // 不 dismiss:执行后菜单保留,用户能看到状态变化(喜欢/睡眠定时切换);按返回键关闭。
        TVFocusButton(radius: 16, scale: 1.08, lift: 8, action: { a.run() }) { focused in
            VStack(spacing: 14) {
                Image(systemName: a.icon).font(.system(size: 40, weight: .regular))
                    .foregroundStyle(focused ? TVColor.onBrand : (a.on ? TVColor.brand : TVColor.text))
                Text(a.label).font(.system(size: 18, weight: focused ? .bold : .medium))
                    .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
            }
            .frame(width: 150, height: 150)
            .background(focused ? AnyShapeStyle(TVColor.brand) : AnyShapeStyle(TVColor.surfaceStrong))
        }
    }
}

struct TVFullscreenEffectPicker: View {
    @Binding var selectedRawValue: String
    @Binding var lyricsMotionEnabled: Bool
    let onDismiss: () -> Void

    @FocusState private var focusedEffect: FullscreenPlayerEffect?
    @FocusState private var lyricsToggleFocused: Bool

    private var selectedEffect: FullscreenPlayerEffect {
        FullscreenPlayerEffect(rawValue: selectedRawValue) ?? .defaultValue
    }

    var body: some View {
        GeometryReader { _ in
            let columns = Array(repeating: GridItem(.flexible(), spacing: 18), count: 4)
            ZStack {
                Color.black.opacity(0.92).ignoresSafeArea()

                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(PMString("ext.tv.settings.immersive"))
                                .font(.system(size: 38, weight: .bold))
                                .foregroundStyle(TVColor.text)
                            Text("原生效果保持默认，另有 8 类动态场景可选")
                                .font(.system(size: 17))
                                .foregroundStyle(TVColor.textMuted)
                        }
                        Spacer()
                        Button {
                            lyricsMotionEnabled.toggle()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("歌词逐字动效", systemImage: lyricsMotionEnabled ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 19, weight: .semibold))
                                Text("换句时轻柔上移并淡入；关闭后歌词保持静态")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.58))
                            }
                            .foregroundStyle(lyricsMotionEnabled ? ImmersiveStagePalette.accent200 : .white.opacity(0.82))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 13)
                            .background(.white.opacity(lyricsToggleFocused ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 14))
                            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.20), lineWidth: 1) }
                            .tvFocusRing(lyricsToggleFocused, radius: 14, accent: .white, scale: 1.04, lift: 5)
                        }
                        .buttonStyle(TVBareButtonStyle())
                        .focused($lyricsToggleFocused)
                        .focusEffectDisabled()
                    }

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(FullscreenEffectCollection.allCases) { collection in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(collection.title)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(TVColor.textMuted)

                                    LazyVGrid(columns: columns, spacing: 18) {
                                        ForEach(collection.effects) { candidate in
                                            effectChoice(candidate)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 70)
                .padding(.vertical, 46)
            }
        }
        .focusSection()
        .onAppear { focusedEffect = selectedEffect }
        .accessibilityAddTraits(.isModal)
    }

    private func effectChoice(_ candidate: FullscreenPlayerEffect) -> some View {
        let focused = focusedEffect == candidate
        let selected = selectedEffect == candidate
        return Button {
            selectedRawValue = candidate.rawValue
            FullscreenPlayerEffectSync.shared.select(candidate)
            onDismiss()
        } label: {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: candidate.symbolName)
                    .font(.system(size: 24, weight: .bold))
                    .frame(width: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.tvTitle)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Text(candidate.fallbackSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(2)
                    Label(candidate.motionDescription, systemImage: "waveform.path")
                        .font(.system(size: 12))
                        .foregroundStyle(ImmersiveStagePalette.accent200.opacity(0.84))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? ImmersiveStagePalette.accent200 : TVColor.text)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .background(.white.opacity(focused ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? ImmersiveStagePalette.accent300 : .white.opacity(0.20), lineWidth: selected ? 2 : 1)
            }
            .tvFocusRing(focused, radius: 14, accent: .white, scale: 1.04, lift: 6)
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($focusedEffect, equals: candidate)
        .focusEffectDisabled()
    }
}
#endif
