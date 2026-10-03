#if os(macOS)
import PrimuseKit
import SwiftUI

/// Mac 首页的「播客更新」:订阅里最近出的单集。点卡片放这一集(正在放就暂停),
/// 「全部」切到侧栏的「播客」项。还没订阅时是一张去发现的卡片。
struct MacHomePodcastsStrip: View {
    @Environment(AudioPlayerService.self) private var player

    private var store: PodcastStore { PodcastStore.shared }
    private var tint: Color { ListeningSpace.podcast.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: PMSpace.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("home_section_podcasts")
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(PMColor.text)
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .primuseSelectSpokenWord, object: LibrarySection.podcasts)
                } label: {
                    HStack(spacing: 3) {
                        Text("home_section_view_all")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PMColor.brand)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if store.isLoaded, store.shows.isEmpty {
                PodcastInviteCard {
                    NotificationCenter.default.post(name: .primuseSelectSpokenWord, object: LibrarySection.podcasts)
                }
                .frame(maxWidth: 520, alignment: .leading)
            } else {
                let latest = store.latestEpisodes(limit: 16)
                if latest.isEmpty {
                    Text(store.isLoaded ? "podcast_all_caught_up" : "podcast_refreshing")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PMColor.textMuted)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: PMSpace.m16) {
                            ForEach(Array(latest.enumerated()), id: \.element.id) { index, episode in
                                tile(episode, continuing: Array(latest.dropFirst(index + 1)))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .pmAppearFade(.contentAppear)
        .task { store.loadIfNeeded() }
    }

    private func tile(_ episode: PodcastEpisode, continuing: [PodcastEpisode]) -> some View {
        let show = store.show(id: episode.showID)
        let isCurrent = player.currentSong?.id == episode.id
        return Button {
            if isCurrent {
                player.togglePlayPause()
            } else {
                PodcastPlaybackLauncher.play(episode, continuing: continuing, player: player) { _ in
                    NotificationCenter.default.post(name: .primuseSelectSpokenWord, object: LibrarySection.podcasts)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                PodcastArtwork(episode: episode, show: show, size: 132, cornerRadius: PMRadius.l14)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(tint, in: Circle())
                            .padding(7)
                    }
                if let show {
                    Text(verbatim: show.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                Text(verbatim: episode.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let date = PodcastFormat.date(episode.publishedAt) {
                    Text(verbatim: date)
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                }
            }
            .frame(width: 132, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pmHoverLift()
        .podcastEpisodeContextMenu(episode, continuing: continuing)
    }
}
#endif
