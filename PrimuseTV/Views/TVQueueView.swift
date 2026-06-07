#if os(tvOS)
import SwiftUI

/// tvOS 播放队列覆层 — 左侧大封面,右侧「接下来」列表(对应 TVQueueArtboard)。
struct TVQueueView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var upNext: [TVSong] { store.queueUpNextIDs.compactMap(store.song) }

    var body: some View {
        let np = store.nowPlaying
        ZStack {
            TVAmbientBackdrop(tint: np.tint, tint2: np.tint2, strength: 0.55)
            Color.black.opacity(0.5).ignoresSafeArea()

            HStack(alignment: .center, spacing: 80) {
                VStack(alignment: .leading, spacing: 0) {
                    TVEyebrow(text: TVL("正在播放", "Now Playing")).padding(.bottom, 20)
                    TVArtworkView(coverKey: np.albumID, artist: np.artist, album: np.album,
                                  tint: np.tint, tint2: np.tint2, glyph: np.glyph, size: 340, radius: 18)
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                    Text(np.title).font(.system(size: 42, weight: .bold)).tracking(-0.6)
                        .foregroundStyle(.white).padding(.top, 26)
                    Text(np.artist).font(.system(size: 22)).foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 0) {
                    TVEyebrow(text: TVL("接下来 · \(upNext.count) 首", "Up Next · \(upNext.count) songs")).padding(.bottom, 20)
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 10) {
                            ForEach(Array(upNext.enumerated()), id: \.offset) { idx, song in
                                queueRow(index: idx, song: song)
                            }
                        }
                        // 留出边距,否则选中行的左右描边会被竖向 ScrollView 的横向裁切切掉。
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 120).padding(.vertical, 80)
        }
        .onExitCommand { dismiss() }
    }

    private func queueRow(index idx: Int, song: TVSong) -> some View {
        let album = store.albumOf(song)
        return TVFocusButton(radius: TVRadius.card, scale: 1.01, lift: 0,
                             action: { store.playQueueItem(at: idx); dismiss() }) { focused in
            HStack(spacing: 18) {
                Text("\(idx + 1)").font(.system(size: 20, design: .monospaced))
                    .foregroundStyle(TVColor.textGhost).frame(width: 28)
                TVArtworkView(coverKey: album?.id ?? "", artist: album?.artist ?? song.artist,
                              album: album?.title ?? "", tint: album?.tint ?? TVColor.brand,
                              tint2: album?.tint2 ?? .black, glyph: album?.glyph ?? "♪", size: 56, radius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white).lineLimit(1)
                    Text(song.artist).font(.system(size: 16))
                        .foregroundStyle(TVColor.textFaint).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(TVFmt.time(song.duration)).font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(focused ? Color.white.opacity(0.12) : TVColor.card)
        }
    }
}
#endif
