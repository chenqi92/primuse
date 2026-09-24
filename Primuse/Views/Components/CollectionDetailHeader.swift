#if os(iOS)
import PrimuseKit
import SwiftUI

/// 集合详情页(专辑、艺术家、歌单、智能歌单、风格)头图与操作行的功能契约。
///
/// 五种详情页只负责组装它 —— 标题、副标题、元信息、封面从哪来、操作行的几个动作 —— 头图怎么画
/// 交给 `CollectionDetailHeader`,它按界面皮肤的 `collectionDetail` 表面分派到具体画法。
/// 播放、随机、下载、加入快速访问的逻辑留在页面里,以闭包交进来;换一种画法不会碰到它们。
@MainActor
struct CollectionDetailHeaderModel {
    /// 封面从哪来。它同时决定头图的形态(浮在底色上的封面、铺满上半屏的海报、封面墙……)。
    enum Artwork {
        /// 专辑封面,浮在整页底色上。
        case album(Album)
        /// 艺术家人像,铺满上半屏的海报。
        case artistPoster(Artist)
        /// 歌单:封面够多时是一面封面墙,不够时是这张歌单封面。
        case playlistCover(Playlist, placeholderIcon: String)
        /// 智能歌单:封面够多时是一面封面墙,不够时是按类别着色、印着类别符号的色块。
        case generatedCover(symbol: String, isAI: Bool)
        /// 风格:几张代表封面叠成的马赛克。
        case genreMosaic(LibraryGenre)
    }

    /// 副标题(专辑的艺术家名)。给了 `destination` 就能点进艺术家页。
    struct Subtitle {
        let text: String
        let destination: Artist?
    }

    struct Action {
        let isEnabled: Bool
        let perform: () -> Void
    }

    /// 操作行最后那一颗。
    enum TrailingAction {
        /// 离线下载这一集合里的歌。
        case download(Action)
        /// 加入 / 移出快速访问。
        case quickAccessPin(LibraryPinReference)
    }

    /// 「随机 · 播放 ·(下载 / 快速访问)」。
    struct Actions {
        let shuffle: Action
        let play: Action
        /// 播放键上的字(「播放」「播放全部」);画成圆钮的播放键不写字。
        let playTitle: LocalizedStringKey
        let trailing: TrailingAction?
    }

    let title: String
    /// 标题旁的符号:「我喜欢」的心、智能歌单的类别。
    let titleSymbol: String?
    let subtitle: Subtitle?
    /// 元信息一行(流派 · 年份 · 格式、首数 · 总时长……,见 `CollectionDetailHeaderPolicy`)。
    let meta: String
    /// 头图下面的一段摘要(智能歌单的规则或描述)。
    let summary: String?
    let artwork: Artwork
    /// 封面墙从这些歌里取封面,按页面上看到的顺序。
    let songs: [Song]
    /// 正在播放的歌:它的封面在墙里时成为焦点。
    let nowPlaying: Song?
    let actions: Actions
    /// 排在头图里的评分(专辑、风格)。歌单与智能歌单的评分排在正文里,这里是 nil。
    let review: LibraryReviewSubject?

    init(
        title: String,
        titleSymbol: String? = nil,
        subtitle: Subtitle? = nil,
        meta: String,
        summary: String? = nil,
        artwork: Artwork,
        songs: [Song] = [],
        nowPlaying: Song? = nil,
        actions: Actions,
        review: LibraryReviewSubject? = nil
    ) {
        self.title = title
        self.titleSymbol = titleSymbol
        self.subtitle = subtitle
        self.meta = meta
        self.summary = summary
        self.artwork = artwork
        self.songs = songs
        self.nowPlaying = nowPlaying
        self.actions = actions
        self.review = review
    }
}

/// 集合详情页的头图与操作行。按界面皮肤的 `collectionDetail` 表面分派;现在只有经典实现。
struct CollectionDetailHeader: View {
    let model: CollectionDetailHeaderModel
    let insets: ImmersiveLibraryDetailInsets

    @Environment(\.skin) private var skin

    var body: some View {
        switch skin.skin.collectionDetail {
        case .classic:
            ClassicCollectionDetailHeader(model: model, insets: insets)
        }
    }
}

/// `CollectionDetail.classic`:两套外壳共用的 Apple Music 式头图 —— 整页封面取色,封面 / 海报 /
/// 封面墙压在上面,标题居中,下面一排「随机 · 播放 · 下载」。
///
/// 头图按「首屏高度」收放(`LibraryDetailHeroLayoutPolicy`),矮屏上操作行也整条露在底部遮挡上面;
/// 手机横屏封面挪到左边、标题与操作行排进右栏或压在墙面下沿。横竖切换只换排法,不换视图。
private struct ClassicCollectionDetailHeader: View {
    let model: CollectionDetailHeaderModel
    let insets: ImmersiveLibraryDetailInsets

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        switch model.artwork {
        case .album(let album):
            albumHero(album)
        case .artistPoster(let artist):
            artistHero(artist)
        case .playlistCover(let playlist, let placeholderIcon):
            playlistHero(playlist, placeholderIcon: placeholderIcon)
        case .generatedCover(let symbol, let isAI):
            generatedCoverHero(symbol: symbol, isAI: isAI)
        case .genreMosaic(let genre):
            genreHero(genre)
        }
    }

    // MARK: - 操作行

    /// 「随机 · 播放 · 下载」:播放居中最宽,两侧是圆形玻璃键。窄屏或无障碍字号下胶囊独占一行。
    /// 手机横屏排在封面右栏时靠前对齐。
    private func pillActionRow(
        _ arrangement: LibraryDetailActionRowArrangement,
        alignment: Alignment = .center
    ) -> some View {
        let actions = model.actions
        return LibraryDetailActionRow(arrangement: arrangement, alignment: alignment) {
            LibraryDetailCircleButton(
                systemImage: "shuffle",
                label: "shuffle",
                disabled: !actions.shuffle.isEnabled,
                action: actions.shuffle.perform
            )
            LibraryDetailPlayPill(
                title: actions.playTitle,
                disabled: !actions.play.isEnabled,
                action: actions.play.perform
            )
            .frame(maxWidth: arrangement.primaryMaxWidth)
            .libraryDetailPrimaryAction()
            if let trailing = actions.trailing {
                trailingButton(trailing, size: 54)
            }
        }
    }

    @ViewBuilder
    private func trailingButton(_ trailing: CollectionDetailHeaderModel.TrailingAction, size: CGFloat) -> some View {
        switch trailing {
        case .download(let download):
            LibraryDetailCircleButton(
                systemImage: "arrow.down",
                label: "offline_download",
                size: size,
                disabled: !download.isEnabled,
                action: download.perform
            )
        case .quickAccessPin(let pin):
            QuickAccessPinCircleButton(pin: pin, size: size)
        }
    }

    // MARK: - 专辑

    /// 封面浮在整页底色上,标题 / 艺术家 / 信息居中,下面一排操作与评分。
    private func albumHero(_ album: Album) -> some View {
        let hero = insets.hero
        let compact = hero.isCompactHeight
        let tier = hero.titleTier
        // 无障碍字号下横排放不下, 一律回到竖排居中。
        let stacksIdentity = hero.stacksArtworkHeader(accessibilityType: dynamicTypeSize.isAccessibilitySize)
        let actionSpacing = compact ? 14 : CGFloat(LibraryDetailHeroLayoutPolicy.albumIdentityToActions(tier))
        let headerLayout = hero.artworkHeaderLayout(
            hero.album,
            actionsSpacing: actionSpacing,
            stacksVertically: stacksIdentity
        )

        return VStack(spacing: actionSpacing) {
            headerLayout {
                LibraryDetailArtworkSlot { size in
                    albumCover(album, side: size.width)
                }
                .libraryDetailHeroMotion(.artwork)

                albumIdentityText(centered: stacksIdentity, tier: tier)

                pillActionRow(hero.actionRow, alignment: stacksIdentity ? .center : .leading)
            }
            .frame(maxWidth: .infinity)

            if let review = model.review {
                LibraryReviewSection(subject: review, compact: true, onArtwork: true)
            }
        }
        .frame(maxWidth: hero.bodyMaxWidth.map { CGFloat($0) })
        // 底色铺满整幅屏幕, 文字与按钮按侧留在安全区内 —— 横屏两侧安全区不一定相等。
        .padding(.leading, insets.leading + 20)
        .padding(.trailing, insets.trailing + 20)
        .padding(.top, insets.top + (compact ? 12 : 16))
        .padding(.bottom, compact ? 12 : 18)
        .frame(maxWidth: .infinity)
    }

    private func albumCover(_ album: Album, side: CGFloat) -> some View {
        AlbumArtworkView(
            album: album,
            size: side,
            cornerRadius: side > 140 ? 14 : 10,
            presentationRole: .animatedHero
        )
        .shadow(color: .black.opacity(0.32), radius: 24, y: 14)
        .accessibilityHidden(true)
    }

    private func albumIdentityText(centered: Bool, tier: LibraryDetailTitleTier) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 4) {
            Text(model.title)
                .font(tier == .regular ? .title2.weight(.heavy) : .title3.weight(.heavy))
                .foregroundStyle(.white)
                .lineLimit(centered ? LibraryDetailHeroLayoutPolicy.titleLineLimit(tier) : LibraryDetailHeroLayoutPolicy.compactTitleLineLimit)
                .minimumScaleFactor(centered ? 1 : 0.8)
                .fixedSize(horizontal: false, vertical: true)
                .libraryDetailHeroTitle()

            if let subtitle = model.subtitle {
                subtitleLink(subtitle, tier: tier)
            }

            if !model.meta.isEmpty {
                Text(verbatim: model.meta)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.top, 2)
            }
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    /// 艺术家名可点进艺术家页。专辑页也会从播放页的 sheet 里打开,那个导航栈没登记
    /// `Artist` 目的地,所以这里用视图目的地而不是 value 链接。
    @ViewBuilder
    private func subtitleLink(
        _ subtitle: CollectionDetailHeaderModel.Subtitle,
        tier: LibraryDetailTitleTier
    ) -> some View {
        let name = Text(subtitle.text)
            .font(tier == .regular ? .title3.weight(.semibold) : .headline)
            .foregroundStyle(.white.opacity(0.9))
        if let artist = subtitle.destination {
            NavigationLink {
                ArtistDetailView(artist: artist)
            } label: {
                name
            }
            .buttonStyle(.plain)
        } else {
            name
        }
    }

    // MARK: - 艺术家

    /// 人像海报铺满上半屏,向下化进封面色;名字居中压在渐隐段上,下面一排「随机 · 播放 · 快捷收藏」。
    ///
    /// 手机横屏首屏只有两百点上下:名字靠前、按钮靠后排成一行压在海报下沿(Apple Music 横屏的做法),
    /// 海报按首屏收(最高 230),按钮整排露在底部遮挡上面。
    /// 竖屏海报高度由 `LibraryDetailHeroLayoutPolicy` 按首屏定:Pro 这类机型仍是 440,
    /// SE、折叠屏外屏这类矮屏收小,按钮始终整排露在底部遮挡上面。横竖切换只换排法。
    private func artistHero(_ artist: Artist) -> some View {
        let hero = insets.hero
        let compact = hero.isCompactHeight
        let reducedTitle = compact || hero.titleTier == .reduced
        let posterHeight: CGFloat = insets.top + CGFloat(hero.artistPosterHeight)
        let circleSize: CGFloat = compact ? CGFloat(LibraryDetailHeroLayoutPolicy.Compact.artistCircle) : 56
        let blockLayout = compact
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 16))
            : AnyLayout(VStackLayout(spacing: 10))
        let actions = model.actions

        return ZStack(alignment: .bottom) {
            GeometryReader { geometry in
                ArtistArtworkView(
                    artist: artist,
                    size: max(geometry.size.width, geometry.size.height),
                    cornerRadius: 0
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
            .frame(height: posterHeight)
            // 下半段渐隐成透明,底下会呼吸的整页底色透上来,看不出海报在哪儿结束。
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.46),
                        .init(color: .black.opacity(0.18), location: 0.8),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay {
                // 顶部压一点暗让系统返回键读得清。
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.22), location: 0),
                        .init(color: .clear, location: 0.2),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            // iOS 26 起海报延伸到玻璃导航区与屏幕两侧。
            .libraryDetailBackgroundExtension()
            // 下拉时海报往下拉长、上滚时半速跟随;名字与按钮照常随正文走。
            .libraryDetailHeroMotion(.poster)
            .accessibilityHidden(true)

            blockLayout {
                VStack(alignment: compact ? .leading : .center, spacing: compact ? CGFloat(LibraryDetailHeroLayoutPolicy.Compact.artistNameToSummary) : 10) {
                    Text(verbatim: model.title)
                        .font(reducedTitle ? .title.weight(.heavy) : .largeTitle.weight(.heavy))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(compact ? .leading : .center)
                        .lineLimit(compact ? 1 : 2)
                        .minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.22), radius: 12, y: 2)
                        .libraryDetailHeroTitle()

                    Text(verbatim: model.meta)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(compact ? .leading : .center)
                        .lineLimit(compact ? 1 : nil)
                }
                .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)

                HStack(spacing: compact ? 16 : 24) {
                    LibraryDetailCircleButton(
                        systemImage: "shuffle",
                        label: "shuffle",
                        size: circleSize,
                        disabled: !actions.shuffle.isEnabled,
                        action: actions.shuffle.perform
                    )
                    LibraryDetailPlayCircle(
                        size: compact ? CGFloat(LibraryDetailHeroLayoutPolicy.Compact.artistPlayCircle) : 80,
                        disabled: !actions.play.isEnabled,
                        action: actions.play.perform
                    )
                    // 与随机键同一尺寸,三颗键左右对称。
                    if let trailing = actions.trailing {
                        trailingButton(trailing, size: circleSize)
                    }
                }
                .fixedSize()
                .padding(.top, compact ? 0 : 8)
            }
            .frame(maxWidth: hero.bodyMaxWidth.map { CGFloat($0) })
            .padding(.leading, insets.leading + 24)
            .padding(.trailing, insets.trailing + 24)
            .padding(.bottom, compact ? 10 : 16)
        }
        .frame(maxWidth: .infinity)
        // 只裁下沿:下拉拉长的海报要能长到顶部之外。
        .libraryDetailClipBottomEdge()
    }

    // MARK: - 歌单

    /// 头图 + 操作行。封面墙自己带标题块;单封面时标题、信息由这里画。
    /// 墙高与单封面边长都按首屏定(`LibraryDetailHeroLayoutPolicy`),矮屏上操作行也整条露出来。
    /// 手机横屏首屏只有两百点上下,操作行并进头图:封面墙上与标题排成一行压在墙面下沿,
    /// 单封面时排进封面右栏。
    private func playlistHero(_ playlist: Playlist, placeholderIcon: String) -> some View {
        let hero = insets.hero
        let compact = hero.isCompactHeight
        return VStack(spacing: compact ? 12 : 18) {
            CollectionCoverWallHeader(
                title: model.title,
                subtitle: model.meta,
                titleSymbol: model.titleSymbol,
                songs: model.songs,
                nowPlaying: model.nowPlaying,
                topInset: insets.top,
                wallHeight: CGFloat(hero.playlistWallHeight),
                leadingInset: insets.leading,
                trailingInset: insets.trailing,
                overlayActions: compact ? AnyView(pillActionRow(.singleRow)) : nil
            ) {
                playlistSingleCover(playlist, placeholderIcon: placeholderIcon, includesActions: compact)
            }

            if !compact {
                pillActionRow(hero.actionRow)
                    .frame(maxWidth: hero.bodyMaxWidth.map { CGFloat($0) })
                    .padding(.leading, insets.leading + 20)
                    .padding(.trailing, insets.trailing + 20)
            }
        }
        .padding(.bottom, compact ? 8 : 14)
        .frame(maxWidth: .infinity)
    }

    /// 封面不够铺一面墙时的头图,版式与专辑页一致:封面浮在整页底色上,标题与信息居中。
    /// 手机横屏封面挪到左边、与右栏齐高,标题与操作行排进右栏(`includesActions`)。
    private func playlistSingleCover(
        _ playlist: Playlist,
        placeholderIcon: String,
        includesActions: Bool
    ) -> some View {
        let hero = insets.hero
        let compact = hero.isCompactHeight
        let tier = hero.titleTier
        let stacks = hero.stacksArtworkHeader(accessibilityType: dynamicTypeSize.isAccessibilitySize)
        let headerLayout = hero.artworkHeaderLayout(
            hero.playlistCover,
            actionsSpacing: 18,
            stacksVertically: stacks
        )

        return headerLayout {
            LibraryDetailArtworkSlot { size in
                PlaylistArtworkView(
                    playlist: playlist,
                    size: size.width,
                    cornerRadius: 14,
                    placeholderIcon: placeholderIcon
                )
                .shadow(color: .black.opacity(0.32), radius: 24, y: 14)
            }
            .libraryDetailHeroMotion(.artwork)
            .accessibilityHidden(true)

            VStack(alignment: stacks ? .center : .leading, spacing: 5) {
                HStack(spacing: 8) {
                    if let titleSymbol = model.titleSymbol {
                        Image(systemName: titleSymbol)
                            .font(tier == .regular ? .title3.weight(.semibold) : .headline)
                            .foregroundStyle(.pink)
                            .accessibilityHidden(true)
                    }
                    Text(model.title)
                        .font(tier == .regular ? .title2.weight(.heavy) : .title3.weight(.heavy))
                        .foregroundStyle(.white)
                        .lineLimit(stacks ? LibraryDetailHeroLayoutPolicy.titleLineLimit(tier) : LibraryDetailHeroLayoutPolicy.compactTitleLineLimit)
                        .minimumScaleFactor(stacks ? 1 : 0.8)
                        .libraryDetailHeroTitle()
                }
                Text(verbatim: model.meta)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .multilineTextAlignment(stacks ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: stacks ? .center : .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if includesActions {
                pillActionRow(.singleRow, alignment: stacks ? .center : .leading)
            }
        }
        .frame(maxWidth: hero.bodyMaxWidth.map { CGFloat($0) })
        .padding(.leading, insets.leading + 20)
        .padding(.trailing, insets.trailing + 20)
        .padding(.top, insets.top + (compact ? 12 : 16))
        .frame(maxWidth: .infinity)
    }

    // MARK: - 智能歌单

    /// 骨架与普通歌单一致:封面够多时是封面墙,不够时是按类别着色的色块;下面是规则 / 描述摘要
    /// 与操作行。手机横屏首屏只有两百点上下:操作行并进头图(墙面下沿 / 封面右栏),摘要排到头图下面。
    private func generatedCoverHero(symbol: String, isAI: Bool) -> some View {
        let hero = insets.hero
        let compact = hero.isCompactHeight
        let summaryLines = compact ? 2 : LibraryDetailHeroLayoutPolicy.smartSummaryLineLimit(hero.titleTier)
        return VStack(spacing: compact ? 10 : 14) {
            CollectionCoverWallHeader(
                title: model.title,
                subtitle: model.meta,
                titleSymbol: model.titleSymbol,
                songs: model.songs,
                nowPlaying: model.nowPlaying,
                topInset: insets.top,
                wallHeight: CGFloat(hero.smartPlaylistWallHeight),
                leadingInset: insets.leading,
                trailingInset: insets.trailing,
                overlayActions: compact ? AnyView(pillActionRow(.singleRow)) : nil
            ) {
                generatedSingleCover(symbol: symbol, isAI: isAI, includesActions: compact)
            }

            if let summary = model.summary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.66))
                    .multilineTextAlignment(.center)
                    .lineLimit(summaryLines)
                    .frame(maxWidth: hero.bodyMaxWidth.map { CGFloat($0) })
                    // 横屏与折叠屏上左右安全区不一定相等,按侧让开。
                    .padding(.leading, insets.leading + 28)
                    .padding(.trailing, insets.trailing + 28)
            }

            if !compact {
                pillActionRow(hero.actionRow)
                    .frame(maxWidth: hero.bodyMaxWidth.map { CGFloat($0) })
                    .padding(.leading, insets.leading + 20)
                    .padding(.trailing, insets.trailing + 20)
                    .padding(.top, 4)
            }
        }
        .padding(.bottom, compact ? 8 : 14)
        .frame(maxWidth: .infinity)
    }

    /// 封面不够铺一面墙时:渐变色块浮在整页底色上,标题与信息居中。
    /// 手机横屏色块挪到左边、与右栏齐高,标题与操作行排进右栏(`includesActions`)。
    private func generatedSingleCover(symbol: String, isAI: Bool, includesActions: Bool) -> some View {
        let hero = insets.hero
        let compact = hero.isCompactHeight
        let tier = hero.titleTier
        let stacks = hero.stacksArtworkHeader(accessibilityType: dynamicTypeSize.isAccessibilitySize)
        let headerLayout = hero.artworkHeaderLayout(
            hero.smartPlaylistCover,
            actionsSpacing: 18,
            stacksVertically: stacks
        )

        return headerLayout {
            LibraryDetailArtworkSlot { size in
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(
                            colors: isAI
                                ? [.pink.opacity(0.78), .orange.opacity(0.72)]
                                : [.purple.opacity(0.7), .blue.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    // 图标跟着色块的边长走:原来 200 配 64、横屏 112 配 42。
                    Image(systemName: symbol)
                        .font(.system(size: max(32, size.width * 0.32)))
                        .foregroundStyle(.white)
                }
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(0.3), radius: 22, y: 12)
            }
            .libraryDetailHeroMotion(.artwork)
            .accessibilityHidden(true)

            VStack(alignment: stacks ? .center : .leading, spacing: 5) {
                Text(model.title)
                    .font(tier == .regular ? .title2.weight(.heavy) : .title3.weight(.heavy))
                    .foregroundStyle(.white)
                    .lineLimit(stacks ? LibraryDetailHeroLayoutPolicy.titleLineLimit(tier) : LibraryDetailHeroLayoutPolicy.compactTitleLineLimit)
                    .minimumScaleFactor(stacks ? 1 : 0.8)
                    .libraryDetailHeroTitle()
                Text(verbatim: model.meta)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .multilineTextAlignment(stacks ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: stacks ? .center : .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if includesActions {
                pillActionRow(.singleRow, alignment: stacks ? .center : .leading)
            }
        }
        .frame(maxWidth: hero.bodyMaxWidth.map { CGFloat($0) })
        .padding(.leading, insets.leading + 20)
        .padding(.trailing, insets.trailing + 20)
        .padding(.top, insets.top + (compact ? 12 : 16))
        .frame(maxWidth: .infinity)
    }

    // MARK: - 风格

    /// 与专辑页同一套版式:代表封面的马赛克居中当「封面」,下面是名字、数量和一排「随机 · 播放」。
    /// 手机横屏马赛克挪到左边,名字与按钮排进右栏。马赛克按首屏收(`LibraryDetailHeroLayoutPolicy`)。
    private func genreHero(_ genre: LibraryGenre) -> some View {
        let hero = insets.hero
        let compact = hero.isCompactHeight
        let reducedTitle = compact || hero.titleTier == .reduced
        let aspect: CGFloat = 1.9 / 1.3
        let spacing: CGFloat = compact ? 12 : 20
        let headerLayout = hero.artworkHeaderLayout(
            hero.genreMosaic,
            aspectRatio: aspect,
            actionsSpacing: spacing,
            stacksVertically: false
        )

        return VStack(spacing: spacing) {
            headerLayout {
                LibraryDetailArtworkSlot { size in
                    GenreArtworkMosaic(genre: genre, artworkSize: size.height / 1.3)
                        .frame(width: size.width, height: size.height)
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 12)
                }
                .libraryDetailHeroMotion(.artwork)
                .accessibilityHidden(true)

                VStack(alignment: compact ? .leading : .center, spacing: 4) {
                    Text(verbatim: model.title)
                        .font(reducedTitle ? Font.title.weight(.heavy) : Font.largeTitle.weight(.heavy))
                        .foregroundStyle(.white)
                        .lineLimit(compact ? LibraryDetailHeroLayoutPolicy.compactTitleLineLimit : 2)
                        .minimumScaleFactor(0.8)
                        .libraryDetailHeroTitle()
                    Text(verbatim: model.meta)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.74))
                }
                .multilineTextAlignment(compact ? .leading : .center)
                .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
                .frame(maxWidth: compact ? nil : .infinity)

                pillActionRow(hero.actionRow, alignment: compact ? .leading : .center)
            }

            if let review = model.review {
                LibraryReviewSection(
                    subject: review,
                    compact: true,
                    onArtwork: true
                )
            }
        }
        .frame(maxWidth: hero.bodyMaxWidth.map { CGFloat($0) })
        .padding(.leading, insets.leading + 20)
        .padding(.trailing, insets.trailing + 20)
        .padding(.top, insets.top + (compact ? 12 : 24))
        .padding(.bottom, compact ? 12 : 18)
        .frame(maxWidth: .infinity)
    }
}
#endif
