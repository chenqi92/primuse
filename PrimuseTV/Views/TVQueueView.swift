#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 播放队列覆层 — 左侧大封面,右侧「接下来」列表(对应 TVQueueArtboard)。
struct TVQueueView: View {
    private struct UpNextRow: Identifiable {
        let id: QueueRowIdentity
        let song: TVSong
    }

    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var upNextRows: [UpNextRow] {
        QueueRowIdentity.makeVisible(for: store.queueUpNextIDs) { store.song($0) != nil }
            .compactMap { identity in
                store.song(identity.songID).map { UpNextRow(id: identity, song: $0) }
            }
    }

    var body: some View {
        let np = store.nowPlaying
        let colors = store.nowPlayingPresentationColors
        let rows = upNextRows
        ZStack {
            TVAmbientBackdrop(tint: colors.primary, tint2: colors.secondary, strength: 0.55)
            TVColor.bg.opacity(0.48).ignoresSafeArea()

            HStack(alignment: .center, spacing: 80) {
                VStack(alignment: .leading, spacing: 0) {
                    TVEyebrow(text: PMString("ext.tv.queue.nowPlaying")).padding(.bottom, 20)
                    TVArtworkView(coverKey: np.albumID, artist: np.artist, album: np.album,
                                  songID: np.songID, coverRef: np.coverRef,
                                  tint: colors.primary, tint2: colors.secondary,
                                  glyph: np.glyph, size: 340, radius: 18)
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                    Text(np.title).font(.system(size: 42, weight: .bold)).tracking(-0.6)
                        .foregroundStyle(TVColor.text).padding(.top, 26)
                    Text(np.artist).font(.system(size: 22)).foregroundStyle(TVColor.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 0) {
                    TVEyebrow(text: PMString("ext.tv.queue.upNext", rows.count)).padding(.bottom, 20)
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { displayIndex, row in
                                queueRow(
                                    displayIndex: displayIndex,
                                    queueOffset: row.id.position,
                                    song: row.song
                                )
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

    private func queueRow(displayIndex: Int, queueOffset: Int, song: TVSong) -> some View {
        let album = store.albumOf(song)
        return TVFocusButton(radius: TVRadius.card, scale: 1.01, lift: 0,
                             action: { store.playQueueItem(at: queueOffset); dismiss() }) { focused in
            HStack(spacing: 18) {
                Text("\(displayIndex + 1)").font(.system(size: 20, design: .monospaced))
                    .foregroundStyle(TVColor.textGhost).frame(width: 28)
                TVArtworkView(coverKey: album?.id ?? "", artist: album?.artist ?? song.artist,
                              album: album?.title ?? "", songID: song.id, coverRef: song.coverRef,
                              tint: album?.tint ?? TVColor.brand,
                              tint2: album?.tint2 ?? .black, glyph: album?.glyph ?? "♪", size: 56, radius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(TVColor.text).lineLimit(1)
                    Text(song.artist).font(.system(size: 16))
                        .foregroundStyle(TVColor.textFaint).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(TVFmt.time(song.duration)).font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(TVColor.textFaint)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : TVColor.card)
        }
    }
}
#endif
