#if os(tvOS)
import SwiftUI

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
                  label: liked ? "已喜欢" : "喜欢", on: liked,
                  run: { if let id = store.currentSongID { store.toggleLiked(id) } }),
            .init(icon: "moon.zzz.fill",
                  label: sleepOn ? "睡眠 \(store.sleepTimerMinutes) 分" : "睡眠定时", on: sleepOn,
                  run: { store.cycleSleepTimer() }),
        ]
    }

    var body: some View {
        let np = store.nowPlaying
        ZStack {
            TVAmbientBackdrop(tint: np.tint, tint2: np.tint2, strength: 0.5)
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack {
                HStack(spacing: 28) {
                    TVArtworkView(coverKey: np.albumID, artist: np.artist, album: np.album,
                                  tint: np.tint, tint2: np.tint2, glyph: np.glyph, size: 140, radius: 14)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(np.title).font(.system(size: 36, weight: .bold)).foregroundStyle(.white)
                        Text(np.artist).font(.system(size: 22)).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                }
                .opacity(0.7)
                .padding(.horizontal, 100).padding(.top, 80)

                Spacer()

                VStack(alignment: .leading, spacing: 24) {
                    TVEyebrow(text: "选项")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            ForEach(actions) { a in actionTile(a) }
                        }
                        .padding(.vertical, 14).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 100).padding(.bottom, 60)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
        }
        .onExitCommand { dismiss() }
    }

    private func actionTile(_ a: Action) -> some View {
        // 不 dismiss:执行后菜单保留,用户能看到状态变化(喜欢/睡眠定时切换);按返回键关闭。
        TVFocusButton(radius: 16, scale: 1.08, lift: 8, action: { a.run() }) { focused in
            VStack(spacing: 14) {
                Image(systemName: a.icon).font(.system(size: 40, weight: .regular))
                    .foregroundStyle(a.on ? TVColor.brand : (focused ? Color(hex: "#1f1c19") : .white))
                Text(a.label).font(.system(size: 18, weight: focused ? .bold : .medium))
                    .foregroundStyle(focused ? Color(hex: "#1f1c19") : .white)
            }
            .frame(width: 150, height: 150)
            .background(focused ? AnyShapeStyle(.white) : AnyShapeStyle(Color.white.opacity(0.12)))
        }
    }
}
#endif
