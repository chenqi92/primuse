import SwiftUI
import PrimuseKit

/// 首页「情景推荐专辑」:按此刻的情景(时段、星期、节日、刚才在听什么)挑一整张专辑,
/// 标题和理由跟着情景走 ——「通勤路上」「周末午后」「睡前」「今晚听」。
///
/// 推荐本身由 `AlbumRecommendationService` 在后台算好(整库遍历不进主线程,候选
/// 索引最多五分钟重建一次),这里只读结果。整张播放按碟号/轨号排队,「换一张」在
/// 这个情景的几张备选之间轮换,长按可以下一张播放、加入队列、不再推荐、前往专辑。
/// 首页编辑里调成多张时横着滑,「换一批」整批往后换。
struct HomeAlbumPickSection: View {
    /// 一次摆几张(首页编辑里调,1–10)。
    var count = 1

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.pmHeightClass) private var heightClass
    @State private var openedAlbum: Album?

    private var service: AlbumRecommendationService { .shared }

    private var coverSide: CGFloat { heightClass.value(124, compact: 96) }

    /// 多张时每张卡片的宽度:露出下一张的一角,提示还能往后滑;大屏不拉得太宽。
    private static let carouselCardMaxWidth: CGFloat = 400

    var body: some View {
        // 按这里的张数取,不等服务那边记下新张数:调张数的那一刻就照新的摆。
        let all = service.picks
        let picks = AlbumPickBatchPolicy.indices(start: service.selectedIndex, count: count, total: all.count)
            .map { all[$0] }
        let shown = picks.compactMap { pick in
            library.visibleAlbum(id: pick.albumID).map { ShownPick(pick: pick, album: $0) }
        }
        Group {
            if let first = shown.first, let moment = service.moment {
                VStack(alignment: .leading, spacing: 10) {
                    header(moment, showsAnotherBatch: count > 1, canShowAnotherBatch: all.count > count)
                    if count > 1 {
                        carousel(shown)
                    } else {
                        card(first.pick, album: first.album)
                            .padding(.horizontal, 16)
                            .id(first.pick.albumID)
                            .transition(.opacity)
                    }
                }
            } else if service.recommendations == nil, !library.visibleAlbums.isEmpty {
                placeholder
            }
        }
        .pmAnimation(.contentAppear, value: shown.map(\.id))
        .task(id: library.searchRevision) {
            service.setVisibleCount(count)
            service.refresh(library: library)
        }
        .onChange(of: count) { _, count in
            service.setVisibleCount(count)
            service.refresh(library: library)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { service.refresh(library: library) }
        }
        .navigationDestination(item: $openedAlbum) { album in
            AlbumDetailView(album: album)
        }
    }

    private func header(_ moment: ListeningMoment, showsAnotherBatch: Bool, canShowAnotherBatch: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(moment.title)
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.albumPick.title")
            Spacer(minLength: 8)
            if showsAnotherBatch {
                Button {
                    pmWithAnimation(.contentAppear) { service.showAnotherBatch() }
                } label: {
                    Label("album_pick_another_batch", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(!canShowAnotherBatch)
                .accessibilityIdentifier("home.albumPick.anotherBatch")
            }
        }
        .padding(.horizontal, 20)
    }

    private struct ShownPick: Identifiable {
        let pick: AlbumRecommendation
        let album: Album
        var id: String { pick.albumID }
    }

    /// 多张:整张卡片横着滑,一次停一张。
    private func carousel(_ shown: [ShownPick]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(shown) { entry in
                    card(entry.pick, album: entry.album, inCarousel: true)
                        .containerRelativeFrame(.horizontal) { width, _ in
                            min(width - 48, Self.carouselCardMaxWidth)
                        }
                        .transition(.opacity)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
    }

    private func card(_ pick: AlbumRecommendation, album: Album, inCarousel: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 14) {
            NavigationLink(value: album) {
                AlbumArtworkView(album: album, size: coverSide, cornerRadius: 14)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
            }
            .buttonStyle(.pmPressable)
            .mediaZoomSource(.album, id: album.id)
            .accessibilityLabel(Text(pick.title))

            VStack(alignment: .leading, spacing: 3) {
                NavigationLink(value: album) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pick.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(inCarousel ? 1 : 2)
                        if !pick.artistName.isEmpty {
                            Text(pick.artistName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(pick.detailLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Label(pick.reason.text, systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .lineLimit(inCarousel ? 1 : 2)
                    .padding(.top, 2)

                Spacer(minLength: 8)

                // 多张时「换一批」在标题旁边,卡片上只留播放。
                if inCarousel {
                    playButton(pick)
                } else {
                    actions(pick)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: coverSide + 28, alignment: .leading)
        .background(cardSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contextMenu { menu(pick, album: album) }
    }

    private func actions(_ pick: AlbumRecommendation) -> some View {
        // 窄屏放不下两个带字的按钮时,「换一张」只留图标。
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                playButton(pick)
                anotherButton(iconOnly: false)
            }
            HStack(spacing: 8) {
                playButton(pick)
                anotherButton(iconOnly: true)
            }
        }
    }

    private func playButton(_ pick: AlbumRecommendation) -> some View {
        Button {
            play(pick)
        } label: {
            Label("album_pick_play", systemImage: "play.fill")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .accessibilityIdentifier("home.albumPick.play")
    }

    private func anotherButton(iconOnly: Bool) -> some View {
        Button {
            pmWithAnimation(.contentAppear) { service.showAnother() }
        } label: {
            if iconOnly {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
            } else {
                Label("album_pick_another", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(!service.canShowAnother)
        .accessibilityLabel(Text("album_pick_another"))
        .accessibilityIdentifier("home.albumPick.another")
    }

    @ViewBuilder
    private func menu(_ pick: AlbumRecommendation, album: Album) -> some View {
        Button {
            play(pick)
        } label: {
            Label("album_pick_play", systemImage: "play.fill")
        }
        Button {
            let songs = service.songsInTrackOrder(albumID: pick.albumID, library: library)
            player.insertNextInQueue(songs)
        } label: {
            Label("album_pick_play_next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            let songs = service.songsInTrackOrder(albumID: pick.albumID, library: library)
            player.appendToQueue(songs)
        } label: {
            Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        Button {
            openedAlbum = album
        } label: {
            Label("go_to_album", systemImage: "square.stack")
        }
        Divider()
        Button(role: .destructive) {
            pmWithAnimation(.contentAppear) { service.dismiss(albumID: pick.albumID) }
        } label: {
            Label("album_pick_dismiss", systemImage: "hand.thumbsdown")
        }
    }

    /// 整张播放:按碟号、轨号的原曲序排队,随机先关掉。
    private func play(_ pick: AlbumRecommendation) {
        let songs = service.songsInTrackOrder(albumID: pick.albumID, library: library)
        guard !songs.isEmpty else { return }
        player.shuffleEnabled = false
        Task { await player.play(queue: songs, startingAt: 0) }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(cardSurface)
            .frame(height: coverSide + 28)
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .accessibilityHidden(true)
    }

    private var cardSurface: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}
