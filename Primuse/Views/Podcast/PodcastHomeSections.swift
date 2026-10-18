import PrimuseKit
import SwiftUI

/// 首页等处推进播客页面用的值。挂了 `podcastRouteDestinations()` 的导航栈都认。
enum PodcastRoute: Hashable {
    case show(String)
    case episode(String)
}

extension View {
    func podcastRouteDestinations() -> some View {
        navigationDestination(for: PodcastRoute.self) { route in
            switch route {
            case .show(let id):
                PodcastShowDetailView(source: .show(id))
            case .episode(let id):
                PodcastEpisodeDetailView(episodeID: id)
            }
        }
    }
}

/// 首页「播客更新」:订阅里最近出的、还没听完的单集,横排卡片。
/// 一档都没订时是一张邀请卡,点了进播客页去发现。
struct HomePodcastsSection: View {
    var limit = 10
    var openSpace: (ListeningSpace) -> Void

    private var store: PodcastStore { PodcastStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.isLoaded, store.shows.isEmpty {
                PodcastInviteCard { openSpace(.podcast) }
                    .padding(.horizontal, 16)
            } else {
                HomeSpaceSectionHeader(
                    titleKey: "home_section_podcasts",
                    actionKey: "home_podcasts_open_all",
                    action: { openSpace(.podcast) }
                )
                let latest = store.latestEpisodes(limit: max(limit, 1))
                if latest.isEmpty {
                    Text(store.isLoaded ? "podcast_all_caught_up" : "podcast_refreshing")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(Array(latest.enumerated()), id: \.element.id) { index, episode in
                                HomePodcastEpisodeCard(
                                    episode: episode,
                                    show: store.show(id: episode.showID),
                                    continuing: Array(latest.dropFirst(index + 1))
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .pmStopsAtVerticalBar()
                }
            }
        }
        .task { store.loadIfNeeded() }
    }
}

/// 首页上的一集:封面角上一个播放键,点卡片进单集页。
/// 封面和上下几排的专辑、书一样大(`HomeCoverCardMetrics`)。
struct HomePodcastEpisodeCard: View {
    let episode: PodcastEpisode
    let show: PodcastShow?
    var continuing: [PodcastEpisode] = []

    @Environment(\.homeCoverCardWidth) private var width

    private var tint: Color { ListeningSpace.podcast.tint }

    /// 播放键跟着封面缩放,手机横屏的小卡上也不小于 30。
    private var playButtonSize: CGFloat {
        min(36, max(30, (width * 0.23).rounded()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // 封面和文字各是一个链接,播放键压在封面角上、不在链接里,点它只播不跳页。
            NavigationLink(value: PodcastRoute.episode(episode.id)) {
                PodcastArtwork(episode: episode, show: show, size: width, cornerRadius: HomeCoverCardMetrics.cornerRadius)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottomTrailing) {
                PodcastPlayButton(episode: episode, continuing: continuing, size: playButtonSize)
                    .background(.regularMaterial, in: Circle())
                    .padding(8)
            }
            NavigationLink(value: PodcastRoute.episode(episode.id)) {
                VStack(alignment: .leading, spacing: 3) {
                    if let show {
                        Text(show.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                    }
                    Text(episode.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let meta {
                        Text(meta)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: width, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: width, alignment: .leading)
        .podcastEpisodeContextMenu(episode, continuing: continuing)
    }

    private var meta: String? {
        let parts = [PodcastFormat.date(episode.publishedAt), PodcastFormat.duration(episode.duration)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 还没订任何播客时首页上的那张卡。
struct PodcastInviteCard: View {
    var action: () -> Void
    private var tint: Color { ListeningSpace.podcast.tint }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: ListeningSpace.podcast.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("podcast_invite_title")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("podcast_invite_message")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.pmPressable)
        .accessibilityIdentifier("podcast.home.invite")
    }
}

/// 首页筛到「播客」那一面:只有播客主页的正文,和有声书、电台那两面一样不摆发现键与「…」(#320)。
/// 发现、刷新、调整区块、播客设置在完整的播客页里,从「我的节目」右上角的「管理」进去(电台那一面同样如此)。
struct PodcastHomeFace: View {
    let navigation: PodcastNavigationModel
    let onManage: () -> Void

    var body: some View {
        PodcastLibraryContent(navigation: navigation, onManageShows: onManage)
    }
}
